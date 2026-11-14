import XCTest
@testable import Lanvi

/// Revontulet's `focus` record against the fixed contract
/// (firstmate data/lanvi-game-data/contract.md, summarised in ios/REVONTULET.md).
@MainActor
final class RevontuletMeasuresTests: XCTestCase {
    /// The contract's full example.
    private let example = """
    {"id": "rv-2f6c1a0e9b7d4c11", "type": "focus", "started_at": "2026-11-15T08:41:07Z", "duration_s": 90.2,
     "completed": true, "ended_by": "finished", "correct_taps": 5, "wrong_taps": 0, "misses": 1, "reaction_ms": [410, 380, 350],
     "revontulet": {
       "rounds": [
         {"effort": "easy", "choice_ms": 2310, "trace_start_ms": 1840, "trace_ms": 1650, "trace_length_pt": 288.4,
          "trace_mean_speed_pt_s": 174.8, "trace_peak_speed_pt_s": 362.0, "trace_lifts": 0,
          "pull_pt": 96.5, "pull_hold_ms": 820, "embers_shown": 0, "embers_hit": 0, "bonus": false}],
       "strokes": [{"ms": 1450, "length_pt": 410.0, "mean_speed_pt_s": 282.8}],
       "broke_through_s": 52.4, "fox_finished": false, "pt_per_cm": 64.2,
       "touch_radius_mean_pt": 21.3, "touch_radius_var": 4.7}}
    """

    private func keys(_ any: Any, _ path: String = "") -> Set<String> {
        var out = Set<String>()
        if let d = any as? [String: Any] {
            for (k, v) in d {
                out.insert(path + k)
                out.formUnion(keys(v, path + k + "."))
            }
        } else if let a = any as? [Any] {
            for v in a { out.formUnion(keys(v, path + "[].")) }
        }
        return out
    }

    /// A finished game with every measure present.
    private func game() -> RevontuletResult {
        let t0 = 1000.0
        var hard = RevontuletResult.Round(number: 1)
        hard.effort = .hard
        hard.decisionMs = 1480
        hard.firstTouchMs = 1210
        hard.traceDurationMs = 1390
        hard.traceLength = 281
        hard.traceMeanSpeed = 202.2
        hard.tracePeakSpeed = 401.5
        hard.traceLifts = 1
        hard.pullDistance = 104
        hard.holdMs = 610
        hard.launchUptime = t0 + 8
        hard.embersShown = 2
        hard.emberHits = [.init(index: 0, reactionMs: 410, uptime: t0 + 8.4)]
        hard.bonus = true
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var r = RevontuletResult(startedAt: start, endedAt: start.addingTimeInterval(90.2), startUptime: t0, endUptime: t0 + 90.2,
                                 completed: true, rounds: [hard],
                                 strokes: [.init(number: 1, startUptime: t0 + 70, durationMs: 1450, length: 410, meanSpeed: 282.8,
                                                 peakSpeed: 400, downness: 0.9, touchRadius: 20)],
                                 burstUptime: t0 + 52.4, celebrateUptime: t0 + 53.2, foxFinishedWall: false, surpriseRibbons: 1)
        r.touchRadiusMean = 21.3
        r.touchRadiusVar = 4.7
        r.ptPerCm = 64.2
        return r
    }

    func testRecordMatchesTheContractKeyForKey() throws {
        let data = try API.encoder.encode(ActivityRouter.record(game()))
        let ours = keys(try JSONSerialization.jsonObject(with: data))
        let theirs = keys(try JSONSerialization.jsonObject(with: Data(example.utf8)))
        XCTAssertEqual(ours.subtracting(theirs), [], "keys the contract does not have")
        XCTAssertEqual(theirs.subtracting(ours), [], "keys the contract has and we do not send")
    }

    func testValuesFollowTheContract() throws {
        let record = ActivityRouter.record(game())
        XCTAssertEqual(record.reactionMs, [410], "reaction_ms carries only ember taps")
        XCTAssertEqual(record.correctTaps, 2)
        XCTAssertEqual(record.misses, 1)
        let m = try XCTUnwrap(record.revontulet)
        XCTAssertEqual(m.rounds.first?.effort, "hard")
        XCTAssertEqual(m.rounds.first?.choiceMs, 1480)
        XCTAssertEqual(m.rounds.first?.traceStartMs, 1210)
        XCTAssertEqual(m.rounds.first?.embersHit, 1)
        XCTAssertEqual(m.rounds.first?.bonus, true)
        XCTAssertEqual(m.brokeThroughS, 52.4)
        XCTAssertLessThanOrEqual(m.brokeThroughS ?? 0, record.durationS + 1)
    }

    /// The same two steps `LanviClient.send` takes, against a server that refuses the measures.
    func testRefusedMeasuresGoAgainPlainOnceAndStayPlainThisRun() throws {
        let gate = RevontuletSendGate()
        var sent: [API.ActivityIn] = []
        func post(_ a: API.ActivityIn) throws -> String {
            sent.append(a)
            if a.revontulet != nil { throw APIError.rejected("invalid_request") }
            return "stored"
        }
        func send(_ a: API.ActivityIn) throws -> String {
            let first = gate.first(a)
            do { return try post(first) } catch {
                guard let plain = gate.retry(after: error, sent: first) else { throw error }
                return try post(plain)
            }
        }
        let record = ActivityRouter.record(game())
        XCTAssertEqual(try send(record), "stored")
        XCTAssertEqual(sent.count, 2)
        XCTAssertNotNil(sent[0].revontulet)
        XCTAssertNil(sent[1].revontulet)
        XCTAssertEqual(sent[0].id, sent[1].id)
        XCTAssertEqual(sent[1], record.withoutRevontulet)
        sent = []
        XCTAssertEqual(try send(ActivityRouter.record(game())), "stored")
        XCTAssertEqual(sent.count, 1, "after a refusal the rest of the run sends plain at once")
        XCTAssertNil(sent[0].revontulet)
        XCTAssertNil(RevontuletSendGate().retry(after: APIError.offline, sent: record), "only a refusal drops the measures")
    }
}
