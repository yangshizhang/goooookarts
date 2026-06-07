import SwiftUI
import MapKit
import CoreLocation

struct MapTrackDrawingView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var manager: TrackDataManager
    @EnvironmentObject private var locationManager: LocationManager

    @State private var mode: MapDrawingMode = .move
    @State private var coordinates: [CLLocationCoordinate2D] = []
    @State private var trackName = "地图绘制赛道"
    @State private var searchText = ""
    @State private var searchCoordinate: CLLocationCoordinate2D?
    @State private var isSearching = false
    @State private var isGenerating = false
    @State private var message = "模式1可移动缩放地图；切到绘制模式后在实景地图上描出赛道。"
    @State private var errorMessage: String?

    private var isClosed: Bool {
        guard let first = coordinates.first, let last = coordinates.last, coordinates.count >= 4 else { return false }
        return GeoConverter.distanceMeters(from: first, to: last) <= 20
    }

    private var length: Double {
        zip(coordinates, coordinates.dropFirst()).reduce(0) { partial, pair in
            partial + GeoConverter.distanceMeters(from: pair.0, to: pair.1)
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                HStack(spacing: 8) {
                    TextField("搜索卡丁车场/地点", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit { Task { await searchPlace() } }
                    Button {
                        Task { await searchPlace() }
                    } label: {
                        if isSearching { ProgressView() } else { Image(systemName: "magnifyingglass") }
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSearching)
                }

                Picker("模式", selection: $mode) {
                    ForEach(MapDrawingMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .glassEffect(.regular, in: Capsule())

                AMapTrackDrawingMapView(
                    coordinates: $coordinates,
                    mode: mode,
                    initialCoordinate: locationManager.fusedPose?.coordinate,
                    searchCoordinate: searchCoordinate
                )
                .clipShape(RoundedRectangle(cornerRadius: 18))
                .overlay(alignment: .topLeading) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(mode == .move ? "移动缩放地图" : "绘制赛道线")
                            .font(.headline)
                        Text("点数：\(coordinates.count) · 长度：\(Int(length))m · \(isClosed ? "已首尾相接" : "未闭合")")
                            .font(.caption)
                    }
                    .padding(10)
                    .background(.black, in: RoundedRectangle(cornerRadius: 12))
                    .foregroundStyle(.white)
                    .padding()
                }

                TextField("赛道名称", text: $trackName)
                    .textFieldStyle(.roundedBorder)

                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack {
                    Button("撤销") { if !coordinates.isEmpty { coordinates.removeLast() } }
                        .disabled(coordinates.isEmpty || isGenerating)
                    Button("清空", role: .destructive) { coordinates.removeAll() }
                        .disabled(coordinates.isEmpty || isGenerating)
                    Button("首尾相接") { closeLoop() }
                        .disabled(coordinates.count < 3 || isClosed || isGenerating)
                }
                .buttonStyle(.glass)

                Button {
                    Task { await generateBrakeZones() }
                } label: {
                    if isGenerating {
                        ProgressView().tint(.white)
                    } else {
                        Label("发送地图轨迹给AI生成刹车区", systemImage: "sparkles")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.glassProminent)
                .disabled(!isClosed || coordinates.count < 4 || isGenerating)
            }
            .padding()
            .background(.black)
            .navigationTitle("地图绘制赛道")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("关闭") { dismiss() } } }
            .alert("生成失败", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("知道了", role: .cancel) {}
            } message: { Text(errorMessage ?? "") }
        }
        .background(.black)
    }

    private func searchPlace() async {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        isSearching = true
        defer { isSearching = false }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        if let coordinate = locationManager.fusedPose?.coordinate {
            request.region = MKCoordinateRegion(center: coordinate, latitudinalMeters: 20_000, longitudinalMeters: 20_000)
        }
        do {
            let response = try await MKLocalSearch(request: request).start()
            guard let item = response.mapItems.first else {
                errorMessage = "没有找到相关地点"
                return
            }
            searchCoordinate = item.placemark.coordinate
            message = "已定位到：\(item.name ?? query)。切到绘制模式后描出赛道。"
        } catch {
            errorMessage = "搜索失败：\(error.localizedDescription)"
        }
    }

    private func closeLoop() {
        guard let first = coordinates.first else { return }
        coordinates.append(first)
        message = "已首尾相接。现在可以发送给AI生成刹车区。"
    }

    private func generateBrakeZones() async {
        guard isClosed else { errorMessage = "赛道必须首尾相接后才能生成"; return }
        isGenerating = true
        message = "AI正在根据地图轨迹生成速度和刹车区。"
        do {
            let track = try await AITrackGenerationService.shared.generateBrakeZones(
                from: coordinates,
                trackName: trackName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "地图绘制赛道" : trackName
            )
            manager.addGeneratedTrack(track)
            message = "已生成并导入：\(track.trackName)"
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            message = "生成失败，请检查AI Key、网络和轨迹闭合状态。"
        }
        isGenerating = false
    }
}

enum MapDrawingMode: CaseIterable {
    case move
    case draw

    var title: String {
        switch self {
        case .move: return "移动缩放"
        case .draw: return "绘制"
        }
    }
}

struct AMapTrackDrawingMapView: UIViewRepresentable {
    @Binding var coordinates: [CLLocationCoordinate2D]
    var mode: MapDrawingMode
    var initialCoordinate: CLLocationCoordinate2D?
    var searchCoordinate: CLLocationCoordinate2D?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView(frame: .zero)
        mapView.delegate = context.coordinator
        mapView.mapType = .hybridFlyover
        mapView.showsUserLocation = true
        mapView.pointOfInterestFilter = .includingAll
        mapView.isRotateEnabled = true
        mapView.isPitchEnabled = true
        if let initialCoordinate {
            mapView.setRegion(MKCoordinateRegion(center: initialCoordinate, latitudinalMeters: 500, longitudinalMeters: 500), animated: false)
        }

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        tap.cancelsTouchesInView = false
        mapView.addGestureRecognizer(tap)

        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        mapView.addGestureRecognizer(pan)
        context.coordinator.panGesture = pan
        context.coordinator.lastSearchCoordinate = initialCoordinate
        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        context.coordinator.parent = self
        mapView.isScrollEnabled = mode == .move
        mapView.isZoomEnabled = mode == .move
        mapView.isRotateEnabled = mode == .move
        mapView.isPitchEnabled = mode == .move
        context.coordinator.panGesture?.isEnabled = mode == .draw
        if let searchCoordinate, !context.coordinator.isSameCoordinate(searchCoordinate, context.coordinator.lastSearchCoordinate) {
            mapView.setRegion(MKCoordinateRegion(center: searchCoordinate, latitudinalMeters: 800, longitudinalMeters: 800), animated: true)
            context.coordinator.lastSearchCoordinate = searchCoordinate
        }
        context.coordinator.refreshOverlay(on: mapView)
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var parent: AMapTrackDrawingMapView
        weak var panGesture: UIPanGestureRecognizer?
        var lastSearchCoordinate: CLLocationCoordinate2D?
        private var lastAddedCoordinate: CLLocationCoordinate2D?

        init(_ parent: AMapTrackDrawingMapView) {
            self.parent = parent
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard parent.mode == .draw, let mapView = gesture.view as? MKMapView, gesture.state == .ended else { return }
            appendCoordinate(from: gesture.location(in: mapView), mapView: mapView, minimumDistance: 0)
        }

        @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
            guard parent.mode == .draw, let mapView = gesture.view as? MKMapView else { return }
            let point = gesture.location(in: mapView)
            switch gesture.state {
            case .began:
                lastAddedCoordinate = nil
                appendCoordinate(from: point, mapView: mapView, minimumDistance: 0)
            case .changed:
                appendCoordinate(from: point, mapView: mapView, minimumDistance: 2)
            default:
                lastAddedCoordinate = nil
            }
        }

        func isSameCoordinate(_ lhs: CLLocationCoordinate2D, _ rhs: CLLocationCoordinate2D?) -> Bool {
            guard let rhs else { return false }
            return abs(lhs.latitude - rhs.latitude) < 0.000001 && abs(lhs.longitude - rhs.longitude) < 0.000001
        }

        func appendCoordinate(from point: CGPoint, mapView: MKMapView, minimumDistance: Double) {
            let coordinate = mapView.convert(point, toCoordinateFrom: mapView)
            if let lastAddedCoordinate, GeoConverter.distanceMeters(from: lastAddedCoordinate, to: coordinate) < minimumDistance { return }
            parent.coordinates.append(coordinate)
            lastAddedCoordinate = coordinate
            refreshOverlay(on: mapView)
        }

        func refreshOverlay(on mapView: MKMapView) {
            mapView.removeOverlays(mapView.overlays)
            guard parent.coordinates.count > 1 else { return }
            let polyline = MKPolyline(coordinates: parent.coordinates, count: parent.coordinates.count)
            mapView.addOverlay(polyline)
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let polyline = overlay as? MKPolyline else { return MKOverlayRenderer(overlay: overlay) }
            let renderer = MKPolylineRenderer(polyline: polyline)
            renderer.strokeColor = UIColor.systemGreen.withAlphaComponent(0.9)
            renderer.lineWidth = 5
            renderer.lineJoin = .round
            renderer.lineCap = .round
            return renderer
        }
    }
}
