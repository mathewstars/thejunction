import Foundation
import UIKit
import ARKit
import simd

/// Windowed head-movement figures. All application-derived from the pose series.
struct HeadMovementMetrics {
    /// |angular velocity| magnitude, rad/s.
    var angularSpeed: Float
    /// Linear speed in view space, m/s.
    var linearSpeed: Float
    /// Mean over pitch/yaw/roll of (max - min) inside the window, radians.
    var movementAmplitude: Float
    /// Zero-crossing rate of the mean-removed yaw+pitch signal inside the window, Hz.
    var movementFrequencyHz: Float
    /// Mean standard deviation of pitch/yaw/roll inside the window, radians.
    var variability: Float
    /// 1 - clamp(variability / 0.05 rad) : 1 means the head barely moved inside the window.
    var stability: Float
    var windowSeconds: Double
}

/// Extracts position and orientation from the face anchor and camera, and derives velocities,
/// accelerations and windowed movement statistics.
final class HeadPoseProcessor {

    var windowSeconds: Double = 5
    /// Stability formula constant: variability at or above this (radians) scores 0.
    var stabilityReferenceRadians: Float = 0.05

    private var previous: (time: Double, euler: SIMD3<Float>, position: SIMD3<Float>, velocity: SIMD3<Float>?)?
    private var referencePose: (position: SIMD3<Float>, euler: SIMD3<Float>)?
    private var pendingBaselineReset = true
    private(set) var history = TimeAlignedHistory(capacity: 1800)

    func requestBaselineReset() { pendingBaselineReset = true }

    func process(anchor: ARFaceAnchor, camera: ARCamera, timestamp: Double) -> HeadPoseReading {
        let world = anchor.transform
        // viewMatrix(for:) accounts for interface orientation, so view space is "portrait screen":
        // +X right, +Y up, -Z into the scene.
        let view = camera.viewMatrix(for: .portrait) * world
        let worldPos = MathSupport.translation(of: world)
        let viewPos = MathSupport.translation(of: view)
        let worldEuler = MathSupport.eulerAngles(from: world)
        let viewEuler = MathSupport.eulerAngles(from: view)

        var reading = HeadPoseReading(
            worldTransform: world,
            viewTransform: view,
            worldPosition: worldPos,
            viewPosition: viewPos,
            worldEuler: worldEuler,
            viewEuler: viewEuler,
            distanceToCamera: simd_length(viewPos),
            angularVelocity: nil,
            angularAcceleration: nil,
            linearVelocity: nil,
            relativePosition: nil,
            relativeEuler: nil
        )

        if pendingBaselineReset {
            referencePose = (viewPos, viewEuler)
            pendingBaselineReset = false
        }
        if let ref = referencePose {
            reading.relativePosition = viewPos - ref.position
            reading.relativeEuler = MathSupport.wrapAngles(viewEuler - ref.euler)
        }

        var velocity: SIMD3<Float>? = nil
        if let prev = previous {
            let dt = Float(timestamp - prev.time)
            if dt > 0 {
                let dEuler = MathSupport.wrapAngles(viewEuler - prev.euler)
                let v = dEuler / dt
                velocity = v
                reading.angularVelocity = v
                reading.linearVelocity = (viewPos - prev.position) / dt
                if let pv = prev.velocity {
                    reading.angularAcceleration = (v - pv) / dt
                }
            }
        }
        previous = (timestamp, viewEuler, viewPos, velocity)

        history.append(time: timestamp, values: [
            "pitch": viewEuler.x,
            "yaw": viewEuler.y,
            "roll": viewEuler.z,
            "angularSpeed": velocity.map { simd_length($0) } ?? .nan,
            "x": viewPos.x, "y": viewPos.y, "z": viewPos.z
        ])
        return reading
    }

    /// Call when a frame has no tracked face so derivatives do not bridge the gap.
    func noteMissingFrame(timestamp: Double) {
        previous = nil
        history.append(time: timestamp, values: [:])
    }

    func windowedMetrics(reading: HeadPoseReading?) -> HeadMovementMetrics? {
        let n = history.sampleCount(withinLast: windowSeconds)
        guard n >= 4 else { return nil }
        let pitch = history.values(for: "pitch", last: n)
        let yaw = history.values(for: "yaw", last: n)
        let roll = history.values(for: "roll", last: n)
        guard pitch.count >= 4, yaw.count >= 4, roll.count >= 4 else { return nil }

        func range(_ a: [Float]) -> Float { (a.max() ?? 0) - (a.min() ?? 0) }
        let amplitude = (range(pitch) + range(yaw) + range(roll)) / 3
        let variability = (MathSupport.standardDeviation(pitch) + MathSupport.standardDeviation(yaw) + MathSupport.standardDeviation(roll)) / 3

        // Movement frequency: zero crossings of the mean-removed combined (yaw + pitch) signal.
        let count = min(pitch.count, yaw.count)
        var combined = [Float](repeating: 0, count: count)
        for i in 0..<count { combined[i] = pitch[pitch.count - count + i] + yaw[yaw.count - count + i] }
        let m = MathSupport.mean(combined)
        var crossings = 0
        for i in 1..<count where (combined[i - 1] - m) * (combined[i] - m) < 0 { crossings += 1 }
        let seconds = Float(windowSeconds)
        let frequency = seconds > 0 ? Float(crossings) / 2 / seconds : 0

        let stability = 1 - MathSupport.clamp01(variability / stabilityReferenceRadians)

        return HeadMovementMetrics(
            angularSpeed: reading?.angularVelocity.map { simd_length($0) } ?? 0,
            linearSpeed: reading?.linearVelocity.map { simd_length($0) } ?? 0,
            movementAmplitude: amplitude,
            movementFrequencyHz: frequency,
            variability: variability,
            stability: stability,
            windowSeconds: windowSeconds
        )
    }

    func recent(_ key: String, count: Int) -> [Float] { history.values(for: key, last: count) }

    func reset() {
        previous = nil
        referencePose = nil
        pendingBaselineReset = true
        history.removeAll()
    }
}
