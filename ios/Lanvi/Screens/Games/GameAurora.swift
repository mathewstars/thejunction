import SwiftUI

/// The northern lights over Lanvi's world: the "fox fires" of the Finnish legend.
///
/// Drawn like real aurora curtains: each band has a bright, sharp lower edge and soft
/// vertical rays that rise from it and fade into the sky, with a slow wave along the band
/// and shimmer running through the rays. All light is added onto the sky (`plusLighter`),
/// so it glows instead of sitting on top like paint.
///
/// `level` 0 is a faint hint, 1 is a full, bright sky with three bands. A `Flare` is a
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
        var y0: CGFloat, y1: CGFloat          // lower edge at the left and right, share of the rect height
        var amp: CGFloat, freq: Double, speed: Double, phase: Double
        var height: CGFloat                   // ray length, share of the rect height
        var low: Color, high: Color
        var strength: Double
        var appear: Double                    // the level at which this band starts to show
    }

    private static let bands: [Band] = [
        Band(y0: 0.80, y1: 0.50, amp: 0.075, freq: 1.15, speed: 0.045, phase: 0.0,
             height: 0.62, low: mint, high: cyan, strength: 1.0, appear: 0),
        Band(y0: 0.46, y1: 0.24, amp: 0.06, freq: 1.5, speed: -0.035, phase: 1.9,
             height: 0.48, low: cyan, high: violet, strength: 0.8, appear: 0.22),
        Band(y0: 0.98, y1: 0.86, amp: 0.05, freq: 0.9, speed: 0.03, phase: 3.4,
             height: 0.42, low: violet, high: pink, strength: 0.62, appear: 0.55),
    ]

    /// The bright lower edge of the main band at `u` (0 left, 1 right), at time `t`.
    /// Sparks aim for this when they rise into the sky.
    static func edge(u: CGFloat, in rect: CGRect, t: Double) -> CGPoint {
        point(bands[0], u: u, in: rect, t: t)
    }

    private static func point(_ b: Band, u: CGFloat, in rect: CGRect, t: Double) -> CGPoint {
        let a = Double(u) * b.freq * 2 * .pi
        let wave = sin(a + t * b.speed * 2 * .pi + b.phase)
            + 0.4 * sin(a * 2.3 - t * b.speed * 3.1 * 2 * .pi + b.phase * 1.7)
        let y = b.y0 + (b.y1 - b.y0) * u + b.amp * CGFloat(wave)
        return CGPoint(x: rect.minX + u * rect.width, y: rect.minY + y * rect.height)
    }

    /// Draws the aurora into `ctx` (the canvas itself should be blended with `.plusLighter`).
    static func draw(_ ctx: GraphicsContext, in rect: CGRect, level: Double, t: Double,
                     flares: [Flare] = [], brightness: Double = 1) {
        let lvl = GameEase.clamp(level)
        var layer = ctx
        layer.addFilter(.blur(radius: 2.2))
        layer.drawLayer { g in
            for (bi, b) in bands.enumerated() {
                let show = bi == 0 ? 1 : GameEase.step(b.appear, b.appear + 0.3, lvl)
                let base = (0.10 + 0.62 * lvl) * b.strength * show * brightness
                guard base > 0.006 else { continue }
                drawBand(g, b, index: bi, rect: rect, base: base, level: lvl, t: t,
                         flares: bi == 0 ? flares : flares.map { Flare(u: $0.u, age: $0.age + 0.25) })
            }
        }
    }

    private static func drawBand(_ g: GraphicsContext, _ b: Band, index bi: Int, rect: CGRect, base: Double,
                                 level: Double, t: Double, flares: [Flare]) {
        let n = 46
        let full = rect.height * b.height * CGFloat(0.55 + 0.6 * level)

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
            let wobble = 0.72 + 0.28 * sin(u * 23 + t * 0.55 + b.phase) * sin(u * 7.3 - t * 0.31)
            return full * CGFloat(wobble * (1 + 0.45 * min(boost, 1.4)))
        }

        // A wide soft glow under the band, so it lights the sky around it.
        var edgePath = Path()
        for i in 0...24 {
            let p = point(b, u: -0.05 + 1.1 * CGFloat(i) / 24, in: rect, t: t)
            if i == 0 { edgePath.move(to: p) } else { edgePath.addLine(to: p) }
        }
        var haze = g
        haze.addFilter(.blur(radius: 26))
        haze.stroke(edgePath.applying(CGAffineTransform(translationX: 0, y: -full * 0.25)), with: .color(b.low.opacity(0.22 * base)),
                    style: StrokeStyle(lineWidth: full * 0.7, lineCap: .round))

        // The curtain: thin slices, each a ray that is bright at the bottom edge and fades up.
        for i in 0..<n {
            let u0 = -0.04 + 1.08 * Double(i) / Double(n)
            let u1 = -0.04 + 1.08 * Double(i + 1) / Double(n)
            let um = (u0 + u1) / 2
            let p0 = point(b, u: CGFloat(u0), in: rect, t: t)
            let p1 = point(b, u: CGFloat(u1), in: rect, t: t)
            let boost = gain(um)
            let ray = 0.55 + 0.45 * sin(um * 37 + t * 0.8 + 2.2 * sin(um * 11 - t * 0.43 + b.phase))
            let a = min(1, base * ray * (1 + boost))
            guard a > 0.004 else { continue }
            let h0 = rayLength(u0, gain(u0)), h1 = rayLength(u1, gain(u1))
            let drop: CGFloat = 7
            var slice = Path()
            slice.move(to: CGPoint(x: p0.x, y: p0.y + drop))
            slice.addLine(to: CGPoint(x: p1.x + 0.6, y: p1.y + drop))
            slice.addLine(to: CGPoint(x: p1.x + 0.6, y: p1.y - h1))
            slice.addLine(to: CGPoint(x: p0.x, y: p0.y - h0))
            slice.closeSubpath()
            let bottom = CGPoint(x: (p0.x + p1.x) / 2, y: (p0.y + p1.y) / 2 + drop)
            let top = CGPoint(x: bottom.x, y: bottom.y - (h0 + h1) / 2 - drop)
            let hot = min(1, boost * 0.5)
            g.fill(slice, with: .linearGradient(
                Gradient(stops: [
                    .init(color: b.low.opacity(0), location: 0),
                    .init(color: Color.white.opacity(a * (0.35 + 0.5 * hot)), location: 0.045),
                    .init(color: b.low.opacity(a * 0.95), location: 0.1),
                    .init(color: b.low.opacity(a * 0.55), location: 0.32),
                    .init(color: b.high.opacity(a * 0.28), location: 0.62),
                    .init(color: b.high.opacity(0), location: 1),
                ]),
                startPoint: bottom, endPoint: top))
        }

        // Where new light just landed: a soft bloom on the edge.
        guard bi == 0 else { return }
        for f in flares where f.age < 0.9 {
            let k = f.age / 0.9
            let p = point(b, u: f.u, in: rect, t: t)
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
                GameAurora.draw(ctx, in: CGRect(origin: .zero, size: size), level: level, t: t, brightness: brightness)
            }
        }
        .blendMode(.plusLighter)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
