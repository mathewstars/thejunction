import SwiftUI

/// The northern lights over Lanvi's world: the "fox fires" of the Finnish legend.
///
/// Drawn like real aurora curtains: each band has a bright, sharp lower edge and soft
/// vertical rays that rise from it and fade into the sky, with a slow wave along the band
/// and shimmer running through the rays. All light is added onto the sky (`plusLighter`),
/// so it glows instead of sitting on top like paint.
///
/// `level` 0 is a faint hint, 1 is a full, bright sky with three bands. Draw it over the
/// whole screen: it lines up with the painting (`WorldFrame`). A `Flare` is a
/// spot where new light just arrived: the curtain brightens and lengthens there and the
/// brightness spreads along the band, then settles.
enum GameAurora {
    struct Flare {
        /// Across the band, 0 (left) to 1 (right).
        var u: CGFloat
        /// Seconds since it landed.
        var age: Double
        static let life: Double = 1.8
    }

    static let mint = Color(hex: 0x74FFC8)
    static let cyan = Color(hex: 0x7CD8FF)
    static let violet = Color(hex: 0xA98DFF)
    static let pink = Color(hex: 0xF79BDA)

    private struct Band {
        // Along the band, u runs 0 to 1 across the painting from `fx0` to `fx1` (shares of its width).
        var fx0: CGFloat, fx1: CGFloat
        // Lower edge, as a share of the painting's height: y0 at the left, curving down by `rise`.
        var y0: CGFloat, rise: CGFloat
        var amp: CGFloat, freq: Double, speed: Double, phase: Double
        var height: CGFloat                   // ray length, share of the painting's height
        var low: Color, high: Color
        var strength: Double
        var appear: Double                    // the level at which this band starts to show
        var fadeEnds: Bool
    }

    // The main band lies right on the aurora painted in the night scene (top left, sweeping
    // down to the right), so the painting itself seems to brighten and come alive. A violet
    // fringe and a second arc high on the right join it as the sky fills.
    private static let bands: [Band] = [
        Band(fx0: -0.06, fx1: 1.06, y0: 0.132, rise: 0.205, amp: 0.009, freq: 1.2, speed: 0.04, phase: 0,
             height: 0.13, low: mint, high: cyan, strength: 1.0, appear: 0, fadeEnds: false),
        Band(fx0: -0.06, fx1: 1.06, y0: 0.168, rise: 0.205, amp: 0.011, freq: 1.5, speed: -0.03, phase: 1.9,
             height: 0.05, low: violet, high: pink, strength: 0.75, appear: 0.18, fadeEnds: false),
        Band(fx0: 0.28, fx1: 1.08, y0: 0.052, rise: 0.05, amp: 0.008, freq: 1.0, speed: 0.03, phase: 3.4,
             height: 0.07, low: cyan, high: violet, strength: 0.7, appear: 0.5, fadeEnds: true),
    ]

    /// The bright lower edge of the main band at `u` (0 left, 1 right), at time `t`, on a
    /// full screen of `screen` size. Sparks aim for this when they rise into the sky.
    static func edge(u: CGFloat, screen: CGSize, t: Double) -> CGPoint {
        point(bands[0], u: u, world: WorldFrame(screen: screen), t: t)
    }

    private static func point(_ b: Band, u: CGFloat, world: WorldFrame, t: Double) -> CGPoint {
        let a = Double(u) * b.freq * 2 * .pi
        let wave = sin(a + t * b.speed * 2 * .pi + b.phase)
            + 0.4 * sin(a * 2.3 - t * b.speed * 3.1 * 2 * .pi + b.phase * 1.7)
        let fy = b.y0 + b.rise * (1 - (1 - u) * (1 - u)) + b.amp * CGFloat(wave)
        return world.point(b.fx0 + (b.fx1 - b.fx0) * u, fy)
    }

    /// Draws the aurora over a full screen of `screen` size (the canvas should be blended with `.plusLighter`).
    static func draw(_ ctx: GraphicsContext, screen: CGSize, level: Double, t: Double,
                     flares: [Flare] = [], brightness: Double = 1) {
        let lvl = GameEase.clamp(level)
        let world = WorldFrame(screen: screen)
        var layer = ctx
        layer.addFilter(.blur(radius: 1.4))
        layer.drawLayer { g in
            for (bi, b) in bands.enumerated() {
                let show = bi == 0 ? 1 : GameEase.step(b.appear, b.appear + 0.3, lvl)
                let base = (0.05 + 0.6 * lvl) * b.strength * show * brightness
                guard base > 0.006 else { continue }
                drawBand(g, b, index: bi, world: world, base: base, level: lvl, t: t,
                         flares: bi == 0 ? flares : flares.map { Flare(u: $0.u, age: $0.age + 0.25) })
            }
        }
    }

    private static func drawBand(_ g: GraphicsContext, _ b: Band, index bi: Int, world: WorldFrame, base: Double,
                                 level: Double, t: Double, flares: [Flare]) {
        let n = 72
        let full = b.height * WorldFrame.imageSize.height * world.scale * CGFloat(0.6 + 0.6 * level)

        // How much a flare adds at `u`: bright where it landed, spreading and fading.
        func gain(_ u: Double) -> Double {
            var sum = 0.0
            for f in flares where f.age < Flare.life {
                let k = f.age / Flare.life
                let rise = GameEase.outCubic(f.age / 0.18)
                let width = 0.035 + 0.24 * GameEase.outCubic(k)
                let d = (u - Double(f.u)) / width
                sum += 1.5 * rise * pow(1 - k, 2) * exp(-d * d)
            }
            return sum
        }
        func rayLength(_ u: Double, _ boost: Double) -> CGFloat {
            let wobble = 0.74 + 0.26 * sin(u * 19 + t * 0.5 + b.phase) * sin(u * 7.3 - t * 0.29)
            return full * CGFloat(wobble * (1 + 0.5 * min(boost, 1.4)))
        }
        func ends(_ u: Double) -> Double {
            b.fadeEnds ? GameEase.step(0, 0.18, u) * GameEase.step(1, 0.8, u) : 1
        }

        var edgePath = Path()
        for i in 0...36 {
            let p = point(b, u: CGFloat(i) / 36, world: world, t: t)
            if i == 0 { edgePath.move(to: p) } else { edgePath.addLine(to: p) }
        }
        // A wide soft glow around the band, so it lights the sky around it.
        var haze = g
        haze.addFilter(.blur(radius: 24))
        haze.stroke(edgePath.applying(CGAffineTransform(translationX: 0, y: -full * 0.3)),
                    with: .color(b.low.opacity(0.16 * base)),
                    style: StrokeStyle(lineWidth: full * 0.8, lineCap: .round))

        // The curtain: thin slices, each a ray that is bright at the bottom edge and fades up.
        for i in 0..<n {
            let u0 = Double(i) / Double(n)
            let u1 = Double(i + 1) / Double(n)
            let um = (u0 + u1) / 2
            let p0 = point(b, u: CGFloat(u0), world: world, t: t)
            let p1 = point(b, u: CGFloat(u1), world: world, t: t)
            let boost = gain(um)
            let noise = 0.5 * sin(um * 53 + t * 0.9 + b.phase) + 0.3 * sin(um * 97 - t * 1.3)
                + 0.2 * sin(um * 23 + t * 0.4 + b.phase * 2)
            let a = min(1, base * (0.74 + 0.26 * noise) * (1 + boost) * ends(um))
            guard a > 0.004 else { continue }
            let h0 = rayLength(u0, gain(u0)), h1 = rayLength(u1, gain(u1))
            let drop: CGFloat = 5
            var slice = Path()
            slice.move(to: CGPoint(x: p0.x, y: p0.y + drop))
            slice.addLine(to: CGPoint(x: p1.x + 0.5, y: p1.y + drop))
            slice.addLine(to: CGPoint(x: p1.x + 0.5, y: p1.y - h1))
            slice.addLine(to: CGPoint(x: p0.x, y: p0.y - h0))
            slice.closeSubpath()
            let bottom = CGPoint(x: (p0.x + p1.x) / 2, y: (p0.y + p1.y) / 2 + drop)
            let top = CGPoint(x: bottom.x, y: bottom.y - (h0 + h1) / 2 - drop)
            g.fill(slice, with: .linearGradient(
                Gradient(stops: [
                    .init(color: b.low.opacity(0), location: 0),
                    .init(color: b.low.opacity(a), location: 0.06),
                    .init(color: b.low.opacity(a * 0.6), location: 0.3),
                    .init(color: b.high.opacity(a * 0.3), location: 0.62),
                    .init(color: b.high.opacity(0), location: 1),
                ]),
                startPoint: bottom, endPoint: top))
        }

        // The bright lower hem, where real aurora is sharpest.
        g.stroke(edgePath, with: .color(Color.white.opacity(0.18 * base)), lineWidth: 2)

        // Where new light just landed: a soft bloom on the edge.
        guard bi == 0 else { return }
        for f in flares where f.age < 0.9 {
            let k = f.age / 0.9
            let p = point(b, u: f.u, world: world, t: t)
            let r = 18 + 46 * CGFloat(GameEase.outCubic(k))
            let alpha = pow(1 - k, 2) * GameEase.outCubic(f.age / 0.08)
            g.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r * 0.8, width: r * 2, height: r * 1.6)),
                   with: .radialGradient(Gradient(colors: [.white.opacity(0.75 * alpha), b.low.opacity(0.45 * alpha), b.low.opacity(0)]),
                                         center: p, startRadius: 0, endRadius: r))
        }
    }
}

/// The aurora as a view, for screens whose light follows a value (Breathe, the check-in).
/// `level` is animatable, so an eased change draws every in-between frame.
struct GameAuroraView: View, Animatable {
    var level: Double
    var brightness: Double = 1

    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(level, brightness) }
        set { level = newValue.first; brightness = newValue.second }
    }

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                GameAurora.draw(ctx, screen: size, level: level, t: t, brightness: brightness)
            }
        }
        .blendMode(.plusLighter)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
