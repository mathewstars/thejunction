import SwiftUI

/// The three hand-painted scenes Lanvi lives in (same hand as the fox):
/// snow hills in layers, pines at the edges, mountains, a clearing with a
/// hollow in the lower middle for Lanvi, and calm sky on top for its line.
enum WorldScene: String, Equatable {
    case dawn, day, night

    /// Dawn before 10:00, day until 17:00, night after (and before 5:00).
    static func at(hour: Int) -> WorldScene {
        switch hour {
        case 5..<10: return .dawn
        case 10..<17: return .day
        default: return .night
        }
    }

    var imageName: String { "world-\(rawValue)" }
}

/// Where the painting lands on a full screen (it fills the screen, cropping
/// the sides or the top and bottom as needed). Points are in full-screen space.
struct WorldFrame {
    static let imageSize = CGSize(width: 1520, height: 2688)
    /// The hollow in the clearing where Lanvi sits, as a share of the picture.
    static let hollow = CGPoint(x: 0.5, y: 0.786)

    let origin: CGPoint
    let scale: CGFloat

    init(screen: CGSize) {
        let s = max(screen.width / Self.imageSize.width, screen.height / Self.imageSize.height)
        scale = s
        origin = CGPoint(x: (screen.width - Self.imageSize.width * s) / 2,
                         y: (screen.height - Self.imageSize.height * s) / 2)
    }

    func point(_ fx: CGFloat, _ fy: CGFloat) -> CGPoint {
        CGPoint(x: origin.x + fx * Self.imageSize.width * scale,
                y: origin.y + fy * Self.imageSize.height * scale)
    }
}

/// The painted scene, full-bleed, with a little life on top.
struct PaintedWorld: View {
    var scene: WorldScene
    var snow: Bool = true
    /// Today's glow (0...1, already on Home): how strongly the aurora rests.
    var glow: Double = 0
    /// When the reward last played: the sky flares bright for about 2.5 s, then
    /// rests a little stronger for the rest of the visit.
    var flareAt: Date? = nil

    /// Debug only, `-noLife`: the painting without snow, glints or shimmer (to measure their cost).
    private static let lifeOff: Bool = {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("-noLife")
        #else
        return false
        #endif
    }()

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                #if DEBUG
                let _ = FrameMeter.count("World")
                #endif
                Image(scene.imageName)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
                    .frame(width: size.width, height: size.height)
                    .clipped()
                    .id(scene)
                    .transition(.opacity)
                if scene == .dawn { DawnWarmth() }
                if !Self.lifeOff {
                    WorldLife(scene: scene, frame: WorldFrame(screen: size), snow: snow,
                              glow: glow, flareAt: flareAt)
                }
            }
            .animation(.easeInOut(duration: 1.6), value: scene)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

/// Dawn light warming slowly and easing back. Driven by a system animation
/// (no per-frame drawing on the main thread).
private struct DawnWarmth: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var warm = false
    var body: some View {
        LinearGradient(colors: [Color(hex: 0xFFC9A8).opacity(0), Color(hex: 0xFFC9A8).opacity(0.35)],
                       startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.6))
            .blendMode(.softLight)
            .opacity(warm ? 1 : 0.4)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 12).repeatForever(autoreverses: true)) { warm = true }
            }
    }
}

/// Subtle, real life on the painting: slow snow at three depths; at night the
/// painted stars glint and a faint shimmer moves through the aurora. Kept
/// cheap: one canvas at 60 frames a second, plain gradients, no filters.
private struct WorldLife: View {
    var scene: WorldScene
    var frame: WorldFrame
    var snow: Bool
    var glow: Double
    var flareAt: Date?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The painted stars in the night scene, as a share of the picture.
    private static let stars: [CGPoint] = [
        CGPoint(x: 0.433, y: 0.057), CGPoint(x: 0.102, y: 0.195), CGPoint(x: 0.267, y: 0.274),
        CGPoint(x: 0.096, y: 0.362), CGPoint(x: 0.364, y: 0.077), CGPoint(x: 0.918, y: 0.166),
        CGPoint(x: 0.873, y: 0.033), CGPoint(x: 0.880, y: 0.308),
    ]

    var body: some View {
        // Reduce Motion: the whole sky holds still (the timeline is paused).
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: reduceMotion)) { context in
            // One shared, continuous clock for every scene: it advances at most
            // 1/30 s per frame, so a layer that was paused (under an overlay, in the
            // background) or just created never fast-forwards to catch up.
            let t = WorldClock.shared.now(context.date)
            let f = flare(at: context.date)
            Canvas { ctx, size in
                if scene == .night {
                    aurora(&ctx, size: size, t: t, flare: f)
                    glints(&ctx, t: t)
                    twinkles(&ctx, t: t)
                    shimmer(&ctx, t: t)
                } else {
                    shafts(&ctx, size: size, t: t)
                    if f > 0 { sweep(&ctx, size: size, flare: f) }
                }
                if snow { flakes(&ctx, size: size, t: t) }
            }
        }
    }

    private func flakes(_ ctx: inout GraphicsContext, size: CGSize, t: TimeInterval) {
        // (count, radius, fall speed points per second, opacity) per depth.
        let depths: [(Int, CGFloat, Double, Double)] = [(7, 1.3, 9, 0.45), (5, 2.0, 15, 0.6), (3, 2.8, 23, 0.75)]
        var k = 0
        for (count, r, speed, alpha) in depths {
            for i in 0..<count {
                k += 1
                let seed = Double(k) * 7.137
                let x0 = frac(sin(seed) * 4375.85) * size.width
                let fall = (t * speed + frac(sin(seed * 2.1) * 913.7) * size.height)
                let y = fall.truncatingRemainder(dividingBy: Double(size.height + 20)) - 10
                let x = x0 + CGFloat(sin(t * 0.4 + seed) * 14)
                let p = CGPoint(x: x, y: CGFloat(y))
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - r * 2.2, y: p.y - r * 2.2, width: r * 4.4, height: r * 4.4)),
                         with: .radialGradient(Gradient(colors: [.white.opacity(alpha), .white.opacity(0)]),
                                               center: p, startRadius: 0, endRadius: r * 2.2))
                _ = i
            }
        }
    }

    private func glints(_ ctx: inout GraphicsContext, t: TimeInterval) {
        var g = ctx
        g.blendMode = .plusLighter
        for (i, s) in Self.stars.enumerated() {
            let p = frame.point(s.x, s.y)
            let a = max(0, sin(t * (0.6 + 0.13 * Double(i)) + Double(i) * 1.9))
            guard a > 0.05 else { continue }
            let len: CGFloat = 5 + 4 * CGFloat(a)
            g.fill(Path(ellipseIn: CGRect(x: p.x - len, y: p.y - 0.7, width: len * 2, height: 1.4)),
                   with: .color(.white.opacity(0.55 * a)))
            g.fill(Path(ellipseIn: CGRect(x: p.x - 0.7, y: p.y - len, width: 1.4, height: len * 2)),
                   with: .color(.white.opacity(0.55 * a)))
            g.fill(Path(ellipseIn: CGRect(x: p.x - 6, y: p.y - 6, width: 12, height: 12)),
                   with: .radialGradient(Gradient(colors: [.white.opacity(0.35 * a), .clear]),
                                         center: p, startRadius: 0, endRadius: 6))
        }
    }

    /// A faint band of light drifting along the painted aurora.
    private func shimmer(_ ctx: inout GraphicsContext, t: TimeInterval) {
        var g = ctx
        g.blendMode = .plusLighter
        let cycle = 16.0
        let u = (t.truncatingRemainder(dividingBy: cycle)) / cycle
        let fx = CGFloat(0.05 + 0.9 * u)
        let fy = CGFloat(0.10 + 0.26 * u * u)
        let p = frame.point(fx, fy)
        let fade = sin(u * .pi)
        let w: CGFloat = 170, h: CGFloat = 70
        var layer = g
        layer.translateBy(x: p.x, y: p.y)
        layer.rotate(by: .degrees(28))
        layer.fill(Path(ellipseIn: CGRect(x: -w / 2, y: -h / 2, width: w, height: h)),
                   with: .radialGradient(Gradient(colors: [Color(hex: 0xB9FFE4).opacity(0.16 * fade),
                                                           Color(hex: 0xB9FFE4).opacity(0.05 * fade), .clear]),
                                         center: .zero, startRadius: 0, endRadius: w / 2))
    }

    private func frac(_ v: Double) -> Double { v - floor(v) }

    // MARK: The living sky

    /// 0...1: rises in 0.35 s, holds, and eases back by 2.6 s after the reward.
    private func flare(at date: Date) -> Double {
        guard let flareAt, !reduceMotion else { return 0 }
        let dt = date.timeIntervalSince(flareAt)
        switch dt {
        case ..<0: return 0
        case ..<0.35: let u = dt / 0.35; return u * u * (3 - 2 * u)
        case ..<1.5: return 1
        case ..<2.6: let u = (dt - 1.5) / 1.1; return 1 - u * u * (3 - 2 * u)
        default: return 0
        }
    }

    /// How strongly the aurora rests: today's glow, plus a little once the
    /// reward has lit it during this visit.
    private var restingStrength: Double {
        min(0.35 + 0.45 * max(0, min(glow, 1)) + (flareAt != nil ? 0.15 : 0), 0.95)
    }

    /// Two slow ribbons of green and violet light drifting across the night sky,
    /// above the hills. Each is a chain of soft, stretched glows along a gentle
    /// wave, added as light (cheap: no filters, no offscreen layers).
    private func aurora(_ ctx: inout GraphicsContext, size: CGSize, t: TimeInterval, flare: Double) {
        var g = ctx
        g.blendMode = .plusLighter
        let strength = restingStrength + 0.9 * flare
        let span = WorldFrame.imageSize.width * frame.scale
        let green = (r: 0.49, g: 0.96, b: 0.77), violet = (r: 0.71, g: 0.55, b: 1.0)
        for ribbon in 0..<2 {
            let r = Double(ribbon)
            let baseY = 0.13 + 0.10 * r
            let speed = 0.045 + 0.02 * r
            let count = 15
            for i in 0..<count {
                let fx = -0.06 + 1.12 * Double(i) / Double(count - 1)
                let phase = fx * 7.0 + t * speed * 2 * .pi + r * 2.1
                let fy = baseY + 0.028 * sin(phase) + 0.05 * (fx - 0.5) * (r == 0 ? 1 : -1)
                let slope = 0.028 * cos(phase) * 7.0 * WorldFrame.imageSize.height / WorldFrame.imageSize.width
                let breathe = 0.6 + 0.4 * sin(t * 0.21 + Double(i) * 0.7 + r)
                let mix = 0.5 + 0.5 * sin(fx * 3.1 + t * 0.07 + r * 1.7)
                let c = Color(red: green.r + (violet.r - green.r) * mix,
                              green: green.g + (violet.g - green.g) * mix,
                              blue: green.b + (violet.b - green.b) * mix)
                let a = min(0.22 * strength * breathe + 0.32 * flare, 0.62)
                let p = frame.point(CGFloat(fx), CGFloat(fy))
                let w = span * 0.16, h = span * (0.05 + 0.02 * breathe)
                var layer = g
                layer.translateBy(x: p.x, y: p.y)
                layer.rotate(by: .radians(atan(slope)))
                layer.fill(Path(ellipseIn: CGRect(x: -w / 2, y: -h / 2, width: w, height: h)),
                           with: .radialGradient(Gradient(colors: [c.opacity(a), c.opacity(a * 0.35), .clear]),
                                                 center: .zero, startRadius: 0, endRadius: w / 2))
            }
        }
        if flare > 0 {
            // The whole sky lights up a little with it.
            let top = frame.point(0.5, 0.18)
            g.fill(Path(CGRect(origin: .zero, size: size)),
                   with: .radialGradient(Gradient(colors: [Color(hex: 0x9CF7D4).opacity(0.22 * flare), .clear]),
                                         center: top, startRadius: 0, endRadius: size.height * 0.55))
        }
    }

    /// A few small stars twinkle at random, a few at a time.
    private func twinkles(_ ctx: inout GraphicsContext, t: TimeInterval) {
        var g = ctx
        g.blendMode = .plusLighter
        for i in 0..<16 {
            let seed = Double(i) * 12.9898
            let fx = 0.04 + 0.92 * frac(sin(seed) * 43758.5)
            let fy = 0.03 + 0.27 * frac(sin(seed * 1.7) * 24634.6)
            let period = 2.4 + 2.2 * frac(sin(seed * 3.3) * 7919.1)
            let k = (t + period * frac(sin(seed * 5.1) * 311.7)) / period
            // Only some stars take part in each round, so it is never a pattern.
            guard frac(sin(floor(k) * 78.233 + seed) * 43758.5) > 0.62 else { continue }
            let u = frac(k)
            guard u < 0.22 else { continue }
            let a = sin(u / 0.22 * .pi)
            let p = frame.point(CGFloat(fx), CGFloat(fy))
            let len: CGFloat = 2.5 + 3 * CGFloat(a)
            g.fill(Path(ellipseIn: CGRect(x: p.x - len, y: p.y - 0.5, width: len * 2, height: 1)),
                   with: .color(.white.opacity(0.7 * a)))
            g.fill(Path(ellipseIn: CGRect(x: p.x - 0.5, y: p.y - len, width: 1, height: len * 2)),
                   with: .color(.white.opacity(0.7 * a)))
            g.fill(Path(ellipseIn: CGRect(x: p.x - 1.3, y: p.y - 1.3, width: 2.6, height: 2.6)),
                   with: .color(.white.opacity(0.9 * a)))
        }
    }

    /// Dawn and day: three soft shafts of sunlight, slowly drifting and breathing,
    /// fading out before they reach the snow where Lanvi sits.
    private func shafts(_ ctx: inout GraphicsContext, size: CGSize, t: TimeInterval) {
        var g = ctx
        g.blendMode = .plusLighter
        let warm = scene == .dawn ? Color(hex: 0xFFE2C4) : Color.white
        let reach = size.height * 0.58
        for i in 0..<3 {
            let d = Double(i)
            let x0 = size.width * CGFloat(0.55 + 0.22 * d) + CGFloat(sin(t * 0.035 + d * 2.0) * 40)
            let width = CGFloat(70 + 45 * d)
            let breathe = 0.55 + 0.45 * sin(t * 0.09 + d * 1.3)
            var layer = g
            layer.translateBy(x: x0, y: -20)
            layer.rotate(by: .degrees(24))
            // Six stacked pieces, each fainter, so the shaft fades along its length.
            for s in 0..<6 {
                let y = reach * CGFloat(s) / 6
                let fade = 1 - Double(s) / 6
                let a = 0.13 * breathe * fade
                let rect = CGRect(x: -width / 2, y: y, width: width, height: reach / 6 + 1)
                layer.fill(Path(rect), with: .linearGradient(
                    Gradient(colors: [warm.opacity(0), warm.opacity(a), warm.opacity(0)]),
                    startPoint: CGPoint(x: -width / 2, y: 0), endPoint: CGPoint(x: width / 2, y: 0)))
            }
        }
    }

    /// Dawn and day reward: a soft sweep of light across the sky.
    private func sweep(_ ctx: inout GraphicsContext, size: CGSize, flare: Double) {
        var g = ctx
        g.blendMode = .plusLighter
        let c = CGPoint(x: size.width * 0.5, y: size.height * 0.16)
        g.fill(Path(CGRect(origin: .zero, size: size)),
               with: .radialGradient(Gradient(colors: [Color.white.opacity(0.42 * flare),
                                                       Color(hex: 0xC9F6FF).opacity(0.10 * flare), .clear]),
                                     center: c, startRadius: 0, endRadius: size.height * 0.6))
    }
}

/// The world's own time: continuous and shared by every painted scene. Each
/// reading advances it by the real time since the last one, but never by more
/// than 1/30 s, and never backwards. Snow, glints and shimmer are pure
/// functions of it.
final class WorldClock {
    static let shared = WorldClock()
    private var world: Double = 0
    private var lastReal: Double?

    func now(_ date: Date) -> Double {
        let real = date.timeIntervalSinceReferenceDate
        if let lastReal {
            let dt = real - lastReal
            if dt > 0 { world += min(dt, 1.0 / 30) }
            // Several scenes read the same frame: only real time moving forward counts.
            if dt > 0 { self.lastReal = real }
        } else {
            lastReal = real
        }
        return world
    }
}
