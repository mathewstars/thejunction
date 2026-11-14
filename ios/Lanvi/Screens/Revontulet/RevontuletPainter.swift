import SwiftUI

/// The colours of the game's light. Aurora in green and teal with a violet edge, soft and
/// never neon; the fox's spark warm; the ice dark and cold.
enum RevontuletColor {
    static let green = Color(red: 0.42, green: 1.0, blue: 0.70)
    static let teal = Color(red: 0.30, green: 0.86, blue: 0.86)
    static let violet = Color(red: 0.62, green: 0.50, blue: 1.0)
    static let iceDeep = Color(red: 0.035, green: 0.075, blue: 0.19)
    static let iceCold = Color(red: 0.42, green: 0.66, blue: 0.84)
    static let frost = Color(red: 0.90, green: 0.96, blue: 1.0)
    static let hairline = Color(red: 0.84, green: 0.93, blue: 1.0)
    static let gold = Color(red: 1.0, green: 0.85, blue: 0.55)
    static let amber = Color(red: 1.0, green: 0.62, blue: 0.30)
    static let ember = Color(red: 1.0, green: 0.48, blue: 0.24)
    static let core = Color(red: 1.0, green: 0.98, blue: 0.92)
    static let warmWhite = Color(red: 1.0, green: 0.94, blue: 0.82)
    static let snowLight = Color(red: 0.93, green: 0.95, blue: 1.0)
    static let snowShade = Color(red: 0.78, green: 0.83, blue: 0.96)
}

/// Draws one frame from the engine's state, in two layers: behind the fox (the sky, the
/// ice, its cracks and shards) and in front of it (the spark, the half-circle, the sling,
/// the embers, the snow on the fur). Pure drawing: everything that does not change was made
/// once in `RevontuletArt`.
struct RevontuletPainter {
    let e: RevontuletEngine
    let art: RevontuletArt
    let now: Double
    var coach: RevontuletCoachState? = nil
    var reduceMotion = false

    private var L: RevontuletLayout { e.layout }
    private var since: Double { now - e.beatStart }
    private var burstAge: Double? { e.burstAt.map { now - $0 } }
    /// 0 for the whole wall, rising by a third with each impact (eased in after the hit).
    private var thinness: Double {
        e.impacts.reduce(0) { $0 + min(1, max(0, (now - $1.time) / 0.8)) } / 3
    }

    // MARK: - Sky (behind the ice)

    func sky(_ ctx: inout GraphicsContext, size: CGSize) {
        var light = e.broken ? 1.0 : 0.3 + 0.7 * e.skyLight
        if e.beat == .sleep || e.beat == .done { light *= max(0.55, 1 - (since / 2.5) * 0.45) }
        let sweep: Double = burstAge.map { min(1, max(0, ($0 - 0.1) / 2.4)) } ?? 1
        var g = ctx
        g.blendMode = .plusLighter
        let burstX = art.burstPoint.map { Double($0.x) }
        aurora(&g, size: size, light: light, sweep: e.broken ? sweep : 1, origin: burstX)
        // Every impact adds a ribbon of aurora behind the ice (bigger for the vein), unfurling
        // from the hit: seen through the holes and the thinning glass, the sky being won.
        for (k, hit) in e.impacts.enumerated() where !hit.breaking {
            let age = now - hit.time
            guard age > 0 else { continue }
            let big = hit.hard ? 1.0 + 0.2 * Double(hit.embersHit) : 0.55
            let fade = e.beat == .sleep || e.beat == .done ? 0.6 : 1
            curtain(&g, size: size, base: 0.2 + 0.07 * Double(k), amp: 14 + 10 * big, height: 0.09 + 0.07 * big,
                    alpha: (0.22 + 0.3 * big) * fade, speed: 0.12 + 0.03 * Double(k), phase: 4 + 1.7 * Double(k),
                    violetTop: k % 2 == 0, reveal: min(1, age / 1.6), origin: Double(hit.point.x), step: 8)
        }
        for (k, r) in e.impacts.enumerated() where r.ribbon {
            let age = now - r.time
            let a = min(1, age / 1.2) * (e.beat == .sleep || e.beat == .done ? 0.6 : 1)
            curtain(&g, size: size, base: 0.36 + 0.05 * Double(k), amp: 22, height: 0.13, alpha: 0.5 * a,
                    speed: 0.21, phase: 2.0 + Double(k), violetTop: true, reveal: min(1, age / 1.6))
        }
        if let b = burstAge {
            // The sky won: stars come on one by one, and the snow takes a soft tint from it.
            let on = min(1, max(0, (b - 0.6) / 2.2))
            if on > 0 {
                stars(&g, size: size, on: on)
                let h = size.height
                g.fill(Path(CGRect(x: 0, y: h * 0.52, width: size.width, height: h * 0.48)), with: .linearGradient(
                    Gradient(colors: [RevontuletColor.teal.opacity(0.09 * on * light), RevontuletColor.green.opacity(0.04 * on * light), .clear]),
                    startPoint: CGPoint(x: 0, y: h * 0.52), endPoint: CGPoint(x: 0, y: h)))
            }
        }
        if let b = burstAge, b < 1.4 {
            // The sky opening: one soft bloom of green light, gone in a breath.
            let k = pow(1 - b / 1.4, 2)
            let c = art.burstPoint ?? L.foxTarget
            g.fill(Path(CGRect(origin: .zero, size: size)), with: .radialGradient(
                Gradient(colors: [RevontuletColor.green.opacity(0.3 * k), RevontuletColor.teal.opacity(0.12 * k), .clear]),
                center: c, startRadius: 0, endRadius: size.height * 0.7))
        }
    }

    private func aurora(_ ctx: inout GraphicsContext, size: CGSize, light: Double, sweep: Double, origin: Double? = nil) {
        guard light > 0.01 else { return }
        curtain(&ctx, size: size, base: 0.25, amp: 30, height: 0.19, alpha: 0.42 * light, speed: 0.11, phase: 0, violetTop: true, reveal: sweep, origin: origin)
        curtain(&ctx, size: size, base: 0.33, amp: 24, height: 0.16, alpha: 0.5 * light, speed: 0.15, phase: 1.7, violetTop: false, reveal: sweep, origin: origin)
        curtain(&ctx, size: size, base: 0.16, amp: 18, height: 0.12, alpha: 0.3 * light, speed: 0.08, phase: 3.1, violetTop: true, reveal: sweep, origin: origin)
    }

    /// Small four-pointed glints that come on one by one after the burst.
    private func stars(_ g: inout GraphicsContext, size: CGSize, on: Double) {
        for i in 0..<34 {
            let di = Double(i)
            let fx = abs(sin(di * 12.9898) * 43758.5453).truncatingRemainder(dividingBy: 1)
            let fy = abs(sin(di * 78.233) * 12345.678).truncatingRemainder(dividingBy: 1)
            let p = CGPoint(x: CGFloat(fx) * size.width, y: size.height * CGFloat(0.06 + 0.4 * fy))
            let lit = min(1, max(0, on * 34 - di * 0.8))
            let tw = 0.55 + 0.45 * sin(now * (0.7 + 0.05 * di) + di * 1.3)
            let a = lit * tw
            guard a > 0.02 else { continue }
            let len: CGFloat = CGFloat(2.5 + 2.5 * fy)
            g.fill(Path(ellipseIn: CGRect(x: p.x - len, y: p.y - 0.5, width: len * 2, height: 1)), with: .color(Color.white.opacity(0.7 * a)))
            g.fill(Path(ellipseIn: CGRect(x: p.x - 0.5, y: p.y - len, width: 1, height: len * 2)), with: .color(Color.white.opacity(0.7 * a)))
            g.fill(Path(ellipseIn: CGRect(x: p.x - 2.2, y: p.y - 2.2, width: 4.4, height: 4.4)), with: .radialGradient(
                Gradient(colors: [Color.white.opacity(0.6 * a), .clear]), center: p, startRadius: 0, endRadius: 2.2))
        }
    }

    /// One curtain of aurora: vertical rays hanging from a slowly swaying lower edge,
    /// brightest at the edge, green into teal, a violet fringe at the top.
    private func curtain(_ ctx: inout GraphicsContext, size: CGSize, base: Double, amp: Double, height: Double,
                         alpha: Double, speed: Double, phase: Double, violetTop: Bool, reveal: Double, origin: Double? = nil,
                         step: Double = 4) {
        let w = Double(size.width), h = Double(size.height)
        let k1 = 2 * Double.pi / (w * 1.15), k2 = 2 * Double.pi / (w * 0.42)
        let t = now
        var x = -10.0
        while x < w + 10 {
            // Unfurling from the left, or outward both ways from a point (a hit, the burst).
            let lead = origin.map { reveal * (w * 1.1 + 260) - abs(x - $0) } ?? (reveal * (w + 260) - x)
            let shown = min(1, max(0, lead / 260))
            if shown > 0.01 {
                let y1 = sin(x * k1 + t * speed + phase) * amp
                let y2 = sin(x * k2 - t * speed * 2.1 + phase * 1.3) * amp * 0.35
                let yb = base * h + y1 + y2
                let slope = abs(cos(x * k1 + t * speed + phase)) * 0.5 + 0.5
                let rayA = 0.5 + 0.5 * sin(x * 0.11 + t * 0.6 + phase)
                let rayB = 0.6 + 0.4 * sin(x * 0.031 - t * 0.27 + phase * 2)
                let a = 0.5 * alpha * shown * (0.35 + 0.65 * rayA * rayA) * rayB * slope
                let len = height * h * (0.7 + 0.3 * sin(x * 0.017 + t * 0.2 + phase))
                let rect = CGRect(x: x - 3, y: yb - len, width: step + 6, height: len + 8)
                let top: Color = violetTop ? RevontuletColor.violet : RevontuletColor.teal
                let stops: [Gradient.Stop] = [
                    .init(color: .clear, location: 0),
                    .init(color: top.opacity(a * 0.35), location: 0.3),
                    .init(color: RevontuletColor.teal.opacity(a * 0.6), location: 0.62),
                    .init(color: RevontuletColor.green.opacity(a), location: 0.93),
                    .init(color: .clear, location: 1),
                ]
                ctx.fill(Path(rect), with: .linearGradient(Gradient(stops: stops),
                                                           startPoint: CGPoint(x: rect.midX, y: rect.minY),
                                                           endPoint: CGPoint(x: rect.midX, y: rect.maxY)))
            }
            x += step
        }
    }

    // MARK: - The ice

    func ice(_ ctx: inout GraphicsContext, size: CGSize) {
        let standing = art.standing(at: now, burstAt: e.burstAt)
        if !standing.isEmpty {
            glass(&ctx, standing: standing)
            holeSky(&ctx)
            var inside = ctx
            inside.clip(to: standing)
            holes(&inside)
            for (k, list) in art.cracks.enumerated() where k < e.impacts.count {
                hairlines(&inside, list, age: now - e.impacts[k].time)
            }
            faults(&inside)
        }
        falling(&ctx)
        if let b = burstAge { burst(&ctx, age: b) }
        landingLight(&ctx)
        drift(&ctx)
    }

    /// Dark frosted glass made from the sky behind it: the painting blurred, darkened and
    /// cooled, with a bevel, slow sheens, frost from the top, bubbles and shadow at the foot.
    private func glass(_ ctx: inout GraphicsContext, standing: Path) {
        let wall = L.wall
        var g = ctx
        g.clip(to: standing)
        if let sky = art.frostedSky {
            g.draw(Image(decorative: sky, scale: 1), in: art.skyRect.offsetBy(dx: 3, dy: 5))
        }
        // The wall thins with every impact: the real sky glows through more and more, so the
        // player sees how close they are without a counter.
        let thin = thinness
        let open = e.skyLight
        var through = g
        through.opacity = 0.1 + 0.32 * thin
        through.draw(ctx.resolve(Image("world-night")), in: art.skyRect)
        // Faint shapes of the aurora drifting behind the glass.
        var behind = g
        behind.blendMode = .plusLighter
        let shapes: [(Double, Double, Double, Color)] = [(0.2, 0.3, 0.05, RevontuletColor.green), (0.62, 0.22, 0.035, RevontuletColor.teal),
                                                         (0.85, 0.42, 0.045, RevontuletColor.violet)]
        for (k, sh) in shapes.enumerated() {
            let fx: Double = sh.0 + 0.12 * sin(now * sh.2 + Double(k) * 1.9)
            let fy: Double = sh.1 + 0.06 * sin(now * sh.2 * 1.6 + Double(k))
            let c = CGPoint(x: L.size.width * CGFloat(fx), y: wall.minY + wall.height * CGFloat(fy))
            softEllipse(&behind, c, rx: wall.width * 0.32, ry: wall.height * 0.1, [sh.3.opacity(0.1 + 0.16 * thin), sh.3.opacity(0.04 + 0.06 * thin)])
        }
        g.fill(Path(wall), with: .color(RevontuletColor.iceDeep.opacity(0.3 * (1 - thin))))
        // Shadow gathering toward the base.
        g.fill(Path(wall), with: .linearGradient(
            Gradient(colors: [.clear, Color.black.opacity(0.08), Color.black.opacity(0.34)]),
            startPoint: CGPoint(x: 0, y: wall.minY + wall.height * 0.45), endPoint: CGPoint(x: 0, y: wall.maxY)))
        var light = g
        light.blendMode = .plusLighter
        // Light trapped behind the glass, rising as the sky brightens.
        let trapped = 0.05 + 0.12 * open
        let spots: [(Double, Double, Color)] = [(0.25, 0.3, RevontuletColor.green), (0.75, 0.4, RevontuletColor.teal)]
        for (k, s) in spots.enumerated() {
            let fx: Double = s.0 + 0.05 * sin(now * 0.06 + Double(k) * 2)
            let cx: CGFloat = wall.minX + wall.width * CGFloat(fx)
            let cy: CGFloat = wall.minY + wall.height * CGFloat(s.1)
            let c = CGPoint(x: cx, y: cy)
            softEllipse(&light, c, rx: wall.width * 0.45, ry: wall.width * 0.27, [s.2.opacity(trapped)])
        }
        // Wide, soft diagonal sheens drifting very slowly.
        let sheens: [(Double, Double, Double)] = [(90.0, 0.05, 4.0), (140.0, 0.04, 2.6), (60.0, 0.07, 5.5)]
        for (k, s) in sheens.enumerated() {
            let span = Double(wall.width) + 300
            let x = (Double(k) * 170 + now * s.2).truncatingRemainder(dividingBy: span) - 150
            var band = light
            band.translateBy(x: wall.minX + CGFloat(x), y: wall.midY)
            band.rotate(by: .degrees(28))
            let w = CGFloat(s.0)
            band.fill(Path(CGRect(x: -w / 2, y: -wall.height, width: w, height: wall.height * 2)), with: .linearGradient(
                Gradient(colors: [.clear, Color.white.opacity(s.1), .clear]),
                startPoint: CGPoint(x: -w / 2, y: 0), endPoint: CGPoint(x: w / 2, y: 0)))
        }
        // A few long, very faint fracture hints inside, and bubble streaks.
        for h in art.hints {
            g.stroke(h, with: .color(Color.white.opacity(0.06)), lineWidth: 0.7)
        }
        for b in art.bubbles {
            var s = light
            s.translateBy(x: b.p.x, y: b.p.y)
            s.rotate(by: .radians(b.angle))
            s.fill(Path(ellipseIn: CGRect(x: -b.len / 2, y: -0.7, width: b.len, height: 1.4)), with: .color(Color.white.opacity(b.a)))
        }
        // Frost creeping in from the top: a soft haze densest at the edge, fine speckle.
        for (w, a) in [(40.0, 0.03), (24.0, 0.045), (12.0, 0.07), (5.0, 0.1)] {
            g.stroke(art.topEdge, with: .color(RevontuletColor.frost.opacity(a)), lineWidth: w)
        }
        for f in art.frost {
            let tw = 0.7 + 0.3 * sin(now * 1.1 + f.phase)
            light.fill(Path(ellipseIn: CGRect(x: f.p.x - f.r, y: f.p.y - f.r, width: f.r * 2, height: f.r * 2)),
                       with: .color(RevontuletColor.frost.opacity(f.a * tw)))
        }
        // Thickness: a thin bright bevel along the top with a darker line just below it.
        var low = g
        low.translateBy(x: 0, y: 3.5)
        low.stroke(art.topEdge, with: .color(Color.black.opacity(0.3)), lineWidth: 1.2)
        g.stroke(art.topEdge, with: .color(Color.white.opacity(0.62)), lineWidth: 1.1)
    }

    /// Inside each hole: the sky itself, bright and sharp, with its stars and a breath of
    /// aurora light, so a hole reads as a window onto the night, not a patch.
    private func holeSky(_ ctx: inout GraphicsContext) {
        var opened = Path()
        var any = false
        for (i, f) in art.facets.enumerated() {
            guard let t = art.fallAt[i], now >= t else { continue }
            opened.addPath(f.path)
            any = true
        }
        guard any else { return }
        var g = ctx
        g.clip(to: opened)
        g.blendMode = .plusLighter
        // The sharp sky, brightened: its aurora and its light come through clear.
        var bright = g
        bright.opacity = 0.45
        bright.draw(ctx.resolve(Image("world-night")), in: art.skyRect)
        let box = opened.boundingRect
        let c = CGPoint(x: box.midX, y: box.midY)
        softEllipse(&g, c, rx: max(box.width, box.height) * 0.9, ry: max(box.width, box.height) * 0.7,
                    [RevontuletColor.teal.opacity(0.24 + 0.1 * e.skyLight), RevontuletColor.green.opacity(0.08), RevontuletColor.violet.opacity(0.06)])
        // Stars in the window, a few per piece, twinkling.
        for (i, f) in art.facets.enumerated() {
            guard let t = art.fallAt[i], now >= t else { continue }
            let b = f.path.boundingRect
            for k in 0..<5 {
                let dk = Double(i * 7 + k)
                let fx = abs(sin(dk * 12.9898) * 43758.5453).truncatingRemainder(dividingBy: 1)
                let fy = abs(sin(dk * 78.233) * 12345.678).truncatingRemainder(dividingBy: 1)
                let p = CGPoint(x: b.minX + b.width * CGFloat(fx), y: b.minY + b.height * CGFloat(fy))
                guard f.path.contains(p) else { continue }
                let a = (0.55 + 0.45 * sin(now * (0.9 + 0.1 * Double(k)) + dk)) * min(1, (now - t) / 0.6)
                let len: CGFloat = CGFloat(2 + 2.5 * fy)
                g.fill(Path(ellipseIn: CGRect(x: p.x - len, y: p.y - 0.5, width: len * 2, height: 1)), with: .color(Color.white.opacity(0.8 * a)))
                g.fill(Path(ellipseIn: CGRect(x: p.x - 0.5, y: p.y - len, width: 1, height: len * 2)), with: .color(Color.white.opacity(0.8 * a)))
                g.fill(Path(ellipseIn: CGRect(x: p.x - 1.6, y: p.y - 1.6, width: 3.2, height: 3.2)), with: .color(Color.white.opacity(0.7 * a)))
            }
        }
    }

    /// The broken rim of each hole, on the glass that is left: thick and uneven, lit in places
    /// and broken in others, with small chips, and a shaded side for the glass's thickness.
    private func holes(_ ctx: inout GraphicsContext) {
        for (i, f) in art.facets.enumerated() {
            guard let t = art.fallAt[i], now >= t else { continue }
            let fresh = max(0, 1 - (now - t) / 0.8)
            var side = ctx
            side.translateBy(x: 1.5, y: 3)
            side.stroke(f.path, with: .color(Color.black.opacity(0.3)), lineWidth: 5)
            var g = ctx
            g.blendMode = .plusLighter
            let pts = f.points
            var n = 0
            for k in 0..<pts.count {
                let a = pts[k], b = pts[(k + 1) % pts.count]
                // Each edge in a few pieces of different weight; some pieces are missing.
                for piece in 0..<3 {
                    n += 1
                    let r1 = abs(sin(Double(i * 31 + n) * 12.9898) * 43758.5453).truncatingRemainder(dividingBy: 1)
                    let r2 = abs(sin(Double(i * 17 + n) * 78.233) * 12345.678).truncatingRemainder(dividingBy: 1)
                    guard r1 > 0.34 else { continue }
                    let u0 = CGFloat(piece) / 3, u1 = CGFloat(piece + 1) / 3
                    let p0 = CGPoint(x: a.x + (b.x - a.x) * u0, y: a.y + (b.y - a.y) * u0)
                    let p1 = CGPoint(x: a.x + (b.x - a.x) * u1, y: a.y + (b.y - a.y) * u1)
                    var seg = Path()
                    seg.move(to: p0)
                    seg.addLine(to: p1)
                    let w = CGFloat(1.2 + 8 * r2 * r2)
                    let lit = 0.2 + 0.7 * r1 * r1 + 0.3 * fresh
                    g.stroke(seg, with: .color(RevontuletColor.iceCold.opacity(0.12 * lit)), style: StrokeStyle(lineWidth: w * 1.5, lineCap: .round))
                    g.stroke(seg, with: .color(RevontuletColor.frost.opacity(0.6 * lit)), style: StrokeStyle(lineWidth: max(0.8, w * 0.45), lineCap: .butt))
                    if r2 > 0.55 {
                        // A small chip of glass sitting on the edge, catching the light.
                        let m = CGPoint(x: (p0.x + p1.x) / 2, y: (p0.y + p1.y) / 2)
                        var chip = Path()
                        chip.move(to: CGPoint(x: m.x - 3, y: m.y - 1))
                        chip.addLine(to: CGPoint(x: m.x + 1, y: m.y - 4))
                        chip.addLine(to: CGPoint(x: m.x + 3, y: m.y + 2))
                        chip.closeSubpath()
                        g.fill(chip, with: .color(Color.white.opacity(0.5 * lit)))
                    }
                }
            }
        }
    }

    /// Fine white-blue hairlines racing out from a hit and fading with distance.
    private func hairlines(_ ctx: inout GraphicsContext, _ list: [RevontuletArt.Crack], age: Double) {
        guard age >= 0 else { return }
        let flash = max(0, 1 - age / 0.35)
        for crack in list {
            let f = min(1, max(0, (age - crack.delay) / 0.24))
            guard f > 0 else { continue }
            let n = crack.points.count - 1
            let shown = Double(n) * f
            for i in 0..<n where Double(i) < shown {
                let a = crack.points[i]
                var b = crack.points[i + 1]
                let part = min(1, shown - Double(i))
                if part < 1 { b = CGPoint(x: a.x + (b.x - a.x) * CGFloat(part), y: a.y + (b.y - a.y) * CGFloat(part)) }
                let fade = pow(1 - Double(i) / Double(n), 1.3)
                var seg = Path()
                seg.move(to: a)
                seg.addLine(to: b)
                ctx.stroke(seg, with: .color(RevontuletColor.hairline.opacity((0.55 + 0.4 * flash) * fade)),
                           style: StrokeStyle(lineWidth: crack.width * CGFloat(0.5 + 0.5 * fade), lineCap: .round))
            }
        }
    }

    // MARK: Fault lines: light leaking through

    private func faults(_ ctx: inout GraphicsContext) {
        guard [RevontuletBeat.intro, .choice, .trace, .sling, .flight, .impact].contains(e.beat), e.round < art.faults.count else { return }
        let f = art.faults[e.round]
        let chosen = e.choice
        var easy = 0.0, hard = 0.0
        switch e.beat {
        case .intro:
            easy = 0.35; hard = 0.35
        case .choice:
            let k = min(1, max(0, since / 0.35))
            easy = k; hard = k
        case .impact:
            let k = max(0, 1 - since / 0.3)
            easy = chosen == .easy ? k : 0; hard = chosen == .hard ? k : 0
        default:
            let k = min(1, max(0, (now - (e.records.last?.chosenUptime ?? now)) / 0.25))
            easy = chosen == .easy ? 1 : 0.3 * (1 - k)
            hard = chosen == .hard ? 1 : 0.3 * (1 - k)
        }
        let sharp = ctx.resolve(Image("world-night"))
        if easy > 0.01 { leak(&ctx, f.easy, glow: easy, sharp: sharp) }
        if hard > 0.01 { vein(&ctx, f.hard, glow: hard, sharp: sharp) }
    }

    /// The thin low crack: a hairline window with a faint warm-white leak and one glint.
    private func leak(_ ctx: inout GraphicsContext, _ f: RevontuletArt.Fault, glow: Double, sharp: GraphicsContext.ResolvedImage) {
        let pulse = glow * (0.85 + 0.15 * sin(now * 2.4))
        var g = ctx
        g.blendMode = .plusLighter
        softEllipse(&g, f.center, rx: f.length * 0.7, ry: f.length * 0.32, [RevontuletColor.warmWhite.opacity(0.16 * pulse), RevontuletColor.amber.opacity(0.05 * pulse)])
        var w = ctx
        w.clip(to: f.window)
        w.draw(sharp, in: art.skyRect)
        w.blendMode = .plusLighter
        w.fill(f.window, with: .color(RevontuletColor.warmWhite.opacity(0.42 * pulse)))
        let p = f.knots[2]
        let tw = 0.5 + 0.5 * pow(0.5 + 0.5 * sin(now * 1.7), 3)
        glint(&g, at: p, size: 7, alpha: 0.8 * pulse * tw)
    }

    /// The vein: a long, wide, branching window with aurora light pouring out of it, a
    /// shimmer travelling along it and the three knots of the combo pulsing in order.
    private func vein(_ ctx: inout GraphicsContext, _ f: RevontuletArt.Fault, glow: Double, sharp: GraphicsContext.ResolvedImage) {
        let pulse = glow * (0.82 + 0.18 * sin(now * 1.3 + 1))
        // Each round's vein promises more: more light pouring out, a wider glow.
        let grand = 1 + 0.25 * Double(min(e.round, 2))
        var g = ctx
        g.blendMode = .plusLighter
        // Light pouring up out of the vein: soft rays, teal into violet.
        for (i, p) in f.line.enumerated() where i % 3 == 1 {
            let sway = CGFloat(sin(now * 0.7 + Double(i))) * 4
            let h = CGFloat((52 + 30 * sin(Double(i) * 1.7 + now * 0.5)) * grand)
            let rect = CGRect(x: p.x - 13 + sway, y: p.y - h, width: 26, height: h)
            g.fill(Path(ellipseIn: rect), with: .linearGradient(
                Gradient(colors: [.clear, RevontuletColor.violet.opacity(0.1 * pulse), RevontuletColor.teal.opacity(0.22 * pulse)]),
                startPoint: CGPoint(x: rect.midX, y: rect.minY), endPoint: CGPoint(x: rect.midX, y: rect.maxY)))
        }
        softEllipse(&g, f.center, rx: f.length * 0.62 * CGFloat(grand), ry: f.length * 0.36 * CGFloat(grand),
                    [RevontuletColor.teal.opacity(0.24 * pulse), RevontuletColor.violet.opacity(0.09 * pulse)])
        var w = ctx
        w.clip(to: f.window)
        w.draw(sharp, in: art.skyRect)
        w.blendMode = .plusLighter
        w.fill(f.window, with: .linearGradient(
            Gradient(colors: [RevontuletColor.teal.opacity(0.32 * pulse), RevontuletColor.green.opacity(0.26 * pulse), RevontuletColor.violet.opacity(0.3 * pulse)]),
            startPoint: f.line.first ?? .zero, endPoint: f.line.last ?? .zero))
        g.stroke(f.core, with: .color(RevontuletColor.frost.opacity(0.22 * pulse)), lineWidth: 0.6)
        // A shimmer travelling along it.
        let u = (now / 2.2).truncatingRemainder(dividingBy: 1)
        let sp = f.line[min(f.line.count - 1, Int(u * Double(f.line.count - 1)))]
        g.fill(Path(ellipseIn: CGRect(x: sp.x - 16, y: sp.y - 16, width: 32, height: 32)), with: .radialGradient(
            Gradient(colors: [Color.white.opacity(0.5 * pulse), RevontuletColor.teal.opacity(0.2 * pulse), .clear]),
            center: sp, startRadius: 0, endRadius: 16))
        // The three knots, pulsing in order.
        let cycle = (now / 1.5).truncatingRemainder(dividingBy: 1)
        for (k, p) in f.knots.enumerated() {
            let on = max(0, 1 - abs(cycle - (0.12 + 0.28 * Double(k))) / 0.14)
            let a = (0.35 + 0.65 * on) * pulse
            g.fill(Path(ellipseIn: CGRect(x: p.x - 10, y: p.y - 10, width: 20, height: 20)), with: .radialGradient(
                Gradient(colors: [RevontuletColor.core.opacity(a), RevontuletColor.gold.opacity(0.35 * a), .clear]),
                center: p, startRadius: 0, endRadius: 10))
        }
    }

    private func glint(_ g: inout GraphicsContext, at p: CGPoint, size s: CGFloat, alpha: Double) {
        guard alpha > 0.01 else { return }
        for (w, h) in [(s * 2, s * 0.22), (s * 0.22, s * 2)] {
            g.fill(Path(ellipseIn: CGRect(x: p.x - w / 2, y: p.y - h / 2, width: w, height: h)), with: .radialGradient(
                Gradient(colors: [Color.white.opacity(alpha), .clear]), center: p, startRadius: 0, endRadius: max(w, h) / 2))
        }
    }

    // MARK: Pieces falling and the burst

    /// Pieces knocked out by an impact: their own bits of the wall picture, falling away.
    private func falling(_ ctx: inout GraphicsContext) {
        for (i, s) in art.shards.enumerated() {
            guard let at = art.fallAt[s.facet], now >= at, now < at + 1.3 else { continue }
            let t = now - at
            let v = art.push[i]
            let offset = CGSize(width: v.dx * CGFloat(t), height: v.dy * CGFloat(t) + CGFloat(0.5 * 1100 * t * t))
            let alpha = (1 - smooth(0.5, 1.2, t)) * sinkFade(s.center.y + offset.height)
            shard(&ctx, s, offset: offset, angle: s.spin * 0.5 * t, flip: cos(s.tumble * t + s.phase), alpha: alpha, scale: 1 - 0.3 * t)
        }
    }

    /// The burst: every piece blown out from the hit, slow at first, then real gravity,
    /// tumbling and catching the aurora on an edge; gone within about two seconds. Pieces
    /// fade before they could cross the fox's face or the words.
    private func burst(_ ctx: inout GraphicsContext, age: Double) {
        guard age < 2.6, let origin = art.burstPoint else { return }
        let tau: Double
        if age < 0.45 { tau = 0.3 * age }
        else if age < 0.95 { let d = age - 0.45; tau = 0.135 + 0.3 * d + 0.7 * d * d }
        else { tau = 0.46 + (age - 0.95) }
        let fade = 1 - smooth(1.3, 2.2, age)
        let fox = L.foxSquare(.full)
        let head = CGPoint(x: fox.midX, y: fox.minY + fox.height * 0.4)
        for (i, s) in art.shards.enumerated() where (art.fallAt[s.facet].map { $0 > (e.burstAt ?? 0) } ?? true) {
            let v = art.push[i]
            let offset = CGSize(width: v.dx * CGFloat(tau), height: v.dy * CGFloat(tau) + CGFloat(0.5 * 1100 * tau * tau))
            let p = CGPoint(x: s.center.x + offset.width, y: s.center.y + offset.height)
            let clear = smooth(Double(fox.width) * 0.36, Double(fox.width) * 0.58, Double(dist(p, head)))
            let alpha = fade * clear * sinkFade(p.y)
            guard alpha > 0.01 else { continue }
            shard(&ctx, s, offset: offset, angle: s.spin * tau, flip: cos(s.tumble * tau + s.phase), alpha: alpha,
                  scale: 1 - 0.35 * smooth(0, 2, age))
        }
        // Fine glitter dust, drifting and twinkling.
        var g = ctx
        g.blendMode = .plusLighter
        for d in art.glitter where age < d.life {
            let dx = d.p.x - origin.x, dy = d.p.y - origin.y
            let away = 0.25 * CGFloat(tau)
            let p = CGPoint(x: d.p.x + dx * away + d.v.dx * CGFloat(age), y: d.p.y + dy * away + d.v.dy * CGFloat(age) + CGFloat(40 * age * age))
            let tw = 0.5 + 0.5 * sin(age * 14 + d.phase)
            let a = tw * (1 - age / d.life) * sinkFade(p.y) * smooth(Double(fox.width) * 0.3, Double(fox.width) * 0.5, Double(dist(p, head)))
            g.fill(Path(ellipseIn: CGRect(x: p.x - d.r, y: p.y - d.r, width: d.r * 2, height: d.r * 2)),
                   with: .color(RevontuletColor.frost.opacity(0.9 * a)))
        }
    }

    /// Pieces sink into the snow and fade well before the line of words.
    private func sinkFade(_ y: CGFloat) -> Double {
        1 - smooth(Double(L.wall.maxY + L.size.height * 0.05), Double(L.wall.maxY + L.size.height * 0.17), Double(y))
    }

    /// One piece in flight: its own bit of the wall, squashed as it turns in depth, bright
    /// along one or two edges with the aurora's tint, a white glint when it turns face-on.
    private func shard(_ ctx: inout GraphicsContext, _ s: RevontuletArt.Shard, offset: CGSize, angle: Double, flip: Double,
                       alpha: Double, scale: Double) {
        guard alpha > 0.01, let image = s.image else { return }
        var g = ctx
        g.translateBy(x: s.center.x + offset.width, y: s.center.y + offset.height)
        g.rotate(by: .radians(angle))
        let face = abs(flip)
        g.scaleBy(x: CGFloat(max(0.08, face) * scale), y: CGFloat(scale))
        g.opacity = alpha * (0.36 + 0.3 * face)
        g.draw(Image(decorative: image, scale: 2), in: s.bounds)
        g.opacity = alpha
        g.blendMode = .plusLighter
        // The aurora bending in the glass: a band of its colours sliding as the piece turns.
        let slide = CGFloat(sin(angle * 1.7 + s.phase)) * s.bounds.width
        g.fill(s.local, with: .linearGradient(
            Gradient(colors: [.clear, RevontuletColor.teal.opacity(0.22), RevontuletColor.violet.opacity(0.18), .clear]),
            startPoint: CGPoint(x: s.bounds.minX + slide, y: s.bounds.minY), endPoint: CGPoint(x: s.bounds.maxX + slide, y: s.bounds.maxY)))
        g.fill(s.local, with: .color(RevontuletColor.frost.opacity(0.06 + 0.2 * pow(face, 3))))
        let catchLight = 0.3 + 0.7 * pow(abs(sin(angle * 1.2 + s.phase)), 2)
        let hue: Color = [RevontuletColor.green, RevontuletColor.teal, RevontuletColor.violet][s.hue]
        for edge in s.litEdges {
            var p = Path()
            p.move(to: edge.0)
            p.addLine(to: edge.1)
            g.stroke(p, with: .color(hue.opacity(0.55 * catchLight)), style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
            g.stroke(p, with: .color(Color.white.opacity(0.7 * catchLight)), style: StrokeStyle(lineWidth: 0.8, lineCap: .round))
        }
        if face > 0.9 {
            let k = (face - 0.9) * 10
            let w = s.bounds.width * 0.9
            g.fill(Path(ellipseIn: CGRect(x: -w / 2, y: -1.2, width: w, height: 2.4)), with: .linearGradient(
                Gradient(colors: [.clear, Color.white.opacity(0.75 * k), .clear]),
                startPoint: CGPoint(x: -w / 2, y: 0), endPoint: CGPoint(x: w / 2, y: 0)))
        }
    }

    /// Where the spark lands: a warm flash on the ice and a puff of ice dust.
    private func landingLight(_ ctx: inout GraphicsContext) {
        var g = ctx
        g.blendMode = .plusLighter
        for (k, hit) in e.impacts.enumerated() {
            let t = now - hit.time
            guard t >= 0, t < 1.0 else { continue }
            if t < 0.45 {
                let k2 = pow(1 - t / 0.45, 2)
                let big = hit.hard ? 1.0 + 0.25 * Double(hit.embersHit) : 0.6
                let r = CGFloat((22 + 120 * t / 0.45) * big)
                g.fill(Path(ellipseIn: CGRect(x: hit.point.x - r, y: hit.point.y - r, width: r * 2, height: r * 2)), with: .radialGradient(
                    Gradient(colors: [RevontuletColor.core.opacity(0.85 * k2), RevontuletColor.gold.opacity(0.45 * k2), RevontuletColor.amber.opacity(0.15 * k2), .clear]),
                    center: hit.point, startRadius: 0, endRadius: r))
            }
            // Light racing across the ice from the hit.
            if t < 0.5, !hit.breaking {
                let r = CGFloat(t / 0.5) * L.wall.width * 0.9
                let k = 1 - t / 0.5
                var sweep = g
                sweep.clip(to: art.standing(at: now, burstAt: e.burstAt))
                sweep.fill(Path(ellipseIn: CGRect(x: hit.point.x - r, y: hit.point.y - r, width: r * 2, height: r * 2)), with: .radialGradient(
                    Gradient(stops: [.init(color: .clear, location: 0.7), .init(color: RevontuletColor.frost.opacity(0.22 * k), location: 0.92),
                                     .init(color: .clear, location: 1)]), center: hit.point, startRadius: 0, endRadius: max(r, 1)))
            }
            // Snow puffing off the wall's foot below the hit.
            if t < 0.9 {
                let foot = CGPoint(x: hit.point.x, y: L.wall.maxY - 20)
                for i in 0..<(8 + hit.pieces * 3) {
                    let a = -Double.pi / 2 + (Double(i % 7) - 3) * 0.35
                    let sp = 40 + 26 * Double(i % 4)
                    let q = CGPoint(x: foot.x + CGFloat(cos(a) * sp * t) + CGFloat((i % 5) - 2) * 9,
                                    y: foot.y + CGFloat(sin(a) * sp * t + 120 * t * t))
                    let o = (1 - t / 0.9) * 0.8
                    let rr: CGFloat = 1.6 + CGFloat(i % 3)
                    ctx.fill(Path(ellipseIn: CGRect(x: q.x - rr, y: q.y - rr, width: rr * 2, height: rr * 2)), with: .color(Color.white.opacity(o)))
                }
            }
            for (i, m) in art.motes.enumerated() where i < 10 + hit.pieces * 4 {
                guard t < m.life else { continue }
                let a = m.angle + Double(k)
                let x = hit.point.x + CGFloat(cos(a) * m.speed * t)
                let y = hit.point.y + CGFloat(sin(a) * m.speed * t + 0.5 * 420 * t * t)
                let o = 1 - t / m.life
                g.fill(Path(ellipseIn: CGRect(x: x - m.size, y: y - m.size, width: m.size * 2, height: m.size * 2)),
                       with: .color(RevontuletColor.frost.opacity(0.8 * o)))
            }
        }
    }

    /// The pane's foot buried in a drift of the world's own snow, with a soft contact shadow.
    private func drift(_ ctx: inout GraphicsContext) {
        let alpha = 1 - smooth(0.2, 1.6, burstAge ?? -1)
        guard alpha > 0.01 else { return }
        let wall = L.wall
        let top = wall.maxY - 22
        var mound = Path()
        mound.move(to: CGPoint(x: wall.minX, y: wall.maxY + 40))
        var x = wall.minX
        while x <= wall.maxX {
            let wave: Double = 6 * sin(Double(x) * 0.035) + 3.5 * sin(Double(x) * 0.12 + 1)
            mound.addLine(to: CGPoint(x: x, y: top + CGFloat(wave)))
            x += 6
        }
        mound.addLine(to: CGPoint(x: wall.maxX, y: wall.maxY + 40))
        mound.closeSubpath()
        var shadow = ctx
        shadow.translateBy(x: 0, y: -4)
        shadow.fill(mound, with: .color(Color(red: 0.08, green: 0.12, blue: 0.3).opacity(0.25 * alpha)))
        // The world's own snow: a lit lip, periwinkle body, melting into the painting below.
        let lip = Color(red: 0.84, green: 0.89, blue: 1.0), body = Color(red: 0.72, green: 0.8, blue: 0.99)
        ctx.fill(mound, with: .linearGradient(
            Gradient(stops: [.init(color: lip.opacity(alpha), location: 0), .init(color: body.opacity(alpha), location: 0.45),
                             .init(color: body.opacity(0.0), location: 1)]),
            startPoint: CGPoint(x: 0, y: top - 8), endPoint: CGPoint(x: 0, y: wall.maxY + 36)))
    }

    // MARK: - In front: the spark, the half-circle, the sling, the embers, the snow on the fox

    func front(_ ctx: inout GraphicsContext, size: CGSize) {
        if let s = sparkState(), e.beat != .flight {
            pool(&ctx, under: s.p, size: s.size, heat: s.heat)
        }
        switch e.beat {
        case .trace: arc(&ctx)
        case .sling: sling(&ctx)
        default: break
        }
        if let f = e.flight, e.beat == .flight {
            let fnow = e.flightClock(now)
            trail(&ctx, f, at: fnow)
            embers(&ctx, f, at: fnow)
        }
        if let s = sparkState() {
            spark(&ctx, at: s.p, size: s.size, heat: s.heat)
        }
        snow(&ctx)
        touchFlash(&ctx)
        hint(&ctx)
    }

    private func sparkState() -> (p: CGPoint, size: Double, heat: Double)? {
        switch e.beat {
        case .intro:
            return (L.anchor, 1.15 + 0.08 * sin(now * 2.2), 0.85)
        case .choice:
            let grow = e.round == 0 ? 1 : min(1, since / 0.3)
            return (L.anchor, 1.15 * grow, 0.85)
        case .trace:
            return (L.anchor, 1.15 + 0.6 * e.progress, 0.85 + 0.15 * e.progress)
        case .sling:
            let level = Double(hypot(e.pull.dx, e.pull.dy) / L.maxPull)
            let pop = since < 0.25 ? 0.35 * (1 - since / 0.25) : 0
            return (e.sparkPoint(now), 1.75 + pop + 0.2 * level, 1)
        case .flight:
            guard let f = e.flight else { return nil }
            let fnow = e.flightClock(now)
            let lit = f.emberHitAt.enumerated().filter { $0.element != nil && fnow - f.launch >= f.emberT[$0.offset] }.count
            return (f.point(at: fnow), f.foxOwn ? 1.8 : 1.75 + 0.25 * Double(lit), 1)
        default:
            return nil
        }
    }

    /// A soft pool of gold light on the snow under the spark.
    private func pool(_ ctx: inout GraphicsContext, under p: CGPoint, size s: Double, heat: Double) {
        let y = L.anchor.y + L.size.height * 0.07
        let w = CGFloat(120 * s), h = CGFloat(24 * s)
        var g = ctx
        g.blendMode = .plusLighter
        softEllipse(&g, CGPoint(x: p.x, y: y), rx: w / 2, ry: h / 2,
                    [RevontuletColor.gold.opacity(0.3 * heat), RevontuletColor.amber.opacity(0.08 * heat)])
    }

    /// The fox's spark, the one warm thing in a cold world: a white-gold core in layered soft
    /// halos, fine rays turning slowly, a few motes circling.
    func spark(_ ctx: inout GraphicsContext, at p: CGPoint, size s: Double, heat: Double) {
        guard s > 0.02 else { return }
        // A warm base in normal blending, so the light still reads over bright snow.
        softEllipse(&ctx, p, rx: CGFloat(26 * s), ry: CGFloat(26 * s),
                    [RevontuletColor.amber.opacity(0.42 * heat), RevontuletColor.amber.opacity(0.16 * heat)])
        var g = ctx
        g.blendMode = .plusLighter
        let flick = 1 + 0.08 * sin(now * 23) + 0.05 * sin(now * 37 + 1.3)
        let S = CGFloat(s)
        func halo(_ r: CGFloat, _ colors: [Color]) {
            g.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)),
                   with: .radialGradient(Gradient(colors: colors), center: p, startRadius: 0, endRadius: r))
        }
        halo(46 * S, [RevontuletColor.amber.opacity(0.16 * heat), RevontuletColor.amber.opacity(0.05 * heat), .clear])
        halo(25 * S * CGFloat(flick), [RevontuletColor.gold.opacity(0.42 * heat), RevontuletColor.amber.opacity(0.14 * heat), .clear])
        halo(11 * S * CGFloat(flick), [RevontuletColor.core.opacity(0.95), RevontuletColor.gold.opacity(0.7 * heat), .clear])
        // Fine rays, turning slowly.
        let turn = now * 0.35
        for i in 0..<8 {
            let a = turn + Double(i) / 8 * 2 * .pi
            let len = CGFloat(14 + 10 * Double(i % 2)) * S * CGFloat(0.85 + 0.15 * flick)
            let half = 1.1 * S
            let dir = CGPoint(x: CGFloat(cos(a)), y: CGFloat(sin(a)))
            let side = CGPoint(x: -dir.y * half, y: dir.x * half)
            var ray = Path()
            ray.move(to: CGPoint(x: p.x + side.x, y: p.y + side.y))
            ray.addLine(to: CGPoint(x: p.x + dir.x * len, y: p.y + dir.y * len))
            ray.addLine(to: CGPoint(x: p.x - side.x, y: p.y - side.y))
            ray.closeSubpath()
            g.fill(ray, with: .linearGradient(Gradient(colors: [RevontuletColor.core.opacity(0.5 * heat), .clear]),
                                              startPoint: p, endPoint: CGPoint(x: p.x + dir.x * len, y: p.y + dir.y * len)))
        }
        halo(4.2 * S, [Color.white, Color.white.opacity(0.6), .clear])
        for i in 0..<4 {
            let di = Double(i)
            let a = now * (1.1 + 0.37 * di) * (i % 2 == 0 ? 1 : -1) + di * 1.6
            let r = (12 + 4 * di) * s
            let q = CGPoint(x: p.x + CGFloat(cos(a) * r), y: p.y + CGFloat(sin(a) * r * 0.8))
            let o = (0.35 + 0.65 * abs(sin(now * 3 + di))) * heat
            let m = 1.3 * S
            g.fill(Path(ellipseIn: CGRect(x: q.x - m * 2, y: q.y - m * 2, width: m * 4, height: m * 4)), with: .radialGradient(
                Gradient(colors: [RevontuletColor.gold.opacity(o), .clear]), center: q, startRadius: 0, endRadius: m * 2))
        }
    }

    /// The half-circle: fine beads of light; the traced part fills as a tapered ribbon with a
    /// bright head, and light streams from it into the spark.
    private func arc(_ ctx: inout GraphicsContext) {
        let arc = e.arc
        let appear = min(1, max(0, since / 0.15))
        guard appear > 0 else { return }
        var g = ctx
        g.blendMode = .plusLighter
        let count = max(12, Int(Double.pi * Double(arc.radius) / 9))
        for i in 0..<count {
            let s = (Double(i) + 0.5) / Double(count)
            guard s > e.progress else { continue }
            let p = arc.point(s, reversed: e.reversed)
            let tw = 0.6 + 0.4 * sin(now * 2.6 - Double(i) * 0.55)
            softEllipse(&ctx, p, rx: 5, ry: 5, [RevontuletColor.amber.opacity(0.5 * tw * appear), RevontuletColor.amber.opacity(0.18 * tw * appear)])
            g.fill(Path(ellipseIn: CGRect(x: p.x - 1.6, y: p.y - 1.6, width: 3.2, height: 3.2)), with: .color(RevontuletColor.core.opacity(0.9 * tw * appear)))
        }
        if e.progress <= 0.001 {
            let start = arc.point(0, reversed: e.reversed)
            let pulse = 0.5 + 0.5 * sin(now * 4)
            spark(&g, at: start, size: 0.32 + 0.08 * pulse, heat: 0.9)
            let u = (since.truncatingRemainder(dividingBy: 1.7)) / 1.2
            if u < 1 {
                let p = arc.point(u, reversed: e.reversed)
                g.fill(Path(ellipseIn: CGRect(x: p.x - 7, y: p.y - 7, width: 14, height: 14)), with: .radialGradient(
                    Gradient(colors: [RevontuletColor.gold.opacity(0.6 * (1 - u)), .clear]), center: p, startRadius: 0, endRadius: 7))
            }
        } else {
            let m = max(3, Int(48 * e.progress))
            for j in 0..<m {
                let s0 = e.progress * Double(j) / Double(m), s1 = e.progress * Double(j + 1) / Double(m)
                let tt = Double(j + 1) / Double(m)
                var seg = Path()
                seg.move(to: arc.point(s0, reversed: e.reversed))
                seg.addLine(to: arc.point(s1, reversed: e.reversed))
                ctx.stroke(seg, with: .color(RevontuletColor.amber.opacity(0.3)), style: StrokeStyle(lineWidth: CGFloat(3 + 9 * pow(tt, 1.6)), lineCap: .round))
            }
            for (pass, k) in [(0, 3.2), (1, 1.0)] {
                for j in 0..<m {
                    let s0 = e.progress * Double(j) / Double(m), s1 = e.progress * Double(j + 1) / Double(m)
                    let tt = Double(j + 1) / Double(m)
                    var seg = Path()
                    seg.move(to: arc.point(s0, reversed: e.reversed))
                    seg.addLine(to: arc.point(s1, reversed: e.reversed))
                    let w = CGFloat((1.0 + 4.6 * pow(tt, 1.6)) * k)
                    let color: Color = pass == 0 ? RevontuletColor.amber.opacity(0.16) : (tt > 0.85 ? RevontuletColor.core : RevontuletColor.gold.opacity(0.95))
                    g.stroke(seg, with: .color(color), style: StrokeStyle(lineWidth: w, lineCap: .round))
                }
            }
            for i in 0..<10 {
                let s = e.progress * (Double(i) + 0.5) / 10
                let from = arc.point(s, reversed: e.reversed)
                let phase = (now * 1.6 + Double(i) * 0.37).truncatingRemainder(dividingBy: 1)
                let q = CGPoint(x: from.x + (L.anchor.x - from.x) * CGFloat(phase), y: from.y + (L.anchor.y - from.y) * CGFloat(phase))
                let o = sin(phase * .pi) * 0.7
                g.fill(Path(ellipseIn: CGRect(x: q.x - 1.5, y: q.y - 1.5, width: 3, height: 3)), with: .color(RevontuletColor.gold.opacity(o)))
            }
            if e.progress < 1 {
                spark(&g, at: arc.point(e.progress, reversed: e.reversed), size: 0.6, heat: 1)
            }
        }
    }

    /// The sling: one elastic thread of light from the spark's resting place to the pulled
    /// spark, thinner as it stretches, and a path of light beads toward the chosen line,
    /// brighter the further it is pulled.
    private func sling(_ ctx: inout GraphicsContext) {
        let spark = e.sparkPoint(now)
        let level = Double(hypot(e.pull.dx, e.pull.dy) / L.maxPull)
        var g = ctx
        g.blendMode = .plusLighter
        if level > 0.02 {
            let mid = CGPoint(x: (L.anchor.x + spark.x) / 2, y: (L.anchor.y + spark.y) / 2 + CGFloat((1 - level) * 6))
            var thread = Path()
            thread.move(to: L.anchor)
            thread.addQuadCurve(to: spark, control: mid)
            let w = CGFloat(1.6 + 2.6 * level)
            ctx.stroke(thread, with: .color(RevontuletColor.amber.opacity(0.35)), style: StrokeStyle(lineWidth: w * 2.4, lineCap: .round))
            g.stroke(thread, with: .color(RevontuletColor.gold.opacity(0.28 + 0.2 * level)), style: StrokeStyle(lineWidth: w * 3.2, lineCap: .round))
            g.stroke(thread, with: .color(RevontuletColor.core.opacity(0.85)), style: StrokeStyle(lineWidth: w, lineCap: .round))
            g.fill(Path(ellipseIn: CGRect(x: L.anchor.x - 3, y: L.anchor.y - 3, width: 6, height: 6)), with: .color(Color.white.opacity(0.8)))
        }
        if let effort = e.choice {
            let to = L.target(round: e.round, effort: effort)
            let c = RevontuletLayout.flightControl(from: spark, to: to, pull: e.pull)
            let path = RevontuletFlight(launch: 0, from: spark, control: c, to: to, duration: 1, hard: false, foxOwn: false)
            let a = 0.15 + 0.85 * level
            for i in 0..<16 {
                let u = 0.06 + 0.88 * Double(i) / 15
                let p = path.bezier(u)
                let r = CGFloat((2.2 + 1.8 * level) * (1 - 0.45 * u))
                let o = a * (1 - 0.55 * u) * (0.75 + 0.25 * sin(now * 5 - Double(i) * 0.6))
                softEllipse(&ctx, p, rx: r * 2.6, ry: r * 2.6, [RevontuletColor.amber.opacity(0.5 * o), RevontuletColor.amber.opacity(0.15 * o)])
                g.fill(Path(ellipseIn: CGRect(x: p.x - r * 2, y: p.y - r * 2, width: r * 4, height: r * 4)), with: .radialGradient(
                    Gradient(colors: [RevontuletColor.core.opacity(o), RevontuletColor.gold.opacity(0.4 * o), .clear]),
                    center: p, startRadius: 0, endRadius: r * 2))
            }
        }
    }

    /// The spark's trail: a tapering stroke of warm light and embers drifting down from it.
    private func trail(_ ctx: inout GraphicsContext, _ f: RevontuletFlight, at now: Double) {
        var g = ctx
        g.blendMode = .plusLighter
        let span = 0.32
        let n = 24
        var prev = f.point(at: now)
        for i in 1...n {
            let t = now - span * Double(i) / Double(n)
            guard t >= f.launch else { break }
            let p = f.point(at: t)
            let k = 1 - Double(i) / Double(n)
            var seg = Path()
            seg.move(to: prev)
            seg.addLine(to: p)
            g.stroke(seg, with: .color(RevontuletColor.gold.opacity(0.45 * k)), style: StrokeStyle(lineWidth: CGFloat(1 + 9 * k), lineCap: .round))
            g.stroke(seg, with: .color(RevontuletColor.core.opacity(0.7 * k * k)), style: StrokeStyle(lineWidth: CGFloat(0.5 + 2.4 * k), lineCap: .round))
            prev = p
        }
        let slot = 0.03
        var t = (floor(now / slot)) * slot
        while t > now - 0.8 && t >= f.launch {
            let age = now - t
            let p = f.point(at: t)
            let seed = sin(t * 913.7) * 0.5 + 0.5
            let x = p.x + CGFloat((seed - 0.5) * 18 * age * 3)
            let y = p.y + CGFloat(22 * age + 30 * age * age)
            let o = (1 - age / 0.8) * 0.85
            let m: CGFloat = 1.1 + CGFloat(seed)
            g.fill(Path(ellipseIn: CGRect(x: x - m, y: y - m, width: m * 2, height: m * 2)),
                   with: .color((seed > 0.6 ? RevontuletColor.amber : RevontuletColor.gold).opacity(o)))
            t -= slot
        }
    }

    /// The embers on the hard path: they flash ahead of the spark, a soft halo closing in on
    /// them as the spark comes; a lit one flares and waits to be swallowed.
    private func embers(_ ctx: inout GraphicsContext, _ f: RevontuletFlight, at now: Double) {
        guard f.hard else { return }
        let t = now - f.launch
        var g = ctx
        g.blendMode = .plusLighter
        for i in f.emberU.indices {
            let show = f.emberT[i] - RevontuletFlight.emberLead
            guard t >= show else { continue }
            let p = f.emberPoint(i)
            let age = t - show
            let pass = t - f.emberT[i]
            var alpha = min(1, age / 0.08)
            if let hit = f.emberHitAt[i] {
                let ha = now - hit
                if pass > 0 { alpha *= max(0, 1 - pass / 0.12) }
                if ha < 0.4 {
                    let k = 1 - ha / 0.4
                    for ray in 0..<8 {
                        let a = Double(ray) / 8 * 2 * .pi + Double(i)
                        let len = CGFloat(10 + 30 * (1 - k))
                        var r = Path()
                        r.move(to: CGPoint(x: p.x + CGFloat(cos(a)) * 6, y: p.y + CGFloat(sin(a)) * 6))
                        r.addLine(to: CGPoint(x: p.x + CGFloat(cos(a)) * len, y: p.y + CGFloat(sin(a)) * len))
                        g.stroke(r, with: .color(RevontuletColor.gold.opacity(0.8 * k)), style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
                    }
                }
                ember(&g, at: p, size: 1.25, alpha: alpha, lit: true)
            } else {
                if f.emberMissed[i] { alpha *= max(0, 1 - (pass - RevontuletFlight.emberGrace) / 0.3) }
                else if pass > 0 { alpha *= max(0.55, 1 - pass / 0.5) }
                let closing = max(0, min(1, -pass / RevontuletFlight.emberLead))
                if closing > 0 {
                    let r = CGFloat(12 + 30 * closing)
                    g.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)), with: .radialGradient(
                        Gradient(stops: [.init(color: .clear, location: 0.55),
                                         .init(color: RevontuletColor.ember.opacity(0.4 * alpha), location: 0.82),
                                         .init(color: .clear, location: 1)]),
                        center: p, startRadius: 0, endRadius: r))
                }
                ember(&g, at: p, size: 0.9 + 0.12 * sin(age * 9), alpha: alpha, lit: false)
            }
        }
    }

    private func ember(_ g: inout GraphicsContext, at p: CGPoint, size s: Double, alpha: Double, lit: Bool) {
        guard alpha > 0.01 else { return }
        let S = CGFloat(s)
        let flick = 1 + 0.15 * sin(now * 29 + Double(p.x))
        g.fill(Path(ellipseIn: CGRect(x: p.x - 22 * S, y: p.y - 22 * S, width: 44 * S, height: 44 * S)), with: .radialGradient(
            Gradient(colors: [RevontuletColor.ember.opacity(0.42 * alpha), RevontuletColor.ember.opacity(0.1 * alpha), .clear]),
            center: p, startRadius: 0, endRadius: 22 * S))
        let core = 4.5 * S * CGFloat(flick)
        g.fill(Path(ellipseIn: CGRect(x: p.x - core, y: p.y - core, width: core * 2, height: core * 2)), with: .radialGradient(
            Gradient(colors: [RevontuletColor.core.opacity(alpha), (lit ? RevontuletColor.gold : RevontuletColor.amber).opacity(0.8 * alpha), .clear]),
            center: p, startRadius: 0, endRadius: core))
        for i in 0..<4 {
            let a = now * 2.3 + Double(i) * 1.57
            let r = CGFloat(7 + 3 * sin(now * 5 + Double(i))) * S
            let q = CGPoint(x: p.x + CGFloat(cos(a)) * r, y: p.y + CGFloat(sin(a)) * r)
            g.fill(Path(ellipseIn: CGRect(x: q.x - 1, y: q.y - 1, width: 2, height: 2)), with: .color(RevontuletColor.gold.opacity(0.8 * alpha)))
        }
    }

    /// Snow lying on the fox's fur in the warmth beat: soft clumps with a blue shadow; brushed
    /// snow slides and puffs into powder.
    private func snow(_ ctx: inout GraphicsContext) {
        guard let w = e.warmthAt, now >= w else { return }
        let sq = L.foxSquare(e.beat == .sleep || e.beat == .done ? .rest : .warm)
        for (i, s) in art.specks.enumerated() {
            let land = w + 0.25 + s.delay
            guard now >= land - 0.7 else { continue }
            var p = CGPoint(x: sq.midX + s.offset.x * sq.width, y: sq.midY + s.offset.y * sq.height)
            var alpha = 1.0
            var r = s.radius * sq.width / 300
            if now < land {
                let k = (land - now) / 0.7
                p.y -= CGFloat(k * k) * 70
                alpha = 1 - k
            }
            if let gone = art.speckGone[i], now >= gone {
                let a = now - gone
                guard a < 0.7 else { continue }
                // It slides a little down the fur, then puffs into powder.
                let side: CGFloat = s.offset.x < 0 ? -1 : 1
                if a < 0.18 {
                    p.y += CGFloat(a / 0.18) * 6
                } else {
                    let b = a - 0.18
                    for k in 0..<6 {
                        let ang = Double(k) * 1.05 + Double(i)
                        let q = CGPoint(x: p.x + side * CGFloat(b) * 40 + CGFloat(cos(ang) * b * 30),
                                        y: p.y + 6 + CGFloat(sin(ang) * b * 22 + 60 * b * b))
                        let o = 1 - b / 0.52
                        ctx.fill(Path(ellipseIn: CGRect(x: q.x - 1.2, y: q.y - 1.2, width: 2.4, height: 2.4)), with: .color(Color.white.opacity(0.85 * o)))
                    }
                    continue
                }
            }
            // A soft clump: overlapping lobes, a hint of blue shadow underneath.
            for lobe in s.lobes {
                let c = CGPoint(x: p.x + CGFloat(lobe.dx) * r, y: p.y + CGFloat(lobe.dy) * r + r * 0.35)
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r * 0.7, width: r * 2, height: r * 1.4)),
                         with: .color(Color(red: 0.5, green: 0.58, blue: 0.86).opacity(0.22 * alpha)))
            }
            for lobe in s.lobes {
                let c = CGPoint(x: p.x + CGFloat(lobe.dx) * r, y: p.y + CGFloat(lobe.dy) * r)
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r * 0.8, width: r * 2, height: r * 1.6)), with: .radialGradient(
                    Gradient(colors: [Color.white.opacity(alpha), Color.white.opacity(0.9 * alpha), RevontuletColor.snowShade.opacity(0.75 * alpha)]),
                    center: CGPoint(x: c.x - r * 0.3, y: c.y - r * 0.35), startRadius: 0, endRadius: r * 1.2))
            }
        }
    }

    /// Every finger that lands is answered in the same frame: a small bloom of frost light.
    private func touchFlash(_ ctx: inout GraphicsContext) {
        guard let p = e.lastDown, e.beat != .intro else { return }
        let a = now - e.lastDownAt
        guard a >= 0, a < 0.32 else { return }
        let k = 1 - a / 0.32
        let r = CGFloat(14 + 30 * (1 - k * k))
        var g = ctx
        g.blendMode = .plusLighter
        g.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)), with: .radialGradient(
            Gradient(colors: [RevontuletColor.frost.opacity(0.4 * k), RevontuletColor.teal.opacity(0.18 * k), .clear]),
            center: p, startRadius: 0, endRadius: r))
    }

    /// After about four seconds of nothing, a soft ghost finger shows the gesture. It never blocks.
    private func hint(_ ctx: inout GraphicsContext) {
        if let c = coach, c.visible(now) { return }
        let quiet = now - max(e.lastInputAt, e.beatStart + (e.beat == .warmth ? RevontuletEngine.strokesFrom : 0))
        guard quiet > 4, e.finger == nil else { return }
        let fade = min(1, (quiet - 4) / 0.6)
        let t = quiet - 4
        var p: CGPoint
        var a: Double
        switch e.beat {
        case .choice:
            let f = L.faults(round: e.round)
            let loop = t.truncatingRemainder(dividingBy: 2.6)
            let target = (Int(t / 2.6) % 2 == 0) ? f.hard[f.hard.count / 2] : f.easy[f.easy.count / 2]
            let k = min(1, loop / 0.8)
            let e2 = 1 - pow(1 - k, 3)
            p = CGPoint(x: L.anchor.x + (target.x - L.anchor.x) * CGFloat(e2), y: L.anchor.y + (target.y - L.anchor.y) * CGFloat(e2) + 18)
            a = loop < 1.6 ? 1 : max(0, 1 - (loop - 1.6) / 0.5)
            if loop > 0.85, loop < 1.2 { press(&ctx, at: p, k: (loop - 0.85) / 0.35, alpha: fade) }
        case .trace:
            let loop = t.truncatingRemainder(dividingBy: 2.4)
            let k = min(1, loop / 1.5)
            let s = e.progress + (1 - e.progress) * (k * k * (3 - 2 * k))
            p = e.arc.point(s, reversed: e.reversed)
            a = loop < 1.6 ? 1 : max(0, 1 - (loop - 1.6) / 0.4)
        case .sling:
            let loop = t.truncatingRemainder(dividingBy: 2.2)
            let k = min(1, loop / 0.9)
            p = CGPoint(x: L.anchor.x, y: L.anchor.y + L.maxPull * 0.85 * CGFloat(1 - pow(1 - k, 2)))
            a = loop < 1.2 ? 1 : max(0, 1 - (loop - 1.2) / 0.4)
        case .warmth:
            guard e.strokesCounted < RevontuletEngine.strokesWanted else { return }
            let loop = t.truncatingRemainder(dividingBy: 2.6)
            let k = min(1, loop / 1.4)
            let sq = L.foxSquare(.warm)
            p = CGPoint(x: sq.midX - sq.width * 0.05, y: sq.minY + sq.height * (0.18 + 0.55 * CGFloat(k * k * (3 - 2 * k))))
            a = loop < 1.6 ? 1 : max(0, 1 - (loop - 1.6) / 0.4)
        default:
            return
        }
        a *= fade
        guard a > 0.01 else { return }
        let r: CGFloat = 17
        ctx.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)), with: .radialGradient(
            Gradient(colors: [Color.white.opacity(0.42 * a), Color.white.opacity(0.22 * a), .clear]),
            center: p, startRadius: 0, endRadius: r))
        ctx.stroke(Path(ellipseIn: CGRect(x: p.x - r * 0.8, y: p.y - r * 0.8, width: r * 1.6, height: r * 1.6)),
                   with: .color(Color.white.opacity(0.35 * a)), lineWidth: 1.5)
    }

    // MARK: - The first-time coach

    /// The veil with soft pools of light around the thing to touch, and the ghost fingertip
    /// showing the move in a slow loop.
    func coachLayer(_ ctx: inout GraphicsContext, size: CGSize) {
        guard let c = coach else { return }
        let a = c.alpha(now)
        guard a > 0.001 else { return }
        let t = now - c.since
        // Pools that only lift the veil (never brighten): centre, horizontal and vertical radius.
        var spots: [(CGPoint, CGFloat, CGFloat)] = []
        switch c.kind {
        case .start: spots = [(L.anchor, 66, 66)]
        case .choice:
            let f = L.faults(round: e.round)
            spots = [(f.easy[f.easy.count / 2], 74, 46), (f.hard[f.hard.count / 2], 110, 70)]
        case .trace: spots = [(L.anchor, L.arcRadius + 48, L.arcRadius + 40)]
        case .sling: spots = [(CGPoint(x: L.anchor.x, y: L.anchor.y + L.maxPull * 0.42), 62, L.maxPull * 0.42 + 46)]
        case .embers:
            if let f = e.flight, f.emberU.indices.contains(c.ember) { spots = [(f.emberPoint(c.ember), 60, 60)] }
        case .stroke:
            let sq = L.foxSquare(.warm)
            spots = [(CGPoint(x: sq.midX, y: sq.midY - sq.height * 0.05), sq.width * 0.5, sq.height * 0.5)]
        }
        // The veil: soft dark navy, about half strength, lifted softly inside each pool.
        ctx.drawLayer { layer in
            layer.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(red: 0.03, green: 0.05, blue: 0.16).opacity(c.kind.veil * a)))
            layer.blendMode = .destinationOut
            for (p, rx, ry) in spots {
                var hole = layer
                hole.translateBy(x: p.x, y: p.y)
                hole.scaleBy(x: 1, y: ry / rx)
                hole.fill(Path(ellipseIn: CGRect(x: -rx, y: -rx, width: rx * 2, height: rx * 2)), with: .radialGradient(
                    Gradient(stops: [.init(color: .black.opacity(0.92), location: 0), .init(color: .black.opacity(0.7), location: 0.45),
                                     .init(color: .black.opacity(0.25), location: 0.78), .init(color: .clear, location: 1)]),
                    center: .zero, startRadius: 0, endRadius: rx))
            }
        }
        ghost(&ctx, c, t: reduceMotion ? 0 : t, alpha: a)
    }

    /// The ghost fingertip performing the move, slow enough to read once.
    private func ghost(_ ctx: inout GraphicsContext, _ c: RevontuletCoachState, t: Double, alpha: Double) {
        func ease(_ x: Double) -> Double { let k = min(1, max(0, x)); return k * k * (3 - 2 * k) }
        switch c.kind {
        case .start:
            let loop = t.truncatingRemainder(dividingBy: 2.0)
            let k = ease(loop / 0.6)
            let p = CGPoint(x: L.anchor.x + CGFloat(1 - k) * 46, y: L.anchor.y + CGFloat(1 - k) * 64 + 6)
            let fade = loop < 1.3 ? 1 : max(0, 1 - (loop - 1.3) / 0.4)
            fingertip(&ctx, at: p, alpha: alpha * fade, press: loop > 0.6 && loop < 1.0 ? (loop - 0.6) / 0.4 : nil)
        case .choice:
            break
        case .trace:
            let loop = t.truncatingRemainder(dividingBy: 2.8)
            let k = ease(loop / 1.7)
            let arc = e.arc
            var lit = Path()
            let m = max(2, Int(40 * k))
            for i in 0...m {
                let q = arc.point(k * Double(i) / Double(m), reversed: e.reversed)
                if i == 0 { lit.move(to: q) } else { lit.addLine(to: q) }
            }
            let fade = loop < 2.0 ? 1 : max(0, 1 - (loop - 2.0) / 0.5)
            var g = ctx
            g.blendMode = .plusLighter
            g.stroke(lit, with: .color(RevontuletColor.gold.opacity(0.45 * alpha * fade)), style: StrokeStyle(lineWidth: 5, lineCap: .round))
            fingertip(&ctx, at: arc.point(k, reversed: e.reversed), alpha: alpha * fade, press: nil)
        case .sling:
            let loop = t.truncatingRemainder(dividingBy: 3.0)
            let down = ease((loop - 0.35) / 0.9)
            let p = CGPoint(x: L.anchor.x, y: L.anchor.y + L.maxPull * 0.8 * CGFloat(down))
            let lifted = loop > 1.55
            if !lifted {
                fingertip(&ctx, at: p, alpha: alpha, press: loop < 0.35 ? loop / 0.35 : nil)
                var g = ctx
                g.blendMode = .plusLighter
                var th = Path()
                th.move(to: L.anchor)
                th.addLine(to: p)
                g.stroke(th, with: .color(RevontuletColor.gold.opacity(0.4 * alpha * down)), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            } else if let effort = e.choice {
                // Let go: a faint ghost of the spark flies toward the chosen line.
                let u = min(1, (loop - 1.55) / 0.6)
                let to = L.target(round: e.round, effort: effort)
                let from = CGPoint(x: L.anchor.x, y: L.anchor.y + L.maxPull * 0.8)
                let path = RevontuletFlight(launch: 0, from: from, control: RevontuletLayout.flightControl(from: from, to: to, pull: CGVector(dx: 0, dy: L.maxPull * 0.8)),
                                            to: to, duration: 1, hard: false, foxOwn: false)
                let q = path.bezier(1 - pow(1 - u, 2))
                var g = ctx
                g.opacity = alpha * (1 - u) * 0.6
                spark(&g, at: q, size: 0.6, heat: 0.8)
            }
        case .embers:
            guard let f = e.flight, f.emberU.indices.contains(c.ember) else { return }
            let loop = t.truncatingRemainder(dividingBy: 1.3)
            let p = f.emberPoint(c.ember)
            let k = ease(loop / 0.45)
            let q = CGPoint(x: p.x + CGFloat(1 - k) * 30, y: p.y + CGFloat(1 - k) * 44 + 4)
            fingertip(&ctx, at: q, alpha: alpha, press: loop > 0.45 && loop < 0.85 ? (loop - 0.45) / 0.4 : nil)
        case .stroke:
            let loop = t.truncatingRemainder(dividingBy: 3.0)
            let k = ease(loop / 1.9)
            let sq = L.foxSquare(.warm)
            let p = CGPoint(x: sq.midX - sq.width * 0.06, y: sq.minY + sq.height * (0.18 + 0.58 * CGFloat(k)))
            let fade = loop < 2.2 ? 1 : max(0, 1 - (loop - 2.2) / 0.5)
            fingertip(&ctx, at: p, alpha: alpha * fade, press: nil)
        }
    }

    /// A soft fingertip of light: a bright pad, a little tilted, with a soft shadow so it reads
    /// on snow and a glow so it reads on dark ice, and a ripple when it presses.
    private func fingertip(_ ctx: inout GraphicsContext, at p: CGPoint, alpha: Double, press: Double?) {
        guard alpha > 0.01 else { return }
        var glow = ctx
        glow.blendMode = .plusLighter
        softEllipse(&glow, p, rx: 40, ry: 40, [RevontuletColor.gold.opacity(0.22 * alpha), Color.white.opacity(0.06 * alpha)])
        if let k = press {
            let r = CGFloat(16 + 34 * k)
            glow.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)), with: .radialGradient(
                Gradient(stops: [.init(color: .clear, location: 0.55), .init(color: RevontuletColor.gold.opacity(0.7 * (1 - k) * alpha), location: 0.8),
                                 .init(color: .clear, location: 1)]), center: p, startRadius: 0, endRadius: r))
        }
        let squash: CGFloat = press != nil ? 0.9 : 1
        let rect = CGRect(x: -12.5, y: -16.5 * squash, width: 25, height: 33 * squash)
        var shadow = ctx
        shadow.translateBy(x: p.x + 2.5, y: p.y + 4)
        shadow.rotate(by: .degrees(-18))
        shadow.fill(Path(ellipseIn: rect.insetBy(dx: -2, dy: -2)), with: .radialGradient(
            Gradient(colors: [Color(red: 0.05, green: 0.08, blue: 0.25).opacity(0.3 * alpha), .clear]), center: .zero, startRadius: 0, endRadius: 20))
        var pad = ctx
        pad.translateBy(x: p.x, y: p.y)
        pad.rotate(by: .degrees(-18))
        pad.fill(Path(ellipseIn: rect), with: .radialGradient(
            Gradient(colors: [Color.white.opacity(0.95 * alpha), Color(red: 0.95, green: 0.96, blue: 1).opacity(0.85 * alpha),
                              RevontuletColor.warmWhite.opacity(0.7 * alpha)]),
            center: CGPoint(x: -3, y: -5), startRadius: 0, endRadius: 19))
        pad.stroke(Path(ellipseIn: rect), with: .color(RevontuletColor.gold.opacity(0.75 * alpha)), lineWidth: 1.4)
    }

    private func press(_ ctx: inout GraphicsContext, at p: CGPoint, k: Double, alpha: Double) {
        let r = CGFloat(12 + 26 * k)
        var g = ctx
        g.blendMode = .plusLighter
        g.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)), with: .radialGradient(
            Gradient(colors: [Color.white.opacity(0.3 * (1 - k) * alpha), .clear]), center: p, startRadius: 0, endRadius: r))
    }

    // MARK: Helpers

    /// A truly soft elliptical glow (a radial gradient squashed, never cut by an edge).
    private func softEllipse(_ ctx: inout GraphicsContext, _ c: CGPoint, rx: CGFloat, ry: CGFloat, _ colors: [Color]) {
        guard rx > 0.5, ry > 0.5 else { return }
        var g = ctx
        g.translateBy(x: c.x, y: c.y)
        g.scaleBy(x: 1, y: ry / rx)
        g.fill(Path(ellipseIn: CGRect(x: -rx, y: -rx, width: rx * 2, height: rx * 2)),
               with: .radialGradient(Gradient(colors: colors + [.clear]), center: .zero, startRadius: 0, endRadius: rx))
    }

    private func smooth(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let t = min(1, max(0, (x - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }
}
