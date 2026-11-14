import Foundation
import CoreGraphics

/// A pretend finger for the film, the stills and tests: it plays the whole game through
/// the engine's own inputs (down, move, up), at a person's pace, with small human wobbles.
///
/// `-revontuletAuto` plays a mixed game; `-revontuletAuto hard` picks the vein every round
/// and lights every ember; `-revontuletAuto easy` picks the crack twice, then the vein and
/// misses both embers; `-revontuletAuto idle` presses Start and then does nothing (the
/// clock breaks the wall, the fox's own spark finishes it, the fox falls asleep);
/// `-revontuletAuto close` closes the game in the middle of the burst. `mixed` and `hard`
/// end the goodnight with a tap; `easy` and `idle` let it end by itself.
struct RevontuletAutoPlay {
    enum Style: String {
        case mixed, hard, easy, idle
        /// Plays like `mixed`, then presses the close button in the middle of the burst.
        case close
    }

    let style: Style
    private var rng: Rng
    private var plan: [Step] = []
    private var planKey = ""
    /// Where the pretend finger is (nil while it is lifted). Shown as a soft dot.
    private(set) var finger: CGPoint?

    private struct Step {
        var at: Double
        var input: RevontuletInput
    }

    /// Waits are multiplied by `pace` (the self-test plays fast and slow people).
    let pace: Double
    /// Extra seconds in round one, so a forced first-time coach can be seen (the film).
    let coachPause: Double
    private var emberSeen: [Int: Double] = [:]
    private var emberTapped: Set<Int> = []

    init(style: Style, seed: UInt64 = 7, pace: Double = 1, coachPause: Double = 0) {
        self.style = style
        self.pace = pace
        self.coachPause = coachPause
        rng = Rng(seed: seed)
    }

    /// Read from the launch arguments: `-revontuletAuto [mixed|hard|easy|idle]`.
    static func fromArguments() -> Style? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-revontuletAuto") else { return nil }
        if i + 1 < args.count, let s = Style(rawValue: args[i + 1]) { return s }
        return .mixed
    }

    /// The inputs due by `now`, given what the game is doing.
    mutating func step(_ e: RevontuletEngine, now: Double) -> [RevontuletInput] {
        let key = "\(e.beat.rawValue)-\(e.round)-\(e.strokesCounted)-\(e.beatStart)"
        if key != planKey {
            planKey = key
            // A finger that is down still lifts, whatever the new beat plans.
            // It lifts now, before anything the new beat plans.
            let lift = plan.first { if case .up = $0.input { return finger != nil } else { return false } }
            plan = makePlan(e, now: now)
            if let l = lift { plan.insert(Step(at: now, input: l.input), at: 0) }
        }
        var out: [RevontuletInput] = []
        // Embers are tapped by watching them, like a person: a moment after each one flashes
        // (longer while a coach holds time still, so the film shows it).
        if e.beat == .flight, let f = e.flight, f.hard, !f.foxOwn {
            for i in f.emberU.indices where hitsEmber(i, round: e.round) && !emberTapped.contains(i) && f.emberShownAt[i] != nil {
                let seen = emberSeen[i] ?? now
                emberSeen[i] = seen
                let wait = e.slowSince != nil && coachPause > 0 ? 1.2 : (0.22 + 0.12 * Double(i)) * pace
                if now - seen >= wait {
                    emberTapped.insert(i)
                    let p = f.emberPoint(i)
                    plan.insert(Step(at: now, input: .down(p, radius: nil)), at: 0)
                    plan.append(Step(at: now + 0.08, input: .up(p)))
                    plan.sort { $0.at < $1.at }
                }
            }
        }
        while let first = plan.first, first.at <= now {
            plan.removeFirst()
            out.append(first.input)
            switch first.input {
            case let .down(p, _), let .move(p, _): finger = p
            case .up: finger = nil
            default: break
            }
        }
        return out
    }

    /// When the next pretend input is due (for a simulation that skips ahead).
    var nextAt: Double? { plan.first?.at }

    // MARK: Plans per beat

    private mutating func makePlan(_ e: RevontuletEngine, now: Double) -> [Step] {
        let L = e.layout
        let t0 = max(now, e.beatStart)
        if style == .idle && e.beat != .intro { return [] }
        switch e.beat {
        case .intro:
            return [Step(at: now + 2.6 + coachPause * 0.6, input: .start)]

        case .choice:
            let effort = effortFor(round: e.round)
            let target = L.target(round: e.round, effort: effort)
            let wait: Double = (1.5 + 0.35 * Double(e.round)) * pace + (e.round == 0 ? coachPause : 0)
            let at: Double = t0 + wait + rng.next() * 0.5
            return tap(jitter(target, 6), at: at)

        case .trace:
            let arc = e.arc
            var steps: [Step] = []
            let start = t0 + (0.75 + rng.next() * 0.35) * pace + (e.round == 0 ? coachPause : 0)
            let duration = (1.35 + rng.next() * 0.5 + (style == .easy ? 0.5 : 0)) * max(0.6, min(pace, 2))
            // One lift halfway in the easy game's second round.
            let liftAt: Double? = (style == .easy && e.round == 1) ? 0.52 : nil
            let n = Int(duration * 60)
            var t = start
            var down = false
            var paused = 0.0
            for i in 0...n {
                let x = Double(i) / Double(n)
                // Smooth start and stop (a minimum-jerk profile), like a real finger.
                let s = -0.03 + 1.07 * (x * x * x * (10 - 15 * x + 6 * x * x))
                if let l = liftAt, s > l, paused == 0 {
                    steps.append(Step(at: t, input: .up(arc.point(l))))
                    paused = 0.45
                    t += paused
                    down = false
                }
                let wobble = CGFloat(sin(x * 9 + Double(e.round)) * 3.5)
                var p = arc.point(min(max(s, -0.03), 1.04))
                let dir = CGVector(dx: p.x - arc.center.x, dy: p.y - arc.center.y)
                let len = max(hypot(dir.dx, dir.dy), 1)
                p.x += dir.dx / len * wobble
                p.y += dir.dy / len * wobble
                steps.append(Step(at: t, input: down ? .move(p, radius: nil) : .down(p, radius: nil)))
                down = true
                t += duration / Double(n)
            }
            if let last = steps.last, case let .move(p, _) = last.input {
                steps.append(Step(at: t + 0.05, input: .up(p)))
            }
            return steps

        case .sling:
            let start = t0 + (0.55 + rng.next() * 0.3) * pace + (e.round == 0 ? coachPause : 0)
            let from = jitter(L.anchor, 4)
            // Mostly straight down and a little to one side, eased, then a short hold.
            let side = CGFloat(rng.next() - 0.5) * L.maxPull * 0.5
            let to = CGPoint(x: from.x + side, y: from.y + L.maxPull * 1.15)
            var steps = [Step(at: start, input: .down(from, radius: nil))]
            let pullTime = 0.6, n = 36
            for i in 1...n {
                let x = Double(i) / Double(n)
                let ease = 1 - pow(1 - x, 2.4)
                let p = CGPoint(x: from.x + (to.x - from.x) * ease, y: from.y + (to.y - from.y) * ease)
                steps.append(Step(at: start + pullTime * x, input: .move(p, radius: nil)))
            }
            let hold = 0.3 + rng.next() * 0.25
            for i in 1...6 {
                let tx: CGFloat = CGFloat(sin(Double(i) * 2.1)) * 1.2
                let ty: CGFloat = CGFloat(cos(Double(i) * 1.7)) * 1.2
                let tremble = CGPoint(x: to.x + tx, y: to.y + ty)
                steps.append(Step(at: start + pullTime + hold * Double(i) / 6, input: .move(tremble, radius: nil)))
            }
            steps.append(Step(at: start + pullTime + hold + 0.02, input: .up(to)))
            return steps

        case .flight:
            emberSeen = [:]
            emberTapped = []
            return []

        case .warmth:
            guard let w = e.warmthAt, e.strokesCounted < RevontuletEngine.strokesWanted else { return [] }
            let start = max(t0, w + RevontuletEngine.strokesFrom) + ((e.strokesCounted == 0 ? 0.5 : 0.75) + rng.next() * 0.3) * pace
                + (e.strokesCounted == 0 ? coachPause : 0)
            let sq = L.foxSquare(.warm)
            let dx: [CGFloat] = [-0.12, 0.1, -0.01]
            let x = sq.midX + dx[min(e.strokesCounted, 2)] * sq.width
            // A real, slow pass down most of the fox.
            let y0 = sq.minY + sq.height * 0.16, y1 = sq.minY + sq.height * 0.78
            let duration = 1.9 + rng.next() * 0.5
            var steps = [Step(at: start, input: .down(CGPoint(x: x, y: y0), radius: nil))]
            let n = Int(duration * 60)
            for i in 1...n {
                let u = Double(i) / Double(n)
                let s = u * u * (3 - 2 * u)
                let p = CGPoint(x: x + CGFloat(sin(u * 3)) * 6, y: y0 + (y1 - y0) * CGFloat(s))
                steps.append(Step(at: start + duration * u, input: .move(p, radius: nil)))
            }
            steps.append(Step(at: start + duration + 0.02, input: .up(CGPoint(x: x, y: y1))))
            return steps

        case .burst where style == .close:
            return [Step(at: e.beatStart + 0.5, input: .close)]

        case .sleep:
            // Presses Continue a moment after it appears.
            return [Step(at: e.beatStart + RevontuletEngine.asleepAfter + 1.6, input: .finish)]

        default:
            return []
        }
    }

    private func effortFor(round: Int) -> RevontuletEffort {
        switch style {
        case .hard: return .hard
        case .easy: return round < 2 ? .easy : .hard
        case .mixed, .idle, .close: return [RevontuletEffort.hard, .easy, .hard][min(round, 2)]
        }
    }

    private func hitsEmber(_ i: Int, round: Int) -> Bool {
        switch style {
        case .hard: return true
        case .easy, .idle: return false
        case .mixed, .close: return round == 0 ? i == 0 : true
        }
    }

    private func tap(_ p: CGPoint, at t: Double) -> [Step] {
        [Step(at: t, input: .down(p, radius: nil)), Step(at: t + 0.09, input: .up(p))]
    }

    private mutating func jitter(_ p: CGPoint, _ r: CGFloat) -> CGPoint {
        CGPoint(x: p.x + CGFloat(rng.next() - 0.5) * 2 * r, y: p.y + CGFloat(rng.next() - 0.5) * 2 * r)
    }
}
