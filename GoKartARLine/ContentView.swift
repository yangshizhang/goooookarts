import SwiftUI
import UniformTypeIdentifiers
import ReplayKit

struct ContentView: View {
    @EnvironmentObject private var trackDataManager: TrackDataManager
    @EnvironmentObject private var locationManager: LocationManager
    @State private var settings = ARLineSettings()
    @State private var isImporting = false
    @State private var showingSettings = false
    @State private var showingTrackList = false
    @State private var arErrorMessage: String?
    @State private var isRecording = false

    var body: some View {
        ZStack {
            ARViewContainer(track: trackDataManager.selectedTrack, originCoordinate: locationManager.originCoordinate, fusedPose: locationManager.fusedPose, settings: settings)
                .ignoresSafeArea()
            VStack(spacing: 12) {
                topHUD
                Spacer()
                bottomControls
            }
            .padding()
        }
        .preferredColorScheme(.dark)
        .onAppear { locationManager.requestPermissionsAndStart(desiredAccuracy: settings.gpsDesiredAccuracy) }
        .onDisappear { locationManager.stopSensors() }
        .onReceive(locationManager.$fusedPose) { _ in locationManager.autoCalibrateIfNeeded(track: trackDataManager.selectedTrack) }
        .onReceive(NotificationCenter.default.publisher(for: .arSessionError)) { arErrorMessage = $0.object as? String }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.json, .xml], allowsMultipleSelection: false) { result in
            if case let .success(urls) = result, let url = urls.first { trackDataManager.importFile(from: url) }
        }
        .sheet(isPresented: $showingSettings) { SettingsView(settings: $settings) }
        .sheet(isPresented: $showingTrackList) { TrackListView() }
        .alert("提示", isPresented: Binding(get: { trackDataManager.errorMessage != nil || arErrorMessage != nil }, set: { _ in trackDataManager.errorMessage = nil; arErrorMessage = nil })) {
            Button("知道了", role: .cancel) {}
        } message: { Text(trackDataManager.errorMessage ?? arErrorMessage ?? "") }
    }

    private var topHUD: some View {
        VStack(spacing: 8) {
            Text(currentHint)
                .font(.system(size: 34, weight: .black, design: .rounded))
                .foregroundStyle(currentHintColor)
                .shadow(radius: 6)
            HStack(spacing: 16) {
                metricCard(title: "车速", value: speedText)
                metricCard(title: "刹车点", value: brakingDistanceText)
                metricCard(title: "GPS", value: gpsText)
            }
        }
    }

    private var bottomControls: some View {
        HStack(spacing: 10) {
            Button("导入") { isImporting = true }
            Button("赛道") { showingTrackList = true }
            Button("校准") { locationManager.manualCalibrate(using: trackDataManager.selectedTrack) }
            Button(isRecording ? "停止" : "录屏") { toggleRecording() }
            Button("截图") { NotificationCenter.default.post(name: .captureARStillImage, object: nil) }
            Button("设置") { showingSettings = true }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .background(.black.opacity(0.25), in: Capsule())
    }

    private func metricCard(title: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.white.opacity(0.72))
            Text(value).font(.headline.monospacedDigit()).foregroundStyle(.white)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 14))
    }


    private func toggleRecording() {
        isRecording ? stopScreenRecording() : startScreenRecording()
    }

    private func startScreenRecording() {
        let recorder = RPScreenRecorder.shared()
        guard recorder.isAvailable else { arErrorMessage = "当前设备不支持录屏"; return }
        recorder.startRecording { error in
            Task { @MainActor in
                if let error { arErrorMessage = "开始录屏失败：\(error.localizedDescription)" }
                else { isRecording = true }
            }
        }
    }

    private func stopScreenRecording() {
        RPScreenRecorder.shared().stopRecording { preview, error in
            Task { @MainActor in
                isRecording = false
                if let error { arErrorMessage = "停止录屏失败：\(error.localizedDescription)"; return }
                guard let preview else { return }
                UIApplication.shared.connectedScenes
                    .compactMap { $0 as? UIWindowScene }
                    .flatMap { $0.windows }
                    .first { $0.isKeyWindow }?
                    .rootViewController?
                    .present(preview, animated: true)
            }
        }
    }
    private var speedText: String {
        let mps = locationManager.fusedPose?.speed ?? 0
        return settings.metricUnits ? "\(Int(mps * 3.6)) km/h" : "\(Int(mps * 2.23694)) mph"
    }

    private var gpsText: String { locationManager.fusedPose.map { "±\(Int($0.horizontalAccuracy))m" } ?? "--" }
    private var currentHint: String { nearestTrackPoint()?.color.drivingHint ?? "请导入赛道" }
    private var currentHintColor: Color {
        switch nearestTrackPoint()?.color {
        case .green: return .green
        case .orange: return .orange
        case .red: return .red
        case nil: return .white
        }
    }

    private var brakingDistanceText: String {
        guard let pose = locationManager.fusedPose, let track = trackDataManager.selectedTrack else { return "--" }
        let nearest = track.points.filter { $0.color == .red }.map { GeoConverter.distanceMeters(from: pose.coordinate, to: $0.coordinate) }.min() ?? 0
        return "\(Int(nearest)) m"
    }

    private func nearestTrackPoint() -> TrackPoint? {
        guard let pose = locationManager.fusedPose, let track = trackDataManager.selectedTrack else { return nil }
        return track.points.min { GeoConverter.distanceMeters(from: pose.coordinate, to: $0.coordinate) < GeoConverter.distanceMeters(from: pose.coordinate, to: $1.coordinate) }
    }
}

private struct TrackListView: View {
    @EnvironmentObject private var manager: TrackDataManager
    @Environment(\.dismiss) private var dismiss
    @State private var renamingTrack: TrackData?
    @State private var newName = ""

    var body: some View {
        NavigationStack {
            List {
                ForEach(manager.tracks) { track in
                    Button {
                        manager.selectedTrackID = track.id
                        dismiss()
                    } label: {
                        VStack(alignment: .leading) {
                            Text(track.trackName).font(.headline)
                            Text("\(Int(track.trackLength))m · \(track.cornerCount)弯 · \(track.points.count)点").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions { Button("重命名") { renamingTrack = track; newName = track.trackName } }
                }
                .onDelete(perform: manager.deleteTracks)
            }
            .navigationTitle("已导入赛道")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } } }
            .alert("重命名赛道", isPresented: Binding(get: { renamingTrack != nil }, set: { if !$0 { renamingTrack = nil } })) {
                TextField("赛道名称", text: $newName)
                Button("保存") { if let renamingTrack { manager.rename(track: renamingTrack, to: newName) }; renamingTrack = nil }
                Button("取消", role: .cancel) { renamingTrack = nil }
            }
        }
    }
}

