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

/// A record with face frames is the one big body the app sends. When the server
/// refuses it, the record goes again without the frames (same id), so the game is
/// never lost; a temporary failure keeps the whole record for the outbox.
final class FaceSendTests: XCTestCase {
    private func record(frames: Int) -> API.ActivityIn {
        var r = API.ActivityIn(id: API.ActivityIn.newId(), type: .breathing,
                               startedAt: API.isoString(Date()), durationS: 60,
                               completed: true, endedBy: .finished, timePlayedS: 60, breathsCompleted: 6)
        if frames > 0 {
            let row = [Double](repeating: 0.1, count: FaceRawRecorder.channels.count)
            r.faceRaw = API.FaceRaw(rateHz: 30, channels: FaceRawRecorder.channels,
                                    samples: Array(repeating: row, count: frames), tracked: nil, momentsMs: nil)
        }
        return r
    }

    func testRefusedFramesGoAgainWithoutThemSameId() {
        let sent = record(frames: 1800)
        let plain = LanviClient.withoutFaceFallback(after: APIError.rejected("body_too_large"), sent: sent)
        XCTAssertNotNil(plain)
        XCTAssertNil(plain?.faceRaw)
        XCTAssertEqual(plain?.id, sent.id)
        XCTAssertEqual(plain, sent.withoutFaceRaw)
        XCTAssertNotNil(LanviClient.withoutFaceFallback(after: APIError.rejected("invalid_request"), sent: sent))
    }

    func testOnlyARefusalOfARecordWithFramesDropsThem() {
        let sent = record(frames: 1800)
        XCTAssertNil(LanviClient.withoutFaceFallback(after: APIError.offline, sent: sent), "temporary: keep the frames for the outbox")
        XCTAssertNil(LanviClient.withoutFaceFallback(after: APIError.server, sent: sent))
        XCTAssertNil(LanviClient.withoutFaceFallback(after: APIError.conflict, sent: sent), "the server has a record under this id")
        XCTAssertNil(LanviClient.withoutFaceFallback(after: APIError.rejected("invalid_request"), sent: record(frames: 0)),
                     "no frames: nothing to drop, the refusal stands")
    }

    func testARecordWithFramesIsABigBody() throws {
        let small = try API.encoder.encode(record(frames: 0))
        let big = try API.encoder.encode(record(frames: 45 * 30))
        XCTAssertLessThan(small.count, LanviClient.bigBodyBytes)
        XCTAssertGreaterThan(big.count, LanviClient.bigBodyBytes, "45 s of frames goes through the upload session")
    }
}

// MARK: - Fine facial movement (kept in this file so the generated Xcode project needs no change)

/// The fine movement stream the phone computes from the face mesh (`docs/face-fine.md`).
/// The mesh here is a flat grid the size of a face, in metres, in the face anchor's
/// space (+X is the person's left, +Y up).
final class FaceFineTests: XCTestCase {

    /// 41 x 51 points, 14 cm wide and 18 cm high.
    private func grid() -> [SIMD3<Float>] {
        var out: [SIMD3<Float>] = []
        for iy in 0...50 {
            for ix in 0...40 {
                out.append(SIMD3(-0.07 + 0.14 * Float(ix) / 40, -0.09 + 0.18 * Float(iy) / 50, 0))
            }
        }
        return out
    }

    /// The grid with one region pushed `mm` millimetres towards the camera.
    private func pushed(_ shape: [SIMD3<Float>], region: String, mm: Float) -> [SIMD3<Float>] {
        let box = FaceFineRecorder.boxes.first { $0.name == region }!
        return shape.map { p in
            let u = (p.x + 0.07) / 0.14, v = (p.y + 0.09) / 0.18
            return box.u.contains(u) && box.v.contains(v) ? p + SIMD3(0, 0, mm / 1000) : p
        }
    }

    private func recorded(frames: Int = 90, _ shapeAt: (Int) -> [SIMD3<Float>]) -> FaceFineRecorder {
        var r = FaceFineRecorder(rateHz: 30)
        for i in 0..<frames {
            r.add(time: 100 + Double(i) / 30, tracked: true) { shapeAt(i) }
        }
        return r
    }

    func testRegionNamesAreTheServersAndTheDocumentedOnes() throws {
        let doc = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/face-fine.md")
        let text = try String(contentsOf: doc, encoding: .utf8)
        let after = try XCTUnwrap(text.range(of: "## Regions")).upperBound
        let open = try XCTUnwrap(text.range(of: "```\n", range: after..<text.endIndex))
        let close = try XCTUnwrap(text.range(of: "```", range: open.upperBound..<text.endIndex))
        let names = Set(text[open.upperBound..<close.lowerBound]
            .split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init))
        XCTAssertEqual(Set(FaceFineRecorder.boxes.map(\.name)), names)
        XCTAssertEqual(names.count, 14)
    }

    func testEveryRegionCatchesVerticesAndLeftIsThePersonsLeft() {
        let sizes = FaceFineRecorder.assign(grid())
        for (box, ids) in zip(FaceFineRecorder.boxes, sizes) {
            XCTAssertGreaterThanOrEqual(ids.count, FaceFineRecorder.minVertices, box.name)
        }
        let shape = grid()
        let left = sizes[FaceFineRecorder.boxes.firstIndex { $0.name == "mouth_left" }!]
        let right = sizes[FaceFineRecorder.boxes.firstIndex { $0.name == "mouth_right" }!]
        XCTAssert(left.allSatisfy { shape[$0].x > 0 })    // +X: the person's own left
        XCTAssert(right.allSatisfy { shape[$0].x < 0 })
    }

    func testAStillFaceIsZeroEverywhere() throws {
        let shape = grid()
        let fine = try XCTUnwrap(recorded { _ in shape }.faceFine())
        XCTAssertEqual(fine.source, "mesh")
        XCTAssertEqual(fine.rateHz, 30)
        XCTAssertEqual(fine.samples.count, 90)
        XCTAssertEqual(fine.regions.count, 14)
        XCTAssertNil(fine.tracked)
        XCTAssertEqual(fine.noiseMm, 0)
        XCTAssert(fine.samples.allSatisfy { $0.count == 14 && $0.allSatisfy { $0 == 0 } })
    }

    func testAMovementShowsOnItsRegionInMillimetres() throws {
        let shape = grid()
        // Still for 2 seconds, then the left mouth corner moves 2 mm for 5 frames.
        let fine = try XCTUnwrap(recorded { i in
            (60..<65).contains(i) ? self.pushed(shape, region: "mouth_left", mm: 2) : shape
        }.faceFine())
        let l = try XCTUnwrap(fine.regions.firstIndex(of: "mouth_left"))
        let r = try XCTUnwrap(fine.regions.firstIndex(of: "mouth_right"))
        XCTAssertEqual(fine.samples[62][l], 2.0, accuracy: 0.01)
        XCTAssertEqual(fine.samples[62][r], 0)
        // The corner patch lies inside the half, so it moves with it; the other corner does not.
        let cl = try XCTUnwrap(fine.regions.firstIndex(of: "mouth_corner_left"))
        let cr = try XCTUnwrap(fine.regions.firstIndex(of: "mouth_corner_right"))
        XCTAssertEqual(fine.samples[62][cl], 2.0, accuracy: 0.01)
        XCTAssertEqual(fine.samples[62][cr], 0)
        XCTAssertEqual(fine.samples[59][l], 0)
        XCTAssertEqual(fine.samples[66][l], 0)
    }

    func testTheRestingShapeIsTheMedianSoOneEarlyMovementDoesNotShiftIt() throws {
        let shape = grid()
        // A movement inside the first 45 frames: that stretch is not quiet, so the rest
        // is learned from the next one, and the movement still shows in full.
        let fine = try XCTUnwrap(recorded { i in
            (10..<15).contains(i) ? self.pushed(shape, region: "jaw", mm: 3) : shape
        }.faceFine())
        let j = try XCTUnwrap(fine.regions.firstIndex(of: "jaw"))
        XCTAssertEqual(fine.samples[12][j], 3.0, accuracy: 0.01)
        XCTAssertEqual(fine.samples[70][j], 0)
        XCTAssertEqual(fine.noiseMm, 0)   // measured on the quiet stretch, not the restless one
    }

    func testARestlessStartDoesNotBecomeTheRest() throws {
        let shape = grid()
        // The first 1.5 seconds the jaw sits 2 to 3 mm away and wobbles; then the face is still.
        let fine = try XCTUnwrap(recorded(frames: 150) { i in
            i < 45 ? self.pushed(shape, region: "jaw", mm: i % 2 == 0 ? 2 : 3) : shape
        }.faceFine())
        let j = try XCTUnwrap(fine.regions.firstIndex(of: "jaw"))
        XCTAssertGreaterThanOrEqual(fine.samples[10][j], 1.99)
        XCTAssertEqual(fine.samples[60][j], 0)    // the still face is the rest, so it reads zero
        XCTAssertEqual(fine.samples[140][j], 0)
        XCTAssertEqual(fine.noiseMm, 0)
    }

    func testAGameThatEndsBeforeAQuietStretchSendsTheQuietestOne() throws {
        let shape = grid()
        // Never quiet: the jaw wobbles by 1 mm the whole time, and the game ends after 2 seconds.
        let fine = try XCTUnwrap(recorded(frames: 60) { i in
            i % 2 == 0 ? shape : self.pushed(shape, region: "jaw", mm: 1)
        }.faceFine())
        XCTAssertEqual(fine.samples.count, 60)
        XCTAssertGreaterThan(try XCTUnwrap(fine.noiseMm), 0)
    }

    func testFramesJustAfterTrackingReturnsAreLeftOut() throws {
        let shape = grid()
        var r = FaceFineRecorder(rateHz: 30)
        for i in 0..<150 {
            // Lost for 5 frames; when it comes back the mesh jumps 4 mm for 6 frames.
            let lost = (80..<85).contains(i)
            let jump = (85..<91).contains(i)
            r.add(time: 9 + Double(i) / 30, tracked: !lost) {
                jump ? self.pushed(shape, region: "nose", mm: 4) : shape
            }
        }
        let fine = try XCTUnwrap(r.faceFine())
        let tracked = try XCTUnwrap(fine.tracked)
        XCTAssertEqual(tracked.filter { $0 == 0 }.count, 5 + FaceFineRecorder.regainFrames)
        XCTAssert(fine.samples.allSatisfy { $0.allSatisfy { $0 == 0 } })   // the jump never shows
        XCTAssertEqual(tracked[96], 1)
    }

    func testTooFewTrackedFramesGiveNothing() {
        let shape = grid()
        XCTAssertNil(recorded(frames: 30) { _ in shape }.faceFine())
        var r = FaceFineRecorder(rateHz: 30)
        for i in 0..<90 { r.add(time: Double(i) / 30, tracked: false) { [] } }
        XCTAssertNil(r.faceFine())
    }

    func testUntrackedFramesStayInTimeAndSixtyHertzBecomesThirty() throws {
        let shape = grid()
        var r = FaceFineRecorder(rateHz: 30)
        var asked = 0
        for i in 0..<240 {   // 4 seconds at 60 Hz
            let untracked = (130..<150).contains(i)
            r.add(time: 5 + Double(i) / 60, tracked: !untracked) { asked += 1; return shape }
        }
        let fine = try XCTUnwrap(r.faceFine())
        // A frame lands in the slot nearest its time, so 240 frames fill slots 0...120.
        XCTAssertEqual(fine.samples.count, 121)
        XCTAssertEqual(asked, 101)   // the mesh is read only for frames that are kept and tracked
        let tracked = try XCTUnwrap(fine.tracked)
        XCTAssertEqual(tracked.filter { $0 == 0 }.count, 20)   // ten lost, ten left out after
        XCTAssertEqual(tracked[70], 0)
    }

    func testOnlyTheEndIsKeptAndTheJSONKeysAreTheServers() throws {
        let shape = grid()
        let fine = try XCTUnwrap(recorded(frames: 300) { _ in shape }.faceFine(lastSeconds: 4))
        XCTAssertEqual(fine.samples.count, 120)
        var record = API.ActivityIn(id: "fine-test-0001", type: .focus, startedAt: "2026-11-14T20:00:00Z",
                                    durationS: 4, completed: true, endedBy: .finished)
        record.faceFine = fine
        let json = try XCTUnwrap(String(data: try API.encoder.encode(record), encoding: .utf8))
        XCTAssert(json.contains("\"face_fine\""))
        XCTAssert(json.contains("\"rate_hz\":30"))
        XCTAssert(json.contains("\"noise_mm\""))
        XCTAssert(json.contains("\"source\":\"mesh\""))
        XCTAssertFalse(json.contains("vertices"))
    }

    func testARefusedRecordGoesAgainWithoutTheFineStreamFirst() throws {
        let shape = grid()
        var record = API.ActivityIn(id: "fine-test-0002", type: .focus, startedAt: "2026-11-14T20:00:00Z",
                                    durationS: 3, completed: true, endedBy: .finished)
        record.faceFine = recorded { _ in shape }.faceFine()
        record.faceRaw = API.FaceRaw(rateHz: 30, channels: ["mouthSmileLeft"], samples: [[0.1]], tracked: nil, momentsMs: nil)
        let next = try XCTUnwrap(LanviClient.smaller(after: APIError.rejected("invalid_request"), sent: record))
        XCTAssertNil(next.faceFine)
        XCTAssertNotNil(next.faceRaw)   // the raw frames stay for the next try
        XCTAssertEqual(next, record.withoutFaceFine)
    }
}
