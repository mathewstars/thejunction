import SwiftUI

/// The northern-lights glow behind Lanvi's tail ("fox fires"). `glow` 0...1
/// from the server sets how big and bright it is; it never goes dark, a low
/// glow is a small warm ember. Drawn in one Canvas: soft layered gradients,
/// additive light and small motes drifting up. `burst` sends a ring of motes
/// out for the XP moment.
///
/// The view is twice the fox's size and centred on the fox, so place it in the
/// same spot as `LanviView` and behind it.
struct HomeTailGlow: View, Animatable {
    var pose: LanviPose
    var glow: Double
    var foxSize: CGFloat
    var burst: Date? = nil

    var animatableData: Double {
        get { glow }
        set { glow = newValue }
    }

    // Saturated enough to read as coloured light on white snow too.
    private static let green = Color(hex: 0x3EE6A8)
    private static let cyan = Color(hex: 0x5CCBFF)
    private static let violet = Color(hex: 0x9B7BFF)
    private static let pink = Color(hex: 0xFF7FD0)

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                draw(&ctx, size: size, t: t, now: context.date)
            }
        }
        .frame(width: foxSize * 2, height: foxSize * 2)
        .allowsHitTesting(false)
    }

    private func draw(_ ctx: inout GraphicsContext, size: CGSize, t: TimeInterval, now: Date) {
        let g = min(max(glow, 0), 1)
        let tail = tailPoint(in: size)
        let reach = foxSize * (0.28 + 0.82 * g)          // how far the light spreads
        let strength = 0.45 + 0.55 * g                     // how bright it is
        let breathe = 1 + 0.06 * sin(t * 2 * .pi / 3.2)

        // 1. Wide soft halo: green into cyan into nothing.
        var halo = ctx
        halo.addFilter(.blur(radius: foxSize * 0.08))
        let r0 = reach * 1.15 * breathe
        halo.fill(Path(ellipseIn: CGRect(x: tail.x - r0, y: tail.y - r0 * 0.85, width: r0 * 2, height: r0 * 1.7)),
                  with: .radialGradient(Gradient(colors: [Self.green.opacity(0.68 * strength),
                                                          Self.cyan.opacity(0.28 * strength),
                                                          .clear]),
                                        center: tail, startRadius: 0, endRadius: r0))

        // 2. Three slow aurora ribbons turning around the tail, added as light.
        var ribbons = ctx
        ribbons.addFilter(.blur(radius: foxSize * 0.05))
        let ribbonColors = [Self.green, Self.violet, Self.pink]
        for (i, color) in ribbonColors.enumerated() {
            let phase = t * (0.22 + 0.07 * Double(i)) + Double(i) * 2.1
            let len = reach * (1.05 - 0.15 * Double(i))
            let w = len * 0.42
            var layer = ribbons
            layer.translateBy(x: tail.x, y: tail.y)
            layer.rotate(by: .radians(-0.9 + 0.55 * sin(phase)))
            let rect = CGRect(x: -len * 0.15, y: -w / 2 - len * 0.35, width: len, height: w)
            layer.fill(Path(ellipseIn: rect),
                       with: .radialGradient(Gradient(colors: [color.opacity(0.6 * strength), color.opacity(0)]),
                                             center: CGPoint(x: rect.midX, y: rect.midY),
                                             startRadius: 0, endRadius: len * 0.5))
        }

        // 3. A bright core right at the tail.
        var core = ctx
        core.blendMode = .plusLighter
        let rc = foxSize * (0.10 + 0.12 * g) * breathe
        core.fill(Path(ellipseIn: CGRect(x: tail.x - rc, y: tail.y - rc, width: rc * 2, height: rc * 2)),
                  with: .radialGradient(Gradient(colors: [.white.opacity(0.85 * strength),
                                                          Self.cyan.opacity(0.5 * strength), .clear]),
                                        center: tail, startRadius: 0, endRadius: rc))

        // 4. Motes: small sparks drifting up from the tail; more with more glow.
        var motes = ctx
        motes.blendMode = .plusLighter
        let count = 5 + Int(16 * g)
        for i in 0..<count {
            let seed = Double(i) * 12.9898
            let speed = 0.12 + 0.10 * frac(sin(seed) * 43758.5)
            let life = frac(t * speed + frac(sin(seed * 1.7) * 9631.1))
            let spread = reach * (0.35 + 0.8 * frac(sin(seed * 3.1) * 1531.7))
            let side = frac(sin(seed * 5.3) * 7123.3) - 0.5
            let x = tail.x + side * spread + 8 * sin(t * 1.3 + seed)
            let y = tail.y - life * reach * 1.6
            let fade = sin(life * .pi)
            let r = foxSize * (0.012 + 0.018 * frac(sin(seed * 7.7) * 3141.5))
            drawMote(&motes, at: CGPoint(x: x, y: y), radius: r, alpha: fade * strength,
                     color: ribbonColors[i % 3])
        }

        // 5. The XP moment: a ring of motes bursting out and up.
        if let burst {
            let age = now.timeIntervalSince(burst)
            if age >= 0 && age < 1.6 {
                let p = age / 1.6
                for i in 0..<18 {
                    let a = Double(i) / 18 * 2 * .pi
                    let d = foxSize * (0.15 + 0.75 * easeOut(p))
                    let pt = CGPoint(x: tail.x + cos(a) * d, y: tail.y + sin(a) * d * 0.7 - p * foxSize * 0.3)
                    drawMote(&motes, at: pt, radius: foxSize * 0.03 * (1 - p * 0.5), alpha: 1 - p,
                             color: ribbonColors[i % 3])
                }
            }
        }
    }

    private func drawMote(_ ctx: inout GraphicsContext, at p: CGPoint, radius r: CGFloat, alpha: Double, color: Color) {
        let outer = r * 3.2
        ctx.fill(Path(ellipseIn: CGRect(x: p.x - outer, y: p.y - outer, width: outer * 2, height: outer * 2)),
                 with: .radialGradient(Gradient(colors: [color.opacity(0.55 * alpha), .clear]),
                                       center: p, startRadius: 0, endRadius: outer))
        ctx.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)),
                 with: .radialGradient(Gradient(colors: [.white.opacity(alpha), .white.opacity(0)]),
                                       center: p, startRadius: 0, endRadius: r))
    }

    private func tailPoint(in canvas: CGSize) -> CGPoint {
        let o = Self.tailOffset(pose: pose, foxSize: foxSize)
        return CGPoint(x: canvas.width / 2 + o.x, y: canvas.height / 2 + o.y)
    }

    /// Where the tail is, from the centre of the fox's square frame. The share
    /// of the picture comes from each pose's art.
    static func tailOffset(pose: LanviPose, foxSize s: CGFloat) -> CGPoint {
        let (fx, fy, aspect): (CGFloat, CGFloat, CGFloat) = {
            switch pose {
            case .cheer: return (0.14, 0.78, 322.0 / 373)
            case .curious: return (0.82, 0.76, 305.0 / 363)
            case .love: return (0.84, 0.74, 383.0 / 387)
            case .surprised: return (0.16, 0.76, 296.0 / 396)
            case .meh: return (0.82, 0.84, 277.0 / 334)
            case .run: return (0.18, 0.32, 399.0 / 315)
            case .grumpy: return (0.76, 0.28, 339.0 / 334)
            case .peek: return (0.50, 0.86, 308.0 / 194)
            }
        }()
        let (rw, rh) = aspect < 1 ? (s * aspect, s) : (s, s / aspect)
        let x0 = (s - rw) / 2, y0 = s - rh
        return CGPoint(x: x0 + fx * rw - s / 2, y: y0 + fy * rh - s / 2)
    }

    private func frac(_ v: Double) -> Double { v - floor(v) }
    private func easeOut(_ p: Double) -> Double { 1 - pow(1 - p, 3) }
}
