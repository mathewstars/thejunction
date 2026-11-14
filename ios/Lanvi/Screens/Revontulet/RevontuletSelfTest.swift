import Foundation
import CoreGraphics

/// `-revontuletSelfTest`: hundreds of made-up sessions through the plain engine (no
/// drawing), each with its own pace and mischief: fast, slow, idle, lifting mid-trace,
/// closing early, a second finger landing, taps and drags all over the screen, taps during
/// the burst, leaving the app. Every one must end by 1:30 (or when closed) with a valid
/// result and a `focus` record the server would accept. Prints one line per failure and a
/// summary starting with "revontulet selftest:".
enum RevontuletSelfTest {
    struct Report {
        var sessions = 0
        var failures: [String] = []
        var longest = 0.0
        var completed = 0
        var foxFinished = 0
        var summary: String {
            "revontulet selftest: \(sessions) sessions, \(failures.count) failures, \(completed) ran to sleep, "
                + "\(foxFinished) finished by the fox, longest \(String(format: "%.1f", longest)) s"
        }
    }

    static func run(layout: RevontuletLayout, sessions: Int = 400) -> Report {
        var report = Report()
        var rng = Rng(seed: 2026)
        let styles: [RevontuletAutoPlay.Style] = [.mixed, .hard, .easy, .idle]
        for n in 0..<sessions {
            let mischief = n % 9
            let pace = [1.0, 0.35, 2.6, 4.0][Int(rng.next() * 4)]
            var e = RevontuletEngine(layout: layout, seed: UInt64(n + 1))
            var auto = RevontuletAutoPlay(style: styles[n % 4], seed: UInt64(n * 31 + 5), pace: pace)
            let t0 = 5000.0
            var now = t0
            let dt = 1.0 / 60
            let closeAt: Double? = mischief == 4 ? t0 + 2 + rng.next() * 85 : nil
            let leaveAt: Double? = mischief == 8 ? t0 + 2 + rng.next() * 85 : nil
            var fingerDown = false
            _ = e.handle(.start, at: now)
            while now < t0 + 130 {
                for input in auto.step(e, now: now) {
                    switch input {
                    case .down: fingerDown = true
                    case .up: fingerDown = false
                    default: break
                    }
                    _ = e.handle(input, at: now)
                }
                switch mischief {
                case 5:
                    // Taps anywhere, now and then, in every beat (the burst included).
                    if rng.next() < 0.05 {
                        let p = randomPoint(layout, &rng)
                        _ = e.handle(.down(p, radius: 9), at: now)
                        _ = e.handle(.up(p), at: now + 0.06)
                    }
                case 6:
                    // A second finger lands while the first is down (a stray "down").
                    if fingerDown, rng.next() < 0.08 {
                        _ = e.handle(.down(randomPoint(layout, &rng), radius: 11), at: now)
                    }
                case 7:
                    // Drags scribbled across the screen.
                    if rng.next() < 0.02 {
                        var p = randomPoint(layout, &rng)
                        _ = e.handle(.down(p, radius: 8), at: now)
                        for k in 1...12 {
                            p.x += CGFloat(rng.next() - 0.5) * 60
                            p.y += CGFloat(rng.next() - 0.5) * 60
                            _ = e.handle(.move(p, radius: 8), at: now + Double(k) * 0.008)
                        }
                        _ = e.handle(.up(p), at: now + 0.1)
                    }
                default:
                    break
                }
                // Some people tap the goodnight away at once.
                if n % 5 == 2, e.beat == .sleep, now - e.beatStart > 0.4 {
                    _ = e.handle(.down(randomPoint(layout, &rng), radius: 10), at: now)
                }
                _ = e.tick(now)
                if e.beat == .done { break }
                if let c = closeAt, now >= c { _ = e.handle(.close, at: now); break }
                if let l = leaveAt, now >= l { _ = e.handle(.interrupt, at: now); break }
                now += dt
            }
            report.sessions += 1
            let label = "session \(n) (\(styles[n % 4]), pace \(pace), mischief \(mischief))"
            guard e.beat == .done, let r = e.result() else {
                report.failures.append("\(label): stuck in \(e.beat) at \(String(format: "%.1f", now - t0)) s")
                continue
            }
            let length = r.endUptime - r.startUptime
            report.longest = max(report.longest, length)
            if r.completed { report.completed += 1 }
            if r.foxFinishedWall { report.foxFinished += 1 }
            if let problem = check(r, closed: closeAt != nil || leaveAt != nil) {
                report.failures.append("\(label): \(problem)")
            }
            // A player at a normal pace, with no mischief, breaks the wall with their own three
            // shots and strokes the fox three times: the clock's safety nets must not be needed.
            if mischief < 4, styles[n % 4] != .idle, pace <= 1 {
                if !r.completed || r.foxFinishedWall || r.launches != 3 || r.strokes.count != 3 {
                    report.failures.append("\(label): a normal game did not play out (launches \(r.launches), strokes \(r.strokes.count), fox finished \(r.foxFinishedWall))")
                }
            }
        }
        return report
    }

    /// Nil when the result is sound and its `focus` record passes the server's checks
    /// (`engine/clinic_engine/mind/activities.py`, `check_activity`).
    static func check(_ r: RevontuletResult, closed: Bool) -> String? {
        let length = r.endUptime - r.startUptime
        if length > RevontuletEngine.cap + 0.05 { return "ran \(length) s, over the cap" }
        if length < 0 { return "ended before it started" }
        if !closed && !r.completed { return "ended without finishing and nobody closed it" }
        if r.completed && r.burstUptime == nil { return "finished without the wall breaking" }
        if r.completed && r.strokes.count > RevontuletEngine.strokesWanted { return "too many strokes" }
        let a = ActivityRouter.record(r)
        guard a.type == .focus, let correct = a.correctTaps, let wrong = a.wrongTaps, let misses = a.misses,
              let rts = a.reactionMs else { return "record is missing focus fields" }
        if a.durationS < 0 || a.durationS > 1800 { return "duration \(a.durationS)" }
        if correct < 0 || wrong < 0 || misses < 0 { return "negative counts" }
        if correct + wrong + misses > 1000 { return "too many taps" }
        if rts.count > correct + wrong { return "more reactions than taps (\(rts.count) > \(correct + wrong))" }
        if rts.contains(where: { $0 < 0 || $0 > 10_000 }) { return "a reaction outside 0...10000" }
        if a.durationS > 0, Double(correct + wrong) > a.durationS * 10 { return "taps too fast" }
        if a.completed != r.completed { return "completed flag lost" }
        return nil
    }

    private static func randomPoint(_ L: RevontuletLayout, _ rng: inout Rng) -> CGPoint {
        CGPoint(x: CGFloat(rng.next()) * L.size.width, y: CGFloat(rng.next()) * L.size.height)
    }
}
