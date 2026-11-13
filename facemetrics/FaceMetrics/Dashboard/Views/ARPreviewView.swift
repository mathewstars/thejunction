import SwiftUI
import ARKit
import SceneKit

/// Live camera preview driven by the shared ARSession, with an optional wireframe face mesh overlay.
/// The view only renders; it never stores frames.
struct ARPreviewView: UIViewRepresentable {
    let session: ARSession
    var showMesh: Bool = true
    var showEyeRays: Bool = false

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView(frame: .zero)
        view.session = session
        view.delegate = context.coordinator
        view.automaticallyUpdatesLighting = true
        view.preferredFramesPerSecond = 30
        view.scene = SCNScene()
        view.backgroundColor = UIColor(Theme.background)
        context.coordinator.showMesh = showMesh
        context.coordinator.showEyeRays = showEyeRays
        return view
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {
        context.coordinator.showMesh = showMesh
        context.coordinator.showEyeRays = showEyeRays
        context.coordinator.applyVisibility()
    }

    static func dismantleUIView(_ uiView: ARSCNView, coordinator: Coordinator) {
        // Detach the renderer but keep the shared session running for the tracking engine.
        uiView.delegate = nil
        uiView.scene.rootNode.childNodes.forEach { $0.removeFromParentNode() }
    }

    final class Coordinator: NSObject, ARSCNViewDelegate {
        var showMesh = true
        var showEyeRays = false
        private var faceGeometry: ARSCNFaceGeometry?
        private weak var faceNode: SCNNode?
        private weak var leftEye: SCNNode?
        private weak var rightEye: SCNNode?

        func renderer(_ renderer: SCNSceneRenderer, nodeFor anchor: ARAnchor) -> SCNNode? {
            guard anchor is ARFaceAnchor, let device = renderer.device else { return nil }
            let node = SCNNode()
            if let geometry = ARSCNFaceGeometry(device: device, fillMesh: false) {
                let material = geometry.firstMaterial!
                material.fillMode = .lines
                material.lightingModel = .constant
                material.diffuse.contents = UIColor(Theme.accent).withAlphaComponent(0.85)
                material.isDoubleSided = false
                node.geometry = geometry
                faceGeometry = geometry
            }
            let left = Coordinator.makeEyeRay(color: UIColor(Theme.left))
            let right = Coordinator.makeEyeRay(color: UIColor(Theme.right))
            node.addChildNode(left)
            node.addChildNode(right)
            leftEye = left
            rightEye = right
            faceNode = node
            applyVisibility()
            return node
        }

        func renderer(_ renderer: SCNSceneRenderer, didUpdate node: SCNNode, for anchor: ARAnchor) {
            guard let faceAnchor = anchor as? ARFaceAnchor else { return }
            faceGeometry?.update(from: faceAnchor.geometry)
            leftEye?.simdTransform = faceAnchor.leftEyeTransform
            rightEye?.simdTransform = faceAnchor.rightEyeTransform
            node.isHidden = !faceAnchor.isTracked
        }

        func applyVisibility() {
            faceNode?.geometry?.firstMaterial?.transparency = showMesh ? 1 : 0
            leftEye?.isHidden = !showEyeRays
            rightEye?.isHidden = !showEyeRays
        }

        /// A thin cylinder along the eye's +Z axis (its viewing direction), 20 cm long.
        private static func makeEyeRay(color: UIColor) -> SCNNode {
            let parent = SCNNode()
            let cylinder = SCNCylinder(radius: 0.0015, height: 0.2)
            cylinder.firstMaterial?.diffuse.contents = color
            cylinder.firstMaterial?.lightingModel = .constant
            let ray = SCNNode(geometry: cylinder)
            // Cylinder height runs along Y; rotate so it runs along +Z and sits in front of the eye.
            ray.eulerAngles.x = .pi / 2
            ray.position.z = 0.1
            parent.addChildNode(ray)
            return parent
        }
    }
}
