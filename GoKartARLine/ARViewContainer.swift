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
        private let cameraHeightAboveGround: Float = 1.1
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
            guard let camera = view.pointOfView else {
                lineNode.geometry = nil
                return
            }
            lineNode.eulerAngles = SCNVector3(0, camera.eulerAngles.y, 0)
            lineNode.position = SCNVector3(camera.worldPosition.x, camera.worldPosition.y - cameraHeightAboveGround, camera.worldPosition.z)
            guard let track, let originCoordinate, track.points.count > 1 else {
                lineNode.geometry = nil
                return
            }

            let currentCoordinate = fusedPose?.coordinate ?? originCoordinate
            let vehicleWorldPosition = GeoConverter.arPosition(for: currentCoordinate, origin: originCoordinate)
            let vehicleLinePosition = vehicleWorldPosition.rotatedAroundY(degrees: mapHeadingOffsetDegrees)
            let sourcePoints = resampledVisiblePoints(from: track, origin: originCoordinate, vehiclePosition: vehicleLinePosition)

            guard sourcePoints.count > 1 else {
                lineNode.geometry = nil
                return
            }

            lineNode.geometry = makeTriangleStripGeometry(points: cameraAlignedPoints(sourcePoints))
        }

        private func resampledVisiblePoints(from track: TrackData, origin: CLLocationCoordinate2D, vehiclePosition: SCNVector3) -> [VisibleLinePoint] {
            let points = track.points.map { point in
                VisibleLinePoint(position: GeoConverter.arPosition(for: point.coordinate, origin: origin), color: point.color, distanceAhead: 0)
            }
            guard points.count > 1, let nearest = nearestTrackProjection(in: points, to: vehiclePosition) else { return [] }

            var visible: [VisibleLinePoint] = []
            let segmentCount = points.count - 1
            var segmentIndex = nearest.segmentIndex
            var startPosition = nearest.position
            var startColor = nearest.color
            var distanceAhead: Float = 0

            while distanceAhead <= maximumVisibleDistance {
                let nextIndex = (segmentIndex + 1) % points.count
                let endPoint = points[nextIndex]
                let segment = endPoint.position - startPosition
                let length = segment.length
                if length > 0 {
                    let steps = max(Int(ceil(length / 0.5)), 1)
                    for step in 0...steps {
                        let progress = Float(step) / Float(steps)
                        let sampleDistance = distanceAhead + length * progress
                        guard sampleDistance <= maximumVisibleDistance else { break }
                        let position = startPosition + segment * progress
                        let color = VisibleLinePoint.interpolatedColor(from: startColor, to: endPoint.color, progress: progress)
                        visible.append(VisibleLinePoint(position: position, color: color, distanceAhead: sampleDistance))
                    }
                    distanceAhead += length
                }

                segmentIndex = nextIndex
                if segmentIndex >= segmentCount { segmentIndex = 0 }
                startPosition = points[segmentIndex].position
                startColor = points[segmentIndex].color
                if segmentIndex == nearest.segmentIndex { break }
            }

            return visible
        }

        private func nearestTrackProjection(in points: [VisibleLinePoint], to vehiclePosition: SCNVector3) -> TrackProjection? {
            var best: TrackProjection?
            for index in 0..<(points.count - 1) {
                let start = points[index]
                let end = points[index + 1]
                let segment = end.position - start.position
                let lengthSquared = max(segment.x * segment.x + segment.z * segment.z, 0.0001)
                let relative = vehiclePosition - start.position
                let progress = min(max((relative.x * segment.x + relative.z * segment.z) / lengthSquared, 0), 1)
                let position = start.position + segment * progress
                let distance = (vehiclePosition - position).horizontalLength
                let color = VisibleLinePoint.interpolatedColor(from: start.color, to: end.color, progress: progress)
                let projection = TrackProjection(segmentIndex: index, position: position, color: color, distance: distance)
                if best == nil || projection.distance < best!.distance { best = projection }
            }
            return best
        }

        private func cameraAlignedPoints(_ points: [VisibleLinePoint]) -> [VisibleLinePoint] {
            guard points.count > 1 else { return points }
            let anchor = points[0].position
            let tangent = (points[1].position - anchor).normalized
            let rotation = atan2(tangent.x, -tangent.z)
            return points.map { point in
                VisibleLinePoint(position: (point.position - anchor).rotatedAroundY(radians: rotation), color: point.color, distanceAhead: point.distanceAhead)
            }
        }

        private func makeTriangleStripGeometry(points: [VisibleLinePoint]) -> SCNGeometry {
            var vertices: [SCNVector3] = []
            var colors: [SIMD4<Float>] = []

            for index in points.indices {
                let current = points[index].position
                let previous = points[max(index - 1, 0)].position
                let next = points[min(index + 1, points.count - 1)].position
                let tangent = (next - previous).normalized
                let normal = SCNVector3(-tangent.z, 0, tangent.x).normalized
                let y = groundOffset
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
            material.emission.contents = UIColor(red: 0, green: 1, blue: 0.1, alpha: 0.9)
            material.isDoubleSided = true
            material.transparency = 1
            material.blendMode = .alpha
            material.readsFromDepthBuffer = false
            material.writesToDepthBuffer = false
            material.transparent.contents = UIColor(white: 1, alpha: 0.9)
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

private struct TrackProjection {
    var segmentIndex: Int
    var position: SCNVector3
    var color: SIMD3<Float>
    var distance: Float
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
    static func interpolatedColor(from start: SIMD3<Float>, to end: SIMD3<Float>, progress: Float) -> SIMD3<Float> {
        start + (end - start) * min(max(progress, 0), 1)
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
}

private extension SCNVector3 {
    var length: Float { sqrt(x * x + y * y + z * z) }
    var horizontalLength: Float { sqrt(x * x + z * z) }

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

    func rotatedAroundY(degrees: Double) -> SCNVector3 {
        rotatedAroundY(radians: Float(degrees * .pi / 180.0))
    }

    func rotatedAroundY(radians: Float) -> SCNVector3 {
        let cosine = cos(radians)
        let sine = sin(radians)
        return SCNVector3(x * cosine + z * sine, y, -x * sine + z * cosine)
    }

    static func dot(_ lhs: SCNVector3, _ rhs: SCNVector3) -> Float { lhs.x * rhs.x + lhs.y * rhs.y + lhs.z * rhs.z }
}
