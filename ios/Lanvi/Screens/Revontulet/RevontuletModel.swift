import Foundation
import CoreGraphics

// MARK: - Revontulet: the plain values the game is made of
//
// No SwiftUI in this file or in `RevontuletEngine.swift`: the engine is a value driven by
// inputs (start, a finger going down, moving, lifting, close, and the clock), so the same
// engine runs from real fingers and from the auto-play. Read `ios/REVONTULET.md` first.

/// The beats of the game, in order. `intro` waits for Start; `done` has handed back.
enum RevontuletBeat: String, CaseIterable, Equatable {
    case intro, choice, trace, sling, flight, impact, burst, celebrate, warmth, sleep, done
}

/// Which fault line the person picked.
enum RevontuletEffort: String, Equatable {
    /// The thin low crack: one shot, a small warm glow.
    case easy
    /// The thick crystalline vein higher up: two embers on the way, a big burst of aurora.
    case hard
}

/// What the engine takes. Points are screen points (full screen, top-left origin);
/// `radius` is `UITouch.majorRadius` when the finger came from UIKit, nil from the auto-play.
enum RevontuletInput: Equatable {
    case start
    case down(CGPoint, radius: CGFloat?)
    case move(CGPoint, radius: CGFloat?)
    case up(CGPoint)
    case close
}

/// What just happened, for the screen (haptics, the fox, `GameMoments`). Rounds count from 0.
enum RevontuletEvent: Equatable {
    case started
    case choiceShown(round: Int)
    case chose(round: Int, effort: RevontuletEffort)
    case arcShown(round: Int)
    case traceStarted(round: Int)
    /// The light passed another twelfth of the half-circle.
    case traceStep(Int)
    case traceEnded(round: Int)
    case pullStarted
    /// How far the spark is pulled, 0...1.
    case pull(Double)
    case pullLetGo
    case released(round: Int, level: Double)
    case foxLaunched
    case emberShown(index: Int)
    case emberHit(index: Int, reactionMs: Int)
    case emberMissed(index: Int)
    /// The landing is now certain (time, size, whether it breaks the wall): said ahead of
    /// the hit so the haptics can be scheduled on the frame it happens.
    case landing(at: Double, pieces: Int, hard: Bool, embersHit: Int, breaking: Bool, ribbon: Bool, burstAt: Double?)
    case impact(round: Int, pieces: Int, breaking: Bool)
    case shattered
    case celebrate
    case warmthBegan
    case strokeBegan(number: Int)
    /// Finger speed in points per second while stroking (for the purr).
    case strokeMoved(speed: Double)
    case strokeEnded(number: Int, counted: Bool)
    case sleep
    case ended(completed: Bool)
}

// MARK: - Where everything is

/// The game's geometry for one screen size, in full-screen points.
struct RevontuletLayout: Equatable {
    var size: CGSize
    var safeTop: CGFloat
    var safeBottom: CGFloat
    /// The fox's square side and centre, and where its feet touch the snow.
    var foxSize: CGFloat
    var foxCenter: CGPoint
    var feetY: CGFloat
    /// The pane of ice (its base is buried in the snow behind the fox).
    var wall: CGRect
    /// Where the fox's spark rests, above the fox.
    var anchor: CGPoint
    /// The half-circle's radius, and the farthest the spark can be pulled.
    var arcRadius: CGFloat
    var maxPull: CGFloat
    /// Where the fox's own spark goes if the wall is still standing at 1:12.
    var foxTarget: CGPoint

    init(size: CGSize, safeTop: CGFloat, safeBottom: CGFloat) {
        self.size = size
        self.safeTop = safeTop
        self.safeBottom = safeBottom
        let w = size.width, h = size.height
        // The painted hollow (see `WorldFrame`): the picture fills the screen.
        let imageW: CGFloat = 1520, imageH: CGFloat = 2688
        let s = max(w / imageW, h / imageH)
        let originY = (h - imageH * s) / 2
        let hollowY = originY + 0.786 * imageH * s
        foxSize = min(w * 0.5, h * 0.235)
        feetY = min(hollowY + foxSize * 0.03, h - safeBottom - 64)
        foxCenter = CGPoint(x: w / 2, y: feetY - foxSize / 2)
        let foxTop = feetY - foxSize
        arcRadius = min(w * 0.25, h * 0.115)
        anchor = CGPoint(x: w / 2, y: foxTop - arcRadius - h * 0.012)
        maxPull = arcRadius * 0.95
        let top = safeTop + 58
        let bottom = feetY - foxSize * 0.42
        wall = CGRect(x: w * 0.055, y: top, width: w * 0.89, height: bottom - top)
        foxTarget = CGPoint(x: w * 0.5, y: top + (bottom - top) * 0.3)
    }

    /// The two fault lines for a round, as polylines in screen points, easy first.
    /// They move each round to ice that is still standing.
    func faults(round: Int) -> (easy: [CGPoint], hard: [CGPoint]) {
        func p(_ fx: CGFloat, _ fy: CGFloat) -> CGPoint {
            CGPoint(x: wall.minX + fx * wall.width, y: wall.minY + fy * wall.height)
        }
        // Each round's lines sit on ice no earlier impact has touched, clear of that
        // round's half-circle: the crack always low, the vein always high.
        switch round % 3 {
        case 0:
            return ([p(0.04, 0.79), p(0.09, 0.775), p(0.14, 0.795), p(0.19, 0.78), p(0.24, 0.795)],
                    [p(0.60, 0.13), p(0.66, 0.19), p(0.72, 0.16), p(0.79, 0.235), p(0.85, 0.21), p(0.91, 0.28), p(0.97, 0.26)])
        case 1:
            return ([p(0.76, 0.795), p(0.81, 0.78), p(0.86, 0.8), p(0.91, 0.785), p(0.96, 0.8)],
                    [p(0.03, 0.27), p(0.09, 0.21), p(0.15, 0.24), p(0.21, 0.17), p(0.28, 0.2), p(0.34, 0.13), p(0.40, 0.15)])
        default:
            return ([p(0.04, 0.6), p(0.09, 0.585), p(0.14, 0.605), p(0.19, 0.59), p(0.24, 0.61)],
                    [p(0.30, 0.17), p(0.37, 0.11), p(0.43, 0.14), p(0.50, 0.07), p(0.57, 0.10), p(0.64, 0.05), p(0.70, 0.08)])
        }
    }

    /// Where the spark lands for a choice: the middle of that fault line.
    func target(round: Int, effort: RevontuletEffort) -> CGPoint {
        let f = faults(round: round)
        let line = effort == .easy ? f.easy : f.hard
        return line[line.count / 2]
    }

    /// The half-circle for a round: a quarter turn clockwise each round
    /// (bulging left, then up, then right), always clear of the fox.
    func arc(round: Int) -> RevontuletArc {
        let bulge: Double = [Double.pi, Double.pi * 1.5, 0][round % 3]
        // A bulge to the side spans its full height, so it sits a little higher.
        let lift: CGFloat = round % 3 == 1 ? -arcRadius * 0.15 : arcRadius * 0.08
        return RevontuletArc(center: CGPoint(x: anchor.x, y: anchor.y - lift), radius: arcRadius, bulge: bulge)
    }
}

/// A half-circle: points `center + radius·(cos φ, sin φ)` for φ from `bulge − π/2` to
/// `bulge + π/2` (screen angles, y down, so it is traced clockwise).
struct RevontuletArc: Equatable {
    var center: CGPoint
    var radius: CGFloat
    var bulge: Double

    var startAngle: Double { bulge - .pi / 2 }

    func point(_ s: Double, reversed: Bool = false) -> CGPoint {
        let u = reversed ? 1 - s : s
        let a = startAngle + u * .pi
        return CGPoint(x: center.x + radius * cos(a), y: center.y + radius * sin(a))
    }

    /// Where along the arc a point lies (0 at the start, 1 at the end; outside 0...1
    /// beyond the ends) and how far it is from the arc's line.
    func locate(_ p: CGPoint, reversed: Bool = false) -> (s: Double, off: CGFloat) {
        let dx = p.x - center.x, dy = p.y - center.y
        var a = atan2(Double(dy), Double(dx)) - startAngle
        // Bring into −π/2 ... 3π/2 so the gap behind the arc splits evenly.
        while a < -.pi / 2 { a += 2 * .pi }
        while a >= 1.5 * .pi { a -= 2 * .pi }
        var s = a / .pi
        if reversed { s = 1 - s }
        return (s, abs(hypot(dx, dy) - radius))
    }
}

// MARK: - The flight

/// One spark in the air, from the release (or the fox's own launch) to the ice.
struct RevontuletFlight: Equatable {
    var launch: Double
    var from: CGPoint
    var control: CGPoint
    var to: CGPoint
    var duration: Double
    var hard: Bool
    var foxOwn: Bool
    /// For a hard choice: where the embers sit along the path (0...1) and when the spark
    /// passes each, in seconds after launch.
    var emberU: [Double] = []
    var emberT: [Double] = []
    var emberShownAt: [Double?] = []
    var emberHitAt: [Double?] = []
    var emberMissed: [Bool] = []
    /// Worked out once the last ember can no longer be tapped (at once for an easy shot).
    var planned: Planned?

    struct Planned: Equatable {
        var pieces: Int
        var embersHit: Int
        var breaking: Bool
        var ribbon: Bool
    }

    /// The moment nothing a finger does can change how this flight lands.
    var settledAt: Double {
        guard hard, let last = emberT.last else { return launch }
        return launch + last + Self.emberGrace
    }

    static let emberLead = 0.62      // an ember flashes this long before the spark reaches it
    static let emberGrace = 0.38     // and can still be tapped this long after

    func bezier(_ u: Double) -> CGPoint {
        let a = 1 - u
        let x = a * a * Double(from.x) + 2 * a * u * Double(control.x) + u * u * Double(to.x)
        let y = a * a * Double(from.y) + 2 * a * u * Double(control.y) + u * u * Double(to.y)
        return CGPoint(x: x, y: y)
    }

    /// How far along the path the spark is at `t` seconds after launch. For a hard choice
    /// it slows to a near stop at each ember (the rhythm), then speeds into the ice.
    func progress(_ t: Double) -> Double {
        let x = min(max(t / duration, 0), 1)
        if emberT.count == 2 {
            let k = [0, emberT[0], emberT[1], duration], u = [0, emberU[0], emberU[1], 1]
            for i in 0..<3 where t <= k[i + 1] || i == 2 {
                let f = min(max((t - k[i]) / (k[i + 1] - k[i]), 0), 1)
                let e: Double
                switch i {
                case 0: e = 1 - pow(1 - f, 2.2)               // leaves fast, eases to the first ember
                case 1: e = f * f * (3 - 2 * f)                // eases from one ember to the next
                default: e = pow(f, 1.8)                       // speeds up into the ice
                }
                return u[i] + (u[i + 1] - u[i]) * e
            }
            return 1
        }
        return 1 - pow(1 - x, 1.7)
    }

    func point(at now: Double) -> CGPoint { bezier(progress(now - launch)) }

    func emberPoint(_ i: Int) -> CGPoint { bezier(emberU[i]) }
}

/// The spark hit the ice.
struct RevontuletImpact: Equatable {
    var time: Double
    var point: CGPoint
    var round: Int
    /// 1 for the crack, 2 for the vein, 3 and 4 with one or both embers lit.
    var pieces: Int
    var hard: Bool
    var embersHit: Int
    /// This impact breaks the wall.
    var breaking: Bool
    /// Both embers lit, and this time the sky added a ribbon nobody was promised.
    var ribbon: Bool
    var foxOwn: Bool
}

// MARK: - The result (stays on the phone; see `ActivityRouter.record`)

/// Everything one game measured. Instants are given twice: as wall-clock dates and as
/// `CACurrentMediaTime()` seconds (`…Uptime`), the clock face frames use.
struct RevontuletResult: Equatable {
    struct EmberHit: Equatable {
        var index: Int
        /// From the ember's flash to the finger landing on it.
        var reactionMs: Int
        var uptime: Double
    }

    struct Round: Equatable {
        var number: Int
        var effort: RevontuletEffort?
        /// From the fault lines lighting up to the tap that picked one.
        var decisionMs: Int?
        var chosenUptime: Double?
        /// The half-circle appearing, and the first touch on it after that.
        var arcShownUptime: Double?
        var firstTouchMs: Int?
        /// First touch on the half-circle to the light reaching its end.
        var traceDurationMs: Int?
        /// The finger's path while tracing, in points (lifts left out).
        var traceLength: Double = 0
        /// Path length over the time the finger was down, points per second.
        var traceMeanSpeed: Double?
        /// The fastest the finger went (smoothed over a few samples), points per second.
        var tracePeakSpeed: Double?
        /// Times the finger lifted before the light reached the end.
        var traceLifts: Int = 0
        /// Mean `UITouch.majorRadius` while tracing, points (a stand-in for pressure).
        var traceTouchRadius: Double?
        /// How far the spark was pulled at the release (points, after the soft limit),
        /// and the farthest the finger went from where the pull began.
        var pullDistance: Double?
        var pullMaxFinger: Double?
        var holdMs: Int?
        var launchUptime: Double?
        var launchDate: Date?
        var embersShown: Int = 0
        var emberHits: [EmberHit] = []
        var impactUptime: Double?
    }

    struct Stroke: Equatable {
        var number: Int
        var startUptime: Double
        var durationMs: Int
        var length: Double
        var meanSpeed: Double
        var peakSpeed: Double
        /// Down the screen is positive: how much of the stroke went downwards (−1...1).
        var downness: Double
        var touchRadius: Double?
    }

    var startedAt: Date
    var endedAt: Date
    var startUptime: Double
    var endUptime: Double
    /// True when the game ran to the fox falling asleep; false when the person closed it.
    var completed: Bool
    var rounds: [Round]
    var strokes: [Stroke]
    var burstUptime: Double?
    var celebrateUptime: Double?
    /// The wall still stood at 1:12 and the fox's own spark broke it.
    var foxFinishedWall: Bool
    var surpriseRibbons: Int

    // What goes into the `focus` record.
    var launches: Int { rounds.filter { $0.launchUptime != nil }.count }
    var embersShown: Int { rounds.reduce(0) { $0 + $1.embersShown } }
    var embersHit: Int { rounds.reduce(0) { $0 + $1.emberHits.count } }
    /// For each launch the half-circle's first touch, then each ember hit's reaction.
    var reactionMs: [Int] {
        rounds.compactMap { $0.launchUptime != nil ? $0.firstTouchMs : nil }
            + rounds.flatMap { $0.emberHits.map(\.reactionMs) }
    }
}
