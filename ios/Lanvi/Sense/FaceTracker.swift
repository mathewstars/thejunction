import Foundation
import simd
#if canImport(ARKit)
import ARKit
#endif

/// Runs ARKit face tracking quietly behind a game and writes each frame's numbers into
/// a `FaceRawRecorder`. No view, no preview: the camera image is never shown, kept or
/// sent. Approach after Peter's `ARSessionController`, `FaceTrackingManager` and
/// `HeadPoseProcessor` (`facemetrics/FaceMetrics/Tracking/`): delegate on its own serial
/// queue, the face anchor read in portrait camera space, nothing from an `ARFrame` kept
/// beyond the callback.
///
/// Any trouble (no TrueDepth camera, camera denied, an interruption, a session error)
/// and `finish` answers with nothing, so the game goes on exactly as before and no
/// `face_raw` is sent.
///
/// Beside the raw frames it feeds a `FaceFineRecorder` from the face mesh (research
/// only, `docs/face-fine.md`): one distance per region and frame, computed here.
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
    private var recorder = FaceRawRecorder()
    private var fine = FaceFineRecorder()
    private var fineOn = false

    /// What one game gave: the raw frames and, beside them, the fine movement stream.
    struct Captured {
        var raw: API.FaceRaw?
        var fine: API.FaceFine?
    }
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
        // and to the game, and what the server asks for.
        let formats = ARFaceTrackingConfiguration.supportedVideoFormats
        if let calm = formats.filter({ $0.framesPerSecond >= 30 }).min(by: { $0.framesPerSecond < $1.framesPerSecond }) {
            config.videoFormat = calm
        }
        queue.sync {
            recorder = FaceRawRecorder(rateHz: 30)
            fine = FaceFineRecorder(rateHz: 30)
            fineOn = FaceFineRecorder.isEnabled
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

    /// A pleasant moment in the game (`moments_ms`).
    func mark() {
        let now = ProcessInfo.processInfo.systemUptime   // same clock as ARFrame.timestamp
        queue.async { [self] in
            guard running else { return }
            recorder.mark(at: now)
        }
    }

    /// Stops tracking and gives the frames, or nil when there is nothing trustworthy.
    /// `seconds` is the activity's `duration_s`: only that much of the end is kept.
    func finish(seconds: Double?) -> Captured {
        #if canImport(ARKit) && !targetEnvironment(simulator)
        session?.pause()
        session?.delegate = nil
        session = nil
        #endif
        return queue.sync {
            defer {
                running = false
                recorder = FaceRawRecorder()   // forget the frames once handed over
                fine = FaceFineRecorder()      // and the resting shape with them
            }
            guard running, !spoiled else { return Captured() }
            let keep = seconds.map { $0 + 1 }
            #if DEBUG
            if fineOn { print("lanvi-sense: face_fine regions \(fine.regionSizes.sorted { $0.key < $1.key })") }
            #endif
            return Captured(raw: recorder.faceRaw(lastSeconds: keep),
                            fine: fineOn ? fine.faceFine(lastSeconds: keep) : nil)
        }
    }

    /// Stops and keeps nothing (the game was closed early or went away).
    func cancel() {
        _ = finish(seconds: nil)
    }
}

#if canImport(ARKit) && !targetEnvironment(simulator)
extension FaceTracker: ARSessionDelegate {
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard running else { return }
        // Read the numbers and let the frame go at once.
        let time = frame.timestamp
        guard let anchor = frame.anchors.lazy.compactMap({ $0 as? ARFaceAnchor }).first, anchor.isTracked else {
            recorder.add(time: time, tracked: false, shapes: [:], pitch: 0, yaw: 0, roll: 0)
            if fineOn { fine.add(time: time, tracked: false) { [] } }
            return
        }
        var shapes: [String: Float] = [:]
        shapes.reserveCapacity(anchor.blendShapes.count)
        for (key, value) in anchor.blendShapes { shapes[key.rawValue] = value.floatValue }
        // The face relative to the camera, portrait screen axes (+X right, +Y up), as in
        // Peter's HeadPoseProcessor. Pitch is then positive when the chin goes down.
        let view = frame.camera.viewMatrix(for: .portrait) * anchor.transform
        let e = FaceAngles.euler(view)
        let deg = 180 / Double.pi
        recorder.add(time: time, tracked: true, shapes: shapes,
                     pitch: Double(e.x) * deg, yaw: Double(e.y) * deg, roll: Double(e.z) * deg)
        // The mesh is read here and reduced to one number per region at once; it is
        // never kept beyond the resting shape of this game, and never sent.
        if fineOn { fine.add(time: time, tracked: true) { Array(anchor.geometry.vertices) } }
    }

    func sessionWasInterrupted(_ session: ARSession) {
        spoiled = true
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        spoiled = true
    }
}
#endif

/// Peter's `MathSupport.eulerAngles` (`facemetrics/FaceMetrics/Support/MathSupport.swift`):
/// pitch about X, yaw about Y, roll about Z, R = Rz(roll) * Ry(yaw) * Rx(pitch),
/// from a column-major transform. Radians.
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
