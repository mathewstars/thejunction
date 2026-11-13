import Foundation
import ARKit
import simd

/// Snapshot of the latest mesh for the geometry lab and for opt-in geometry recording.
/// Vertices are in face-anchor space (metres). Triangle indices are shared by every frame.
struct FaceMeshData {
    let timestamp: Double
    let vertices: [SIMD3<Float>]
    let triangleIndices: [Int16]
    let textureCoordinates: [SIMD2<Float>]
    let viewTransform: simd_float4x4
}

/// Reads ARFaceGeometry each frame, derives update magnitude and keeps the most recent mesh
/// behind a lock so a render loop on another thread can pick it up.
final class FaceGeometryProcessor {

    private let lock = NSLock()
    private var latestMesh: FaceMeshData?
    private var latestARGeometry: ARFaceGeometry?
    private var previousVertices: [SIMD3<Float>]?
    private var referenceVertices: [SIMD3<Float>]?
    // Topology and texture coordinates never change for a session; copy them from ARKit once.
    private var cachedIndices: [Int16]?
    private var cachedTextureCoordinates: [SIMD2<Float>]?
    private var pendingReferenceCapture = false
    private(set) var meshUpdateCount: Int = 0
    private(set) var lastMeshUpdateTimestamp: Double?

    /// Set to false to skip the per-frame vertex copy when nothing consumes it.
    var retainsMesh: Bool = true

    func process(anchor: ARFaceAnchor, viewTransform: simd_float4x4, timestamp: Double) -> GeometryReading {
        let geometry = anchor.geometry
        let vertices = geometry.vertices
        var minV = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var maxV = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for v in vertices {
            minV = simd_min(minV, v)
            maxV = simd_max(maxV, v)
        }
        var meanDisp: Float? = nil
        var maxDisp: Float? = nil
        if let prev = previousVertices, prev.count == vertices.count, !vertices.isEmpty {
            var acc: Float = 0
            var mx: Float = 0
            for i in 0..<vertices.count {
                let d = simd_length(vertices[i] - prev[i])
                acc += d
                if d > mx { mx = d }
            }
            meanDisp = acc / Float(vertices.count)
            maxDisp = mx
        }
        previousVertices = vertices
        meshUpdateCount += 1
        lastMeshUpdateTimestamp = timestamp

        if retainsMesh {
            if cachedIndices == nil || cachedIndices?.count != geometry.triangleCount * 3 {
                cachedIndices = geometry.triangleIndices
                cachedTextureCoordinates = geometry.textureCoordinates
            }
            let mesh = FaceMeshData(
                timestamp: timestamp,
                vertices: vertices,
                triangleIndices: cachedIndices ?? [],
                textureCoordinates: cachedTextureCoordinates ?? [],
                viewTransform: viewTransform
            )
            lock.lock()
            latestMesh = mesh
            latestARGeometry = geometry
            if pendingReferenceCapture {
                referenceVertices = vertices
                pendingReferenceCapture = false
            }
            lock.unlock()
        }

        return GeometryReading(
            vertexCount: geometry.vertexCount,
            triangleCount: geometry.triangleCount,
            textureCoordinateCount: geometry.textureCoordinateCount,
            boundingBoxMin: vertices.isEmpty ? .zero : minV,
            boundingBoxMax: vertices.isEmpty ? .zero : maxV,
            meanVertexDisplacement: meanDisp,
            maxVertexDisplacement: maxDisp
        )
    }

    func noteMissingFrame() {
        previousVertices = nil
    }

    /// Latest mesh copy for rendering or recording. Safe from any thread.
    func currentMesh() -> FaceMeshData? {
        lock.lock(); defer { lock.unlock() }
        return latestMesh
    }

    /// The most recent ARFaceGeometry object. It holds no camera imagery, so retaining it is safe.
    func currentARGeometry() -> ARFaceGeometry? {
        lock.lock(); defer { lock.unlock() }
        return latestARGeometry
    }

    /// Reference mesh for the displacement heat-map view (captured on request, e.g. a neutral face).
    func referenceMesh() -> [SIMD3<Float>]? {
        lock.lock(); defer { lock.unlock() }
        return referenceVertices
    }

    func captureReferenceOnNextFrame() {
        lock.lock(); pendingReferenceCapture = true; lock.unlock()
    }

    func clearReference() {
        lock.lock(); referenceVertices = nil; lock.unlock()
    }

    func reset() {
        lock.lock()
        latestMesh = nil
        latestARGeometry = nil
        referenceVertices = nil
        lock.unlock()
        previousVertices = nil
        cachedIndices = nil
        cachedTextureCoordinates = nil
        meshUpdateCount = 0
        lastMeshUpdateTimestamp = nil
    }
}
