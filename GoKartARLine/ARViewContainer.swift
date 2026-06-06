import SwiftUI
import ARKit
import SceneKit
import CoreLocation

struct ARViewContainer: UIViewRepresentable {
    var track: TrackData?
    var originCoordinate: CLLocationCoordinate2D?
    var fusedPose: FusedPose?
    var settings: ARLineSettings

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView(frame: .zero)
        view.delegate = context.coordinator
        view.automaticallyUpdatesLighting = false
        view.preferredFramesPerSecond = settings.powerSavingMode ? 30 : 60
        view.preferredFrameRateRange = CAFrameRateRange(minimum: Float(settings.powerSavingMode ? 30 : 60), maximum: Float(settings.powerSavingMode ? 30 : 60), preferred: Float(settings.powerSavingMode ? 30 : 60))
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
        context.coordinator.renderVisibleLineSegments(in: view)
    }

    final class Coordinator: NSObject, ARSCNViewDelegate {
        var track: TrackData?
        var originCoordinate: CLLocationCoordinate2D?
        var fusedPose: FusedPose?
        var settings = ARLineSettings()
        private let lineRoot = SCNNode()
        private var lastRenderedTrackID: TrackData.ID?
        private var lastRenderedOrigin: CLLocationCoordinate2D?

        func configureSession(for view: ARSCNView) {
            let configuration = ARWorldTrackingConfiguration()
            configuration.worldAlignment = .gravity
            configuration.isLightEstimationEnabled = false
            configuration.environmentTexturing = .none
            view.scene = SCNScene()
            view.scene.rootNode.addChildNode(lineRoot)
            view.session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        }

        func installNotifications(view: ARSCNView) {
            NotificationCenter.default.addObserver(forName: .captureARStillImage, object: nil, queue: .main) { [weak view] _ in
                guard let image = view?.snapshot() else { return }
                UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
            }
        }

        func renderVisibleLineSegments(in view: ARSCNView) {
            guard let track, let originCoordinate, track.points.count > 1 else {
                lineRoot.childNodes.forEach { $0.removeFromParentNode() }
                return
            }
            let originChanged = lastRenderedOrigin?.latitude != originCoordinate.latitude || lastRenderedOrigin?.longitude != originCoordinate.longitude
            guard lastRenderedTrackID != track.id || originChanged || lineRoot.childNodes.isEmpty else { return }
            lastRenderedTrackID = track.id
            lastRenderedOrigin = originCoordinate
            lineRoot.childNodes.forEach { $0.removeFromParentNode() }

            let currentCoordinate = fusedPose?.coordinate ?? originCoordinate
            for (startPoint, endPoint) in zip(track.points, track.points.dropFirst()) {
                guard GeoConverter.distanceMeters(from: currentCoordinate, to: startPoint.coordinate) <= 160 else { continue }
                let start = GeoConverter.arPosition(for: startPoint.coordinate, origin: originCoordinate)
                let end = GeoConverter.arPosition(for: endPoint.coordinate, origin: originCoordinate)
                lineRoot.addChildNode(makeCylinderSegment(from: start, to: end, color: startPoint.color.uiColor))
            }
        }

        private func makeCylinderSegment(from start: SCNVector3, to end: SCNVector3, color: UIColor) -> SCNNode {
            let vector = SCNVector3(end.x - start.x, end.y - start.y, end.z - start.z)
            let length = CGFloat(sqrt(vector.x * vector.x + vector.y * vector.y + vector.z * vector.z))
            let cylinder = SCNCylinder(radius: CGFloat(settings.width / 2), height: max(length, 0.01))
            cylinder.radialSegmentCount = 12
            let material = SCNMaterial()
            material.diffuse.contents = color.withAlphaComponent(settings.opacity)
            material.emission.contents = color.withAlphaComponent(settings.brightness)
            material.lightingModel = .constant
            material.isDoubleSided = true
            if settings.disableDepthTest {
                material.readsFromDepthBuffer = false
                material.writesToDepthBuffer = false
            }
            cylinder.materials = [material]
            let node = SCNNode(geometry: cylinder)
            node.position = SCNVector3((start.x + end.x) / 2, (start.y + end.y) / 2, (start.z + end.z) / 2)
            node.orientation = SCNQuaternion.rotationBetween(vector: SCNVector3(0, 1, 0), target: vector.normalized)
            return node
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

private extension SCNVector3 {
    var normalized: SCNVector3 {
        let length = sqrt(x * x + y * y + z * z)
        guard length > 0 else { return SCNVector3(0, 1, 0) }
        return SCNVector3(x / length, y / length, z / length)
    }

    static func cross(_ lhs: SCNVector3, _ rhs: SCNVector3) -> SCNVector3 {
        SCNVector3(lhs.y * rhs.z - lhs.z * rhs.y, lhs.z * rhs.x - lhs.x * rhs.z, lhs.x * rhs.y - lhs.y * rhs.x)
    }

    static func dot(_ lhs: SCNVector3, _ rhs: SCNVector3) -> Float { lhs.x * rhs.x + lhs.y * rhs.y + lhs.z * rhs.z }
}

private extension SCNQuaternion {
    static func rotationBetween(vector from: SCNVector3, target to: SCNVector3) -> SCNQuaternion {
        let from = from.normalized
        let to = to.normalized
        let dot = max(min(SCNVector3.dot(from, to), 1), -1)
        if dot < -0.9999 { return SCNQuaternion(1, 0, 0, Float.pi) }
        let axis = SCNVector3.cross(from, to).normalized
        return SCNQuaternion(axis.x, axis.y, axis.z, acos(dot))
    }
}
