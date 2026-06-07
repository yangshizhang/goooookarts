import SwiftUI
import CoreLocation

struct TrackMapCalibrationView: View {
    var track: TrackData
    var onConfirm: (CLLocationCoordinate2D, Double) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedIndex = 0
    @State private var headingDegrees = 0.0

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                Text("在地图上点击你当前所在位置；拖动红色方向箭头或使用滑块校准车头方向。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                GeometryReader { proxy in
                    ZStack {
                        Canvas { context, size in
                            drawTrack(context: context, size: size)
                        }
                        .background(.black, in: RoundedRectangle(cornerRadius: 16))
                        .gesture(DragGesture(minimumDistance: 0).onEnded { value in
                            selectedIndex = nearestPointIndex(to: value.location, size: proxy.size)
                        })

                        let selected = screenPoint(for: selectedIndex, size: proxy.size)
                        Circle()
                            .fill(.red)
                            .frame(width: 18, height: 18)
                            .overlay(Circle().stroke(.white, lineWidth: 3))
                            .position(selected)

                        Path { path in
                            path.move(to: selected)
                            let radians = headingDegrees * .pi / 180.0
                            path.addLine(to: CGPoint(x: selected.x + cos(radians) * 54, y: selected.y - sin(radians) * 54))
                        }
                        .stroke(.red, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                            let dx = value.location.x - selected.x
                            let dy = selected.y - value.location.y
                            headingDegrees = normalizedDegrees(atan2(dy, dx) * 180.0 / .pi)
                        })
                    }
                }
                .frame(minHeight: 340)

                VStack(spacing: 8) {
                    HStack {
                        Text("方向")
                        Spacer()
                        Text("\(Int(headingDegrees))°")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $headingDegrees, in: 0...359, step: 1)
                }
                .padding(12)
                .modifier(LiquidGlassPanelModifier(cornerRadius: 14))

                VStack(alignment: .leading, spacing: 4) {
                    Text("当前位置点：#\(track.points.isEmpty ? 0 : selectedIndex + 1) / \(track.points.count)")
                    if track.points.indices.contains(selectedIndex) {
                        Text("坐标：\(track.points[selectedIndex].latitude, specifier: "%.6f"), \(track.points[selectedIndex].longitude, specifier: "%.6f")")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    guard track.points.indices.contains(selectedIndex) else { return }
                    onConfirm(track.points[selectedIndex].coordinate, headingDegrees)
                    dismiss()
                } label: {
                    Label("加载赛道并应用校准", systemImage: "location.north.line.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.liquidGlassProminent)
                .disabled(track.points.isEmpty)
            }
            .padding()
            .background(.black)
            .navigationTitle("校准地图")
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarItems(trailing: Button("取消") { dismiss() })
            .onAppear { selectedIndex = min(selectedIndex, max(track.points.count - 1, 0)) }
        }
        .background(.black)
    }

    private func drawTrack(context: GraphicsContext, size: CGSize) {
        guard track.points.count > 1 else { return }
        var path = Path()
        path.move(to: screenPoint(for: 0, size: size))
        for index in track.points.indices.dropFirst() {
            path.addLine(to: screenPoint(for: index, size: size))
        }
        context.stroke(path, with: .color(.white.opacity(0.75)), lineWidth: 3)

        for index in track.points.indices {
            let point = screenPoint(for: index, size: size)
            let color = swiftUIColor(for: track.points[index].color)
            let rect = CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6)
            context.fill(Path(ellipseIn: rect), with: .color(color))
        }
    }

    private func nearestPointIndex(to location: CGPoint, size: CGSize) -> Int {
        guard !track.points.isEmpty else { return 0 }
        return track.points.indices.min { lhs, rhs in
            distance(screenPoint(for: lhs, size: size), location) < distance(screenPoint(for: rhs, size: size), location)
        } ?? 0
    }

    private func screenPoint(for index: Int, size: CGSize) -> CGPoint {
        let bounds = localBounds()
        guard bounds.width > 0, bounds.height > 0, track.points.indices.contains(index), let origin = track.startCoordinate else {
            return CGPoint(x: size.width / 2, y: size.height / 2)
        }
        let ar = GeoConverter.arPosition(for: track.points[index].coordinate, origin: origin)
        let padding: CGFloat = 28
        let scale = min((size.width - padding * 2) / CGFloat(bounds.width), (size.height - padding * 2) / CGFloat(bounds.height))
        let x = padding + (CGFloat(ar.x) - bounds.minX) * scale
        let y = padding + (bounds.maxY - CGFloat(-ar.z)) * scale
        return CGPoint(x: x, y: y)
    }

    private func localBounds() -> CGRect {
        guard let origin = track.startCoordinate, !track.points.isEmpty else { return .zero }
        let values = track.points.map { point -> CGPoint in
            let ar = GeoConverter.arPosition(for: point.coordinate, origin: origin)
            return CGPoint(x: CGFloat(ar.x), y: CGFloat(-ar.z))
        }
        let minX = values.map(\.x).min() ?? 0
        let maxX = values.map(\.x).max() ?? 1
        let minY = values.map(\.y).min() ?? 0
        let maxY = values.map(\.y).max() ?? 1
        return CGRect(x: minX, y: minY, width: max(maxX - minX, 1), height: max(maxY - minY, 1))
    }

    private func swiftUIColor(for color: TrackPointColor) -> Color {
        switch color {
        case .green: return .green
        case .orange: return .orange
        case .red: return .red
        }
    }

    private func distance(_ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat {
        hypot(lhs.x - rhs.x, lhs.y - rhs.y)
    }

    private func normalizedDegrees(_ degrees: Double) -> Double {
        let value = degrees.truncatingRemainder(dividingBy: 360)
        return value < 0 ? value + 360 : value
    }
}
