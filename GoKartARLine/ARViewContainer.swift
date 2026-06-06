import SwiftUI
import ARKit
import SceneKit
import CoreLocation

struct ARViewContainer: UIViewRepresentable {
    var track: TrackData?
    var originCoordinate: CLLocationCoordinate2D?
    var fusedPose: FusedPose?
    var settings: ARLineSettings
    var mapHeadingOffsetDegrees: Double = 0

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView(frame: .zero)
        view.delegate = context.coordinator
        view.automaticallyUpdatesLighting = false
        view.preferredFramesPerSecond = settings.powerSavingMode ? 30 : 60
        context.coordinator.configureSession(for: view)
        context.coordinator.installNotifications(view: view)
        return view
    }

    func updateUIView(_ view: ARSCNView, context: Context) {
        view.preferredFramesPerSecond = settings.powerSavingMode ? 30 : 60
        context.coordinator.track = track
        context.coordinator.originCoordinate = originCoordinate ?? track?.startCoordinate
        context.coordinator.fusedPose = fusedPose
        context.coordinator.settings = settings
        context.coordinator.mapHeadingOffsetDegrees = mapHeadingOffsetDegrees
        context.coordinator.renderDrivingLine(in: view)
    }

    final class Coordinator: NSObject, ARSCNViewDelegate {
        var track: TrackData?
        var originCoordinate: CLLocationCoordinate2D?
        var fusedPose: FusedPose?
        var settings = ARLineSettings()
        var mapHeadingOffsetDegrees: Double = 0
        private let lineNode = SCNNode()
        private let maximumVisibleDistance: Float = 30
        private let fadeStartDistance: Float = 10
        private let lineWidth: Float = 0.4
        private let groundOffset: Float = 0.01

        func configureSession(for view: ARSCNView) {
            let configuration = ARWorldTrackingConfiguration()
            configuration.worldAlignment = .gravity
            configuration.isLightEstimationEnabled = false
            configuration.environmentTexturing = .none
            view.scene = SCNScene()
            view.scene.rootNode.addChildNode(lineNode)
            view.session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        }

        func installNotifications(view: ARSCNView) {
            NotificationCenter.default.addObserver(forName: .captureARStillImage, object: nil, queue: .main) { [weak view] _ in
                guard let image = view?.snapshot() else { return }
                UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
            }
        }

        func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
            guard let view = renderer as? ARSCNView else { return }
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self, let view else { return }
                self.renderDrivingLine(in: view)
            }
        }

        func renderDrivingLine(in view: ARSCNView) {
            lineNode.eulerAngles.y = Float(-mapHeadingOffsetDegrees * .pi / 180.0)
            guard let track, let originCoordinate, track.points.count > 1 else {
                lineNode.geometry = nil
                return
            }

            let currentCoordinate = fusedPose?.coordinate ?? originCoordinate
            let vehiclePosition = GeoConverter.arPosition(for: currentCoordinate, origin: originCoordinate)
            let course = Float((fusedPose?.course ?? 0) * .pi / 180.0)
            let forward = SCNVector3(sin(course), 0, -cos(course)).normalized
            let sourcePoints = resampledVisiblePoints(from: track, origin: originCoordinate, vehiclePosition: vehiclePosition, forward: forward)

            guard sourcePoints.count > 1 else {
                lineNode.geometry = nil
                return
            }

            lineNode.geometry = makeTriangleStripGeometry(points: sourcePoints, view: view)
        }

        private func resampledVisiblePoints(from track: TrackData, origin: CLLocationCoordinate2D, vehiclePosition: SCNVector3, forward: SCNVector3) -> [VisibleLinePoint] {
            let positions = track.points.map { point in
                VisibleLinePoint(position: GeoConverter.arPosition(for: point.coordinate, origin: origin), color: point.color, distanceAhead: 0)
            }
            var visible: [VisibleLinePoint] = []

            for (start, end) in zip(positions, positions.dropFirst()) {
                let segment = end.position - start.position
                let length = segment.length
                guard length > 0 else { continue }
                let steps = max(Int(ceil(length / 0.5)), 1)
                for step in 0...steps {
                    let progress = Float(step) / Float(steps)
                    let position = start.position + segment * progress
                    let relative = position - vehiclePosition
                    let distanceAhead = SCNVector3.dot(relative, forward)
                    guard distanceAhead >= 0, distanceAhead <= maximumVisibleDistance else { continue }
                    let lateral = (relative - forward * distanceAhead).length
                    guard lateral <= 8 else { continue }
                    let color = TrackPointColor.interpolated(from: start.color, to: end.color, progress: progress)
                    visible.append(VisibleLinePoint(position: position, color: color, distanceAhead: distanceAhead))
                }
            }

            return visible
        }

        private func makeTriangleStripGeometry(points: [VisibleLinePoint], view: ARSCNView) -> SCNGeometry {
            var vertices: [SCNVector3] = []
            var colors: [SIMD4<Float>] = []

            for index in points.indices {
                let current = points[index].position
                let previous = points[max(index - 1, 0)].position
                let next = points[min(index + 1, points.count - 1)].position
                let tangent = (next - previous).normalized
                let normal = SCNVector3(-tangent.z, 0, tangent.x).normalized
                let y = groundHeight(near: current, in: view) + groundOffset
                let left = SCNVector3(current.x + normal.x * lineWidth / 2, y, current.z + normal.z * lineWidth / 2)
                let right = SCNVector3(current.x - normal.x * lineWidth / 2, y, current.z - normal.z * lineWidth / 2)
                let color = vertexColor(for: points[index])
                vertices.append(left)
                vertices.append(right)
                colors.append(color)
                colors.append(color)
            }

            let vertexData = vertices.withUnsafeBufferPointer { Data(buffer: $0) }
            let colorData = colors.withUnsafeBufferPointer { Data(buffer: $0) }
            let vertexSource = SCNGeometrySource(data: vertexData, semantic: .vertex, vectorCount: vertices.count, usesFloatComponents: true, componentsPerVector: 3, bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0, dataStride: MemoryLayout<SCNVector3>.stride)
            let colorSource = SCNGeometrySource(data: colorData, semantic: .color, vectorCount: colors.count, usesFloatComponents: true, componentsPerVector: 4, bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0, dataStride: MemoryLayout<SIMD4<Float>>.stride)
            let indices = Array(UInt32(0)..<UInt32(vertices.count))
            let indexData = indices.withUnsafeBufferPointer { Data(buffer: $0) }
            let element = SCNGeometryElement(data: indexData, primitiveType: .triangleStrip, primitiveCount: max(vertices.count - 2, 0), bytesPerIndex: MemoryLayout<UInt32>.stride)
            let geometry = SCNGeometry(sources: [vertexSource, colorSource], elements: [element])
            geometry.materials = [makeLineMaterial()]
            return geometry
        }

        private func groundHeight(near position: SCNVector3, in view: ARSCNView) -> Float {
            let start = SCNVector3(position.x, position.y + 1, position.z)
            let end = SCNVector3(position.x, position.y - 1, position.z)
            let hits = view.scene.rootNode.hitTestWithSegment(from: start, to: end, options: [
                .ignoreHiddenNodes: true,
                .boundingBoxOnly: false,
                .searchMode: SCNHitTestSearchMode.closest.rawValue
            ])
            if let hit = hits.first(where: { abs($0.worldNormal.y) > 0.85 }) {
                return hit.worldCoordinates.y
            }
            return -0.01
        }

        private func vertexColor(for point: VisibleLinePoint) -> SIMD4<Float> {
            let fade: Float
            if point.distanceAhead <= fadeStartDistance {
                fade = 1
            } else {
                fade = max(0, 1 - (point.distanceAhead - fadeStartDistance) / (maximumVisibleDistance - fadeStartDistance))
            }
            return SIMD4<Float>(point.color.x, point.color.y, point.color.z, 0.7 * fade)
        }

        private func makeLineMaterial() -> SCNMaterial {
            let material = SCNMaterial()
            material.lightingModel = .constant
            material.emission.contents = UIColor.white
            material.isDoubleSided = true
            material.transparency = 1
            material.blendMode = .alpha
            material.readsFromDepthBuffer = false
            material.writesToDepthBuffer = false
            material.shaderModifiers = [.fragment: """
            #pragma transparent
            _output.color = _geometry.color;
            """]
            return material
        }

        func session(_ session: ARSession, didFailWithError error: Error) {
            NotificationCenter.default.post(name: .arSessionError, object: error.localizedDescription)
        }
    }
}

extension Notification.Name {
    static let captureARStillImage = Notification.Name("captureARStillImage")
    static let arSessionError = Notification.Name("arSessionError")
}

private struct VisibleLinePoint {
    var position: SCNVector3
    var color: SIMD3<Float>
    var distanceAhead: Float

    init(position: SCNVector3, color: TrackPointColor, distanceAhead: Float) {
        self.position = position
        self.color = color.gradientColor
        self.distanceAhead = distanceAhead
    }

    init(position: SCNVector3, color: SIMD3<Float>, distanceAhead: Float) {
        self.position = position
        self.color = color
        self.distanceAhead = distanceAhead
    }
}

private extension TrackPointColor {
    var gradientColor: SIMD3<Float> {
        switch self {
        case .green: return SIMD3<Float>(0, 1, 0)
        case .orange: return SIMD3<Float>(1, 1, 0)
        case .red: return SIMD3<Float>(1, 0, 0)
        }
    }

    static func interpolated(from start: TrackPointColor, to end: TrackPointColor, progress: Float) -> SIMD3<Float> {
        start.gradientColor + (end.gradientColor - start.gradientColor) * min(max(progress, 0), 1)
    }
}

private extension SCNVector3 {
    var length: Float { sqrt(x * x + y * y + z * z) }

    var normalized: SCNVector3 {
        let length = length
        guard length > 0 else { return SCNVector3(0, 0, -1) }
        return SCNVector3(x / length, y / length, z / length)
    }

    static func +(lhs: SCNVector3, rhs: SCNVector3) -> SCNVector3 {
        SCNVector3(lhs.x + rhs.x, lhs.y + rhs.y, lhs.z + rhs.z)
    }

    static func -(lhs: SCNVector3, rhs: SCNVector3) -> SCNVector3 {
        SCNVector3(lhs.x - rhs.x, lhs.y - rhs.y, lhs.z - rhs.z)
    }

    static func *(lhs: SCNVector3, rhs: Float) -> SCNVector3 {
        SCNVector3(lhs.x * rhs, lhs.y * rhs, lhs.z * rhs)
    }

    static func dot(_ lhs: SCNVector3, _ rhs: SCNVector3) -> Float { lhs.x * rhs.x + lhs.y * rhs.y + lhs.z * rhs.z }
}
