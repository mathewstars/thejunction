import SwiftUI

/// One spark or snowflake drifting down the sky.
struct FocusDrop: Identifiable {
    enum Kind { case spark, snow }

    let id: Int
    let kind: Kind
    /// Seconds since the round started when it appeared.
    let born: TimeInterval
    /// Seconds it takes to drift from the top of the sky to the bottom of the play field.
    let fall: TimeInterval
    /// Where across the sky it starts, 0 (left) to 1 (right).
    let x: CGFloat
    /// How far it sways left and right, in points.
    let sway: CGFloat
    let phase: Double
    /// Snow only: a slow sideways drift in points per second, like a breath of wind.
    let wind: CGFloat
}

/// A short visual left behind by a tap: a burst, a light rising into the aurora,
/// a melting snowflake, or a soft ripple where a finger touched empty sky.
struct FocusEffect {
    enum Kind { case burst, flight, melt, touch }

    let kind: Kind
    let at: CGPoint
    let t0: TimeInterval
    let angle: Double
    /// Flight only: where across the aurora it lands, 0 (left) to 1 (right).
    var u: CGFloat = 0.5

    var life: TimeInterval {
        switch kind {
        case .burst: 0.5
        case .flight: FocusEngine.flightTime
        case .melt: 0.8
        case .touch: 0.4
        }
    }
}

/// The rules of Sparks and snow, without any drawing.
///
/// A plain class on purpose: the sky redraws 60 times a second and moves things along here,
/// which must not cause SwiftUI view updates. The screen reads the counts when the round ends.
///
/// Every caught spark rises into the sky and feeds the aurora ("fox fires": in the Finnish
/// legend the fox's sparks make the northern lights), so the aurora grows catch by catch.
final class FocusEngine {
    static let roundLength: TimeInterval = 45
    static let flightTime: TimeInterval = 0.82
    static let maxReactions = 200

    /// Taps this close to a spark count as catching it. Generous, so nobody feels clumsy.
    private static let sparkReach: CGFloat = 46
    /// Snowflakes need a closer tap, so a near miss on a spark does not melt a flake.
    private static let snowReach: CGFloat = 30

    let start: Date
    /// The part of the screen the drops fall through, set by the screen from its layout.
    var field: CGRect = .zero
    /// The whole screen's size, set by the screen: the aurora lines up with the painting on it.
    var screen: CGSize = .zero

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

    /// Sparks whose light has reached the aurora.
    private(set) var fed = 0
    /// Spots on the aurora where light just landed.
    private(set) var flares: [(u: CGFloat, t0: TimeInterval)] = []
    /// How full the aurora looks right now, eased toward `auroraTarget` so it swells, never jumps.
    private(set) var auroraShown: Double = 0.1

    private var nextId = 0
    private var nextSpawn: TimeInterval = 0.6
    private var snowInARow = 0
    private var recentX: [CGFloat] = []
    /// Above 1 the sky slows down, below 1 it speeds up. Misses slow it, catches nudge it faster.
    private var ease: Double = 1
    private var lastStep: TimeInterval = 0
    private var nextEcho: TimeInterval = .infinity
    private var echoSeed = 0.37

    init(start: Date = Date()) {
        self.start = start
    }

    func clock(_ now: Date) -> TimeInterval { now.timeIntervalSince(start) }

    /// The aurora's fullness for the sparks fed so far: quick at first, then filling out.
    var auroraTarget: Double {
        let base = 0.1 + 0.9 * (1 - exp(-Double(fed) / 8))
        return endedAt == nil || fed == 0 ? base : min(1, base + 0.08)
    }

    // MARK: Moving along

    /// Called every frame: new drops appear, drops that reached the bottom go, light lands
    /// in the aurora, old effects end.
    func step(now: Date) {
        let t = clock(now)
        let dt = max(0, min(0.1, t - lastStep))
        lastStep = t

        if endedAt == nil {
            // Nothing new in the last seconds, so the round ends on a calm sky.
            while t >= nextSpawn && nextSpawn < Self.roundLength - 4 {
                spawn(at: nextSpawn)
            }
            drops.removeAll { d in
                guard t - d.born >= d.fall else { return false }
                if d.kind == .spark {
                    // A missed spark just settles into the snow. Nothing is lost; the sky slows a little.
                    misses += 1
                    ease = min(1.35, ease + 0.08)
                } else {
                    snowPassed += 1
                }
                return true
            }
        } else if let end = endedAt {
            if t - end > 0.6 { drops.removeAll() }
            // The finish: the aurora you made keeps rippling with light, now and then.
            if fed > 0 && t >= nextEcho {
                echoSeed = GameEase.fract(echoSeed * 7.31 + 0.413)
                flares.append((u: 0.12 + 0.76 * CGFloat(echoSeed), t0: t))
                nextEcho = t + 1.1 + 0.6 * echoSeed
            }
        }

        // Light that finished rising lands in the aurora.
        effects.removeAll { e in
            guard t - e.t0 > e.life else { return false }
            if e.kind == .flight {
                fed += 1
                flares.append((u: e.u, t0: t))
            }
            return true
        }
        flares.removeAll { t - $0.t0 > GameAurora.Flare.life }
        auroraShown += (auroraTarget - auroraShown) * (1 - exp(-dt * 2.4))
    }

    private func spawn(at t: TimeInterval) {
        // Starts slow and ramps gently (eased, never a sudden step), scaled by how the person is doing.
        let p = GameEase.smooth(t / Self.roundLength)
        let fall = (6.4 - 1.6 * p) * ease
        let gap = (1.15 - 0.36 * p) * ease

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
            fall: kind == .snow ? fall * 1.06 : fall,
            x: freshX(),
            sway: .random(in: 8...18),
            phase: .random(in: 0..<(2 * .pi)),
            wind: .random(in: -9...9)))
        nextId += 1
        nextSpawn = t + gap * .random(in: 0.85...1.15)
    }

    /// A spot across the sky that is not right on top of the last two drops.
    private func freshX() -> CGFloat {
        var x = CGFloat.random(in: 0.04...0.96)
        for _ in 0..<10 where recentX.contains(where: { abs($0 - x) < 0.22 }) {
            x = .random(in: 0.04...0.96)
        }
        recentX = Array((recentX + [x]).suffix(2))
        return x
    }

    // MARK: Where things are

    /// How far down its path a drop is, 0 at the top, 1 at the bottom of the field.
    func progress(of d: FocusDrop, at t: TimeInterval) -> CGFloat {
        CGFloat((t - d.born) / d.fall)
    }

    func position(of d: FocusDrop, at t: TimeInterval) -> CGPoint {
        let age = t - d.born
        let p = progress(of: d, at: t)
        let x: CGFloat
        let y: CGFloat
        switch d.kind {
        case .spark:
            // Floats down on a soft curve, a touch slower near the end as if settling.
            x = field.minX + d.x * field.width + d.sway * CGFloat(sin(d.phase + age * 1.7))
            y = field.minY + p * field.height
        case .snow:
            // Snow drifts on the wind, sways in slow wide loops and flutters a little.
            let flutter = 3 * CGFloat(sin(d.phase * 3 + age * 4.1))
            x = field.minX + d.x * field.width + d.wind * CGFloat(age)
                + d.sway * 1.3 * CGFloat(sin(d.phase + age * 0.95)) + flutter
            y = field.minY + p * field.height + 2 * CGFloat(cos(d.phase + age * 1.9))
        }
        return CGPoint(x: x, y: y)
    }

    /// Fades in at the top, settles softly into the snow at the bottom, and away when the round ends.
    func opacity(of d: FocusDrop, at t: TimeInterval) -> Double {
        let p = Double(progress(of: d, at: t))
        var a = GameEase.smooth((t - d.born) / 0.35)
        if p > 0.8 { a *= GameEase.smooth((1 - p) / 0.2) }
        if let end = endedAt { a *= 1 - GameEase.smooth((t - end) / 0.5) }
        return a
    }

    /// Where light from a catch lands on the aurora right now.
    func landing(_ u: CGFloat, at t: TimeInterval) -> CGPoint {
        GameAurora.edge(u: u, screen: screen, t: start.timeIntervalSinceReferenceDate + t)
    }

    // MARK: Taps

    enum TapOutcome {
        case caught(reactionMs: Int, toward: CGPoint)
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
            // It rises to the part of the aurora above where it was caught, give or take.
            let across = screen.width > 0 ? hit.pos.x / screen.width : 0.5
            let u = min(0.92, max(0.12, across + .random(in: -0.12...0.12)))
            effects.append(FocusEffect(kind: .burst, at: hit.pos, t0: t, angle: d.phase))
            effects.append(FocusEffect(kind: .flight, at: hit.pos, t0: t, angle: d.phase, u: u))
            return .caught(reactionMs: ms, toward: landing(u, at: t + Self.flightTime))
        }
        if let hit = nearest(.snow, within: Self.snowReach) {
            let d = drops.remove(at: hit.index)
            wrongTaps += 1
            effects.append(FocusEffect(kind: .melt, at: hit.pos, t0: t, angle: d.phase + (t - d.born) * 0.6))
            return .melted
        }
        effects.append(FocusEffect(kind: .touch, at: point, t0: t, angle: 0))
        return .nothing
    }

    // MARK: Ending

    func end(now: Date) {
        guard endedAt == nil else { return }
        let t = clock(now)
        endedAt = t
        nextEcho = t + 1.4
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
