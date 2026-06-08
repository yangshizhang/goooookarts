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
                if let image = selectedImage {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    traceCanvas
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                            addTracePoint(value.location, container: proxy.size, imageSize: image.size)
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

    private var traceCanvas: some View {
        Canvas { context, _ in
            guard !tracedPoints.isEmpty else { return }
            if tracedPoints.count > 1 {
                var path = Path()
                path.move(to: tracedPoints[0])
                for point in tracedPoints.dropFirst() {
                    path.addLine(to: point)
                }
                context.stroke(path, with: .color(.green), style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                if let first = tracedPoints.first, let last = tracedPoints.last, tracedPoints.count > 2 {
                    var closing = Path()
                    closing.move(to: last)
                    closing.addLine(to: first)
                    context.stroke(closing, with: .color(.white.opacity(0.45)), style: StrokeStyle(lineWidth: 2, dash: [6, 6]))
                }
            }
            for (index, point) in tracedPoints.enumerated() {
                let radius: CGFloat = index == 0 ? 7 : 4
                let rect = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
                context.fill(Path(ellipseIn: rect), with: .color(index == 0 ? .red : .green))
                if index == 0 {
                    context.stroke(Path(ellipseIn: rect), with: .color(.white), lineWidth: 2)
                }
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
        guard imageRect(imageSize: imageSize, container: container).contains(location) else { return }
        if let last = tracedPoints.last, hypot(location.x - last.x, location.y - last.y) < 2 { return }
        tracedPoints.append(location)
        updateTraceMessage()
    }

    private func updateTraceMessage() {
        message = tracedPoints.isEmpty ? "沿赛道中心线描一圈。" : "已记录 \(tracedPoints.count) 个描线点。越贴近中心线，生成越准。"
    }

    private func imageRect(imageSize: CGSize, container: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0, container.width > 0, container.height > 0 else { return .zero }
        let scale = min(container.width / imageSize.width, container.height / imageSize.height)
        let fitted = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(x: (container.width - fitted.width) / 2, y: (container.height - fitted.height) / 2, width: fitted.width, height: fitted.height)
    }
}
