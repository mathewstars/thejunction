import SwiftUI

private let mint = Color(hex: 0x9DF5D4)

/// The light Lanvi breathes with: a soft aurora bloom floating in the sky above the fox, drawn as layered
/// radial gradients that add up like real light (mint and cyan melting into violet, no
/// hard edge, no rings: one smooth falloff), and a handful of tiny motes.
///
/// `breath` 0 is all the way out, 1 all the way in. The motes drift in toward the fox and
/// brighten as the breath comes in, and drift out and fade as it goes. `flare` (0 to 1)
/// opens the motes into a wide, slow halo for the finish.
/// Both values are animatable, so every frame is drawn from the eased in-between value.
struct BreathBloom: View, Animatable {
    var breath: CGFloat
    var flare: CGFloat = 0

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(breath, flare) }
        set { breath = newValue.first; flare = newValue.second }
    }

    /// Angle, distance factor, size and twinkle speed of each mote.
    private static let motes: [(a: Double, d: CGFloat, s: CGFloat, k: Double)] = (0..<18).map { i in
        let golden = 2.39996323
        return (a: Double(i) * golden,
                d: 0.82 + 0.36 * CGFloat((i * 7) % 11) / 10,
                s: 1.6 + CGFloat((i * 5) % 7) * 0.45,
                k: 0.7 + Double((i * 3) % 5) * 0.22)
    }

    /// A bell-shaped fade (a Gaussian, nudged to reach exactly zero at the edge), sampled
    /// finely enough that the straight pieces between stops never show as rings.
    private static let falloff: [(CGFloat, CGFloat)] = (0...24).map { i in
        let x = Double(i) / 24
        let floor = exp(-4.0)
        return (CGFloat(x), CGFloat((exp(-4 * x * x) - floor) / (1 - floor)))
    }

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            // 16-bit colour, so the dim outer edge of each glow fades without 8-bit steps.
            Canvas(colorMode: .extendedLinear) { gc, size in
                draw(in: &gc, size: size, t: t)
            }
        }
        .blendMode(.plusLighter)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func draw(in gc: inout GraphicsContext, size: CGSize, t: Double) {
        let b = min(max(breath, 0), 1.2)
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        // Nominal bloom radius. The canvas is 2.3 units from centre to top and bottom, more
        // than the biggest glow and the furthest mote; sideways it is only as wide as the
        // screen, so the light simply runs off the screen edges.
        let unit = size.height / 4.6
        let swell = 0.78 + 0.34 * b
        gc.blendMode = .plusLighter

        // Every glow fades along one smooth bell curve, so there is no knee or band
        // anywhere: just light that thins out until it is gone.
        func glow(_ color: Color, at p: CGPoint, radius r: CGFloat, alpha: CGFloat) {
            let gradient = Gradient(stops: Self.falloff.map {
                .init(color: color.opacity(Double(alpha * $0.1)), location: $0.0)
            })
            let rect = CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)
            gc.fill(Path(ellipseIn: rect),
                    with: .radialGradient(gradient, center: p, startRadius: 0, endRadius: r))
        }

        // Slow wander so the bloom feels alive even while holding.
        let wx = CGFloat(sin(t * 0.37)) * unit * 0.05
        let wy = CGFloat(cos(t * 0.29)) * unit * 0.04

        // Wide violet base.
        glow(Theme.auroraViolet, at: CGPoint(x: c.x - wx, y: c.y + unit * 0.06),
             radius: unit * 1.6 * swell, alpha: 0.26 + 0.28 * b)
        // Cyan lobe up and to the left.
        glow(Theme.aurora, at: CGPoint(x: c.x - unit * 0.2 + wx, y: c.y - unit * 0.1 + wy),
             radius: unit * 1.35 * swell, alpha: 0.18 + 0.30 * b)
        // Mint lobe down and to the right.
        glow(mint, at: CGPoint(x: c.x + unit * 0.24 - wx, y: c.y + unit * 0.1 - wy),
             radius: unit * 1.2 * swell, alpha: 0.14 + 0.24 * b)
        // Soft light right behind the fox.
        glow(.white, at: CGPoint(x: c.x, y: c.y - unit * 0.05),
             radius: unit * 0.95 * swell, alpha: 0.05 + 0.10 * b)

        // Motes of light.
        for (i, m) in Self.motes.enumerated() {
            let angle = m.a + t * 0.045 * (i.isMultiple(of: 2) ? 1 : -1)
            let drift = CGFloat(sin(t * m.k + Double(i))) * 0.04
            let dist = unit * (m.d * (1.55 - 0.62 * b) + drift + 0.3 * flare)
            let p = CGPoint(x: c.x + CGFloat(cos(angle)) * dist,
                            y: c.y + CGFloat(sin(angle)) * dist * 0.92)
            let twinkle = 0.65 + 0.35 * CGFloat(sin(t * m.k * 2.1 + Double(i) * 1.7))
            let alpha = (0.12 + 0.88 * min(b, 1)) * twinkle * (1 - 0.35 * flare)
            let tint = i % 3 == 0 ? mint : (i % 3 == 1 ? Theme.aurora : .white)
            glow(tint, at: p, radius: m.s * 4.5, alpha: alpha * 0.55)
            glow(.white, at: p, radius: m.s * 1.6, alpha: alpha)
        }
    }
}

/// Breaths left, as small dots on the snow. Done dots are full and glossy; the current one
/// glows softly and fills up as the breath goes round; the rest wait, sunk into the snow.
struct BreathDots: View {
    var total: Int
    var done: Int
    /// 0 to 1 through the current breath (in, hold and out).
    var progress: CGFloat
    var breath: CGFloat

    var body: some View {
        HStack(spacing: 14) {
            ForEach(0..<total, id: \.self) { i in
                dot(i)
                    .frame(width: 16, height: 16)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("\(max(0, total - done)) breaths left")
    }

    /// Every dot has the same layers, so moving to the next breath never swaps views and
    /// the fill only ever animates from the value it already shows.
    private func dot(_ i: Int) -> some View {
        let current = i == done
        let fill: CGFloat = i < done ? 1 : (current ? progress : 0)
        return ZStack {
            // A small well in the snow.
            Circle().fill(LinearGradient(colors: [Color(hex: 0xC9D5F2), Theme.tint], startPoint: .top, endPoint: .bottom))
            // Pie fill: a stroke as wide as the radius, trimmed to the progress.
            Circle()
                .trim(from: 0, to: fill)
                .stroke(LinearGradient(colors: [Color(hex: 0x6F8FF0), Theme.brand], startPoint: .top, endPoint: .bottom),
                        lineWidth: 8)
                .rotationEffect(.degrees(-90))
                .frame(width: 8, height: 8)
            // Gloss once full.
            Capsule().fill(.white.opacity(i < done ? 0.5 : 0)).frame(width: 6, height: 2.5).offset(y: -4)
            Circle().stroke(Theme.brand.opacity(current ? 0.45 : 0), lineWidth: 1.5)
        }
        .shadow(color: current ? Theme.glow.opacity(0.35 + 0.55 * breath) : .clear,
                radius: current ? 3 + 5 * breath : 0)
        .scaleEffect(current ? 1.15 : 1)
        .animation(.spring(response: 0.45, dampingFraction: 0.6), value: done)
    }
}
