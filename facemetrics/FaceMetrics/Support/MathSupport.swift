import Foundation
import simd

/// Small numeric helpers shared by the processors. Everything here is pure and thread-safe.
enum MathSupport {

    /// Extracts Tait-Bryan angles (pitch about X, yaw about Y, roll about Z) in radians
    /// from the rotation part of a column-major transform, using the convention
    /// R = Rz(roll) * Ry(yaw) * Rx(pitch).
    static func eulerAngles(from transform: simd_float4x4) -> SIMD3<Float> {
        let c0 = transform.columns.0
        let c1 = transform.columns.1
        let c2 = transform.columns.2
        // Normalise the columns in case the matrix carries scale.
        let r0 = simd_normalize(SIMD3<Float>(c0.x, c0.y, c0.z))
        let r1 = simd_normalize(SIMD3<Float>(c1.x, c1.y, c1.z))
        let r2 = simd_normalize(SIMD3<Float>(c2.x, c2.y, c2.z))
        // Matrix element R[row][col]: R[2][0] = r0.z, R[2][1] = r1.z, R[2][2] = r2.z, R[1][0] = r0.y, R[0][0] = r0.x
        let sy = -r0.z
        let yaw = asin(max(-1, min(1, sy)))
        let pitch: Float
        let roll: Float
        if abs(sy) < 0.9999 {
            pitch = atan2(r1.z, r2.z)
            roll = atan2(r0.y, r0.x)
        } else {
            // Gimbal lock: yaw is +-90 degrees, distribute remaining rotation into pitch.
            pitch = atan2(-r2.y, r1.y)
            roll = 0
        }
        return SIMD3<Float>(pitch, yaw, roll)
    }

    static func translation(of transform: simd_float4x4) -> SIMD3<Float> {
        let c = transform.columns.3
        return SIMD3<Float>(c.x, c.y, c.z)
    }

    static func axis(_ index: Int, of transform: simd_float4x4) -> SIMD3<Float> {
        let c: SIMD4<Float>
        switch index {
        case 0: c = transform.columns.0
        case 1: c = transform.columns.1
        default: c = transform.columns.2
        }
        let v = SIMD3<Float>(c.x, c.y, c.z)
        let len = simd_length(v)
        return len > 0 ? v / len : v
    }

    /// Rotates a direction vector by the rotation part of a transform (ignores translation).
    static func rotate(_ v: SIMD3<Float>, by transform: simd_float4x4) -> SIMD3<Float> {
        let r = simd_float3x3(
            SIMD3<Float>(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z),
            SIMD3<Float>(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z),
            SIMD3<Float>(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z)
        )
        return r * v
    }

    static func transformPoint(_ p: SIMD3<Float>, by transform: simd_float4x4) -> SIMD3<Float> {
        let v = transform * SIMD4<Float>(p.x, p.y, p.z, 1)
        return SIMD3<Float>(v.x, v.y, v.z)
    }

    /// Wraps an angle difference into (-pi, pi].
    static func wrapAngle(_ a: Float) -> Float {
        var x = a
        while x > .pi { x -= 2 * .pi }
        while x <= -.pi { x += 2 * .pi }
        return x
    }

    static func wrapAngles(_ v: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3<Float>(wrapAngle(v.x), wrapAngle(v.y), wrapAngle(v.z))
    }

    static func degrees(_ radians: Float) -> Float { radians * 180 / .pi }
    static func degrees(_ v: SIMD3<Float>) -> SIMD3<Float> { v * (180 / .pi) }

    /// Angle in degrees between two direction vectors.
    static func angleDegrees(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
        let la = simd_length(a), lb = simd_length(b)
        guard la > 0, lb > 0 else { return 0 }
        let c = max(-1, min(1, simd_dot(a, b) / (la * lb)))
        return degrees(acos(c))
    }

    /// Flattens a 4x4 matrix into 16 floats in row-major order (m00, m01, m02, m03, m10, ...).
    static func rowMajor(_ m: simd_float4x4) -> [Float] {
        var out = [Float](repeating: 0, count: 16)
        for row in 0..<4 {
            out[row * 4 + 0] = m.columns.0[row]
            out[row * 4 + 1] = m.columns.1[row]
            out[row * 4 + 2] = m.columns.2[row]
            out[row * 4 + 3] = m.columns.3[row]
        }
        return out
    }

    /// Yaw (rotation about Y, positive toward +X) and pitch (positive toward +Y) of a direction
    /// in a right-handed frame where the camera looks down -Z. Returned in degrees.
    /// For a face-anchor-space direction the "forward" axis is +Z instead, so callers pass
    /// `forwardIsPositiveZ: true` there.
    static func yawPitchDegrees(of direction: SIMD3<Float>, forwardIsPositiveZ: Bool) -> (yaw: Float, pitch: Float) {
        let d = simd_normalize(direction)
        let forward = forwardIsPositiveZ ? d.z : -d.z
        let yaw = atan2(d.x, forward)
        let pitch = atan2(d.y, sqrt(d.x * d.x + forward * forward))
        return (degrees(yaw), degrees(pitch))
    }

    static func mean(_ values: [Float]) -> Float {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Float(values.count)
    }

    static func standardDeviation(_ values: [Float]) -> Float {
        guard values.count > 1 else { return 0 }
        let m = mean(values)
        var acc: Float = 0
        for v in values { let d = v - m; acc += d * d }
        return sqrt(acc / Float(values.count - 1))
    }

    static func clamp01(_ x: Float) -> Float { max(0, min(1, x)) }
}

extension simd_float4x4 {
    static let identityMatrix = matrix_identity_float4x4
}
