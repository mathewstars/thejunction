import SwiftUI

/// One spark or snowflake drifting down the sky.
struct FocusDrop: Identifiable {
    enum Kind { case spark, snow }

    let id: Int
    let kind: Kind
    /// Seconds since the round started when it appeared.
    let born: TimeInterval
    /// Seconds it takes to drift from the top of the sky to the hill.
    let fall: TimeInterval
    /// Where across the sky it drifts, 0 (left) to 1 (right).
    let x: CGFloat
    /// How far it sways left and right, in points.
    let sway: CGFloat
    let phase: Double
}

/// A short visual left behind by a tap: a burst, a light flying to Lanvi's tail, or a melting snowflake.
struct FocusEffect {
    enum Kind { case burst, flight, melt }

    let kind: Kind
    let at: CGPoint
    let t0: TimeInterval
    let angle: Double

    var life: TimeInterval {
        switch kind {
        case .burst: 0.55
        case .flight: FocusEngine.flightTime
        case .melt: 0.8
        }
    }
}

/// The rules of Sparks and snow, without any drawing.
///
/// A plain class on purpose: the sky redraws 60 times a second and moves things along here,
/// which must not cause SwiftUI view updates. The screen reads the counts when the round ends.
final class FocusEngine {
    static let roundLength: TimeInterval = 45
    static let flightTime: TimeInterval = 0.5
    static let maxReactions = 200

    /// Taps this close to a spark count as catching it. Generous, so nobody feels clumsy.
    private static let sparkReach: CGFloat = 46
    /// Snowflakes need a closer tap, so a near miss on a spark does not melt a flake.
    private static let snowReach: CGFloat = 30

    let start: Date
    /// The part of the screen the drops fall through, set by the screen from its layout.
    var field: CGRect = .zero

    private(set) var drops: [FocusDrop] = []
    private(set) var effects: [FocusEffect] = []
    private(set) var correctTaps = 0
    private(set) var wrongTaps = 0
    private(set) var misses = 0
    /// Snowflakes that drifted all the way down untouched (only used for Lanvi's little comments).
    private(set) var snowPassed = 0
    private(set) var reactionMs: [Int] = []
    /// Round time when the round ended; the drops still in the sky fade away.
    private(set) var endedAt: TimeInterval?

    private var nextId = 0
    private var nextSpawn: TimeInterval = 0.5
    private var snowInARow = 0
    private var recentX: [CGFloat] = []
    /// Above 1 the sky slows down, below 1 it speeds up. Misses slow it, catches nudge it faster.
    private var ease: Double = 1

    init(start: Date = Date()) {
        self.start = start
    }

    func clock(_ now: Date) -> TimeInterval { now.timeIntervalSince(start) }

    // MARK: Moving along

    /// Called every frame: new drops appear, drops that reached the hill go, old effects end.
    func step(now: Date) {
        let t = clock(now)
        if endedAt == nil {
            // Nothing new in the last seconds, so the round ends on a calm sky.
            while t >= nextSpawn && nextSpawn < Self.roundLength - 4 {
                spawn(at: nextSpawn)
            }
            drops.removeAll { d in
                guard t - d.born >= d.fall else { return false }
                if d.kind == .spark {
                    // A missed spark just fades into the snow. Nothing is lost; the sky slows a little.
                    misses += 1
                    ease = min(1.35, ease + 0.08)
                } else {
                    snowPassed += 1
                }
                return true
            }
        } else if let end = endedAt, t - end > 0.6 {
            drops.removeAll()
        }
        effects.removeAll { t - $0.t0 > $0.life }
    }

    private func spawn(at t: TimeInterval) {
        let progress = min(1, t / Self.roundLength)
        // Starts slow, speeds up a little, scaled by how the person is doing.
        let fall = (6.6 - 1.5 * progress) * ease
        let gap = (1.2 - 0.38 * progress) * ease

        let kind: FocusDrop.Kind
        if nextId < 3 {
            kind = .spark                      // the first few are always sparks: start with a win
        } else if snowInARow >= 2 {
            kind = .spark
        } else {
            kind = Double.random(in: 0..<1) < 0.66 ? .spark : .snow
        }
        snowInARow = kind == .snow ? snowInARow + 1 : 0

        drops.append(FocusDrop(
            id: nextId,
            kind: kind,
            born: t,
            fall: fall,
            x: freshX(),
            sway: .random(in: 8...18),
            phase: .random(in: 0..<(2 * .pi))))
        nextId += 1
        nextSpawn = t + gap * .random(in: 0.85...1.15)
    }

    /// A spot across the sky that is not right on top of the last two drops.
    private func freshX() -> CGFloat {
        var x = CGFloat.random(in: 0...1)
        for _ in 0..<10 where recentX.contains(where: { abs($0 - x) < 0.22 }) {
            x = .random(in: 0...1)
        }
        recentX = Array((recentX + [x]).suffix(2))
        return x
    }

    // MARK: Where things are

    /// How far down its path a drop is, 0 at the top, 1 at the hill.
    func progress(of d: FocusDrop, at t: TimeInterval) -> CGFloat {
        CGFloat((t - d.born) / d.fall)
    }

    func position(of d: FocusDrop, at t: TimeInterval) -> CGPoint {
        let age = t - d.born
        let x = field.minX + d.x * field.width + d.sway * CGFloat(sin(d.phase + age * 1.7))
        let y = field.minY + progress(of: d, at: t) * field.height
        return CGPoint(x: x, y: y)
    }

    /// Fades in at the top, fades softly into the snow at the bottom, and away when the round ends.
    func opacity(of d: FocusDrop, at t: TimeInterval) -> Double {
        let p = Double(progress(of: d, at: t))
        var a = min(1, (t - d.born) / 0.3)
        if p > 0.82 { a *= max(0, (1 - p) / 0.18) }
        if let end = endedAt { a *= max(0, 1 - (t - end) / 0.5) }
        return a
    }

    // MARK: Taps

    enum TapOutcome {
        case caught(reactionMs: Int)
        case melted
        case nothing
    }

    /// A finger touched the sky at `point`. Sparks win over snowflakes when both are near.
    func tap(at point: CGPoint, now: Date) -> TapOutcome {
        let t = clock(now)
        guard endedAt == nil else { return .nothing }

        func nearest(_ kind: FocusDrop.Kind, within reach: CGFloat) -> (index: Int, pos: CGPoint)? {
            var best: (Int, CGPoint, CGFloat)?
            for (i, d) in drops.enumerated() where d.kind == kind && opacity(of: d, at: t) > 0.05 {
                let p = position(of: d, at: t)
                let dist = hypot(p.x - point.x, p.y - point.y)
                if dist <= reach && dist < (best?.2 ?? .infinity) { best = (i, p, dist) }
            }
            return best.map { ($0.0, $0.1) }
        }

        if let hit = nearest(.spark, within: Self.sparkReach) {
            let d = drops.remove(at: hit.index)
            let ms = Int(((t - d.born) * 1000).rounded())
            correctTaps += 1
            if reactionMs.count < Self.maxReactions { reactionMs.append(ms) }
            ease = max(0.88, ease - 0.025)
            effects.append(FocusEffect(kind: .burst, at: hit.pos, t0: t, angle: d.phase))
            effects.append(FocusEffect(kind: .flight, at: hit.pos, t0: t, angle: d.phase))
            return .caught(reactionMs: ms)
        }
        if let hit = nearest(.snow, within: Self.snowReach) {
            let d = drops.remove(at: hit.index)
            wrongTaps += 1
            effects.append(FocusEffect(kind: .melt, at: hit.pos, t0: t, angle: d.phase + (t - d.born) * 0.6))
            return .melted
        }
        return .nothing
    }

    // MARK: Ending

    func end(now: Date) {
        guard endedAt == nil else { return }
        endedAt = clock(now)
    }

    func result(completed: Bool, endedAt: Date) -> FocusResult {
        FocusResult(
            correctTaps: correctTaps,
            wrongTaps: wrongTaps,
            misses: misses,
            reactionMs: reactionMs,
            startedAt: start,
            endedAt: endedAt,
            completed: completed)
    }
}
