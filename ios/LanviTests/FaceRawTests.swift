import XCTest
import simd
@testable import Lanvi

/// The raw face frames the phone sends (`docs/face-raw.md`). Frames are shaped like a
/// FaceMetrics recording: ARKit's raw identifiers ("mouthSmile_L"), 60 Hz, a few
/// untracked frames, head angles in degrees.
final class FaceRawTests: XCTestCase {

    /// The channel block of docs/face-raw.md, read from the repo.
    private func documentedChannels() throws -> [String] {
        let doc = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/face-raw.md")
        let text = try String(contentsOf: doc, encoding: .utf8)
        let after = try XCTUnwrap(text.range(of: "## Channels")).upperBound
        let open = try XCTUnwrap(text.range(of: "```\n", range: after..<text.endIndex))
        let close = try XCTUnwrap(text.range(of: "```", range: open.upperBound..<text.endIndex))
        return text[open.upperBound..<close.lowerBound].split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
    }

    func testChannelsAreExactlyTheDocumentedOnes() throws {
        let doc = try documentedChannels()
        XCTAssertEqual(doc.count, 55)
        XCTAssertEqual(FaceRawRecorder.channels, doc)
        XCTAssertEqual(Set(FaceRawRecorder.channels).count, 55)
        for required in ["mouthSmileLeft", "mouthSmileRight", "eyeBlinkLeft", "eyeBlinkRight"] {
            XCTAssert(FaceRawRecorder.channels.contains(required))
        }
    }

    func testARKitNamesBecomeTheServerNames() {
        XCTAssertEqual(FaceRawRecorder.friendlyName("eyeBlink_L"), "eyeBlinkLeft")
        XCTAssertEqual(FaceRawRecorder.friendlyName("mouthSmile_R"), "mouthSmileRight")
        XCTAssertEqual(FaceRawRecorder.friendlyName("jawOpen"), "jawOpen")
        XCTAssertEqual(FaceRawRecorder.friendlyName("browInnerUp"), "browInnerUp")
    }

    private func smile(_ s: Float) -> [String: Float] {
        ["mouthSmile_L": s, "mouthSmile_R": s * 0.9, "eyeBlink_L": 0.08, "eyeBlink_R": 0.07,
         "cheekSquint_L": 0.0204, "jawOpen": 0.03, "tongueOut": 0, "someFutureShape_L": 0.5]
    }

    func testSixtyFramesASecondBecomeThirtyRowsAtThreeDecimals() throws {
        var r = FaceRawRecorder(rateHz: 30)
        for i in 0..<600 {   // 10 s at 60 Hz
            r.add(time: 1000 + Double(i) / 60, tracked: true, shapes: smile(0.31234),
                  pitch: 6.234, yaw: -1.4, roll: 0.8)
        }
        let raw = try XCTUnwrap(r.faceRaw())
        XCTAssertEqual(raw.rateHz, 30)
        XCTAssert((300...301).contains(raw.samples.count), "10 s at 30 Hz, the last 60 Hz frame may round up")
        XCTAssertNil(raw.tracked, "every frame tracked: tracked is left out")
        XCTAssertNil(raw.momentsMs)
        let row = raw.samples[0]
        XCTAssertEqual(row.count, 55)
        func v(_ name: String) -> Double { row[FaceRawRecorder.channels.firstIndex(of: name)!] }
        XCTAssertEqual(v("mouthSmileLeft"), 0.312)
        XCTAssertEqual(v("mouthSmileRight"), 0.281)
        XCTAssertEqual(v("cheekSquintLeft"), 0.02)
        XCTAssertEqual(v("headPitch"), 6.23)
        XCTAssertEqual(v("headYaw"), -1.4)
        XCTAssertEqual(v("noseSneerLeft"), 0, "a shape ARKit did not report is 0")
    }

    func testUntrackedFramesAndGapsKeepTimeTrue() throws {
        var r = FaceRawRecorder(rateHz: 30)
        // 0 to 1 s tracked, nothing from 1 to 2 s (camera hiccup), 2 to 3 s face lost.
        for i in 0...30 { r.add(time: Double(i) / 30, tracked: true, shapes: smile(0.1), pitch: 0, yaw: 0, roll: 0) }
        for i in 60...90 { r.add(time: Double(i) / 30, tracked: false, shapes: [:], pitch: 0, yaw: 0, roll: 0) }
        let raw = try XCTUnwrap(r.faceRaw())
        XCTAssertEqual(raw.samples.count, 91)
        let tracked = try XCTUnwrap(raw.tracked)
        XCTAssertEqual(tracked.count, 91)
        XCTAssertEqual(tracked.reduce(0, +), 31)
        XCTAssertEqual(tracked[45], 0)
        XCTAssert(raw.samples.allSatisfy { $0.count == 55 })
    }

    func testNothingTrackedMeansNoFaceRaw() {
        var r = FaceRawRecorder()
        XCTAssertNil(r.faceRaw())
        for i in 0..<90 { r.add(time: Double(i) / 30, tracked: false, shapes: [:], pitch: 0, yaw: 0, roll: 0) }
        XCTAssertNil(r.faceRaw())
    }

    func testOnlyTheActivitysTimeIsKeptAndMomentsFollow() throws {
        var r = FaceRawRecorder(rateHz: 30)
        for i in 0..<(30 * 60) {   // 60 s, but the activity lasted 40 s
            r.add(time: 500 + Double(i) / 30, tracked: true, shapes: smile(0.2), pitch: 0, yaw: 0, roll: 0)
        }
        r.mark(at: 505)          // before the kept part: dropped
        r.mark(at: 530.5)        // 10.5 s into the kept part
        r.mark(at: 900)          // after the last frame: dropped
        let raw = try XCTUnwrap(r.faceRaw(lastSeconds: 40))
        XCTAssertEqual(raw.samples.count, 1200)
        XCTAssertEqual(raw.momentsMs, [10_500])   // kept part starts at 520 s
    }

    func testAtMostTwentyMomentsAndASizeCap() throws {
        var r = FaceRawRecorder(rateHz: 30)
        for i in 0..<(FaceRawRecorder.maxSamples + 600) {
            r.add(time: Double(i) / 30, tracked: true, shapes: smile(0.1), pitch: 0, yaw: 0, roll: 0)
            if i % 30 == 0 { r.mark(at: Double(i) / 30) }
        }
        let raw = try XCTUnwrap(r.faceRaw())
        XCTAssertEqual(raw.samples.count, FaceRawRecorder.maxSamples)
        XCTAssertEqual(raw.momentsMs?.count, 20)
    }

    func testValuesStayInsideTheServersLimits() throws {
        var r = FaceRawRecorder()
        r.add(time: 0, tracked: true, shapes: ["eyeBlink_L": 1.07, "eyeBlink_R": -0.01, "mouthSmile_L": .nan],
              pitch: 190, yaw: -200, roll: .infinity)
        let row = try XCTUnwrap(r.faceRaw()?.samples.first)
        XCTAssert(row.allSatisfy { $0.isFinite })
        XCTAssertEqual(row[FaceRawRecorder.channels.firstIndex(of: "eyeBlinkLeft")!], 1)
        XCTAssertEqual(row[FaceRawRecorder.channels.firstIndex(of: "eyeBlinkRight")!], 0)
        XCTAssertEqual(row[52], -170)
        XCTAssertEqual(row[53], 160)
        XCTAssertEqual(row[54], 0)
    }

    func testTheRecordSendsFaceRawWithTheServersKeys() throws {
        var r = FaceRawRecorder()
        for i in 0..<300 { r.add(time: Double(i) / 30, tracked: i != 5, shapes: smile(0.3), pitch: 5, yaw: 0, roll: 1) }
        r.mark(at: 2)
        var a = API.ActivityIn(id: API.ActivityIn.newId(), type: .focus, startedAt: API.isoString(Date()),
                               durationS: 10, completed: true, endedBy: .finished)
        a.correctTaps = 10; a.wrongTaps = 0; a.misses = 1; a.reactionMs = [500, 480]
        a.faceRaw = r.faceRaw(lastSeconds: 11)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: API.encoder.encode(a)) as? [String: Any])
        XCTAssertNil(json["face"], "never the old summary next to the frames")
        let face = try XCTUnwrap(json["face_raw"] as? [String: Any])
        XCTAssertEqual(Set(face.keys), ["rate_hz", "channels", "samples", "tracked", "moments_ms"])
        XCTAssertEqual(face["rate_hz"] as? Int, 30)
        XCTAssertEqual(face["moments_ms"] as? [Int], [2000])
        XCTAssertEqual((face["tracked"] as? [Int])?.count, 300)
    }

    /// Peter's Euler order: a nod of 10 degrees about X (chin down) reads as pitch +10.
    func testHeadAnglesFollowPetersEulerOrder() {
        let a: Float = 10 * .pi / 180
        let m = simd_float4x4(simd_quatf(angle: a, axis: SIMD3(1, 0, 0)))
        let e = FaceAngles.euler(m)
        XCTAssertEqual(e.x, a, accuracy: 1e-4)
        XCTAssertEqual(e.y, 0, accuracy: 1e-4)
        XCTAssertEqual(e.z, 0, accuracy: 1e-4)
        let yawed = FaceAngles.euler(simd_float4x4(simd_quatf(angle: -a, axis: SIMD3(0, 1, 0))))
        XCTAssertEqual(yawed.y, -a, accuracy: 1e-4)
    }

    /// A 40-second Sparks and snow record the way the app sends it, written to
    /// `ios/build/face-raw-record.json` (git-ignored) so it can be posted to a local
    /// engine by hand: smiles after the cheers, blinks every few seconds, a moment
    /// where the face was lost.
    func testWritesASampleRecordForTheEngineCheck() throws {
        var r = FaceRawRecorder(rateHz: 30)
        let t0 = 2000.0
        for i in 0..<(40 * 60) {   // ARKit at 60 Hz
            let t = Double(i) / 60
            let lost = t > 21 && t < 22.5
            let sinceCheer = t.truncatingRemainder(dividingBy: 8)
            let smiling = sinceCheer > 0.8 && sinceCheer < 2.6
            let blink = t.truncatingRemainder(dividingBy: 3.7) < 0.12
            var shapes: [String: Float] = [:]
            for name in FaceRawRecorder.blendShapes { shapes[name] = 0.02 }
            shapes["mouthSmileLeft"] = smiling ? 0.46 : 0.05
            shapes["mouthSmileRight"] = smiling ? 0.41 : 0.04
            shapes["cheekSquintLeft"] = smiling ? 0.27 : 0.03
            shapes["cheekSquintRight"] = smiling ? 0.25 : 0.03
            shapes["eyeBlinkLeft"] = blink ? 0.86 : 0.07
            shapes["eyeBlinkRight"] = blink ? 0.83 : 0.06
            shapes["eyeLookDownLeft"] = 0.34
            shapes["eyeLookDownRight"] = 0.33
            r.add(time: t0 + t, tracked: !lost, shapes: lost ? [:] : shapes,
                  pitch: 8 + sin(t) * 2, yaw: -2 + cos(t / 3) * 3, roll: 1.5)
            if i % (8 * 60) == 0 { r.mark(at: t0 + t) }
        }
        var a = API.ActivityIn(id: "sense-check-face-raw-1", type: .focus, startedAt: API.isoString(Date().addingTimeInterval(-60)),
                               durationS: 40, completed: true, endedBy: .finished)
        a.correctTaps = 17; a.wrongTaps = 1; a.misses = 2; a.reactionMs = [512, 498, 530, 470, 505]
        a.faceRaw = r.faceRaw(lastSeconds: 41)
        let raw = try XCTUnwrap(a.faceRaw)
        XCTAssert((1200...1201).contains(raw.samples.count))
        XCTAssertEqual(raw.momentsMs?.count, 5)
        let out = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/face-raw-record.json")
        try? FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        try API.encoder.encode(a).write(to: out)
    }
}
