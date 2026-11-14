import Foundation
import simd
#if canImport(ARKit)
import ARKit
#endif

/// Runs ARKit face tracking quietly behind a game and turns each frame into a few
/// numbers for `FaceSummaryBuilder`. No view, no preview: the camera image is never
/// shown, kept or sent. Approach after Peter's `ARSessionController` and
/// `FaceTrackingManager` (`facemetrics/FaceMetrics/Tracking/`): delegate on its own
/// serial queue, nothing from an `ARFrame` kept beyond the callback.
///
/// Any trouble (no TrueDepth camera, camera denied, an interruption, a session
/// error) and `finish()` answers nil, so the game goes on exactly as before and no
/// `face` object is sent.
final class FaceTracker: NSObject, @unchecked Sendable {

    /// True on a phone with a TrueDepth camera. Always false in the simulator.
    static var isSupported: Bool {
        #if canImport(ARKit) && !targetEnvironment(simulator)
        return ARFaceTrackingConfiguration.isSupported
        #else
        return false
        #endif
    }

    private let queue = DispatchQueue(label: "app.lanvi.face", qos: .userInitiated)
    private var builder = FaceSummaryBuilder()
    private var spoiled = false
    private var running = false
    #if canImport(ARKit) && !targetEnvironment(simulator)
    private var session: ARSession?
    #endif

    /// Starts tracking. Returns false (and does nothing) when it cannot run here.
    @discardableResult
    func start() -> Bool {
        #if canImport(ARKit) && !targetEnvironment(simulator)
        guard Self.isSupported else { return false }
        let config = ARFaceTrackingConfiguration()
        config.maximumNumberOfTrackedFaces = 1
        config.isLightEstimationEnabled = false
        // The slowest format that still gives 30 frames a second: kinder to the battery
        // and to the game, and plenty for blinks and smiles.
        let formats = ARFaceTrackingConfiguration.supportedVideoFormats
        if let calm = formats.filter({ $0.framesPerSecond >= 30 }).min(by: { $0.framesPerSecond < $1.framesPerSecond }) {
            config.videoFormat = calm
        }
        let fps = Double(config.videoFormat.framesPerSecond)
        queue.sync {
            builder = FaceSummaryBuilder()
            builder.thresholds.expectedInterval = 1 / max(fps, 1)
            spoiled = false
            running = true
        }
        let s = ARSession()
        s.delegate = self
        s.delegateQueue = queue
        session = s
        s.run(config, options: [.resetTracking, .removeExistingAnchors])
        return true
        #else
        return false
        #endif
    }

    /// A pleasant moment in the game, for the smile response.
    func mark() {
        let now = ProcessInfo.processInfo.systemUptime   // same clock as ARFrame.timestamp
        queue.async { [self] in
            guard running else { return }
            builder.mark(at: now)
        }
    }

    /// Stops tracking and gives the summary, or nil when there is nothing trustworthy.
    func finish() -> API.FaceSummary? {
        #if canImport(ARKit) && !targetEnvironment(simulator)
        session?.pause()
        session?.delegate = nil
        session = nil
        #endif
        return queue.sync {
            defer {
                running = false
                builder = FaceSummaryBuilder()   // forget everything once summarised
            }
            guard running, !spoiled else { return nil }
            return builder.summary()
        }
    }

    /// Stops without a summary (the game was closed early or went away).
    func cancel() {
        _ = finish()
    }
}

#if canImport(ARKit) && !targetEnvironment(simulator)
extension FaceTracker: ARSessionDelegate {
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // Read what we need and let the frame go at once.
        let time = frame.timestamp
        let camera = frame.camera
        let weight: Float
        switch camera.trackingState {
        case .normal: weight = 1
        case .limited: weight = 0.5
        case .notAvailable: weight = 0
        }
        var f = FaceFrame(time: time, tracked: false, cameraWeight: weight)
        if let anchor = frame.anchors.lazy.compactMap({ $0 as? ARFaceAnchor }).first, anchor.isTracked {
            f.tracked = true
            var shapes: [String: Float] = [:]
            shapes.reserveCapacity(anchor.blendShapes.count)
            for (key, value) in anchor.blendShapes { shapes[key.rawValue] = value.floatValue }
            f.shapes = shapes
            // Portrait camera view (as in HeadPoseProcessor): +X right, +Y up.
            let view = camera.viewMatrix(for: .portrait) * anchor.transform
            let e = FaceAngles.euler(view)
            f.pitch = e.x; f.yaw = e.y; f.roll = e.z
        }
        guard running else { return }
        builder.add(f)
    }

    func sessionWasInterrupted(_ session: ARSession) {
        spoiled = true
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        spoiled = true
    }
}
#endif

/// Peter's `MathSupport.eulerAngles`: pitch about X, yaw about Y, roll about Z,
/// R = Rz(roll) * Ry(yaw) * Rx(pitch), from a column-major transform.
enum FaceAngles {
    static func euler(_ m: simd_float4x4) -> SIMD3<Float> {
        let r0 = simd_normalize(SIMD3<Float>(m.columns.0.x, m.columns.0.y, m.columns.0.z))
        let r1 = simd_normalize(SIMD3<Float>(m.columns.1.x, m.columns.1.y, m.columns.1.z))
        let r2 = simd_normalize(SIMD3<Float>(m.columns.2.x, m.columns.2.y, m.columns.2.z))
        let sy = -r0.z
        let yaw = asin(max(-1, min(1, sy)))
        if abs(sy) < 0.9999 {
            return SIMD3(atan2(r1.z, r2.z), yaw, atan2(r0.y, r0.x))
        }
        return SIMD3(atan2(-r2.y, r1.y), yaw, 0)
    }
}
