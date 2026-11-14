import XCTest
@testable import Lanvi

/// The three faults dad's agent found in the real records (ios/REVONTULET.md, "Record faults"),
/// each reproduced on the engine and turned into a test.
@MainActor
final class RevontuletRecordTests: XCTestCase {
    private let layout = RevontuletLayout(size: CGSize(width: 402, height: 874), safeTop: 62, safeBottom: 34)

    /// Plays with the pretend finger until `stop` says so; returns the engine and the clock.
    private func play(_ style: RevontuletAutoPlay.Style = .mixed, seed: UInt64 = 3, emberDelay: Double? = nil,
                      until stop: (RevontuletEngine) -> Bool) -> (RevontuletEngine, Double) {
        var e = RevontuletEngine(layout: layout, seed: seed)
        var auto = RevontuletAutoPlay(style: style, seed: seed)
        var now = 100.0
        _ = e.handle(.start, at: now)
        var seen: [Int: Double] = [:], tapped: Set<Int> = [], flight = -1.0
        while now < 240, !stop(e), e.beat != .done {
            for input in auto.step(e, now: now) {
                if emberDelay != nil, e.beat == .flight, e.flight?.hard == true {
                    if case .down = input { continue }
                    if case .up = input { continue }
                }
                _ = e.handle(input, at: now)
            }
            if let d = emberDelay, e.beat == .flight, let f = e.flight, f.hard, !f.foxOwn {
                if f.launch != flight { flight = f.launch; seen = [:]; tapped = [] }
                for k in f.emberU.indices where f.emberShownAt[k] != nil && !tapped.contains(k) {
                    let s = seen[k] ?? now
                    seen[k] = s
                    if now - s >= d {
                        tapped.insert(k)
                        _ = e.handle(.down(f.emberPoint(k), radius: 9), at: now)
                        _ = e.handle(.up(f.emberPoint(k)), at: now + 0.06)
                    }
                }
            }
            _ = e.tick(now)
            now += 1.0 / 60
        }
        return (e, now)
    }

    // Fault 1: a game whose wall has burst is finished, however the person leaves.

    func testClosingAfterTheBurstIsAFinishedGame() throws {
        for beat in [RevontuletBeat.burst, .celebrate, .warmth, .sleep] {
            var (e, now) = play { $0.beat == beat }
            XCTAssertEqual(e.beat, beat)
            _ = e.handle(.close, at: now)
            let r = try XCTUnwrap(e.result())
            XCTAssertTrue(r.completed, "closed in \(beat)")
            let record = ActivityRouter.record(r)
            XCTAssertEqual(record.endedBy, .finished, "closed in \(beat)")
            XCTAssertTrue(record.completed)
        }
    }

    func testLeavingTheAppAfterTheBurstIsAFinishedGame() throws {
        var (e, now) = play { $0.beat == .warmth }
        _ = e.handle(.interrupt, at: now)
        let record = ActivityRouter.record(try XCTUnwrap(e.result()))
        XCTAssertEqual(record.endedBy, .finished)
    }

    func testClosingBeforeTheBurstIsStoppedAndLeavingIsInterrupted() throws {
        var (a, t1) = play { $0.round == 1 && $0.beat == .trace }
        _ = a.handle(.close, at: t1)
        XCTAssertEqual(ActivityRouter.record(try XCTUnwrap(a.result())).endedBy, .userStopped)
        var (b, t2) = play { $0.round == 1 && $0.beat == .trace }
        _ = b.handle(.interrupt, at: t2)
        XCTAssertEqual(ActivityRouter.record(try XCTUnwrap(b.result())).endedBy, .interrupted)
    }

    func testContinueAndTheSafetyNetAreFinished() throws {
        var (e, now) = play { $0.beat == .sleep && $0.completed }
        _ = e.handle(.finish, at: now)
        XCTAssertEqual(ActivityRouter.record(try XCTUnwrap(e.result())).endedBy, .finished)
    }

    // Fault 2: a person who picks the vein and taps the embers at a human pace ends with
    // reaction times; every hit is in reaction_ms.

    func testHumanPacedEmberTapsReachReactionTimes() throws {
        for delay in [0.5, 0.7, 0.85] {
            let (e, _) = play(.hard, emberDelay: delay) { $0.beat == .sleep && $0.completed }
            let r = try XCTUnwrap(e.result())
            XCTAssertEqual(r.embersShown, 6, "tap \(delay) s after the flash")
            XCTAssertEqual(r.embersHit, 6, "tap \(delay) s after the flash")
            let record = ActivityRouter.record(r)
            XCTAssertEqual(record.reactionMs?.count, 6)
            for ms in record.reactionMs ?? [] {
                XCTAssertEqual(Double(ms), delay * 1000, accuracy: 40, "measured from the flash on the real clock")
            }
        }
    }

    func testAnEasyOnlyGameSendsNoReactionTimes() throws {
        let (e, _) = play(.easy) { $0.round == 2 && $0.beat == .choice }
        XCTAssertEqual(ActivityRouter.record(try XCTUnwrap(e.result())).reactionMs, [])
    }

    func testACoachedEmberTapIsStillAReactionTime() throws {
        var (e, now) = play(.hard) { $0.beat == .flight && ($0.flight?.emberShownAt.first ?? nil) != nil }
        e.slowFlight(at: now)                      // the coach holds time still
        now += 1.1
        let f = try XCTUnwrap(e.flight)
        _ = e.handle(.down(f.emberPoint(0), radius: 9), at: now)
        let hit = try XCTUnwrap(e.records[0].emberHits.first)
        XCTAssertEqual(Double(hit.reactionMs), 1100, accuracy: 60, "real time from the flash")
    }

    // Fault 3: refused records are sent again smaller, never lost; size is not shape.

    private func record(face: Bool) -> API.ActivityIn {
        let (e, _) = play { $0.beat == .sleep && $0.completed }
        var a = ActivityRouter.record(try! XCTUnwrap(e.result()))
        if face { a.faceRaw = API.FaceRaw(rateHz: 30, channels: ["eyeBlinkLeft"], samples: [[0.1]], tracked: nil, momentsMs: nil) }
        return a
    }

    func testTooLargeDropsTheFramesFirstAndKeepsTheMeasures() throws {
        RevontuletSendGate.shared.reset()
        let full = record(face: true)
        let next = try XCTUnwrap(LanviClient.smaller(after: APIError.rejected("body_too_large"), sent: full))
        XCTAssertNil(next.faceRaw)
        XCTAssertNotNil(next.revontulet, "the measures are not what made it too large")
        XCTAssertTrue(RevontuletSendGate.shared.accepted, "a size refusal does not turn the measures off")
        let last = try XCTUnwrap(LanviClient.smaller(after: APIError.rejected("body_too_large"), sent: next))
        XCTAssertNil(last.revontulet, "still too large: the plain record is the last try")
        XCTAssertNil(LanviClient.smaller(after: APIError.rejected("body_too_large"), sent: last))
        XCTAssertEqual(last.id, full.id)
    }

    func testRefusedForContentDropsTheMeasuresThenTheFrames() throws {
        RevontuletSendGate.shared.reset()
        let full = record(face: true)
        let next = try XCTUnwrap(LanviClient.smaller(after: APIError.rejected("invalid_request"), sent: full))
        XCTAssertNil(next.revontulet)
        XCTAssertNotNil(next.faceRaw)
        XCTAssertFalse(RevontuletSendGate.shared.accepted, "the rest of the run sends plain")
        let last = try XCTUnwrap(LanviClient.smaller(after: APIError.rejected("invalid_request"), sent: next))
        XCTAssertNil(last.faceRaw)
        XCTAssertNil(LanviClient.smaller(after: APIError.offline, sent: full), "temporary: the outbox keeps it whole")
        RevontuletSendGate.shared.reset()
    }

    /// A first game with the coach on: every required field is present with its real value;
    /// only optional ones may be left out.
    func testACoachedFirstGameSendsEveryRequiredField() throws {
        var (e, _) = play { $0.beat == .sleep && $0.completed }
        e.markCoached()
        let data = try API.encoder.encode(ActivityRouter.record(try XCTUnwrap(e.result())))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let rounds = try XCTUnwrap((json["revontulet"] as? [String: Any])?["rounds"] as? [[String: Any]])
        XCTAssertEqual(rounds.count, 3)
        for round in rounds {
            XCTAssertNotNil(round["effort"] as? String)
            XCTAssertNotNil(round["choice_ms"] as? Int, "choice_ms is required, even on a coached round")
        }
    }
}
