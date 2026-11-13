import Foundation
import ARKit
import simd

/// Windowed gaze statistics, application-derived.
struct GazeMetrics {
    /// Standard deviation of gaze yaw and pitch (degrees) inside the window, averaged.
    var gazeVariabilityDegrees: Float
    /// Mean angular speed of the gaze direction inside the window, deg/s.
    var meanGazeSpeed: Float
    /// Mean eye-forward angular change per second inside the window, deg/s (eye movement).
    var eyeMovementDegPerSecond: Float
    var windowSeconds: Double
}

/// Reads ARKit's per-eye transforms and lookAtPoint and derives gaze directions.
///
/// Limitations, stated plainly: ARKit gives an estimated eye orientation and a single focus
/// point in face-anchor space. There is no pupil tracking, no calibration and no
/// screen-coordinate gaze. The "camera plane hit" is a geometric ray intersection and
/// should be treated as approximate (typically several centimetres of error).
final class EyeTrackingProcessor {

    var windowSeconds: Double = 5

    private var previousGaze: (time: Double, direction: SIMD3<Float>, leftForward: SIMD3<Float>, rightForward: SIMD3<Float>)?
    private(set) var history = TimeAlignedHistory(capacity: 1800)

    func process(anchor: ARFaceAnchor, viewTransform: simd_float4x4, worldTransform: simd_float4x4, timestamp: Double) -> EyeReading {
        let left = anchor.leftEyeTransform
        let right = anchor.rightEyeTransform
        let leftPos = MathSupport.translation(of: left)
        let rightPos = MathSupport.translation(of: right)
        // Eye transforms point their +Z axis along the eye's viewing direction, like the face
        // anchor whose +Z points out of the face toward the camera.
        let leftFwd = MathSupport.axis(2, of: left)
        let rightFwd = MathSupport.axis(2, of: right)
        let lookAt = anchor.lookAtPoint
        let eyeMid = (leftPos + rightPos) / 2
        var gazeAnchor = lookAt - eyeMid
        let gazeLen = simd_length(gazeAnchor)
        gazeAnchor = gazeLen > 0 ? gazeAnchor / gazeLen : SIMD3<Float>(0, 0, 1)

        let gazeView = simd_normalize(MathSupport.rotate(gazeAnchor, by: viewTransform))
        let gazeWorld = simd_normalize(MathSupport.rotate(gazeAnchor, by: worldTransform))
        let leftFwdView = simd_normalize(MathSupport.rotate(leftFwd, by: viewTransform))
        let rightFwdView = simd_normalize(MathSupport.rotate(rightFwd, by: viewTransform))

        // In view space the camera looks down -Z, and a face looking at the camera has gaze +Z.
        // We report yaw/pitch of the gaze as seen by the camera: a gaze toward the camera is 0/0.
        let gazeYP = MathSupport.yawPitchDegrees(of: gazeView, forwardIsPositiveZ: true)
        let leftYP = MathSupport.yawPitchDegrees(of: leftFwdView, forwardIsPositiveZ: true)
        let rightYP = MathSupport.yawPitchDegrees(of: rightFwdView, forwardIsPositiveZ: true)

        // Camera plane hit: ray from the eye midpoint (view space) along gazeView until z == 0.
        let eyeMidView = MathSupport.transformPoint(eyeMid, by: viewTransform)
        var planeHit: SIMD2<Float>? = nil
        if gazeView.z > 1e-4, eyeMidView.z < 0 {
            let t = -eyeMidView.z / gazeView.z
            let hit = eyeMidView + gazeView * t
            planeHit = SIMD2<Float>(hit.x, hit.y)
        }

        var gazeSpeed: Float? = nil
        var eyeMovement: Float = .nan
        if let prev = previousGaze {
            let dt = Float(timestamp - prev.time)
            if dt > 0 {
                gazeSpeed = MathSupport.angleDegrees(prev.direction, gazeAnchor) / dt
                let lm = MathSupport.angleDegrees(prev.leftForward, leftFwd) / dt
                let rm = MathSupport.angleDegrees(prev.rightForward, rightFwd) / dt
                eyeMovement = (lm + rm) / 2
            }
        }
        previousGaze = (timestamp, gazeAnchor, leftFwd, rightFwd)

        history.append(time: timestamp, values: [
            "gazeYaw": gazeYP.yaw,
            "gazePitch": gazeYP.pitch,
            "gazeSpeed": gazeSpeed ?? .nan,
            "eyeMovement": eyeMovement,
            "leftYaw": leftYP.yaw, "leftPitch": leftYP.pitch,
            "rightYaw": rightYP.yaw, "rightPitch": rightYP.pitch
        ])

        return EyeReading(
            leftTransform: left,
            rightTransform: right,
            leftPosition: leftPos,
            rightPosition: rightPos,
            leftForwardAnchor: leftFwd,
            rightForwardAnchor: rightFwd,
            leftEulerAnchor: MathSupport.eulerAngles(from: left),
            rightEulerAnchor: MathSupport.eulerAngles(from: right),
            lookAtPointAnchor: lookAt,
            gazeDirectionAnchor: gazeAnchor,
            gazeDirectionView: gazeView,
            gazeDirectionWorld: gazeWorld,
            leftForwardView: leftFwdView,
            rightForwardView: rightFwdView,
            leftRightDivergenceDegrees: MathSupport.angleDegrees(leftFwd, rightFwd),
            gazeYawDegrees: gazeYP.yaw,
            gazePitchDegrees: gazeYP.pitch,
            leftYawDegrees: leftYP.yaw,
            leftPitchDegrees: leftYP.pitch,
            rightYawDegrees: rightYP.yaw,
            rightPitchDegrees: rightYP.pitch,
            gazePlaneHit: planeHit,
            gazeAngularSpeed: gazeSpeed
        )
    }

    func noteMissingFrame(timestamp: Double) {
        previousGaze = nil
        history.append(time: timestamp, values: [:])
    }

    func windowedMetrics() -> GazeMetrics? {
        let n = history.sampleCount(withinLast: windowSeconds)
        guard n >= 4 else { return nil }
        let yaw = history.values(for: "gazeYaw", last: n)
        let pitch = history.values(for: "gazePitch", last: n)
        let speed = history.values(for: "gazeSpeed", last: n)
        let movement = history.values(for: "eyeMovement", last: n)
        guard yaw.count >= 4 else { return nil }
        return GazeMetrics(
            gazeVariabilityDegrees: (MathSupport.standardDeviation(yaw) + MathSupport.standardDeviation(pitch)) / 2,
            meanGazeSpeed: MathSupport.mean(speed),
            eyeMovementDegPerSecond: MathSupport.mean(movement),
            windowSeconds: windowSeconds
        )
    }

    func recent(_ key: String, count: Int) -> [Float] { history.values(for: key, last: count) }

    func reset() {
        previousGaze = nil
        history.removeAll()
    }
}
