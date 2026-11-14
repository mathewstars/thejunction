import Foundation

// MARK: - Revontulet's measures on the `focus` record
//
// The contract (fixed, agreed with the server side): `data/lanvi-game-data/contract.md`
// in the firstmate home, summarised in `ios/REVONTULET.md`. One optional object,
// `revontulet`, on the `focus` record; every number is clamped to the contract's range so
// a record is never refused for an out-of-range value.

extension API {
    /// The `revontulet` object. Keys become snake case through `API.encoder`; nil fields
    /// are left out.
    struct Revontulet: Codable, Equatable {
        struct Round: Codable, Equatable {
            var effort: String
            var choiceMs: Int
            var traceStartMs: Int?
            var traceMs: Int?
            var traceLengthPt: Double
            var traceMeanSpeedPtS: Double?
            var tracePeakSpeedPtS: Double?
            var traceLifts: Int
            var pullPt: Double?
            var pullHoldMs: Int?
            var embersShown: Int
            var embersHit: Int
            var bonus: Bool
        }

        struct Stroke: Codable, Equatable {
            var ms: Int
            var lengthPt: Double
            var meanSpeedPtS: Double
        }

        var rounds: [Round]
        var strokes: [Stroke]
        var brokeThroughS: Double?
        var foxFinished: Bool?
        var ptPerCm: Double?
        var touchRadiusMeanPt: Double?
        var touchRadiusVar: Double?
    }
}

extension API.Revontulet {
    /// The measures of one game, in the contract's units and ranges.
    init(_ r: RevontuletResult) {
        func ms(_ v: Int?, _ hi: Int) -> Int? { v.map { min(max($0, 0), hi) } }
        func num(_ v: Double?, _ hi: Double) -> Double? {
            guard let v, v.isFinite else { return nil }
            return (min(max(v, 0), hi) * 10).rounded() / 10
        }
        rounds = r.rounds.prefix(3).compactMap { round in
            guard let effort = round.effort else { return nil }
            let shown = min(max(round.embersShown, 0), 5)
            return Round(effort: effort.rawValue,
                         choiceMs: ms(round.decisionMs ?? 0, 120_000) ?? 0,
                         traceStartMs: round.coached ? nil : ms(round.firstTouchMs, 120_000),
                         traceMs: ms(round.traceDurationMs, 120_000),
                         traceLengthPt: num(round.traceLength, 20_000) ?? 0,
                         traceMeanSpeedPtS: num(round.traceMeanSpeed, 20_000),
                         tracePeakSpeedPtS: num(round.tracePeakSpeed, 50_000),
                         traceLifts: min(max(round.traceLifts, 0), 100),
                         pullPt: round.launchUptime == nil ? nil : num(round.pullDistance, 2000),
                         pullHoldMs: round.launchUptime == nil ? nil : ms(round.holdMs, 120_000),
                         embersShown: shown,
                         embersHit: min(round.emberHits.count, shown),
                         bonus: round.bonus)
        }
        strokes = r.strokes.prefix(10).map {
            Stroke(ms: min(max($0.durationMs, 0), 60_000), lengthPt: num($0.length, 20_000) ?? 0,
                   meanSpeedPtS: num($0.meanSpeed, 20_000) ?? 0)
        }
        let duration = max(0, r.endedAt.timeIntervalSince(r.startedAt))
        brokeThroughS = r.burstUptime.flatMap { num(min($0 - r.startUptime, duration), 600) }
        foxFinished = r.burstUptime == nil ? nil : r.foxFinishedWall
        ptPerCm = r.ptPerCm.flatMap { (10...400).contains($0) ? $0 : nil }
        touchRadiusMeanPt = num(r.touchRadiusMean, 200)
        touchRadiusVar = num(r.touchRadiusVar, 10_000)
    }

    /// Screen points per centimetre: about 60.4 on 3x iPhones, 64.2 on 2x; nil otherwise.
    static func pointsPerCentimetre(displayScale: CGFloat) -> Double? {
        switch displayScale {
        case 3: return 60.4
        case 2: return 64.2
        default: return nil
        }
    }
}

extension API.ActivityIn {
    /// The same record without the Revontulet measures (what an older server takes).
    var withoutRevontulet: API.ActivityIn {
        var plain = self
        plain.revontulet = nil
        return plain
    }
}

/// Sends the measures only while the server takes them. The live server refuses unknown
/// fields (422) until dad's change goes live, so a refused record that carried them goes
/// once more, same id, without them, and the rest of this app run sends records plain.
/// The next launch tries with the measures again. Used by `LanviClient.send`, so the outbox
/// follows the same rule and a refused record can never get stuck.
final class RevontuletSendGate: @unchecked Sendable {
    static let shared = RevontuletSendGate()

    private let lock = NSLock()
    private var refusedThisRun = false

    var accepted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !refusedThisRun
    }

    /// The record to send first: with the measures unless the server refused them this run.
    func first(_ a: API.ActivityIn) -> API.ActivityIn {
        a.revontulet == nil || accepted ? a : a.withoutRevontulet
    }

    /// After a refused send: the record without the measures, or nil when it had none. Only a
    /// refusal of its content is remembered for the run; "too large" is about face frames.
    func retry(after error: Error, sent: API.ActivityIn) -> API.ActivityIn? {
        guard sent.revontulet != nil, case APIError.rejected(let code) = error else { return nil }
        if code != "body_too_large" {
            lock.lock()
            refusedThisRun = true
            lock.unlock()
        }
        return sent.withoutRevontulet
    }

    /// For tests: forget the refusal.
    func reset() {
        lock.lock()
        refusedThisRun = false
        lock.unlock()
    }
}
