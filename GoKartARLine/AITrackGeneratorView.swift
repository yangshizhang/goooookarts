import SwiftUI
import PhotosUI
import CoreLocation

struct AITrackGeneratorView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var trackDataManager: TrackDataManager
    @EnvironmentObject private var locationManager: LocationManager
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var selectedImage: UIImage?
    @State private var displayedImageSize: CGSize = .zero
    @State private var finishPoint: CGPoint?
    @State private var apiKey = AITrackGenerationService.shared.apiKey
    @State private var modelID = AITrackGenerationService.shared.model
    @State private var baseURL = AITrackGenerationService.shared.baseURLString
    @State private var isGenerating = false
    @State private var message = "选择赛道俯视图，然后点击图片上的起终点位置。"
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                PhotosPicker(selection: $selectedPhoto, matching: .images) {
                    Label(selectedImage == nil ? "选择赛道照片" : "更换赛道照片", systemImage: "photo")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                VStack(spacing: 10) {
                    SecureField("AI接口Key（保存在本机Keychain）", text: $apiKey)
                        .textContentType(.password)
                    TextField("Base URL", text: $baseURL)
                        .keyboardType(.URL)
                    TextField("Model ID", text: $modelID)
                }
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .padding(12)
                .background(.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))

                imageSelectionArea

                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    Task { await generateTrack() }
                } label: {
                    if isGenerating {
                        ProgressView().tint(.white)
                    } else {
                        Label("AI生成并导入赛道", systemImage: "sparkles")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedImage == nil || finishPoint == nil || apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isGenerating)
            }
            .padding()
            .navigationTitle("AI生成赛道")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("关闭") { dismiss() } } }
            .onChange(of: selectedPhoto) { _, newValue in Task { await loadPhoto(newValue) } }
            .alert("AI生成失败", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("知道了", role: .cancel) {}
            } message: { Text(errorMessage ?? "") }
        }
    }

    private var imageSelectionArea: some View {
        GeometryReader { proxy in
            ZStack {
                RoundedRectangle(cornerRadius: 16)
                    .fill(.black.opacity(0.08))
                if let selectedImage {
                    Image(uiImage: selectedImage)
                        .resizable()
                        .scaledToFit()
                        .background(
                            GeometryReader { imageProxy in
                                Color.clear.onAppear { displayedImageSize = imageProxy.size }
                            }
                        )
                        .overlay(alignment: .topLeading) {
                            if let finishPoint {
                                Circle()
                                    .fill(.red)
                                    .frame(width: 18, height: 18)
                                    .overlay(Circle().stroke(.white, lineWidth: 3))
                                    .position(viewPoint(from: finishPoint, container: proxy.size, imageSize: selectedImage.size))
                            }
                        }
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0).onEnded { value in
                            let imagePoint = imagePoint(from: value.location, container: proxy.size, imageSize: selectedImage.size)
                            finishPoint = imagePoint
                            message = "已选择终点：x=\(Int(imagePoint.x)), y=\(Int(imagePoint.y))。"
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
        .frame(minHeight: 280)
    }

    private func loadPhoto(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        do {
            guard let data = try await item.loadTransferable(type: Data.self), let image = UIImage(data: data) else {
                errorMessage = "照片读取失败"
                return
            }
            selectedImage = image
            finishPoint = nil
            message = "照片已选择。请点击图片上的起终点位置。"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func generateTrack() async {
        guard let selectedImage, let finishPoint else { return }
        isGenerating = true
        message = "AI正在分析赛道并生成≥200个行车线点，可能需要1-3分钟。"
        do {
            AITrackGenerationService.shared.apiKey = apiKey
            AITrackGenerationService.shared.model = modelID
            AITrackGenerationService.shared.baseURLString = baseURL
            let origin = locationManager.fusedPose?.coordinate ?? locationManager.originCoordinate ?? CLLocationCoordinate2D(latitude: 31.234567, longitude: 121.345678)
            let request = AITrackGenerationRequest(image: selectedImage, finishPoint: finishPoint, imageSize: selectedImage.size, originCoordinate: origin)
            let track = try await AITrackGenerationService.shared.generateTrack(request: request)
            trackDataManager.addGeneratedTrack(track)
            message = "已生成并导入：\(track.trackName)（\(track.points.count)点）"
            isGenerating = false
            dismiss()
        } catch {
            isGenerating = false
            errorMessage = error.localizedDescription
            message = "生成失败，请检查Key、网络或图片质量。"
        }
    }

    private func aspectFitSize(imageSize: CGSize, container: CGSize) -> CGSize {
        guard imageSize.width > 0, imageSize.height > 0, container.width > 0, container.height > 0 else { return .zero }
        let scale = min(container.width / imageSize.width, container.height / imageSize.height)
        return CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
    }

    private func imagePoint(from viewPoint: CGPoint, container: CGSize, imageSize: CGSize) -> CGPoint {
        let fitted = aspectFitSize(imageSize: imageSize, container: container)
        let origin = CGPoint(x: (container.width - fitted.width) / 2, y: (container.height - fitted.height) / 2)
        let x = min(max((viewPoint.x - origin.x) / max(fitted.width, 1) * imageSize.width, 0), imageSize.width)
        let y = min(max((viewPoint.y - origin.y) / max(fitted.height, 1) * imageSize.height, 0), imageSize.height)
        return CGPoint(x: x, y: y)
    }

    private func viewPoint(from imagePoint: CGPoint, container: CGSize, imageSize: CGSize) -> CGPoint {
        let fitted = aspectFitSize(imageSize: imageSize, container: container)
        let origin = CGPoint(x: (container.width - fitted.width) / 2, y: (container.height - fitted.height) / 2)
        return CGPoint(x: origin.x + imagePoint.x / max(imageSize.width, 1) * fitted.width, y: origin.y + imagePoint.y / max(imageSize.height, 1) * fitted.height)
    }
}




