import SwiftUI
import UniformTypeIdentifiers
import ReplayKit

struct ContentView: View {
    @EnvironmentObject private var trackDataManager: TrackDataManager
    @EnvironmentObject private var locationManager: LocationManager
    @EnvironmentObject private var onlineSyncManager: OnlineSyncManager
    @State private var settings = ARLineSettings()
    @State private var isImporting = false
    @State private var showingSettings = false
    @State private var showingTrackList = false
    @State private var showingOnline = false
    @State private var arErrorMessage: String?
    @State private var isRecording = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            ARViewContainer(track: trackDataManager.selectedTrack, originCoordinate: locationManager.originCoordinate, fusedPose: locationManager.renderPose(for: trackDataManager.selectedTrack), settings: settings, mapHeadingOffsetDegrees: locationManager.mapHeadingOffsetDegrees, isTrackDirectionReversed: locationManager.isTrackDirectionReversed, isCameraActive: isMainInterfaceActive)
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
        .onReceive(locationManager.$fusedPose) { pose in
            locationManager.autoCalibrateIfNeeded(track: trackDataManager.selectedTrack)
            if let pose { onlineSyncManager.observe(pose: pose, track: trackDataManager.selectedTrack) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .arSessionError)) { arErrorMessage = $0.object as? String }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.json, .xml], allowsMultipleSelection: false) { result in
            if case let .success(urls) = result, let url = urls.first { trackDataManager.importFile(from: url) }
        }
        .sheet(isPresented: $showingSettings) { SettingsView(settings: $settings) }
        .sheet(isPresented: $showingTrackList) { TrackListView() }
        .sheet(isPresented: $showingOnline) {
            OnlineCenterView()
                .environmentObject(onlineSyncManager)
                .environmentObject(trackDataManager)
        }
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
                metricCard(title: "偏离", value: lineDeviationText)
                metricCard(title: "GPS", value: gpsText)
            }
        }
    }

    private var bottomControls: some View {
        HStack(spacing: 10) {
            Button("导入") { isImporting = true }
            Button("赛道") { showingTrackList = true }
            Button("在线") { showingOnline = true }
            Button("智能校准") { locationManager.smartCalibrate(using: trackDataManager.selectedTrack) }
            Button(isRecording ? "停止" : "录屏") { toggleRecording() }
            Button("截图") { NotificationCenter.default.post(name: .captureARStillImage, object: nil) }
            Button("设置") { showingSettings = true }
        }
        .buttonStyle(.liquidGlassProminent)
        .controlSize(.large)
    }

    private func metricCard(title: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.white.opacity(0.72))
            Text(value).font(.headline.monospacedDigit()).foregroundStyle(.white)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 14))
    }

    private var isMainInterfaceActive: Bool {
        !isImporting && !showingSettings && !showingTrackList && !showingOnline
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
    private var lineDeviationText: String {
        guard let pose = locationManager.fusedPose, let track = trackDataManager.selectedTrack else { return "--" }
        return "\(Int(GeoConverter.lineDeviationMeters(from: pose.coordinate, along: track.points))) m"
    }
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
        guard let projection = GeoConverter.nearestProjection(from: pose.coordinate, along: track.points) else { return "--" }
        guard let distance = distanceToNextRed(from: projection, in: track.points, maxDistance: 300) else { return "--" }
        return "\(Int(distance)) m"
    }

    private func nearestTrackPoint() -> TrackPoint? {
        guard let pose = locationManager.fusedPose, let track = trackDataManager.selectedTrack else { return nil }
        guard let projection = GeoConverter.nearestProjection(from: pose.coordinate, along: track.points) else { return track.points.first }
        return trackPointAhead(from: projection, in: track.points, distance: max(2, drivingLeadMeters))
    }

    private var drivingLeadMeters: Double {
        min(max((locationManager.fusedPose?.speed ?? 0) * 0.45, 0), 8)
    }

    private func closesLoop(_ points: [TrackPoint]) -> Bool {
        guard points.count > 2, let first = points.first, let last = points.last else { return false }
        return GeoConverter.distanceMeters(from: first.coordinate, to: last.coordinate) <= 80
    }

    private func advanceSegmentIndex(_ index: Int, segmentCount: Int, reversed: Bool) -> Int {
        if reversed {
            let next = index - 1
            return next < 0 ? segmentCount - 1 : next
        }
        let next = index + 1
        return next >= segmentCount ? 0 : next
    }

    private func colorAtSegment(_ segmentIndex: Int, points: [TrackPoint], reversed: Bool) -> TrackPointColor {
        guard !points.isEmpty else { return .green }
        let index = reversed ? min(max(segmentIndex, 0), points.count - 1) : min(max((segmentIndex + 1) % points.count, 0), points.count - 1)
        return points[index].color
    }

    private func trackPointAhead(from projection: TrackCoordinateProjection, in points: [TrackPoint], distance: Double) -> TrackPoint? {
        guard !points.isEmpty else { return nil }
        let segmentCount = max(closesLoop(points) ? points.count : points.count - 1, 1)
        var segmentIndex = min(max(projection.segmentIndex, 0), segmentCount - 1)
        var current = TrackPoint(latitude: projection.coordinate.latitude, longitude: projection.coordinate.longitude, speed: 0, color: colorAtSegment(segmentIndex, points: points, reversed: locationManager.isTrackDirectionReversed))
        var remaining = distance
        var guardCount = 0
        while remaining > 0, guardCount < points.count + 2 {
            let pointIndex = locationManager.isTrackDirectionReversed ? segmentIndex : (segmentIndex + 1) % points.count
            let target = points[pointIndex]
            let segmentLength = GeoConverter.distanceMeters(from: current.coordinate, to: target.coordinate)
            if segmentLength >= remaining, segmentLength > 0.001 {
                let ratio = remaining / segmentLength
                return TrackPoint(
                    latitude: current.latitude + (target.latitude - current.latitude) * ratio,
                    longitude: current.longitude + (target.longitude - current.longitude) * ratio,
                    speed: target.speed,
                    color: target.color
                )
            }
            remaining -= segmentLength
            current = target
            segmentIndex = advanceSegmentIndex(segmentIndex, segmentCount: segmentCount, reversed: locationManager.isTrackDirectionReversed)
            guardCount += 1
        }
        return current
    }

    private func distanceToNextRed(from projection: TrackCoordinateProjection, in points: [TrackPoint], maxDistance: Double) -> Double? {
        guard !points.isEmpty else { return nil }
        let segmentCount = max(closesLoop(points) ? points.count : points.count - 1, 1)
        var segmentIndex = min(max(projection.segmentIndex, 0), segmentCount - 1)
        var current = TrackPoint(latitude: projection.coordinate.latitude, longitude: projection.coordinate.longitude, speed: 0, color: colorAtSegment(segmentIndex, points: points, reversed: locationManager.isTrackDirectionReversed))
        var distance = 0.0
        var guardCount = 0
        while distance <= maxDistance, guardCount < points.count + 2 {
            let pointIndex = locationManager.isTrackDirectionReversed ? segmentIndex : (segmentIndex + 1) % points.count
            let target = points[pointIndex]
            distance += GeoConverter.distanceMeters(from: current.coordinate, to: target.coordinate)
            if target.color == .red { return distance }
            current = target
            segmentIndex = advanceSegmentIndex(segmentIndex, segmentCount: segmentCount, reversed: locationManager.isTrackDirectionReversed)
            guardCount += 1
        }
        return nil
    }
}

private struct TrackListView: View {
    @EnvironmentObject private var locationManager: LocationManager
    @EnvironmentObject private var manager: TrackDataManager
    @Environment(\.dismiss) private var dismiss
    @State private var renamingTrack: TrackData?
    @State private var newName = ""
    @State private var showingAITrackGenerator = false
    @State private var showingMapTrackDrawer = false

    var body: some View {
        NavigationStack {
            List {
                ForEach(manager.tracks) { track in
                    Button {
                        manager.selectedTrackID = track.id
                        locationManager.smartCalibrate(using: track)
                        dismiss()
                    } label: {
                        VStack(alignment: .leading) {
                            Text(track.trackName).font(.headline)
                            Text("\(Int(track.trackLength))m · \(track.cornerCount)弯 · \(track.points.count)点").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button("删除", role: .destructive) { manager.delete(track: track) }
                        Button("重命名") { renamingTrack = track; newName = track.trackName }
                    }
                }
                .onDelete(perform: manager.deleteTracks)
            }
            .scrollContentBackground(.hidden)
            .background(.black)
            .navigationTitle("已导入赛道")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    HStack {
                        Button("图片描线") { showingAITrackGenerator = true }
                        Button("地图绘制") { showingMapTrackDrawer = true }
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack {
                        EditButton()
                        Button("完成") { dismiss() }
                    }
                }
            }
            .buttonStyle(.liquidGlass)
            .sheet(isPresented: $showingAITrackGenerator) {
                AITrackGeneratorView()
                    .environmentObject(manager)
                    .environmentObject(locationManager)
            }
            .sheet(isPresented: $showingMapTrackDrawer) {
                MapTrackDrawingView()
                    .environmentObject(manager)
                    .environmentObject(locationManager)
            }
            .alert("重命名赛道", isPresented: Binding(get: { renamingTrack != nil }, set: { if !$0 { renamingTrack = nil } })) {
                TextField("赛道名称", text: $newName)
                Button("保存") { if let renamingTrack { manager.rename(track: renamingTrack, to: newName) }; renamingTrack = nil }
                Button("取消", role: .cancel) { renamingTrack = nil }
            }
        }
    }
}
