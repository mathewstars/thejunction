import SwiftUI
import UIKit

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
                WorldPictures.shared.image(scene)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
                    .frame(width: size.width, height: size.height)
                    .clipped()
                    .id(scene)
                    .transition(.opacity)
                if scene == .dawn { DawnWarmth() }
                if !Self.lifeOff {
                    WorldLife(scene: scene, frame: WorldFrame(screen: size), snow: snow)
                }
            }
            .animation(.easeInOut(duration: 1.6), value: scene)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

/// The painted worlds, each decoded once off the main thread and kept. A world
/// is 1520 x 2688 pixels: decoding it the first time a screen shows it would
/// hold the main thread for a few frames (at launch, and the first time Help,
/// the chat or the first run shows it). The app decodes today's world at launch.
final class WorldPictures: @unchecked Sendable {
    static let shared = WorldPictures()
    private let lock = NSLock()
    private var decoded: [WorldScene: UIImage] = [:]
    private var loading: Set<WorldScene> = []

    /// The decoded picture when it is ready; until then the picture by name
    /// (decoded on first use, as before), and its decoding is started.
    func image(_ scene: WorldScene) -> Image {
        if let ui = lock.withLock({ decoded[scene] }) { return Image(uiImage: ui) }
        preload([scene])
        return Image(scene.imageName)
    }

    /// Decode these worlds in the background, each once.
    func preload(_ scenes: [WorldScene]) {
        let todo = lock.withLock { scenes.filter { decoded[$0] == nil && loading.insert($0).inserted } }
        guard !todo.isEmpty else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            for scene in todo {
                guard let ui = UIImage(named: scene.imageName) else { continue }
                let ready = ui.preparingForDisplay() ?? ui
                self.lock.withLock {
                    self.decoded[scene] = ready
                    self.loading.remove(scene)
                }
            }
        }
    }
}

/// Dawn light warming slowly and easing back. Driven by a system animation
/// (no per-frame drawing on the main thread).
private struct DawnWarmth: View {
    @State private var warm = false
    var body: some View {
        LinearGradient(colors: [Color(hex: 0xFFC9A8).opacity(0), Color(hex: 0xFFC9A8).opacity(0.35)],
                       startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.6))
            .blendMode(.softLight)
            .opacity(warm ? 1 : 0.4)
            .onAppear {
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

    /// The painted stars in the night scene, as a share of the picture.
    private static let stars: [CGPoint] = [
        CGPoint(x: 0.433, y: 0.057), CGPoint(x: 0.102, y: 0.195), CGPoint(x: 0.267, y: 0.274),
        CGPoint(x: 0.096, y: 0.362), CGPoint(x: 0.364, y: 0.077), CGPoint(x: 0.918, y: 0.166),
        CGPoint(x: 0.873, y: 0.033), CGPoint(x: 0.880, y: 0.308),
    ]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60)) { context in
            // One shared, continuous clock for every scene: it advances at most
            // 1/30 s per frame, so a layer that was paused (under an overlay, in the
            // background) or just created never fast-forwards to catch up.
            let t = WorldClock.shared.now(context.date)
            Canvas { ctx, size in
                if scene == .night { glints(&ctx, t: t); shimmer(&ctx, t: t) }
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
