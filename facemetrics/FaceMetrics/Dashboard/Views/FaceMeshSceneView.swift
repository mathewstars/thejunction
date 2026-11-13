import SwiftUI
import SceneKit
import simd

enum MeshRenderMode: String, CaseIterable, Identifiable {
    case wireframe = "Wireframe"
    case solid = "Solid"
    case points = "Vertices"
    case displacement = "Displacement"
    var id: String { rawValue }
}

/// Inspectable 3D view of the latest face mesh. Rebuilds a SceneKit geometry from the vertex
/// buffer at up to 30 Hz and supports rotation with the standard SceneKit camera controls.
struct FaceMeshSceneView: UIViewRepresentable {
    let processor: FaceGeometryProcessor
    var mode: MeshRenderMode
    var followHead: Bool
    var paused: Bool = false

    func makeCoordinator() -> Coordinator { Coordinator(processor: processor) }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView(frame: .zero)
        view.backgroundColor = UIColor(Theme.background)
        view.antialiasingMode = .multisampling2X
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = false
        view.preferredFramesPerSecond = 30
        view.rendersContinuously = true

        let scene = SCNScene()
        let cameraNode = SCNNode()
        cameraNode.camera = SCNCamera()
        cameraNode.camera?.zNear = 0.01
        cameraNode.camera?.zFar = 5
        cameraNode.camera?.fieldOfView = 45
        cameraNode.position = SCNVector3(0, 0, 0.45)
        cameraNode.name = "camera"
        scene.rootNode.addChildNode(cameraNode)

        let key = SCNNode()
        key.light = SCNLight()
        key.light?.type = .directional
        key.light?.intensity = 900
        key.eulerAngles = SCNVector3(-0.4, 0.5, 0)
        scene.rootNode.addChildNode(key)
        let fill = SCNNode()
        fill.light = SCNLight()
        fill.light?.type = .ambient
        fill.light?.intensity = 350
        scene.rootNode.addChildNode(fill)

        let faceNode = SCNNode()
        faceNode.name = "face"
        scene.rootNode.addChildNode(faceNode)

        // Reference axes: x red, y green, z blue, 5 cm each.
        scene.rootNode.addChildNode(Coordinator.makeAxes())

        view.scene = scene
        view.pointOfView = cameraNode
        context.coordinator.view = view
        context.coordinator.faceNode = faceNode
        context.coordinator.mode = mode
        context.coordinator.followHead = followHead
        context.coordinator.start()
        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        context.coordinator.mode = mode
        context.coordinator.followHead = followHead
        context.coordinator.paused = paused
        if let cam = uiView.scene?.rootNode.childNode(withName: "camera", recursively: false) {
            let target = followHead ? SCNVector3(0, 0, 0) : SCNVector3(0, 0, 0.45)
            if abs(cam.position.z - target.z) > 0.01 && !context.coordinator.userMovedCamera {
                cam.position = target
            }
        }
    }

    static func dismantleUIView(_ uiView: SCNView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator: NSObject {
        let processor: FaceGeometryProcessor
        weak var view: SCNView?
        weak var faceNode: SCNNode?
        var mode: MeshRenderMode = .wireframe
        var followHead = true
        var paused = false
        var userMovedCamera = false
        private var timer: Timer?
        private var lastTimestamp: Double = -1
        private var lastMode: MeshRenderMode?

        init(processor: FaceGeometryProcessor) {
            self.processor = processor
            super.init()
        }

        func start() {
            timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
                self?.tick()
            }
        }

        func stop() {
            timer?.invalidate()
            timer = nil
        }

        private func tick() {
            guard !paused, let mesh = processor.currentMesh(), let faceNode else { return }
            guard mesh.timestamp != lastTimestamp || mode != lastMode else { return }
            lastTimestamp = mesh.timestamp
            lastMode = mode
            faceNode.geometry = Coordinator.buildGeometry(mesh: mesh, mode: mode, reference: mode == .displacement ? processor.referenceMesh() : nil)
            if followHead {
                faceNode.simdTransform = mesh.viewTransform
            } else {
                faceNode.simdTransform = matrix_identity_float4x4
            }
        }

        // MARK: Geometry construction

        static func buildGeometry(mesh: FaceMeshData, mode: MeshRenderMode, reference: [SIMD3<Float>]?) -> SCNGeometry {
            let vertices = mesh.vertices
            let vertexSource = SCNGeometrySource(vertices: vertices.map { SCNVector3($0.x, $0.y, $0.z) })

            switch mode {
            case .points:
                let indices = (0..<Int32(vertices.count)).map { $0 }
                let element = SCNGeometryElement(indices: indices, primitiveType: .point)
                element.pointSize = 3
                element.minimumPointScreenSpaceRadius = 1.5
                element.maximumPointScreenSpaceRadius = 3.5
                let geometry = SCNGeometry(sources: [vertexSource], elements: [element])
                let m = SCNMaterial()
                m.lightingModel = .constant
                m.diffuse.contents = UIColor(Theme.accent)
                geometry.materials = [m]
                return geometry

            case .wireframe:
                let element = SCNGeometryElement(indices: mesh.triangleIndices, primitiveType: .triangles)
                let geometry = SCNGeometry(sources: [vertexSource], elements: [element])
                let m = SCNMaterial()
                m.lightingModel = .constant
                m.fillMode = .lines
                m.diffuse.contents = UIColor(Theme.accent).withAlphaComponent(0.9)
                m.isDoubleSided = true
                geometry.materials = [m]
                return geometry

            case .solid:
                let normals = computeNormals(vertices: vertices, indices: mesh.triangleIndices)
                let normalSource = SCNGeometrySource(normals: normals.map { SCNVector3($0.x, $0.y, $0.z) })
                let element = SCNGeometryElement(indices: mesh.triangleIndices, primitiveType: .triangles)
                let geometry = SCNGeometry(sources: [vertexSource, normalSource], elements: [element])
                let m = SCNMaterial()
                m.lightingModel = .physicallyBased
                m.diffuse.contents = UIColor(red: 0.72, green: 0.74, blue: 0.78, alpha: 1)
                m.roughness.contents = 0.65
                m.metalness.contents = 0.05
                m.isDoubleSided = true
                geometry.materials = [m]
                return geometry

            case .displacement:
                let normals = computeNormals(vertices: vertices, indices: mesh.triangleIndices)
                let normalSource = SCNGeometrySource(normals: normals.map { SCNVector3($0.x, $0.y, $0.z) })
                var colors = [SIMD4<Float>](repeating: SIMD4<Float>(0.35, 0.37, 0.42, 1), count: vertices.count)
                if let reference, reference.count == vertices.count {
                    // Colour by displacement from the captured reference: 0 mm = grey, 10 mm+ = amber.
                    for i in 0..<vertices.count {
                        let d = simd_length(vertices[i] - reference[i])
                        let t = min(1, d / 0.010)
                        let grey = SIMD3<Float>(0.35, 0.37, 0.42)
                        let hot = SIMD3<Float>(1.0, 0.70, 0.42)
                        let c = grey + (hot - grey) * t
                        colors[i] = SIMD4<Float>(c.x, c.y, c.z, 1)
                    }
                }
                let colorData = colors.withUnsafeBufferPointer { Data(buffer: $0) }
                let colorSource = SCNGeometrySource(
                    data: colorData, semantic: .color, vectorCount: colors.count, usesFloatComponents: true,
                    componentsPerVector: 4, bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0,
                    dataStride: MemoryLayout<SIMD4<Float>>.stride)
                let element = SCNGeometryElement(indices: mesh.triangleIndices, primitiveType: .triangles)
                let geometry = SCNGeometry(sources: [vertexSource, normalSource, colorSource], elements: [element])
                let m = SCNMaterial()
                m.lightingModel = .lambert
                m.diffuse.contents = UIColor.white
                m.isDoubleSided = true
                geometry.materials = [m]
                return geometry
            }
        }

        static func computeNormals(vertices: [SIMD3<Float>], indices: [Int16]) -> [SIMD3<Float>] {
            var normals = [SIMD3<Float>](repeating: .zero, count: vertices.count)
            var i = 0
            while i + 2 < indices.count {
                let a = Int(indices[i]), b = Int(indices[i + 1]), c = Int(indices[i + 2])
                i += 3
                guard a < vertices.count, b < vertices.count, c < vertices.count else { continue }
                let n = simd_cross(vertices[b] - vertices[a], vertices[c] - vertices[a])
                normals[a] += n; normals[b] += n; normals[c] += n
            }
            for j in 0..<normals.count {
                let len = simd_length(normals[j])
                normals[j] = len > 0 ? normals[j] / len : SIMD3<Float>(0, 0, 1)
            }
            return normals
        }

        static func makeAxes() -> SCNNode {
            let parent = SCNNode()
            let specs: [(SCNVector3, UIColor)] = [
                (SCNVector3(0.05, 0, 0), UIColor(Theme.bad)),
                (SCNVector3(0, 0.05, 0), UIColor(Theme.ok)),
                (SCNVector3(0, 0, 0.05), UIColor(Theme.left))
            ]
            for (end, color) in specs {
                let source = SCNGeometrySource(vertices: [SCNVector3(0, 0, 0), end])
                let element = SCNGeometryElement(indices: [Int32(0), Int32(1)], primitiveType: .line)
                let g = SCNGeometry(sources: [source], elements: [element])
                g.firstMaterial?.lightingModel = .constant
                g.firstMaterial?.diffuse.contents = color.withAlphaComponent(0.6)
                parent.addChildNode(SCNNode(geometry: g))
            }
            parent.position = SCNVector3(-0.12, -0.10, 0)
            return parent
        }
    }
}
