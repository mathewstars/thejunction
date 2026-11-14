import SwiftUI

/// The light on Lanvi's tail tip ("fox fires"): mint into violet, growing
/// with `glow` (0...1) from the server, with a faint colour cast on the snow
/// beside the tail. It never goes dark; a low glow is a small ember. `burst`
/// opens one soft ring of light for the XP moment.
///
/// The view is twice the fox's size and centred on the fox, so place it in the
/// same spot as `LanviView` and behind it.
struct HomeTailGlow: View, Animatable {
    var pose: LanviPose
    var glow: Double
    var foxSize: CGFloat
    var burst: Date? = nil
    /// Which part to draw: `.back` goes behind Lanvi (snow cast, halo), `.front`
    /// on top (the light on the tail tip, the XP ring), `.all` both at once.
    var layer: Layer = .all

    enum Layer { case back, front, all }

    var animatableData: Double {
        get { glow }
        set { glow = newValue }
    }


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
        let breathe = 1 + 0.05 * sin(t * 2 * .pi / 3.4)
        let mint = Color(hex: 0x7CF5C4)
        let violet = Color(hex: 0xA98BFF)

        let back = layer != .front
        let front = layer != .back

        // 1. A faint colour cast on the snow right beside the tail.
        let castW = foxSize * (0.30 + 0.35 * g)
        let castH = castW * 0.28
        let castCenter = CGPoint(x: tail.x, y: tail.y + foxSize * 0.13)
        var cast = ctx
        if !back { cast.opacity = 0 }
        cast.addFilter(.blur(radius: foxSize * 0.03))
        cast.fill(Path(ellipseIn: CGRect(x: castCenter.x - castW / 2, y: castCenter.y - castH / 2, width: castW, height: castH)),
                  with: .radialGradient(Gradient(colors: [mint.opacity(0.30 * (0.35 + 0.65 * g)), violet.opacity(0.12 * g), .clear]),
                                        center: castCenter, startRadius: 0, endRadius: castW / 2))

        // 2. The light on the tail tip: white heart, mint, then violet, as light.
        var light = ctx
        light.blendMode = .plusLighter
        let r = foxSize * (0.07 + 0.13 * g) * breathe
        if back {
            light.fill(Path(ellipseIn: CGRect(x: tail.x - r * 1.8, y: tail.y - r * 1.8, width: r * 3.6, height: r * 3.6)),
                       with: .radialGradient(Gradient(colors: [violet.opacity(0.22 * (0.4 + 0.6 * g)), .clear]),
                                             center: tail, startRadius: r * 0.6, endRadius: r * 1.8))
        }
        guard front else { return }
        light.fill(Path(ellipseIn: CGRect(x: tail.x - r, y: tail.y - r, width: r * 2, height: r * 2)),
                   with: .radialGradient(Gradient(stops: [
                       .init(color: .white.opacity(0.75 * (0.5 + 0.5 * g)), location: 0),
                       .init(color: mint.opacity(0.55 * (0.5 + 0.5 * g)), location: 0.35),
                       .init(color: violet.opacity(0.0), location: 1),
                   ]), center: tail, startRadius: 0, endRadius: r))

        // 3. The XP moment: one soft ring of light opening from the tail.
        if let burst {
            let age = now.timeIntervalSince(burst)
            if age >= 0 && age < 1.2 {
                let p = age / 1.2
                let rr = foxSize * (0.08 + 0.45 * (1 - pow(1 - p, 3)))
                let a = (1 - p) * 0.6
                light.fill(Path(ellipseIn: CGRect(x: tail.x - rr, y: tail.y - rr, width: rr * 2, height: rr * 2)),
                           with: .radialGradient(Gradient(stops: [
                               .init(color: .clear, location: 0.55),
                               .init(color: mint.opacity(a), location: 0.85),
                               .init(color: .clear, location: 1),
                           ]), center: tail, startRadius: 0, endRadius: rr))
            }
        }
    }

    private func tailPoint(in canvas: CGSize) -> CGPoint {
        let o = Self.tailOffset(pose: pose, foxSize: foxSize)
        return CGPoint(x: canvas.width / 2 + o.x, y: canvas.height / 2 + o.y)
    }

    /// Where the tail is, from the centre of the fox's square frame. The share
    /// of the picture comes from each pose's art.
    static func tailOffset(pose: LanviPose, foxSize s: CGFloat) -> CGPoint {
        // The paper puppet knows where its own tail tip is.
        if pose.isPuppet { return LanviView.puppetTailTip(foxSize: s) }
        let (fx, fy, aspect): (CGFloat, CGFloat, CGFloat) = {
            switch pose {
            case .cheer: return (0.13, 0.80, 953.0 / 1000)
            case .curious: return (0.85, 0.78, 828.0 / 1000)
            case .love: return (0.86, 0.76, 975.0 / 1000)
            case .surprised: return (0.14, 0.78, 740.0 / 1000)
            case .meh: return (0.84, 0.86, 827.0 / 1000)
            case .run: return (0.14, 0.30, 1000.0 / 860)
            case .grumpy: return (0.78, 0.26, 1000.0 / 960)
            case .peek: return (0.50, 0.88, 1000.0 / 603)
            }
        }()
        let (rw, rh) = aspect < 1 ? (s * aspect, s) : (s, s / aspect)
        let x0 = (s - rw) / 2, y0 = s - rh
        return CGPoint(x: x0 + fx * rw - s / 2, y: y0 + fy * rh - s / 2)
    }

}
