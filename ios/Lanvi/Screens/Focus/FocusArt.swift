import SwiftUI

/// Drawing for Sparks and snow. Everything is drawn into a few Canvas layers inside one
/// TimelineView, so the sky stays smooth at 60 fps.
///
/// A spark is a small living piece of fox fire, built from layered light:
/// - the `warm` layer (drawn normally) holds its golden ember body, so it stays warm on the blue sky;
/// - the `light` layer (added onto the sky with `plusLighter`) holds the white-hot core, a wide soft
///   bloom tinted with aurora colours, thin shimmering rays and a short trail of motes.
/// A snowflake is the opposite: cool, crisp and matte, so the two never look alike.
enum FocusArt {
    enum Layer { case warm, light }

    static let core = Color(hex: 0xFFFBEA)
    static let gold = Color(hex: 0xFFC94F)
    static let ember = Color(hex: 0xFF9F3D)
    static let snow = Color(hex: 0xEEF4FF)

    /// Aurora edge colours. Each spark picks one from its seed, so the sky feels alive.
    private static let auroraTints: [Color] = [
        Color(hex: 0x6DFFC4),   // mint
        Color(hex: 0x6FD9FF),   // cyan
        Color(hex: 0xB596FF),   // violet
        Color(hex: 0xFF9AD5),   // aurora pink
    ]

    static func tint(_ seed: Double) -> Color {
        auroraTints[Int(abs(seed) * 997) % auroraTints.count]
    }

    // MARK: The spark

    /// Draws one layer of a spark. Call it once for `.warm` (normal blending) and once for `.light`
    /// (a canvas blended with `plusLighter`).
    /// - Parameters:
    ///   - trail: where the spark was a moment ago, newest first; drawn as fading motes.
    ///   - bloom: 0 to 1 while it appears, so it opens out of a point of light.
    static func spark(_ ctx: GraphicsContext, _ layer: Layer, at c: CGPoint, scale: CGFloat = 1, alpha: Double,
                      time t: Double, seed: Double, trail: [CGPoint] = [], bloom: Double = 1) {
        guard alpha > 0.01 else { return }
        let edge = tint(seed)
        let breath = sin(t * 2.3 + seed * 2.7)
        let shimmer = 0.5 * sin(t * 9.7 + seed * 5.1) + 0.5 * sin(t * 15.3 + seed * 1.3)
        let a = alpha * (0.85 + 0.15 * breath)
        let open = easeOutBack(min(1, max(0, bloom)))
        let s = scale * CGFloat(1 + 0.08 * breath) * CGFloat(0.1 + 0.9 * open)

        switch layer {
        case .warm:
            // Golden ember body: deep gold at the heart, glowing amber, melting away.
            let body = 17 * s
            ctx.fill(circle(c, body), with: .radialGradient(
                Gradient(stops: [
                    .init(color: gold.opacity(0.95 * a), location: 0),
                    .init(color: gold.opacity(0.75 * a), location: 0.25),
                    .init(color: ember.opacity(0.4 * a), location: 0.55),
                    .init(color: ember.opacity(0), location: 1),
                ]),
                center: c, startRadius: 0, endRadius: body))
            // Trail of tiny warm motes, shrinking behind.
            for (i, p) in trail.enumerated() {
                let f = Double(i + 1) / Double(trail.count + 1)
                ctx.fill(circle(p, (2.3 - 1.5 * CGFloat(f)) * scale), with: .color(gold.opacity(0.85 * a * (1 - f))))
            }

        case .light:
            // Wide, very soft bloom in aurora colour.
            let wide = 44 * s
            ctx.fill(circle(c, wide), with: .radialGradient(
                Gradient(stops: [
                    .init(color: edge.opacity(0.34 * a), location: 0),
                    .init(color: edge.opacity(0.16 * a), location: 0.35),
                    .init(color: edge.opacity(0.05 * a), location: 0.7),
                    .init(color: edge.opacity(0), location: 1),
                ]),
                center: c, startRadius: 0, endRadius: wide))
            // Soft aurora glints around the trail motes.
            for (i, p) in trail.enumerated() {
                let f = Double(i + 1) / Double(trail.count + 1)
                let r = 6 * scale * CGFloat(1 - 0.5 * f)
                ctx.fill(circle(p, r), with: .radialGradient(
                    Gradient(colors: [edge.opacity(0.35 * a * (1 - f)), edge.opacity(0)]),
                    center: p, startRadius: 0, endRadius: r))
            }
            // Thin tapered rays: two longer, two short, slowly turning and shimmering.
            let spin = t * 0.25 + seed
            let rays: [(angle: Double, length: CGFloat, width: CGFloat, strength: Double)] = [
                (0, 23 * CGFloat(1 + 0.18 * shimmer), 1.2, 0.75),
                (.pi / 2, 15 * CGFloat(1 - 0.15 * shimmer), 1.0, 0.6),
                (.pi / 4, 8, 0.8, 0.45),
                (3 * .pi / 4, 8, 0.8, 0.45),
            ]
            for ray in rays {
                let len = ray.length * s
                ctx.fill(lens(c, angle: spin + ray.angle, length: len, width: ray.width * s), with: .radialGradient(
                    Gradient(stops: [
                        .init(color: core.opacity(ray.strength * a), location: 0),
                        .init(color: gold.opacity(0.5 * ray.strength * a), location: 0.4),
                        .init(color: edge.opacity(0), location: 1),
                    ]),
                    center: c, startRadius: 0, endRadius: len))
            }
            // White-hot core. Bigger and brighter while it is blooming in from a point of light.
            let flash = 1 + 1.5 * (1 - min(1, max(0, bloom)))
            let coreR = 5 * scale * CGFloat(flash)
            ctx.fill(circle(c, coreR), with: .radialGradient(
                Gradient(stops: [
                    .init(color: core.opacity(a), location: 0),
                    .init(color: core.opacity(0.7 * a), location: 0.35),
                    .init(color: gold.opacity(0), location: 1),
                ]),
                center: c, startRadius: 0, endRadius: coreR))
        }
    }

    // MARK: The snowflake

    static func snowflake(_ ctx: GraphicsContext, at c: CGPoint, arm L: CGFloat = 15, alpha: Double,
                          angle: Double, squash: CGFloat = 1) {
        guard alpha > 0.01 else { return }
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
        ctx.stroke(p, with: .color(Theme.nightTop.opacity(0.3 * alpha)),
                   style: StrokeStyle(lineWidth: 4.6, lineCap: .round))
        ctx.stroke(p, with: .color(snow.opacity(alpha)),
                   style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
        ctx.fill(circle(c, 2.6), with: .color(snow.opacity(alpha)))
    }

    // MARK: Effects

    /// Draws one layer of a tap effect. Melting snow lives on the snow canvas and ignores `layer`.
    static func draw(_ e: FocusEffect, _ ctx: GraphicsContext, _ layer: Layer, at t: TimeInterval, tail: CGPoint) {
        let k = min(1, max(0, (t - e.t0) / e.life))
        switch e.kind {
        case .burst: burst(ctx, layer, at: e.at, k: k, life: e.life, seed: e.angle)
        case .flight: ribbon(ctx, layer, from: e.at, to: tail, k: k, seed: e.angle)
        case .melt: melt(ctx, at: e.at, k: k, angle: e.angle)
        }
    }

    /// Caught: the core flashes, a thin ring of light opens, and motes scatter and fall with a little gravity.
    private static func burst(_ ctx: GraphicsContext, _ layer: Layer, at c: CGPoint, k: Double, life: Double, seed: Double) {
        let edge = tint(seed)
        let fade = 1 - k
        let out = CGFloat(1 - pow(1 - k, 3))
        let tau = k * life

        func mote(_ i: Int) -> (CGPoint, CGFloat) {
            let jitter = fract(sin(Double(i) * 12.9898 + seed) * 43758.5453)
            let a = seed + Double(i) * 2 * .pi / 9 + jitter * 0.5
            let speed = 120 + 80 * jitter
            let p = CGPoint(x: c.x + CGFloat(cos(a) * speed * tau),
                            y: c.y + CGFloat(sin(a) * speed * tau + 0.5 * 560 * tau * tau))
            return (p, 1.7 * CGFloat(fade) + 0.4)
        }

        switch layer {
        case .warm:
            let body = 14 * (1 + 0.5 * out)
            ctx.fill(circle(c, body), with: .radialGradient(
                Gradient(colors: [gold.opacity(0.85 * fade * fade * fade), ember.opacity(0.3 * fade * fade * fade), ember.opacity(0)]),
                center: c, startRadius: 0, endRadius: body))
            for i in 0..<9 {
                let (p, r) = mote(i)
                ctx.fill(circle(p, r), with: .color(gold.opacity(0.9 * fade)))
            }

        case .light:
            let flash = 6 + 22 * CGFloat(min(1, k * 2.5))
            let f3 = fade * fade * fade
            ctx.fill(circle(c, flash), with: .radialGradient(
                Gradient(stops: [
                    .init(color: core.opacity(f3), location: 0),
                    .init(color: edge.opacity(0.4 * f3), location: 0.45),
                    .init(color: edge.opacity(0), location: 1),
                ]),
                center: c, startRadius: 0, endRadius: flash))
            let ring = circle(c, 10 + 34 * out)
            let ringFade = fade * fade
            ctx.stroke(ring, with: .color(edge.opacity(0.25 * ringFade)), lineWidth: 5 * CGFloat(fade) + 0.5)
            ctx.stroke(ring, with: .color(core.opacity(0.55 * ringFade)), lineWidth: 0.8 * CGFloat(fade) + 0.2)
            for i in 0..<9 {
                let (p, r) = mote(i)
                ctx.fill(circle(p, r * 4.5), with: .radialGradient(
                    Gradient(colors: [(i.isMultiple(of: 2) ? core : edge).opacity(0.6 * fade), edge.opacity(0)]),
                    center: p, startRadius: 0, endRadius: r * 4.5))
            }
        }
    }

    /// A ribbon of light with a tapering glowing tail sweeps down into Lanvi's tail.
    /// It first lifts and curls outward a little, then swoops down; the ribbon is one smooth tapered shape.
    private static func ribbon(_ ctx: GraphicsContext, _ layer: Layer, from a: CGPoint, to b: CGPoint, k: Double, seed: Double) {
        let edge = tint(seed)
        let side: CGFloat = a.x < b.x ? -1 : 1
        let c1 = CGPoint(x: a.x + side * 70, y: a.y - 40)
        let c2 = CGPoint(x: b.x + side * 50, y: b.y - 180)
        func at(_ u: Double) -> CGPoint {
            let x = CGFloat(min(1, max(0, u)))
            let e = x * x * (3 - 2 * x)
            let m = 1 - e
            return CGPoint(
                x: m * m * m * a.x + 3 * m * m * e * c1.x + 3 * m * e * e * c2.x + e * e * e * b.x,
                y: m * m * m * a.y + 3 * m * m * e * c1.y + 3 * m * e * e * c2.y + e * e * e * b.y)
        }
        let head = min(1, k * 1.12)
        let fadeOut = k > 0.86 ? (1 - k) / 0.14 : 1
        let tailStart = max(0, head - 0.3)
        guard head > 0.001 else { return }

        // Points along the ribbon from its faint end to the head, and a tapered outline around them.
        let n = 18
        let pts = (0...n).map { at(tailStart + (head - tailStart) * Double($0) / Double(n)) }
        func taper(_ halfWidth: CGFloat) -> Path {
            var left: [CGPoint] = [], right: [CGPoint] = []
            for i in 0...n {
                let p = pts[i]
                let q = pts[min(n, i + 1)], o = pts[max(0, i - 1)]
                var dx = q.x - o.x, dy = q.y - o.y
                let len = max(0.001, hypot(dx, dy)); dx /= len; dy /= len
                let w = halfWidth * CGFloat(i) / CGFloat(n)
                left.append(CGPoint(x: p.x - dy * w, y: p.y + dx * w))
                right.append(CGPoint(x: p.x + dy * w, y: p.y - dx * w))
            }
            var path = Path()
            path.addLines(left)
            path.addLines(right.reversed())
            path.closeSubpath()
            return path
        }
        func along(_ color: Color, _ opacity: Double) -> GraphicsContext.Shading {
            .linearGradient(Gradient(colors: [color.opacity(0), color.opacity(opacity * fadeOut)]),
                            startPoint: pts[0], endPoint: pts[n])
        }
        let p = pts[n]
        switch layer {
        case .warm:
            ctx.fill(taper(3.2), with: along(gold, 0.9))
            ctx.fill(circle(p, 10), with: .radialGradient(
                Gradient(colors: [gold.opacity(fadeOut), ember.opacity(0)]),
                center: p, startRadius: 0, endRadius: 10))
        case .light:
            ctx.fill(taper(9), with: along(edge, 0.35))
            ctx.fill(taper(1.6), with: along(core, 0.9))
            ctx.fill(circle(p, 18), with: .radialGradient(
                Gradient(stops: [
                    .init(color: core.opacity(fadeOut), location: 0),
                    .init(color: edge.opacity(0.35 * fadeOut), location: 0.35),
                    .init(color: edge.opacity(0), location: 1),
                ]),
                center: p, startRadius: 0, endRadius: 18))
        }
    }

    /// The snowflake softens, shrinks and becomes a drop that slides away. No colour change, no fuss.
    private static func melt(_ ctx: GraphicsContext, at c: CGPoint, k: Double, angle: Double) {
        let shrink = CGFloat(1 - k * 0.8)
        snowflake(ctx, at: CGPoint(x: c.x, y: c.y + CGFloat(k) * 6), arm: 17 * shrink,
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

    // MARK: Shapes and helpers

    static func circle(_ c: CGPoint, _ r: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
    }

    /// A thin lens: pointed at both ends, widest in the middle. Used for light rays.
    private static func lens(_ c: CGPoint, angle: Double, length: CGFloat, width: CGFloat) -> Path {
        let d = CGPoint(x: CGFloat(cos(angle)), y: CGFloat(sin(angle)))
        let n = CGPoint(x: -d.y, y: d.x)
        var p = Path()
        p.move(to: CGPoint(x: c.x + d.x * length, y: c.y + d.y * length))
        p.addQuadCurve(to: CGPoint(x: c.x - d.x * length, y: c.y - d.y * length),
                       control: CGPoint(x: c.x + n.x * width * 2, y: c.y + n.y * width * 2))
        p.addQuadCurve(to: CGPoint(x: c.x + d.x * length, y: c.y + d.y * length),
                       control: CGPoint(x: c.x - n.x * width * 2, y: c.y - n.y * width * 2))
        p.closeSubpath()
        return p
    }

    private static func easeOutBack(_ x: Double) -> Double {
        let c1 = 1.70158, c3 = c1 + 1
        return 1 + c3 * pow(x - 1, 3) + c1 * pow(x - 1, 2)
    }

    private static func fract(_ x: Double) -> Double { x - floor(x) }
}

/// Two canvases for the sparks: the warm ember bodies drawn normally, and their light added on top.
private struct SparkLayers: View {
    let draw: (GraphicsContext, FocusArt.Layer, CGSize) -> Void

    var body: some View {
        ZStack {
            Canvas { ctx, size in draw(ctx, .warm, size) }
            Canvas { ctx, size in draw(ctx, .light, size) }
                .blendMode(.plusLighter)
        }
    }
}

/// The live play field: draws the engine's drops and effects every frame.
struct FocusSky: View {
    let engine: FocusEngine
    let field: CGRect
    let tail: CGPoint

    private static let trailSteps: [Double] = [0.05, 0.1, 0.15, 0.2, 0.25, 0.3]

    var body: some View {
        TimelineView(.animation) { timeline in
            let now = timeline.date
            let t = advance(to: now)
            ZStack {
                Canvas { ctx, _ in
                    for d in engine.drops where d.kind == .snow {
                        FocusArt.snowflake(ctx, at: engine.position(of: d, at: t), arm: 17,
                                           alpha: engine.opacity(of: d, at: t), angle: d.phase + (t - d.born) * 0.6)
                    }
                    for e in engine.effects where e.kind == .melt {
                        FocusArt.draw(e, ctx, .warm, at: t, tail: tail)
                    }
                }
                SparkLayers { ctx, layer, _ in
                    let wall = now.timeIntervalSinceReferenceDate
                    for d in engine.drops where d.kind == .spark {
                        let age = t - d.born
                        let trail = Self.trailSteps.filter { $0 < age }.map { engine.position(of: d, at: t - $0) }
                        FocusArt.spark(ctx, layer, at: engine.position(of: d, at: t), scale: 1.1,
                                       alpha: engine.opacity(of: d, at: t), time: wall, seed: d.phase,
                                       trail: trail, bloom: age / 0.45)
                    }
                    for e in engine.effects where e.kind != .melt {
                        FocusArt.draw(e, ctx, layer, at: t, tail: tail)
                    }
                }
            }
        }
    }

    /// Moves the round along to `now` (new drops, fallen drops, finished effects) and returns the round time.
    private func advance(to now: Date) -> TimeInterval {
        engine.field = field
        engine.step(now: now)
        return engine.clock(now)
    }
}

/// Decoration for the intro and the finish: a few sparks and flakes drifting on a loop.
/// `rising` sends sparks up from the bottom, like fox fires leaving Lanvi's tail.
struct FocusDecor: View {
    var rising = false

    private struct Lane {
        let x: CGFloat, period: Double, offset: Double, spark: Bool
    }

    private let lanes: [Lane] = [
        Lane(x: 0.12, period: 7.5, offset: 0.0, spark: true), Lane(x: 0.30, period: 9.0, offset: 3.1, spark: false),
        Lane(x: 0.52, period: 8.0, offset: 5.4, spark: true), Lane(x: 0.70, period: 10.0, offset: 1.7, spark: false),
        Lane(x: 0.88, period: 7.0, offset: 4.2, spark: true), Lane(x: 0.40, period: 11.0, offset: 7.9, spark: true),
        Lane(x: 0.20, period: 9.5, offset: 6.3, spark: false), Lane(x: 0.80, period: 8.5, offset: 2.6, spark: true),
    ]

    /// Where lane `i` is at `time`, and how far along its loop (0 to 1).
    private func spot(_ i: Int, _ time: Double, _ size: CGSize) -> (CGPoint, CGFloat) {
        let lane = lanes[i]
        let p = CGFloat((time + lane.offset).truncatingRemainder(dividingBy: lane.period) / lane.period)
        let travel = rising ? 1 - p : p
        let x = lane.x * size.width + 16 * CGFloat(sin(time * 1.1 + Double(i)))
        return (CGPoint(x: x, y: -30 + travel * (size.height + 30)), p)
    }

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            ZStack {
                if !rising {
                    Canvas { ctx, size in
                        for i in lanes.indices where !lanes[i].spark {
                            let (pos, p) = spot(i, t, size)
                            let a = Double(min(1, min(p / 0.15, (1 - p) / 0.2)))
                            FocusArt.snowflake(ctx, at: pos, arm: 13, alpha: a * 0.85, angle: t * 0.5 + Double(i))
                        }
                    }
                }
                SparkLayers { ctx, layer, size in
                    for i in lanes.indices where lanes[i].spark {
                        let (pos, p) = spot(i, t, size)
                        let a = Double(min(1, min(p / 0.15, (1 - p) / 0.2)))
                        let trail = [0.06, 0.12, 0.18, 0.24].map { spot(i, t - $0, size) }.filter { $0.1 < p }.map(\.0)
                        FocusArt.spark(ctx, layer, at: pos, scale: 0.85, alpha: a, time: t, seed: Double(i) * 1.37,
                                       trail: trail, bloom: Double(p) / 0.06)
                    }
                }
            }
        }
        .clipped()
        .allowsHitTesting(false)
    }
}

/// A small round icon with a live spark or snowflake, for the intro's "how to play" cards.
struct FocusArtIcon: View {
    var spark: Bool

    var body: some View {
        ZStack {
            Circle().fill(LinearGradient(colors: [Theme.nightTop, Theme.nightBottom],
                                         startPoint: .top, endPoint: .bottom))
            TimelineView(.animation) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                if spark {
                    SparkLayers { ctx, layer, size in
                        FocusArt.spark(ctx, layer, at: CGPoint(x: size.width / 2, y: size.height / 2),
                                       scale: 0.85, alpha: 1, time: t, seed: 0.4)
                    }
                } else {
                    Canvas { ctx, size in
                        FocusArt.snowflake(ctx, at: CGPoint(x: size.width / 2, y: size.height / 2),
                                           arm: 14, alpha: 1, angle: t * 0.5)
                    }
                }
            }
        }
        .frame(width: 56, height: 56)
        .compositingGroup()
        .clipShape(Circle())
        .overlay(Circle().stroke(.white.opacity(0.25), lineWidth: 1.5).padding(1))
    }
}
