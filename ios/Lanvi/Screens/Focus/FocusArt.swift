import SwiftUI

/// Drawing for Sparks and snow: warm glowing sparks, crisp white snowflakes and the tap effects.
/// Everything is drawn into one Canvas so the sky stays smooth at 60 fps.
enum FocusArt {
    static let sparkCore = Color(hex: 0xFFF8E1)
    static let sparkGold = Color(hex: 0xFFD45E)
    static let sparkWarm = Color(hex: 0xFFAA4C)

    // MARK: Pieces

    static func spark(_ ctx: GraphicsContext, at c: CGPoint, scale s: CGFloat = 1, alpha: Double, time t: Double, seed: Double) {
        guard alpha > 0.01 else { return }
        let pulse = 1 + 0.09 * CGFloat(sin(t * 5 + seed))
        let r = 30 * s * pulse
        ctx.fill(circle(c, r), with: .radialGradient(
            Gradient(stops: [
                .init(color: sparkGold.opacity(0.85 * alpha), location: 0),
                .init(color: sparkWarm.opacity(0.32 * alpha), location: 0.42),
                .init(color: sparkWarm.opacity(0), location: 1),
            ]),
            center: c, startRadius: 0, endRadius: r))
        let spin = t * 0.9 + seed
        ctx.fill(star(c, outer: 15 * s * pulse, inner: 3.4 * s, rotation: spin), with: .color(sparkCore.opacity(alpha)))
        ctx.fill(star(c, outer: 8 * s, inner: 2.4 * s, rotation: spin + .pi / 4), with: .color(sparkGold.opacity(alpha)))
        ctx.fill(circle(c, 4.2 * s), with: .color(.white.opacity(alpha)))
    }

    static func snowflake(_ ctx: GraphicsContext, at c: CGPoint, arm L: CGFloat = 15, alpha: Double,
                          angle: Double, squash: CGFloat = 1) {
        guard alpha > 0.01 else { return }
        ctx.fill(circle(c, L * 1.35), with: .radialGradient(
            Gradient(colors: [.white.opacity(0.22 * alpha), .white.opacity(0)]),
            center: c, startRadius: 0, endRadius: L * 1.35))

        func pt(_ from: CGPoint, _ a: Double, _ r: CGFloat) -> CGPoint {
            CGPoint(x: from.x + CGFloat(cos(a)) * r, y: from.y + CGFloat(sin(a)) * r * squash)
        }
        var p = Path()
        for k in 0..<6 {
            let a = angle + Double(k) * .pi / 3
            p.move(to: c)
            p.addLine(to: pt(c, a, L))
            let b = pt(c, a, L * 0.56)
            p.move(to: b); p.addLine(to: pt(b, a + .pi / 4, L * 0.32))
            p.move(to: b); p.addLine(to: pt(b, a - .pi / 4, L * 0.32))
        }
        ctx.stroke(p, with: .color(Theme.nightTop.opacity(0.25 * alpha)),
                   style: StrokeStyle(lineWidth: 4.4, lineCap: .round))
        ctx.stroke(p, with: .color(.white.opacity(alpha)),
                   style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
        ctx.fill(circle(c, 2.6), with: .color(.white.opacity(alpha)))
    }

    // MARK: Effects

    static func draw(_ e: FocusEffect, _ ctx: GraphicsContext, at t: TimeInterval, tail: CGPoint) {
        let k = min(1, max(0, (t - e.t0) / e.life))
        switch e.kind {
        case .burst: burst(ctx, at: e.at, k: k, seed: e.angle)
        case .flight: flight(ctx, from: e.at, to: tail, k: k, time: t)
        case .melt: melt(ctx, at: e.at, k: k, angle: e.angle)
        }
    }

    /// The spark pops open: a flash, a ring and a few motes.
    private static func burst(_ ctx: GraphicsContext, at c: CGPoint, k: Double, seed: Double) {
        let out = CGFloat(1 - pow(1 - k, 3))
        let fade = 1 - k
        let flash = 34 * (0.6 + 0.6 * out)
        ctx.fill(circle(c, flash), with: .radialGradient(
            Gradient(colors: [sparkCore.opacity(0.9 * fade * fade), sparkGold.opacity(0)]),
            center: c, startRadius: 0, endRadius: flash))
        ctx.stroke(circle(c, 12 + 34 * out), with: .color(sparkGold.opacity(0.9 * fade)),
                   lineWidth: 1 + 3 * CGFloat(fade))
        for i in 0..<8 {
            let a = seed + Double(i) * .pi / 4
            let d = 10 + 40 * out
            let p = CGPoint(x: c.x + CGFloat(cos(a)) * d, y: c.y + CGFloat(sin(a)) * d)
            ctx.fill(circle(p, 3.2 * CGFloat(fade) + 0.4), with: .color(sparkCore.opacity(fade)))
        }
    }

    /// A ball of light swoops down into Lanvi's tail, leaving a short trail.
    private static func flight(_ ctx: GraphicsContext, from a: CGPoint, to b: CGPoint, k: Double, time t: Double) {
        let control = CGPoint(x: a.x + (b.x - a.x) * 0.1, y: b.y - 30)
        func at(_ u: Double) -> CGPoint {
            let u = CGFloat(min(1, max(0, u)))
            let e = u * u * (3 - 2 * u)
            let m = 1 - e
            return CGPoint(x: m * m * a.x + 2 * m * e * control.x + e * e * b.x,
                           y: m * m * a.y + 2 * m * e * control.y + e * e * b.y)
        }
        for i in stride(from: 6, through: 1, by: -1) {
            let p = at(k - Double(i) * 0.035)
            ctx.fill(circle(p, 7 - CGFloat(i) * 0.8), with: .color(sparkGold.opacity(0.5 - Double(i) * 0.07)))
        }
        let head = at(k)
        ctx.fill(circle(head, 18), with: .radialGradient(
            Gradient(colors: [sparkGold.opacity(0.9), sparkWarm.opacity(0)]),
            center: head, startRadius: 0, endRadius: 18))
        ctx.fill(circle(head, 5), with: .color(.white))
    }

    /// The snowflake softens, shrinks and becomes a drop that slides away. No colour change, no fuss.
    private static func melt(_ ctx: GraphicsContext, at c: CGPoint, k: Double, angle: Double) {
        let shrink = CGFloat(1 - k * 0.8)
        snowflake(ctx, at: CGPoint(x: c.x, y: c.y + CGFloat(k) * 6), arm: 15 * shrink,
                  alpha: max(0, 1 - k * 1.4), angle: angle, squash: 1 - CGFloat(k) * 0.4)
        if k > 0.25 {
            let d = (k - 0.25) / 0.75
            let p = CGPoint(x: c.x, y: c.y + 6 + CGFloat(d) * 18)
            var drop = Path()
            drop.move(to: CGPoint(x: p.x, y: p.y - 7))
            drop.addQuadCurve(to: CGPoint(x: p.x, y: p.y + 4), control: CGPoint(x: p.x + 7, y: p.y + 2))
            drop.addQuadCurve(to: CGPoint(x: p.x, y: p.y - 7), control: CGPoint(x: p.x - 7, y: p.y + 2))
            ctx.fill(drop, with: .color(Theme.aurora.opacity(0.8 * (1 - d))))
        }
    }

    // MARK: Shapes

    static func circle(_ c: CGPoint, _ r: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
    }

    static func star(_ c: CGPoint, outer: CGFloat, inner: CGFloat, rotation: Double) -> Path {
        var p = Path()
        for i in 0..<8 {
            let r = i.isMultiple(of: 2) ? outer : inner
            let a = rotation + Double(i) * .pi / 4
            let pt = CGPoint(x: c.x + CGFloat(cos(a)) * r, y: c.y + CGFloat(sin(a)) * r)
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        p.closeSubpath()
        return p
    }
}

/// The live play field: draws the engine's drops and effects every frame.
struct FocusSky: View {
    let engine: FocusEngine
    let field: CGRect
    let tail: CGPoint

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { ctx, _ in
                let now = timeline.date
                engine.field = field
                engine.step(now: now)
                let t = engine.clock(now)
                let wall = now.timeIntervalSinceReferenceDate
                for d in engine.drops {
                    let p = engine.position(of: d, at: t)
                    let a = engine.opacity(of: d, at: t)
                    switch d.kind {
                    case .spark: FocusArt.spark(ctx, at: p, alpha: a, time: wall, seed: d.phase)
                    case .snow: FocusArt.snowflake(ctx, at: p, alpha: a, angle: d.phase + (t - d.born) * 0.6)
                    }
                }
                for e in engine.effects {
                    FocusArt.draw(e, ctx, at: t, tail: tail)
                }
            }
        }
    }
}

/// Decoration for the intro and the finish: a few sparks and flakes drifting on a loop.
/// `rising` sends sparks up from the bottom, like fox fires leaving Lanvi's tail.
struct FocusDecor: View {
    var rising = false

    private let lanes: [(x: CGFloat, period: Double, offset: Double, spark: Bool)] = [
        (0.12, 7.5, 0.0, true), (0.30, 9.0, 3.1, false), (0.52, 8.0, 5.4, true),
        (0.70, 10.0, 1.7, false), (0.88, 7.0, 4.2, true), (0.40, 11.0, 7.9, true),
        (0.20, 9.5, 6.3, false), (0.80, 8.5, 2.6, true),
    ]

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { ctx, size in
                let t = timeline.date.timeIntervalSinceReferenceDate
                for (i, lane) in lanes.enumerated() where !rising || lane.spark {
                    let p = CGFloat((t + lane.offset).truncatingRemainder(dividingBy: lane.period) / lane.period)
                    let travel = rising ? 1 - p : p
                    let y = -20 + travel * (size.height + 20)
                    let x = lane.x * size.width + 14 * CGFloat(sin(t * 1.3 + Double(i)))
                    let a = Double(min(1, min(p / 0.15, (1 - p) / 0.2)))
                    if lane.spark {
                        FocusArt.spark(ctx, at: CGPoint(x: x, y: y), scale: 0.8, alpha: a * 0.9, time: t, seed: Double(i))
                    } else {
                        FocusArt.snowflake(ctx, at: CGPoint(x: x, y: y), arm: 12, alpha: a * 0.8, angle: t * 0.5 + Double(i))
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// A small round icon with a live spark or snowflake, for the intro's "how to play" cards.
struct FocusArtIcon: View {
    var spark: Bool

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { ctx, size in
                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                let t = timeline.date.timeIntervalSinceReferenceDate
                if spark {
                    FocusArt.spark(ctx, at: c, scale: 0.85, alpha: 1, time: t, seed: 0)
                } else {
                    FocusArt.snowflake(ctx, at: c, arm: 14, alpha: 1, angle: t * 0.5)
                }
            }
        }
        .frame(width: 52, height: 52)
        .background(
            Circle().fill(LinearGradient(colors: [Theme.nightTop, Theme.nightBottom],
                                         startPoint: .top, endPoint: .bottom)))
        .overlay(Circle().stroke(.white.opacity(0.25), lineWidth: 1.5).padding(1))
    }
}
