import XCTest
import simd
@testable import Lanvi

/// The face summary maths, fed with blend-shape values shaped like a FaceMetrics
/// recording (60 frames a second; a resting face sits around 0.02 to 0.08 on most
/// coefficients; a smile rises to 0.5 to 0.7 over about 0.3 s and holds; a blink
/// closes to about 0.9 for 120 to 180 ms). ARKit itself does not run in the
/// simulator, so these tests are where the numbers are checked.
final class FaceSummaryTests: XCTestCase {

    // MARK: A recorded-style session

    /// Builds frames for `seconds`, with smiles, blinks and head angles from the closures.
    private func session(seconds: Double, fps: Double = 60,
                         tracked: (Double) -> Bool = { _ in true },
                         smile: (Double) -> Float = { _ in 0.03 },
                         cheek: (Double) -> Float = { _ in 0.05 },
                         blink: (Double) -> Float = { _ in 0.06 },
                         pitchDeg: (Double) -> Float = { _ in 2 },
                         rollDeg: (Double) -> Float = { _ in 1 },
                         marks: [Double] = []) -> FaceSummaryBuilder {
        var b = FaceSummaryBuilder()
        b.thresholds.expectedInterval = 1 / fps
        var pending = marks.sorted()
        let n = Int(seconds * fps)
        for i in 0...n {
            let t = 1000 + Double(i) / fps       // ARFrame-like uptime seconds
            let rel = Double(i) / fps
            while let m = pending.first, m <= rel {
                b.mark(at: 1000 + m)
                pending.removeFirst()
            }
            // A little natural jitter, the same every run.
            let jitter = Float(sin(rel * 7.3) * 0.01)
            let s = max(0, smile(rel) + jitter)
            let shapes: [String: Float] = [
                "mouthSmile_L": s, "mouthSmile_R": max(0, s - 0.03),
                "cheekSquint_L": cheek(rel), "cheekSquint_R": cheek(rel),
                "eyeBlink_L": blink(rel), "eyeBlink_R": blink(rel),
                "browDown_L": 0.04, "browDown_R": 0.05, "browInnerUp": 0.08 + jitter,
                "eyeLookDown_L": 0.2, "eyeLookDown_R": 0.2,
                "jawOpen": 0.05 + jitter, "mouthClose": 0.02,
            ]
            b.add(FaceFrame(time: t, tracked: tracked(rel), shapes: shapes,
                            pitch: pitchDeg(rel) * .pi / 180, yaw: 0, roll: rollDeg(rel) * .pi / 180,
                            cameraWeight: 1))
        }
        return b
    }

    /// A smile: 0.3 s up to `peak`, held for `hold` seconds, 0.3 s down.
    private func smileCurve(at starts: [Double], peak: [Float], hold: Double = 1.0) -> (Double) -> Float {
        { t in
            for (i, s) in starts.enumerated() {
                let p = peak[i]
                let up = 0.3, down = 0.3
                if t >= s && t < s + up { return 0.03 + (p - 0.03) * Float((t - s) / up) }
                if t >= s + up && t < s + up + hold { return p }
                if t >= s + up + hold && t < s + up + hold + down {
                    return p - (p - 0.03) * Float((t - s - up - hold) / down)
                }
            }
            return 0.03
        }
    }

    /// Blinks of `ms` milliseconds starting at the given times.
    private func blinkCurve(at starts: [Double], ms: Double = 150) -> (Double) -> Float {
        { t in
            for s in starts where t >= s && t < s + ms / 1000 { return 0.9 }
            return 0.06
        }
    }

    // MARK: Tests

    func testAMinuteOfPlay() throws {
        let blinks = stride(from: 2.0, through: 58.0, by: 4.0).map { $0 }   // 15 blinks
        let b = session(seconds: 60,
                        smile: smileCurve(at: [10, 25, 40], peak: [0.6, 0.5, 0.7]),
                        cheek: { t in (t > 25 && t < 27) ? 0.35 : 0.05 },
                        blink: blinkCurve(at: blinks))
        let f = try XCTUnwrap(b.summary())

        XCTAssertEqual(f.smileRatePerMin!, 3, accuracy: 0.1)
        XCTAssertEqual(f.smileIntensity!, 0.6, accuracy: 0.03)
        XCTAssertEqual(f.blinkRatePerMin!, 15, accuracy: 0.3)
        XCTAssertEqual(f.blinkDurationMs!, 150, accuracy: 20)
        // Three smiles of about 1.4 s each above the "on" threshold out of 60 s.
        XCTAssertEqual(f.smileTimeShare!, 0.07, accuracy: 0.02)
        // Only the second smile had a cheek raise.
        XCTAssertEqual(f.eyeSmileShare!, 1.0 / 3.0, accuracy: 0.01)
        // The right side smiles 0.03 less: a small asymmetry.
        XCTAssertGreaterThan(f.smileAsymmetry!, 0.02)
        XCTAssertLessThan(f.smileAsymmetry!, 0.15)
        XCTAssertEqual(f.headPitchDeg!, 2, accuracy: 0.01)
        XCTAssertEqual(f.headTiltDeg!, 1, accuracy: 0.01)
        XCTAssertEqual(f.lookDownShare!, 0, accuracy: 0.001)
        XCTAssertEqual(f.headMovement!, 0, accuracy: 0.001)
        XCTAssertEqual(f.browDownShare!, 0, accuracy: 0.001)
        XCTAssertEqual(f.innerBrowUpShare!, 0, accuracy: 0.001)
        XCTAssertGreaterThan(f.facialActivity!, 0)
        XCTAssertLessThan(f.facialActivity!, 1)
        XCTAssertEqual(f.trackingQuality, 1, accuracy: 0.01)
        XCTAssertNil(f.smileResponseShare, "no pleasant moments were marked")
    }

    func testTooLittleFaceGivesNoSummary() {
        let b = session(seconds: 4)
        XCTAssertNil(b.summary())
        XCTAssertNil(FaceSummaryBuilder().summary())
    }

    func testLostFaceLowersQualityAndIsNotCounted() throws {
        // The face is gone for the middle 30 s.
        let b = session(seconds: 60, tracked: { t in t < 15 || t >= 45 },
                        blink: blinkCurve(at: [5, 10, 20, 30, 50, 55]))
        let f = try XCTUnwrap(b.summary())
        // 4 blinks seen in 30 tracked seconds: 8 a minute, not 6.
        XCTAssertEqual(f.blinkRatePerMin!, 8, accuracy: 0.5)
        // 0.5 * 0.5 tracked + 0.3 + 0.2 = 0.75
        XCTAssertEqual(f.trackingQuality, 0.75, accuracy: 0.02)
    }

    func testDroppedFramesLowerQuality() throws {
        // Frames at 20 a second where 60 were expected: two of three dropped.
        var b = FaceSummaryBuilder()
        for i in 0...(20 * 30) {
            b.add(FaceFrame(time: Double(i) / 20, tracked: true, shapes: ["mouthSmile_L": 0.02]))
        }
        let f = try XCTUnwrap(b.summary())
        // dropped share 2/3: 0.5 + 0.3 * (1/3) + 0.2 = 0.8
        XCTAssertEqual(f.trackingQuality, 0.8, accuracy: 0.02)
    }

    func testSmileResponseToPleasantMoments() throws {
        // Lanvi cheers at 10 s, 30 s and 50 s. A smile follows the first after 1.2 s,
        // the person is already smiling at the second, and nothing follows the third.
        let b = session(seconds: 58,
                        smile: smileCurve(at: [11.2, 29.5], peak: [0.6, 0.6], hold: 2),
                        marks: [10, 30, 50])
        let f = try XCTUnwrap(b.summary())
        XCTAssertEqual(f.smileResponseShare!, 2.0 / 3.0, accuracy: 0.01)
        // Median of 0 (already smiling) and about 1.25 (onset crosses 0.25 a little after 11.2).
        XCTAssertEqual(f.smileResponseLatencyS!, 0.65, accuracy: 0.1)
    }

    func testAMomentTooCloseToTheEndIsNotCounted() throws {
        let b = session(seconds: 30, marks: [29])
        let f = try XCTUnwrap(b.summary())
        XCTAssertNil(f.smileResponseShare)
    }

    func testLongClosureIsNotABlink() throws {
        let b = session(seconds: 30, blink: { t in
            if t >= 5 && t < 5.15 { return 0.9 }        // a blink
            if t >= 10 && t < 11.5 { return 0.95 }      // eyes closed 1.5 s: a closure
            return 0.06
        })
        let f = try XCTUnwrap(b.summary())
        XCTAssertEqual(f.blinkRatePerMin!, 2, accuracy: 0.1)   // one blink in half a minute
        XCTAssertEqual(f.blinkDurationMs!, 150, accuracy: 20)
        XCTAssertEqual(b.closures, 1)
    }

    func testLookingDownAndMovingHead() throws {
        // Looking down 20 degrees for the first half, then nodding.
        let b = session(seconds: 40,
                        pitchDeg: { t in t < 20 ? 20 : Float(8 * sin(t * 2)) },
                        rollDeg: { _ in -4 })
        let f = try XCTUnwrap(b.summary())
        XCTAssertEqual(f.lookDownShare!, 0.5, accuracy: 0.03)
        XCTAssertEqual(f.headTiltDeg!, -4, accuracy: 0.01)
        XCTAssertGreaterThan(f.headPitchDeg!, 9)
        // Nodding 8 degrees has a pitch std of about 0.1 rad: over the 0.05 reference half the time.
        XCTAssertGreaterThan(f.headMovement!, 0.2)
        XCTAssertLessThanOrEqual(f.headMovement!, 1)
    }

    func testValuesStayInsideTheServerRanges() throws {
        // A wild, noisy face: every value must still be inside the API's limits.
        var b = FaceSummaryBuilder()
        var rng = SeededRandom(seed: 42)
        for i in 0...(60 * 45) {
            var shapes: [String: Float] = [:]
            for k in ["mouthSmile_L", "mouthSmile_R", "eyeBlink_L", "eyeBlink_R", "browDown_L", "browDown_R",
                      "browInnerUp", "cheekSquint_L", "cheekSquint_R", "eyeLookDown_L", "eyeLookDown_R"] {
                shapes[k] = Float(rng.unit())
            }
            b.add(FaceFrame(time: Double(i) / 60, tracked: rng.unit() > 0.1, shapes: shapes,
                            pitch: Float(rng.unit() * 3 - 1.5), yaw: Float(rng.unit() - 0.5),
                            roll: Float(rng.unit() * 3 - 1.5)))
            if i % 300 == 0 { b.mark(at: Double(i) / 60) }
        }
        let f = try XCTUnwrap(b.summary())
        let unit: [Double?] = [f.smileIntensity, f.facialActivity, f.lookDownShare, f.smileTimeShare,
                               f.eyeSmileShare, f.smileResponseShare, f.browDownShare, f.innerBrowUpShare,
                               f.headMovement, f.smileAsymmetry, f.trackingQuality]
        for v in unit.compactMap({ $0 }) { XCTAssert((0...1).contains(v), "\(v) outside 0...1") }
        for v in [f.smileRatePerMin, f.blinkRatePerMin].compactMap({ $0 }) { XCTAssert((0...120).contains(v)) }
        for v in [f.headTiltDeg, f.headPitchDeg].compactMap({ $0 }) { XCTAssert((-90...90).contains(v)) }
        if let d = f.blinkDurationMs { XCTAssert((0...2000).contains(d)) }
        if let l = f.smileResponseLatencyS { XCTAssert((0...30).contains(l)) }
    }

    func testFaceJSONUsesTheServerNames() throws {
        let b = session(seconds: 20, smile: smileCurve(at: [5], peak: [0.6]), marks: [4])
        let f = try XCTUnwrap(b.summary())
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: API.encoder.encode(f)) as? [String: Any])
        let allowed: Set<String> = [
            "smile_rate_per_min", "smile_intensity", "facial_activity", "blink_rate_per_min",
            "look_down_share", "head_tilt_deg", "smile_time_share", "eye_smile_share",
            "smile_response_share", "smile_response_latency_s", "brow_down_share",
            "inner_brow_up_share", "blink_duration_ms", "head_pitch_deg", "head_movement",
            "smile_asymmetry", "tracking_quality",
        ]
        XCTAssert(Set(json.keys).isSubset(of: allowed), "unknown keys: \(Set(json.keys).subtracting(allowed))")
        XCTAssertNotNil(json["tracking_quality"])
        XCTAssertNotNil(json["smile_rate_per_min"])
        XCTAssertNotNil(json["smile_response_latency_s"])
    }

    func testEulerAnglesMatchFaceMetrics() {
        // A pure rotation about X by 20 degrees (looking down) gives pitch +20.
        let a: Float = 20 * .pi / 180
        let m = simd_float4x4(columns: (SIMD4(1, 0, 0, 0), SIMD4(0, cos(a), sin(a), 0),
                                        SIMD4(0, -sin(a), cos(a), 0), SIMD4(0, 0, -0.3, 1)))
        let e = FaceAngles.euler(m)
        XCTAssertEqual(e.x * 180 / .pi, 20, accuracy: 0.01)
        XCTAssertEqual(e.y, 0, accuracy: 0.0001)
        XCTAssertEqual(e.z, 0, accuracy: 0.0001)
    }

    func testTrackerIsSkippedInTheSimulator() {
        #if targetEnvironment(simulator)
        XCTAssertFalse(FaceTracker.isSupported)
        let t = FaceTracker()
        XCTAssertFalse(t.start())
        XCTAssertNil(t.finish())
        #endif
    }
}
