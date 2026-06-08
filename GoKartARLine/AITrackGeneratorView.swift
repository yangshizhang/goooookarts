import SwiftUI
import PhotosUI
import CoreLocation

struct AITrackGeneratorView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var trackDataManager: TrackDataManager
    @EnvironmentObject private var locationManager: LocationManager
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var selectedImage: UIImage?
    @State private var tracedPoints: [CGPoint] = []
    @State private var trackName = "图片描线赛道"
    @State private var trackLengthText = "800"
    @State private var message = "选择赛道俯视图，然后沿赛道中心线手指描一圈。"
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                HStack {
                    PhotosPicker(selection: $selectedPhoto, matching: .images) {
                        Label(selectedImage == nil ? "选择赛道照片" : "更换照片", systemImage: "photo")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.liquidGlassProminent)
                    Button("撤销") { if !tracedPoints.isEmpty { tracedPoints.removeLast(); updateTraceMessage() } }
                        .buttonStyle(.liquidGlass)
                    Button("清空") { tracedPoints.removeAll(); updateTraceMessage() }
                        .buttonStyle(.liquidGlass)
                }

                HStack(spacing: 10) {
                    TextField("赛道名称", text: $trackName)
                    TextField("长度米", text: $trackLengthText)
                        .keyboardType(.numberPad)
                        .frame(width: 90)
                }
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .padding(12)
                .background(.black, in: RoundedRectangle(cornerRadius: 12))

                imageTraceArea

                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    generateTrackFromTrace()
                } label: {
                    Label("按描线生成并导入", systemImage: "point.topleft.down.curvedto.point.bottomright.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.liquidGlassProminent)
                .disabled(selectedImage == nil || tracedPoints.count < 8)
            }
            .padding()
            .background(.black)
            .navigationTitle("图片描线生成")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("关闭") { dismiss() } } }
            .onChange(of: selectedPhoto) { newValue in Task { await loadPhoto(newValue) } }
            .alert("生成失败", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("知道了", role: .cancel) {}
            } message: { Text(errorMessage ?? "") }
        }
        .background(.black)
    }

    private var imageTraceArea: some View {
        GeometryReader { proxy in
            ZStack {
                RoundedRectangle(cornerRadius: 16)
                    .fill(.black)
                if let selectedImage {
                    Image(uiImage: selectedImage)
                        .resizable()
                        .scaledToFit()
                        .overlay {
                            traceOverlay(container: proxy.size, imageSize: selectedImage.size)
                        }
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                            addTracePoint(value.location, container: proxy.size, imageSize: selectedImage.size)
                        })
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "map")
                            .font(.system(size: 42))
                        Text("请选择一张赛道俯视图")
                    }
                    .foregroundStyle(.secondary)
                }
            }
        }
        .frame(minHeight: 300)
    }

    private func traceOverlay(container: CGSize, imageSize: CGSize) -> some View {
        Canvas { context, _ in
            guard tracedPoints.count > 1 else { return }
            var path = Path()
            path.move(to: viewPoint(from: tracedPoints[0], container: container, imageSize: imageSize))
            for point in tracedPoints.dropFirst() {
                path.addLine(to: viewPoint(from: point, container: container, imageSize: imageSize))
            }
            context.stroke(path, with: .color(.green), style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
            if let first = tracedPoints.first, let last = tracedPoints.last, tracedPoints.count > 2 {
                var closing = Path()
                closing.move(to: viewPoint(from: last, container: container, imageSize: imageSize))
                closing.addLine(to: viewPoint(from: first, container: container, imageSize: imageSize))
                context.stroke(closing, with: .color(.white.opacity(0.45)), style: StrokeStyle(lineWidth: 2, dash: [6, 6]))
            }
        }
        .overlay {
            ForEach(Array(tracedPoints.enumerated()), id: \.offset) { index, point in
                Circle()
                    .fill(index == 0 ? .red : .green)
                    .frame(width: index == 0 ? 14 : 8, height: index == 0 ? 14 : 8)
                    .overlay(Circle().stroke(.white.opacity(index == 0 ? 1 : 0), lineWidth: 2))
                    .position(viewPoint(from: point, container: container, imageSize: imageSize))
            }
        }
    }

    private func loadPhoto(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        do {
            guard let data = try await item.loadTransferable(type: Data.self), let image = UIImage(data: data) else {
                errorMessage = "照片读取失败"
                return
            }
            selectedImage = image
            tracedPoints = []
            message = "照片已选择。沿赛道中心线描一圈，首尾会自动闭合。"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func generateTrackFromTrace() {
        guard selectedImage != nil else { return }
        do {
            let origin = locationManager.fusedPose?.coordinate ?? locationManager.originCoordinate ?? CLLocationCoordinate2D(latitude: 31.234567, longitude: 121.345678)
            let length = Double(trackLengthText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 800
            let track = try AITrackGenerationService.convertImageTraceToTrackData(trackName: trackName, imagePoints: tracedPoints, origin: origin, targetLength: length)
            trackDataManager.addGeneratedTrack(track)
            dismiss()
        } catch {
            errorMessage = "描线点太少或路径无效，请沿赛道中心线完整描一圈。"
        }
    }

    private func addTracePoint(_ location: CGPoint, container: CGSize, imageSize: CGSize) {
        guard let point = imagePointIfInside(location, container: container, imageSize: imageSize) else { return }
        if let last = tracedPoints.last, hypot(point.x - last.x, point.y - last.y) < 6 { return }
        tracedPoints.append(point)
        updateTraceMessage()
    }

    private func updateTraceMessage() {
        message = tracedPoints.isEmpty ? "沿赛道中心线描一圈。" : "已记录 \(tracedPoints.count) 个描线点。越贴近中心线，生成越准。"
    }

    private func aspectFitRect(imageSize: CGSize, container: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0, container.width > 0, container.height > 0 else { return .zero }
        let scale = min(container.width / imageSize.width, container.height / imageSize.height)
        let fitted = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(x: (container.width - fitted.width) / 2, y: (container.height - fitted.height) / 2, width: fitted.width, height: fitted.height)
    }

    private func imagePointIfInside(_ viewPoint: CGPoint, container: CGSize, imageSize: CGSize) -> CGPoint? {
        let rect = aspectFitRect(imageSize: imageSize, container: container)
        guard rect.contains(viewPoint) else { return nil }
        return CGPoint(x: (viewPoint.x - rect.minX) / max(rect.width, 1) * imageSize.width, y: (viewPoint.y - rect.minY) / max(rect.height, 1) * imageSize.height)
    }

    private func viewPoint(from imagePoint: CGPoint, container: CGSize, imageSize: CGSize) -> CGPoint {
        let rect = aspectFitRect(imageSize: imageSize, container: container)
        return CGPoint(x: rect.minX + imagePoint.x / max(imageSize.width, 1) * rect.width, y: rect.minY + imagePoint.y / max(imageSize.height, 1) * rect.height)
    }
}
