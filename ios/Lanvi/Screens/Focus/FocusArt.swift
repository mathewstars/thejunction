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

    /// A crisp, cool, matte crystal. `squash` flattens it as it tumbles, so it turns in 3D.
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
            let tip = pt(c, a, L * 0.84)
            p.move(to: tip); p.addLine(to: pt(tip, a + .pi / 4, L * 0.16))
            p.move(to: tip); p.addLine(to: pt(tip, a - .pi / 4, L * 0.16))
        }
        // A cool soft shadow so it reads on any sky, then the crystal, then a frosty centre.
        ctx.fill(circle(c, L * 1.25), with: .radialGradient(
            Gradient(colors: [Theme.nightTop.opacity(0.22 * alpha), Theme.nightTop.opacity(0)]),
            center: c, startRadius: 0, endRadius: L * 1.25))
        ctx.stroke(p, with: .color(Theme.nightTop.opacity(0.32 * alpha)),
                   style: StrokeStyle(lineWidth: 4.4, lineCap: .round, lineJoin: .round))
        ctx.stroke(p, with: .linearGradient(Gradient(colors: [.white.opacity(alpha), snow.opacity(alpha), Color(hex: 0xCFE0FF).opacity(alpha)]),
                                            startPoint: CGPoint(x: c.x - L, y: c.y - L), endPoint: CGPoint(x: c.x + L, y: c.y + L)),
                   style: StrokeStyle(lineWidth: 2.3, lineCap: .round, lineJoin: .round))
        ctx.fill(circle(c, 2.8), with: .color(.white.opacity(alpha)))
    }

    // MARK: Effects

    /// Draws one layer of a tap effect. Melting snow and touch ripples live on the snow canvas and ignore `layer`.
    /// `landing` says where on the aurora a rising light is headed right now.
    static func draw(_ e: FocusEffect, _ ctx: GraphicsContext, _ layer: Layer, at t: TimeInterval,
                     landing: (CGFloat) -> CGPoint) {
        let k = min(1, max(0, (t - e.t0) / e.life))
        switch e.kind {
        case .burst: burst(ctx, layer, at: e.at, k: k, life: e.life, seed: e.angle)
        case .flight: rise(ctx, layer, from: e.at, to: landing(e.u), k: k, seed: e.angle)
        case .melt: melt(ctx, at: e.at, k: k, angle: e.angle)
        case .touch: touch(ctx, at: e.at, k: k)
        }
    }

    /// Caught: the core flashes white, a thin ring of light opens, and motes scatter and fall
    /// with a little gravity. Crisp and over in half a second.
    private static func burst(_ ctx: GraphicsContext, _ layer: Layer, at c: CGPoint, k: Double, life: Double, seed: Double) {
        let edge = tint(seed)
        let fade = 1 - k
        let out = CGFloat(1 - pow(1 - k, 4))
        let tau = k * life

        func mote(_ i: Int) -> (CGPoint, CGFloat) {
            let jitter = fract(sin(Double(i) * 12.9898 + seed) * 43758.5453)
            let a = seed + Double(i) * 2 * .pi / 9 + jitter * 0.5
            let speed = 150 + 90 * jitter
            // Fast at first, then slowed by the air, then pulled down a little.
            let travel = speed * (1 - exp(-tau * 5)) / 5
            let p = CGPoint(x: c.x + CGFloat(cos(a) * travel),
                            y: c.y + CGFloat(sin(a) * travel + 0.5 * 420 * tau * tau))
            return (p, 1.8 * CGFloat(fade) + 0.4)
        }

        switch layer {
        case .warm:
            let f3 = fade * fade * fade
            let body = 14 * (1 + 0.6 * out)
            ctx.fill(circle(c, body), with: .radialGradient(
                Gradient(colors: [gold.opacity(0.85 * f3), ember.opacity(0.3 * f3), ember.opacity(0)]),
                center: c, startRadius: 0, endRadius: body))
            for i in 0..<9 {
                let (p, r) = mote(i)
                ctx.fill(circle(p, r), with: .color(gold.opacity(0.9 * fade)))
            }

        case .light:
            // The flash peaks almost at once (crisp), then falls away.
            let pop = min(1, k / 0.12)
            let flash = 8 + 26 * CGFloat(pop)
            let f3 = fade * fade * fade
            ctx.fill(circle(c, flash), with: .radialGradient(
                Gradient(stops: [
                    .init(color: core.opacity(f3), location: 0),
                    .init(color: core.opacity(0.6 * f3), location: 0.2),
                    .init(color: edge.opacity(0.4 * f3), location: 0.5),
                    .init(color: edge.opacity(0), location: 1),
                ]),
                center: c, startRadius: 0, endRadius: flash))
            let ring = circle(c, 10 + 40 * out)
            let ringFade = fade * fade
            ctx.stroke(ring, with: .color(edge.opacity(0.28 * ringFade)), lineWidth: 6 * CGFloat(fade) + 0.5)
            ctx.stroke(ring, with: .color(core.opacity(0.6 * ringFade)), lineWidth: 1 * CGFloat(fade) + 0.2)
            for i in 0..<9 {
                let (p, r) = mote(i)
                ctx.fill(circle(p, r * 4.5), with: .radialGradient(
                    Gradient(colors: [(i.isMultiple(of: 2) ? core : edge).opacity(0.6 * fade), edge.opacity(0)]),
                    center: p, startRadius: 0, endRadius: r * 4.5))
            }
        }
    }

    /// The caught light rises into the sky as a ribbon with a tapering glowing tail and
    /// becomes part of the aurora: it leaves warm and gold and arrives as aurora colour.
    /// It first curls out a little to the side, then sweeps up; the head slows as it arrives.
    private static func rise(_ ctx: GraphicsContext, _ layer: Layer, from a: CGPoint, to b: CGPoint, k: Double, seed: Double) {
        let edge = GameAurora.mint
        let side: CGFloat = sin(seed * 3.1) > 0 ? 1 : -1
        let c1 = CGPoint(x: a.x + side * 64, y: a.y - 26)
        let c2 = CGPoint(x: b.x - side * 30, y: b.y + 150)
        func at(_ u: Double) -> CGPoint {
            let x = CGFloat(min(1, max(0, u)))
            let m = 1 - x
            return CGPoint(
                x: m * m * m * a.x + 3 * m * m * x * c1.x + 3 * m * x * x * c2.x + x * x * x * b.x,
                y: m * m * m * a.y + 3 * m * m * x * c1.y + 3 * m * x * x * c2.y + x * x * x * b.y)
        }
        // Quick lift-off, gentle arrival.
        let head = 1 - pow(1 - min(1, k * 1.08), 2.6)
        let fadeOut = k > 0.82 ? max(0, (1 - k) / 0.18) : 1
        let tailStart = max(0, head - 0.34)
        guard head > 0.001 else { return }
        let warmth = 1 - GameEase.smooth(k / 0.75)

        // Points along the ribbon from its faint end to the head, and a tapered outline around them.
        let n = 20
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
            guard warmth > 0.01 else { return }
            ctx.fill(taper(3.2), with: along(gold, 0.9 * warmth))
            ctx.fill(circle(p, 10), with: .radialGradient(
                Gradient(colors: [gold.opacity(fadeOut * warmth), ember.opacity(0)]),
                center: p, startRadius: 0, endRadius: 10))
        case .light:
            let cool = 1 - warmth
            ctx.fill(taper(10), with: along(edge, 0.22 + 0.25 * cool))
            ctx.fill(taper(1.7), with: along(core, 0.9))
            ctx.fill(circle(p, 20), with: .radialGradient(
                Gradient(stops: [
                    .init(color: core.opacity(fadeOut), location: 0),
                    .init(color: edge.opacity((0.3 + 0.3 * cool) * fadeOut), location: 0.35),
                    .init(color: edge.opacity(0), location: 1),
                ]),
                center: p, startRadius: 0, endRadius: 20))
        }
    }

    /// The snowflake softens, shrinks and becomes a drop that slides away. No colour change, no fuss.
    private static func melt(_ ctx: GraphicsContext, at c: CGPoint, k: Double, angle: Double) {
        let shrink = CGFloat(1 - GameEase.smooth(k) * 0.8)
        snowflake(ctx, at: CGPoint(x: c.x, y: c.y + CGFloat(GameEase.smooth(k)) * 6), arm: 17 * shrink,
                  alpha: max(0, 1 - k * 1.4), angle: angle, squash: 1 - CGFloat(k) * 0.4)
        if k > 0.25 {
            let d = (k - 0.25) / 0.75
            let fall = CGFloat(d * d) * 22
            let p = CGPoint(x: c.x, y: c.y + 6 + fall)
            var drop = Path()
            drop.move(to: CGPoint(x: p.x, y: p.y - 7))
            drop.addQuadCurve(to: CGPoint(x: p.x, y: p.y + 4), control: CGPoint(x: p.x + 7, y: p.y + 2))
            drop.addQuadCurve(to: CGPoint(x: p.x, y: p.y - 7), control: CGPoint(x: p.x - 7, y: p.y + 2))
            ctx.fill(drop, with: .linearGradient(Gradient(colors: [.white.opacity(0.9 * (1 - d)), Theme.aurora.opacity(0.85 * (1 - d))]),
                                                 startPoint: CGPoint(x: p.x - 4, y: p.y - 7), endPoint: CGPoint(x: p.x + 4, y: p.y + 4)))
        }
    }

    /// A finger touched empty sky: a small soft ripple of frost, so every touch is felt.
    private static func touch(_ ctx: GraphicsContext, at c: CGPoint, k: Double) {
        let out = CGFloat(GameEase.outCubic(k))
        let fade = pow(1 - k, 2)
        ctx.stroke(circle(c, 8 + 18 * out), with: .color(.white.opacity(0.35 * fade)), lineWidth: 2.5 * CGFloat(1 - k) + 0.4)
        ctx.fill(circle(c, 14), with: .radialGradient(Gradient(colors: [.white.opacity(0.18 * fade), .white.opacity(0)]),
                                                      center: c, startRadius: 0, endRadius: 14))
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
struct SparkLayers: View {
    let draw: (GraphicsContext, FocusArt.Layer, CGSize) -> Void

    var body: some View {
        ZStack {
            Canvas { ctx, size in draw(ctx, .warm, size) }
            Canvas { ctx, size in draw(ctx, .light, size) }
                .blendMode(.plusLighter)
        }
    }
}

/// The whole live sky of the game in one `TimelineView`: the aurora the sparks feed, then the
/// snowflakes, then the sparks and their effects. Works before the round (no engine: a faint
/// aurora), during it, and after it (the finished aurora keeps rippling).
struct FocusSky: View {
    let engine: FocusEngine?
    let field: CGRect
    let auroraRect: CGRect

    private static let trailSteps: [Double] = [0.05, 0.1, 0.15, 0.2, 0.25, 0.3]

    var body: some View {
        TimelineView(.animation) { timeline in
            let now = timeline.date
            let wall = now.timeIntervalSinceReferenceDate
            let t = advance(to: now)
            ZStack {
                Canvas { ctx, _ in
                    let finale = engine?.endedAt.map { GameEase.smooth((t - $0) / 2.4) } ?? 0
                    let flares = engine?.flares.map { GameAurora.Flare(u: $0.u, age: t - $0.t0) } ?? []
                    GameAurora.draw(ctx, in: auroraRect, level: engine?.auroraShown ?? 0.1, t: wall,
                                    flares: flares, brightness: 1 + 0.25 * finale)
                }
                .blendMode(.plusLighter)

                if let engine {
                    Canvas { ctx, _ in
                        for d in engine.drops where d.kind == .snow {
                            let age = t - d.born
                            FocusArt.snowflake(ctx, at: engine.position(of: d, at: t), arm: 17,
                                               alpha: engine.opacity(of: d, at: t), angle: d.phase + age * 0.55,
                                               squash: 0.72 + 0.28 * CGFloat(cos(d.phase + age * 1.25)))
                        }
                        for e in engine.effects where e.kind == .melt || e.kind == .touch {
                            FocusArt.draw(e, ctx, .warm, at: t, landing: { engine.landing($0, at: t) })
                        }
                    }
                    SparkLayers { ctx, layer, _ in
                        for d in engine.drops where d.kind == .spark {
                            let age = t - d.born
                            let trail = Self.trailSteps.filter { $0 < age }.map { engine.position(of: d, at: t - $0) }
                            FocusArt.spark(ctx, layer, at: engine.position(of: d, at: t), scale: 1.1,
                                           alpha: engine.opacity(of: d, at: t), time: wall, seed: d.phase,
                                           trail: trail, bloom: age / 0.45)
                        }
                        for e in engine.effects where e.kind == .burst || e.kind == .flight {
                            FocusArt.draw(e, ctx, layer, at: t, landing: { engine.landing($0, at: t) })
                        }
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }

    /// Moves the round along to `now` (new drops, fallen drops, light landing) and returns the round time.
    private func advance(to now: Date) -> TimeInterval {
        guard let engine else { return 0 }
        engine.field = field
        engine.auroraRect = auroraRect
        engine.step(now: now)
        return engine.clock(now)
    }
}

/// A live spark or snowflake on its own, floating gently, for the intro's "how to play"
/// and the finish line. No box around it: it sits right on the sky.
struct FocusArtPreview: View {
    var spark: Bool
    var size: CGFloat = 72

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let bob = CGFloat(sin(t * 1.6 + (spark ? 0 : 1.3))) * 4
            if spark {
                SparkLayers { ctx, layer, s in
                    FocusArt.spark(ctx, layer, at: CGPoint(x: s.width / 2, y: s.height / 2 + bob),
                                   scale: size / 72, alpha: 1, time: t, seed: 0.4)
                }
            } else {
                Canvas { ctx, s in
                    FocusArt.snowflake(ctx, at: CGPoint(x: s.width / 2, y: s.height / 2 + bob), arm: 15 * size / 72,
                                       alpha: 1, angle: t * 0.4, squash: 0.8 + 0.2 * CGFloat(cos(t * 1.1)))
                }
            }
        }
        .frame(width: size, height: size)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
