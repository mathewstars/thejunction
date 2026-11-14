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
    static let gold = Color(red: 1.0, green: 0.85, blue: 0.55)
    static let amber = Color(red: 1.0, green: 0.62, blue: 0.30)
    static let ember = Color(red: 1.0, green: 0.48, blue: 0.24)
    static let core = Color(red: 1.0, green: 0.98, blue: 0.92)
    static let night = Color(red: 0.06, green: 0.10, blue: 0.30)
}

/// Draws one frame from the engine's state. Three layers: the sky behind the ice, the ice
/// (and its shards), and the light in front (the spark, the half-circle, the embers, snow on
/// the fox). Pure drawing, no state.
struct RevontuletPainter {
    let e: RevontuletEngine
    let art: RevontuletArt
    let now: Double

    private var L: RevontuletLayout { e.layout }
    private var since: Double { now - e.beatStart }
    private var burstAge: Double? { e.burstAt.map { now - $0 } }

    // MARK: - Sky (behind the ice)

    func sky(_ ctx: inout GraphicsContext, size: CGSize) {
        // A veil that keeps the night dark until the ice starts to give.
        let veil = 0.42 * (1 - min(1, e.skyLight * 1.2))
        if veil > 0.01 {
            let rect = CGRect(x: 0, y: 0, width: size.width, height: L.wall.maxY)
            ctx.fill(Path(rect), with: .linearGradient(
                Gradient(colors: [RevontuletColor.night.opacity(veil), RevontuletColor.night.opacity(veil * 0.6), .clear]),
                startPoint: .zero, endPoint: CGPoint(x: 0, y: rect.maxY)))
        }
        var light = e.broken ? 1.0 : 0.25 + 0.75 * e.skyLight
        if e.beat == .sleep || e.beat == .done { light *= max(0.55, 1 - (since / 2.5) * 0.45) }
        let sweep: Double = burstAge.map { min(1, max(0, ($0 - 0.1) / 2.4)) } ?? 1
        let ribbons = e.impacts.filter { $0.ribbon }
        var g = ctx
        g.blendMode = .plusLighter
        aurora(&g, size: size, light: light, sweep: e.broken ? sweep : 1)
        for (k, r) in ribbons.enumerated() {
            let age = now - r.time
            let a = min(1, age / 1.2) * (e.beat == .sleep || e.beat == .done ? 0.6 : 1)
            curtain(&g, size: size, base: 0.36 + 0.05 * Double(k), amp: 22, height: 0.13, alpha: 0.5 * a,
                    speed: 0.21, phase: 2.0 + Double(k), violetTop: true, reveal: min(1, age / 1.6))
        }
        if let b = burstAge, b < 1.4 {
            // The sky opening: one soft bloom of green light, gone in a breath.
            let k = pow(1 - b / 1.4, 2)
            var h = ctx
            h.blendMode = .plusLighter
            let c = e.impacts.last?.point ?? L.foxTarget
            h.fill(Path(CGRect(origin: .zero, size: size)), with: .radialGradient(
                Gradient(colors: [RevontuletColor.green.opacity(0.32 * k), RevontuletColor.teal.opacity(0.14 * k), .clear]),
                center: c, startRadius: 0, endRadius: size.height * 0.7))
        }
    }

    private func aurora(_ ctx: inout GraphicsContext, size: CGSize, light: Double, sweep: Double) {
        guard light > 0.01 else { return }
        curtain(&ctx, size: size, base: 0.25, amp: 30, height: 0.19, alpha: 0.42 * light, speed: 0.11, phase: 0, violetTop: true, reveal: sweep)
        curtain(&ctx, size: size, base: 0.33, amp: 24, height: 0.16, alpha: 0.5 * light, speed: 0.15, phase: 1.7, violetTop: false, reveal: sweep)
        curtain(&ctx, size: size, base: 0.16, amp: 18, height: 0.12, alpha: 0.3 * light, speed: 0.08, phase: 3.1, violetTop: true, reveal: sweep)
    }

    /// One curtain of aurora: vertical rays hanging from a slowly swaying lower edge,
    /// brightest at the edge, green into teal, a violet fringe at the top.
    private func curtain(_ ctx: inout GraphicsContext, size: CGSize, base: Double, amp: Double, height: Double,
                         alpha: Double, speed: Double, phase: Double, violetTop: Bool, reveal: Double) {
        let w = Double(size.width), h = Double(size.height)
        let step = 4.0
        let k1 = 2 * Double.pi / (w * 1.15), k2 = 2 * Double.pi / (w * 0.42)
        let t = now
        var x = -10.0
        while x < w + 10 {
            let lead = reveal * (w + 260) - x
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

    /// The mask for the frosted blur: the pieces still standing.
    func standing(_ ctx: inout GraphicsContext) {
        ctx.fill(art.standing(at: now, burstAt: e.burstAt), with: .color(.black))
    }

    func ice(_ ctx: inout GraphicsContext, size: CGSize) {
        let standing = art.standing(at: now, burstAt: e.burstAt)
        if !standing.isEmpty {
            body(&ctx, standing: standing)
            for (k, list) in art.cracks.enumerated() where k < e.impacts.count {
                cracks(&ctx, list, age: now - e.impacts[k].time, clip: standing)
            }
            var lines = ctx
            lines.clip(to: standing)
            faults(&lines)
        }
        falling(&ctx)
        if let b = burstAge { shards(&ctx, age: b) }
        impactsLight(&ctx)
    }

    private func body(_ ctx: inout GraphicsContext, standing: Path) {
        let wall = L.wall
        // Behind the glass: the night sky, blurred and darkened, as if through thick ice.
        var deep = ctx
        deep.clip(to: standing)
        if let sky = art.frostedSky {
            deep.draw(Image(decorative: sky, scale: 1), in: art.skyRect)
        }
        deep.fill(standing, with: .linearGradient(
            Gradient(colors: [RevontuletColor.iceDeep.opacity(0.62), RevontuletColor.iceDeep.opacity(0.74), Color(red: 0.03, green: 0.09, blue: 0.16).opacity(0.84)]),
            startPoint: CGPoint(x: wall.midX, y: wall.minY), endPoint: CGPoint(x: wall.midX, y: wall.maxY)))
        // Light trapped behind the glass, rising as the sky brightens.
        var glow = deep
        glow.blendMode = .plusLighter
        let trapped = 0.08 + 0.22 * e.skyLight
        let spots: [(Double, Double, Color)] = [(0.3, 0.22, RevontuletColor.green), (0.72, 0.35, RevontuletColor.teal), (0.45, 0.62, RevontuletColor.violet)]
        for (k, s) in spots.enumerated() {
            let fx: Double = s.0 + 0.08 * sin(now * 0.07 + Double(k) * 2)
            let fy: Double = s.1 + 0.05 * cos(now * 0.05 + Double(k))
            let cx: CGFloat = wall.minX + wall.width * CGFloat(fx)
            let cy: CGFloat = wall.minY + wall.height * CGFloat(fy)
            let r = wall.width * 0.55
            glow.fill(Path(ellipseIn: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)), with: .radialGradient(
                Gradient(colors: [s.2.opacity(trapped * (k == 2 ? 0.6 : 1)), .clear]),
                center: CGPoint(x: cx, y: cy), startRadius: 0, endRadius: r))
        }
        // Each piece is a plane at its own angle: a cold sheen on one side, shade on the other.
        for (i, f) in art.facets.enumerated() where (art.fallAt[i].map { $0 > now } ?? true) {
            let b = f.path.boundingRect
            let tilt = f.shade
            let from = CGPoint(x: tilt > 0 ? b.minX : b.maxX, y: b.minY)
            let to = CGPoint(x: tilt > 0 ? b.maxX : b.minX, y: b.maxY)
            glow.fill(f.path, with: .linearGradient(
                Gradient(colors: [RevontuletColor.iceCold.opacity(0.07 + 0.07 * abs(tilt)), .clear, .clear]),
                startPoint: from, endPoint: to))
            deep.fill(f.path, with: .linearGradient(
                Gradient(colors: [.clear, .clear, Color.black.opacity(0.06 + 0.1 * f.glint)]),
                startPoint: from, endPoint: to))
        }
        // A slow glint sliding across the glass.
        let cycle = 11.0
        let u = (now.truncatingRemainder(dividingBy: cycle)) / cycle
        var band = glow
        band.translateBy(x: wall.minX - wall.width * 0.6 + wall.width * 2.2 * CGFloat(u), y: wall.midY)
        band.rotate(by: .degrees(24))
        band.fill(Path(CGRect(x: -40, y: -wall.height, width: 80, height: wall.height * 2)), with: .linearGradient(
            Gradient(colors: [.clear, RevontuletColor.frost.opacity(0.08), .clear]),
            startPoint: CGPoint(x: -40, y: 0), endPoint: CGPoint(x: 40, y: 0)))

        // Fracture planes: a dark seam with a bright lip, a few catching the light.
        for (i, f) in art.facets.enumerated() where (art.fallAt[i].map { $0 > now } ?? true) {
            deep.stroke(f.path, with: .color(Color.black.opacity(0.22)), lineWidth: 1.6)
            deep.stroke(f.path, with: .color(RevontuletColor.frost.opacity(0.06 + 0.12 * f.glint)), lineWidth: 0.6)
            if f.glint > 0.7 {
                let shimmer = 0.5 + 0.5 * sin(now * 0.8 + f.phase)
                glow.stroke(f.path, with: .color(RevontuletColor.iceCold.opacity(0.1 + 0.18 * shimmer)), lineWidth: 1)
            }
        }
        // Frost growing in from the rim: layers of soft white, thinner and brighter at the edge.
        var rim = ctx
        rim.clip(to: standing)
        for (w, a) in [(34.0, 0.035), (22.0, 0.05), (13.0, 0.07), (6.0, 0.1), (2.4, 0.22)] {
            rim.stroke(art.outline, with: .color(RevontuletColor.frost.opacity(a)), lineWidth: w)
        }
        rim.stroke(art.outline, with: .color(RevontuletColor.frost.opacity(0.55)), lineWidth: 1.1)
        var specks = rim
        specks.blendMode = .plusLighter
        for f in art.frost {
            let tw = 0.65 + 0.35 * sin(now * 1.3 + f.phase)
            specks.fill(Path(ellipseIn: CGRect(x: f.p.x - f.r, y: f.p.y - f.r, width: f.r * 2, height: f.r * 2)),
                        with: .color(RevontuletColor.frost.opacity(f.a * tw)))
        }
        drift(&ctx, alpha: 1)
    }

    /// The pane's foot buried in a drift of snow, the same snow as the painting.
    private func drift(_ ctx: inout GraphicsContext, alpha: Double) {
        let wall = L.wall
        let top = wall.maxY - 34
        var mound = Path()
        mound.move(to: CGPoint(x: wall.minX - 30, y: wall.maxY + 30))
        var x = wall.minX - 30
        while x <= wall.maxX + 30 {
            let wave: Double = 7 * sin(Double(x) * 0.04) + 4 * sin(Double(x) * 0.13 + 1)
            let edge: Double = Double(min(x - wall.minX + 30, wall.maxX + 30 - x)) / 30
            let y: CGFloat = top + CGFloat(wave) + CGFloat(max(0, 1 - edge)) * 18
            mound.addLine(to: CGPoint(x: x, y: y))
            x += 6
        }
        mound.addLine(to: CGPoint(x: wall.maxX + 30, y: wall.maxY + 30))
        mound.closeSubpath()
        // A soft shadow the drift throws up onto the glass, then the snow, lit along its lip.
        ctx.fill(Path(CGRect(x: wall.minX, y: top - 26, width: wall.width, height: 30)), with: .linearGradient(
            Gradient(colors: [.clear, Color.black.opacity(0.18 * alpha)]),
            startPoint: CGPoint(x: 0, y: top - 26), endPoint: CGPoint(x: 0, y: top + 4)))
        ctx.fill(mound, with: .linearGradient(
            Gradient(colors: [Color(red: 0.93, green: 0.95, blue: 1.0).opacity(alpha), Color(red: 0.80, green: 0.84, blue: 0.97).opacity(alpha)]),
            startPoint: CGPoint(x: 0, y: top - 8), endPoint: CGPoint(x: 0, y: wall.maxY + 20)))
        ctx.stroke(mound, with: .color(Color.white.opacity(0.7 * alpha)), lineWidth: 1.2)
    }

    private func cracks(_ ctx: inout GraphicsContext, _ list: [RevontuletArt.Crack], age: Double, clip: Path) {
        guard age >= 0 else { return }
        var c = ctx
        c.clip(to: clip)
        let hot = max(0, 1 - age / 0.9)
        for crack in list {
            let f = min(1, max(0, (age - crack.delay) / 0.32))
            guard f > 0 else { continue }
            let path = partial(crack.points, f)
            var g = c
            g.blendMode = .plusLighter
            if hot > 0 {
                g.stroke(path, with: .color(RevontuletColor.teal.opacity(0.5 * hot)),
                         style: StrokeStyle(lineWidth: crack.width * 5, lineCap: .round, lineJoin: .round))
            }
            g.stroke(path, with: .color(RevontuletColor.frost.opacity(0.32 + 0.6 * hot)),
                     style: StrokeStyle(lineWidth: crack.width, lineCap: .round, lineJoin: .round))
        }
    }

    // MARK: Fault lines

    private func faults(_ ctx: inout GraphicsContext) {
        guard [RevontuletBeat.intro, .choice, .trace, .sling, .flight, .impact].contains(e.beat) else { return }
        let f = L.faults(round: e.round)
        let chosen = e.choice
        var easy = 0.0, hard = 0.0
        switch e.beat {
        case .intro:
            easy = 0.3; hard = 0.3
        case .choice:
            let k = min(1, max(0, since / 0.7))
            easy = k; hard = k
        case .impact:
            let k = max(0, 1 - since / 0.4)
            easy = chosen == .easy ? k : 0; hard = chosen == .hard ? k : 0
        default:
            let k = e.beat == .trace ? min(1, max(0, (now - (e.records.last?.chosenUptime ?? now)) / 0.4)) : 1
            easy = chosen == .easy ? 0.75 : 0.25 * (1 - k)
            hard = chosen == .hard ? 0.75 : 0.25 * (1 - k)
        }
        if easy > 0.01 { crack(&ctx, f.easy, glow: easy) }
        if hard > 0.01 { vein(&ctx, f.hard, glow: hard) }
    }

    /// The thin low crack: a hairline of warm light seeping through.
    private func crack(_ ctx: inout GraphicsContext, _ pts: [CGPoint], glow: Double) {
        let pulse = glow * (0.8 + 0.2 * sin(now * 2.6))
        var path = Path()
        path.addLines(pts)
        var g = ctx
        g.blendMode = .plusLighter
        let mid = pts[pts.count / 2]
        g.fill(Path(ellipseIn: CGRect(x: mid.x - 34, y: mid.y - 22, width: 68, height: 44)), with: .radialGradient(
            Gradient(colors: [RevontuletColor.amber.opacity(0.32 * pulse), .clear]), center: mid, startRadius: 0, endRadius: 34))
        g.stroke(path, with: .color(RevontuletColor.amber.opacity(0.35 * pulse)), style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
        g.stroke(path, with: .color(RevontuletColor.gold.opacity(0.95 * pulse)), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
    }

    /// The thick crystalline vein: a bright seam with branches and crystals, aurora behind it.
    private func vein(_ ctx: inout GraphicsContext, _ pts: [CGPoint], glow: Double) {
        let pulse = glow * (0.78 + 0.22 * sin(now * 1.5 + 1))
        var path = Path()
        path.addLines(pts)
        var g = ctx
        g.blendMode = .plusLighter
        let mid = pts[pts.count / 2]
        g.fill(Path(ellipseIn: CGRect(x: mid.x - 110, y: mid.y - 80, width: 220, height: 160)), with: .radialGradient(
            Gradient(colors: [RevontuletColor.green.opacity(0.3 * pulse), RevontuletColor.violet.opacity(0.1 * pulse), .clear]),
            center: mid, startRadius: 0, endRadius: 110))
        for (w, a) in [(22.0, 0.1), (14.0, 0.18), (8.0, 0.3)] {
            g.stroke(path, with: .color(RevontuletColor.teal.opacity(a * pulse)), style: StrokeStyle(lineWidth: w, lineCap: .round, lineJoin: .round))
        }
        // Branches off the seam.
        for i in 1..<(pts.count - 1) {
            let a = pts[i], dir: CGFloat = i % 2 == 0 ? 1 : -1
            var b = Path()
            b.move(to: a)
            b.addLine(to: CGPoint(x: a.x + 7 * dir, y: a.y + 11 * dir))
            b.addLine(to: CGPoint(x: a.x + 5 * dir, y: a.y + 19 * dir))
            g.stroke(b, with: .color(RevontuletColor.frost.opacity(0.55 * pulse)), style: StrokeStyle(lineWidth: 1, lineCap: .round))
        }
        g.stroke(path, with: .color(RevontuletColor.green.opacity(0.85 * pulse)), style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
        g.stroke(path, with: .color(RevontuletColor.core.opacity(0.95 * pulse)), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
        // Crystals along the vein: small facets that catch the light in turn.
        for i in 0..<(pts.count - 1) {
            let a = pts[i], b = pts[i + 1]
            let c = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
            let ang = atan2(b.y - a.y, b.x - a.x)
            let s: CGFloat = 4.5 + CGFloat(i % 3) * 1.6
            var d = Path()
            d.move(to: CGPoint(x: -s * 1.6, y: 0))
            d.addLine(to: CGPoint(x: 0, y: -s * 0.7))
            d.addLine(to: CGPoint(x: s * 1.6, y: 0))
            d.addLine(to: CGPoint(x: 0, y: s * 0.7))
            d.closeSubpath()
            let tw = 0.45 + 0.55 * pow(0.5 + 0.5 * sin(now * 2.2 + Double(i) * 1.3), 3)
            var h = g
            h.translateBy(x: c.x, y: c.y)
            h.rotate(by: .radians(Double(ang)))
            h.fill(d, with: .linearGradient(Gradient(colors: [RevontuletColor.core.opacity(0.9 * pulse * tw), RevontuletColor.teal.opacity(0.4 * pulse)]),
                                            startPoint: CGPoint(x: 0, y: -s), endPoint: CGPoint(x: 0, y: s)))
        }
    }

    // MARK: Pieces falling and the burst

    private func falling(_ ctx: inout GraphicsContext) {
        for (i, f) in art.facets.enumerated() {
            guard let at = art.fallAt[i], now >= at, now < at + 1.5 else { continue }
            let t = now - at
            let fade = 1 - smooth(0.7, 1.45, t)
            let offset = CGSize(width: CGFloat(f.spin * 9 * t), height: CGFloat(0.5 * 760 * t * t + 14 * t))
            piece(&ctx, f, offset: offset, angle: f.spin * 0.6 * t, flip: cos(f.tumble * t * 1.4), alpha: fade, light: 0.6)
        }
    }

    private func shards(_ ctx: inout GraphicsContext, age: Double) {
        guard age < 4.6, !art.burstPush.isEmpty else { return }
        // Slow motion at first, then real speed.
        let tau: Double
        if age < 1.2 { tau = 0.28 * age }
        else if age < 2.2 { let d = age - 1.2; tau = 0.336 + 0.28 * d + 0.36 * d * d }
        else { tau = 0.976 + (age - 2.2) }
        let fade = 1 - smooth(1.7, 3.9, age)
        let shrink = 1 - 0.45 * smooth(0.2, 3.2, age)
        for (i, f) in art.facets.enumerated() where (art.fallAt[i].map { $0 > (e.burstAt ?? 0) } ?? true) {
            let v = art.burstPush[i]
            let offset = CGSize(width: v.dx * CGFloat(tau), height: v.dy * CGFloat(tau) + CGFloat(0.5 * 560 * tau * tau))
            let flip = cos(f.tumble * tau * 2.2 + f.phase)
            piece(&ctx, f, offset: offset, angle: f.spin * tau * 1.6, flip: flip, alpha: fade * (0.75 + 0.25 * f.glint), light: 1, scale: shrink)
        }
    }

    /// One piece of ice in flight: dark glass with its edges catching the aurora as it turns.
    private func piece(_ ctx: inout GraphicsContext, _ f: RevontuletArt.Facet, offset: CGSize, angle: Double, flip: Double,
                       alpha: Double, light: Double, scale: Double = 1) {
        guard alpha > 0.01 else { return }
        var g = ctx
        g.translateBy(x: f.center.x + offset.width, y: f.center.y + offset.height)
        g.rotate(by: .radians(angle))
        g.scaleBy(x: CGFloat(max(0.12, abs(flip)) * scale), y: CGFloat(scale))
        let local = f.path.offsetBy(dx: -f.center.x, dy: -f.center.y)
        let b = local.boundingRect
        let face = abs(flip)
        // Clear dark glass: see-through in the middle, the light gathering along one side.
        g.fill(local, with: .linearGradient(
            Gradient(colors: [RevontuletColor.iceCold.opacity(alpha * (0.22 + 0.3 * face)), RevontuletColor.iceDeep.opacity(alpha * 0.32),
                              RevontuletColor.iceDeep.opacity(alpha * 0.55)]),
            startPoint: CGPoint(x: b.minX, y: b.minY), endPoint: CGPoint(x: b.maxX, y: b.maxY)))
        var edge = g
        edge.blendMode = .plusLighter
        let catchLight = 0.25 + 0.75 * abs(sin(angle * 1.3 + f.phase))
        let hue: Color = [RevontuletColor.green, RevontuletColor.teal, RevontuletColor.violet][Int(f.phase * 10) % 3]
        edge.stroke(local, with: .color(hue.opacity(alpha * light * 0.8 * catchLight)), lineWidth: 1.6)
        edge.stroke(local, with: .color(RevontuletColor.frost.opacity(alpha * 0.35 * catchLight)), lineWidth: 0.7)
    }

    /// The flash where the spark hits, and the ice dust it throws.
    private func impactsLight(_ ctx: inout GraphicsContext) {
        var g = ctx
        g.blendMode = .plusLighter
        for (k, hit) in e.impacts.enumerated() {
            let t = now - hit.time
            guard t >= 0, t < 1.2 else { continue }
            if t < 0.5 {
                let k2 = pow(1 - t / 0.5, 2)
                let r = CGFloat(20 + (110 + 30 * Double(hit.pieces)) * t / 0.5)
                let tint: Color = hit.hard ? RevontuletColor.green : RevontuletColor.gold
                g.fill(Path(ellipseIn: CGRect(x: hit.point.x - r, y: hit.point.y - r, width: r * 2, height: r * 2)), with: .radialGradient(
                    Gradient(colors: [RevontuletColor.core.opacity(0.9 * k2), tint.opacity(0.45 * k2), .clear]),
                    center: hit.point, startRadius: 0, endRadius: r))
            }
            for (i, m) in art.motes.enumerated() where i < 14 + hit.pieces * 4 {
                let life = m.life * (hit.breaking ? 1.5 : 1)
                guard t < life else { continue }
                let a = m.angle + Double(k)
                let x = hit.point.x + CGFloat(cos(a) * m.speed * t)
                let y = hit.point.y + CGFloat(sin(a) * m.speed * t + 0.5 * 420 * t * t)
                let o = (1 - t / life)
                g.fill(Path(ellipseIn: CGRect(x: x - m.size, y: y - m.size, width: m.size * 2, height: m.size * 2)),
                       with: .color(RevontuletColor.frost.opacity(0.85 * o)))
            }
        }
    }

    // MARK: - In front: the half-circle, the spark, the embers, the snow on the fox

    func front(_ ctx: inout GraphicsContext, size: CGSize) {
        switch e.beat {
        case .trace:
            arc(&ctx)
        case .sling:
            threads(&ctx, tension: Double(hypot(e.pull.dx, e.pull.dy) / L.maxPull), snapAge: nil)
        case .flight:
            if let f = e.flight, !f.foxOwn {
                threads(&ctx, tension: 0, snapAge: now - f.launch)
            }
        default:
            break
        }
        if let f = e.flight, e.beat == .flight {
            trail(&ctx, f)
            embers(&ctx, f)
        }
        if let s = sparkState() {
            spark(&ctx, at: s.p, size: s.size, heat: s.heat)
        }
        snow(&ctx)
        touchFlash(&ctx)
        hint(&ctx)
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

    private func press(_ ctx: inout GraphicsContext, at p: CGPoint, k: Double, alpha: Double) {
        let r = CGFloat(12 + 26 * k)
        var g = ctx
        g.blendMode = .plusLighter
        g.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)), with: .radialGradient(
            Gradient(colors: [Color.white.opacity(0.3 * (1 - k) * alpha), .clear]), center: p, startRadius: 0, endRadius: r))
    }

    private func sparkState() -> (p: CGPoint, size: Double, heat: Double)? {
        switch e.beat {
        case .intro:
            return (L.anchor, 0.62, 0.55)
        case .choice:
            let grow = e.round == 0 ? 1 : min(1, since / 0.35)
            return (L.anchor, 0.62 * grow, 0.55)
        case .trace:
            return (L.anchor, 0.62 + 0.6 * e.progress, 0.55 + 0.45 * e.progress)
        case .sling:
            let level = Double(hypot(e.pull.dx, e.pull.dy) / L.maxPull)
            let burst = since < 0.3 ? 0.3 * (1 - since / 0.3) : 0
            return (e.sparkPoint(now), 1.22 + burst + 0.15 * level, 1)
        case .flight:
            guard let f = e.flight else { return nil }
            let lit = f.emberHitAt.enumerated().filter { $0.element != nil && now - f.launch >= f.emberT[$0.offset] }.count
            return (f.point(at: now), f.foxOwn ? 1.3 : 1.22 + 0.22 * Double(lit), 1)
        default:
            return nil
        }
    }

    /// The fox's spark: a tiny white-hot core inside layered warm light, a faint streak like
    /// light through glass, and a few motes circling it. Never a flat shape.
    func spark(_ ctx: inout GraphicsContext, at p: CGPoint, size s: Double, heat: Double) {
        guard s > 0.02 else { return }
        var g = ctx
        g.blendMode = .plusLighter
        let flick = 1 + 0.1 * sin(now * 23) + 0.07 * sin(now * 37 + 1.3)
        let S = CGFloat(s)
        func glow(_ r: CGFloat, _ colors: [Color]) {
            g.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)),
                   with: .radialGradient(Gradient(colors: colors), center: p, startRadius: 0, endRadius: r))
        }
        glow(40 * S, [RevontuletColor.amber.opacity(0.22 * heat), RevontuletColor.amber.opacity(0.06 * heat), .clear])
        glow(17 * S * CGFloat(flick), [RevontuletColor.gold.opacity(0.6 * heat), RevontuletColor.amber.opacity(0.22 * heat), .clear])
        glow(6 * S * CGFloat(flick), [RevontuletColor.core, RevontuletColor.gold.opacity(0.85), .clear])
        // The streak: a thin horizontal flare, and a shorter vertical one.
        let len = 30 * S * CGFloat(0.85 + 0.15 * flick)
        g.fill(Path(ellipseIn: CGRect(x: p.x - len, y: p.y - 1.1 * S, width: len * 2, height: 2.2 * S)), with: .linearGradient(
            Gradient(colors: [.clear, RevontuletColor.core.opacity(0.55 * heat), .clear]),
            startPoint: CGPoint(x: p.x - len, y: p.y), endPoint: CGPoint(x: p.x + len, y: p.y)))
        let vl = len * 0.45
        g.fill(Path(ellipseIn: CGRect(x: p.x - 0.8 * S, y: p.y - vl, width: 1.6 * S, height: vl * 2)), with: .linearGradient(
            Gradient(colors: [.clear, RevontuletColor.core.opacity(0.35 * heat), .clear]),
            startPoint: CGPoint(x: p.x, y: p.y - vl), endPoint: CGPoint(x: p.x, y: p.y + vl)))
        // Motes circling, each on its own slow orbit, flickering.
        for i in 0..<5 {
            let di = Double(i)
            let a = now * (1.1 + 0.37 * di) * (i % 2 == 0 ? 1 : -1) + di * 1.26
            let r = (9 + 3.2 * di) * s
            let q = CGPoint(x: p.x + CGFloat(cos(a) * r), y: p.y + CGFloat(sin(a) * r * 0.8))
            let o = (0.35 + 0.65 * abs(sin(now * 3 + di))) * heat
            let m = CGFloat(1.1 + 0.3 * di.truncatingRemainder(dividingBy: 2)) * S
            g.fill(Path(ellipseIn: CGRect(x: q.x - m * 2, y: q.y - m * 2, width: m * 4, height: m * 4)), with: .radialGradient(
                Gradient(colors: [RevontuletColor.gold.opacity(o), .clear]), center: q, startRadius: 0, endRadius: m * 2))
        }
    }

    /// The half-circle: a faint band of frost light; the traced part fills with warm light
    /// behind the finger, and light streams from it into the spark.
    private func arc(_ ctx: inout GraphicsContext) {
        let arc = e.arc
        let appear = min(1, max(0, since / 0.18))
        guard appear > 0 else { return }
        let n = 64
        var guide = Path()
        for i in 0...n {
            let p = arc.point(Double(i) / Double(n), reversed: e.reversed)
            if i == 0 { guide.move(to: p) } else { guide.addLine(to: p) }
        }
        var g = ctx
        g.blendMode = .plusLighter
        for (w, a) in [(22.0, 0.05), (13.0, 0.09), (7.0, 0.13)] {
            g.stroke(guide, with: .color(RevontuletColor.iceCold.opacity(a * appear)), style: StrokeStyle(lineWidth: w, lineCap: .round))
        }
        g.stroke(guide, with: .color(RevontuletColor.frost.opacity(0.32 * appear)), style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
        // Frost motes along the way, twinkling.
        for i in 0..<18 {
            let s = (Double(i) + 0.5) / 18
            guard s > e.progress else { continue }
            let p = arc.point(s, reversed: e.reversed)
            let tw = 0.3 + 0.7 * pow(0.5 + 0.5 * sin(now * 2.4 + Double(i) * 0.9), 2)
            g.fill(Path(ellipseIn: CGRect(x: p.x - 1.4, y: p.y - 1.4, width: 2.8, height: 2.8)),
                   with: .color(RevontuletColor.frost.opacity(0.7 * tw * appear)))
        }
        if e.progress <= 0.001 {
            // Where to start: a soft pulse at the start, and a comet showing the way.
            let start = arc.point(0, reversed: e.reversed)
            let pulse = 0.5 + 0.5 * sin(now * 4)
            spark(&g, at: start, size: 0.35 + 0.1 * pulse, heat: 0.8)
            let u = (since.truncatingRemainder(dividingBy: 1.9)) / 1.3
            if u < 1 {
                var comet = Path()
                let tail = max(0, u - 0.18)
                for i in 0...12 {
                    let s = tail + (u - tail) * Double(i) / 12
                    let p = arc.point(s, reversed: e.reversed)
                    if i == 0 { comet.move(to: p) } else { comet.addLine(to: p) }
                }
                g.stroke(comet, with: .color(RevontuletColor.gold.opacity(0.55 * (1 - u))), style: StrokeStyle(lineWidth: 3, lineCap: .round))
            }
        } else {
            var lit = Path()
            let m = max(2, Int(Double(n) * e.progress))
            for i in 0...m {
                let p = arc.point(e.progress * Double(i) / Double(m), reversed: e.reversed)
                if i == 0 { lit.move(to: p) } else { lit.addLine(to: p) }
            }
            for (w, a) in [(26.0, 0.1), (16.0, 0.2), (9.0, 0.35)] {
                g.stroke(lit, with: .color(RevontuletColor.amber.opacity(a)), style: StrokeStyle(lineWidth: w, lineCap: .round, lineJoin: .round))
            }
            g.stroke(lit, with: .color(RevontuletColor.gold.opacity(0.95)), style: StrokeStyle(lineWidth: 4.5, lineCap: .round, lineJoin: .round))
            g.stroke(lit, with: .color(RevontuletColor.core), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
            // Light streaming inwards to the spark.
            for i in 0..<10 {
                let s = e.progress * (Double(i) + 0.5) / 10
                let from = arc.point(s, reversed: e.reversed)
                let phase = (now * 1.6 + Double(i) * 0.37).truncatingRemainder(dividingBy: 1)
                let q = CGPoint(x: from.x + (L.anchor.x - from.x) * CGFloat(phase), y: from.y + (L.anchor.y - from.y) * CGFloat(phase))
                let o = sin(phase * .pi) * 0.75
                g.fill(Path(ellipseIn: CGRect(x: q.x - 1.6, y: q.y - 1.6, width: 3.2, height: 3.2)), with: .color(RevontuletColor.gold.opacity(o)))
            }
            if e.progress < 1 {
                spark(&g, at: arc.point(e.progress, reversed: e.reversed), size: 0.5, heat: 1)
            }
        }
    }

    /// Threads of light from two posts to the pulled spark: slack at rest, straight and
    /// bright under tension, quivering back after the release.
    private func threads(_ ctx: inout GraphicsContext, tension: Double, snapAge: Double?) {
        let r = L.arcRadius
        let posts = [CGPoint(x: L.anchor.x - r * 0.62, y: L.anchor.y - r * 0.12),
                     CGPoint(x: L.anchor.x + r * 0.62, y: L.anchor.y - r * 0.12)]
        var target = e.sparkPoint(now)
        var alpha = 0.3 + 0.6 * tension
        var wobble = 0.0
        if let a = snapAge {
            guard a < 0.6 else { return }
            target = L.anchor
            alpha = 0.6 * (1 - a / 0.6)
            wobble = sin(a * 38) * 10 * (1 - a / 0.6)
        }
        let appear = e.beat == .sling ? min(1, since / 0.3) : 1
        var g = ctx
        g.blendMode = .plusLighter
        for (k, post) in posts.enumerated() {
            for strand in 0..<3 {
                let mid = CGPoint(x: (post.x + target.x) / 2, y: (post.y + target.y) / 2)
                let sag = CGFloat((1 - tension) * 14 + Double(strand) * 3 + wobble * (k == 0 ? 1 : -1))
                let q = CGPoint(x: mid.x + CGFloat(sin(now * 2 + Double(strand))) * 2, y: mid.y + sag)
                var p = Path()
                p.move(to: post)
                p.addQuadCurve(to: target, control: q)
                let a = alpha * appear * (strand == 0 ? 1 : 0.5)
                g.stroke(p, with: .color(RevontuletColor.gold.opacity(a * 0.35)), style: StrokeStyle(lineWidth: 5, lineCap: .round))
                g.stroke(p, with: .color(RevontuletColor.core.opacity(a)), style: StrokeStyle(lineWidth: strand == 0 ? 1.2 : 0.7, lineCap: .round))
            }
            let glint = 0.6 + 0.4 * sin(now * 3 + Double(k))
            g.fill(Path(ellipseIn: CGRect(x: post.x - 7, y: post.y - 7, width: 14, height: 14)), with: .radialGradient(
                Gradient(colors: [RevontuletColor.frost.opacity(0.9 * glint * appear), RevontuletColor.iceCold.opacity(0.3 * appear), .clear]),
                center: post, startRadius: 0, endRadius: 7))
        }
    }

    /// The spark's trail: a tapering stroke of warm light and motes drifting down from it.
    private func trail(_ ctx: inout GraphicsContext, _ f: RevontuletFlight) {
        var g = ctx
        g.blendMode = .plusLighter
        let span = 0.42
        let n = 28
        var prev = f.point(at: now)
        for i in 1...n {
            let t = now - span * Double(i) / Double(n)
            guard t >= f.launch else { break }
            let p = f.point(at: t)
            let k = 1 - Double(i) / Double(n)
            var seg = Path()
            seg.move(to: prev)
            seg.addLine(to: p)
            g.stroke(seg, with: .color(RevontuletColor.gold.opacity(0.5 * k)), style: StrokeStyle(lineWidth: CGFloat(1 + 8 * k), lineCap: .round))
            g.stroke(seg, with: .color(RevontuletColor.core.opacity(0.7 * k * k)), style: StrokeStyle(lineWidth: CGFloat(0.5 + 2 * k), lineCap: .round))
            prev = p
        }
        // Motes shed every few hundredths of a second, drifting down and fading.
        let slot = 0.035
        var t = (floor(now / slot)) * slot
        while t > now - 0.9 && t >= f.launch {
            let age = now - t
            let p = f.point(at: t)
            let seed = sin(t * 913.7) * 0.5 + 0.5
            let x = p.x + CGFloat((seed - 0.5) * 18 * age * 3)
            let y = p.y + CGFloat(22 * age + 30 * age * age)
            let o = (1 - age / 0.9) * 0.8
            let m: CGFloat = 1.2 + CGFloat(seed)
            g.fill(Path(ellipseIn: CGRect(x: x - m, y: y - m, width: m * 2, height: m * 2)), with: .color(RevontuletColor.gold.opacity(o)))
            t -= slot
        }
    }

    /// The embers on the hard path: they flash ahead of the spark, a soft halo closing in
    /// on them as the spark comes; a lit one flares and waits to be swallowed.
    private func embers(_ ctx: inout GraphicsContext, _ f: RevontuletFlight) {
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
            var alpha = min(1, age / 0.12)
            if let hit = f.emberHitAt[i] {
                let ha = now - hit
                // A lit ember flares, then is swallowed by the passing spark.
                if pass > 0 { alpha *= max(0, 1 - pass / 0.15) }
                if ha < 0.5 {
                    let k = 1 - ha / 0.5
                    for ray in 0..<8 {
                        let a = Double(ray) / 8 * 2 * .pi + Double(i)
                        let len = CGFloat(10 + 34 * (1 - k))
                        var r = Path()
                        r.move(to: CGPoint(x: p.x + CGFloat(cos(a)) * 6, y: p.y + CGFloat(sin(a)) * 6))
                        r.addLine(to: CGPoint(x: p.x + CGFloat(cos(a)) * len, y: p.y + CGFloat(sin(a)) * len))
                        g.stroke(r, with: .color(RevontuletColor.gold.opacity(0.8 * k)), style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
                    }
                }
                ember(&g, at: p, size: 1.25, alpha: alpha, lit: true)
            } else {
                if f.emberMissed[i] { alpha *= max(0, 1 - (pass - RevontuletFlight.emberGrace) / 0.4) }
                else if pass > 0 { alpha *= max(0.55, 1 - pass / 0.6) }
                // The halo closing in: the rhythm cue.
                let closing = max(0, min(1, -pass / RevontuletFlight.emberLead))
                if closing > 0 {
                    let r = CGFloat(12 + 34 * closing)
                    g.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)), with: .radialGradient(
                        Gradient(stops: [.init(color: .clear, location: 0.55),
                                         .init(color: RevontuletColor.ember.opacity(0.4 * alpha), location: 0.82),
                                         .init(color: .clear, location: 1)]),
                        center: p, startRadius: 0, endRadius: r))
                }
                ember(&g, at: p, size: 0.85 + 0.15 * sin(age * 9), alpha: alpha, lit: false)
            }
        }
    }

    private func ember(_ g: inout GraphicsContext, at p: CGPoint, size s: Double, alpha: Double, lit: Bool) {
        guard alpha > 0.01 else { return }
        let S = CGFloat(s)
        let flick = 1 + 0.15 * sin(now * 29 + Double(p.x))
        g.fill(Path(ellipseIn: CGRect(x: p.x - 22 * S, y: p.y - 22 * S, width: 44 * S, height: 44 * S)), with: .radialGradient(
            Gradient(colors: [RevontuletColor.ember.opacity(0.45 * alpha), RevontuletColor.ember.opacity(0.1 * alpha), .clear]),
            center: p, startRadius: 0, endRadius: 22 * S))
        let core = 4.5 * S * CGFloat(flick)
        g.fill(Path(ellipseIn: CGRect(x: p.x - core, y: p.y - core, width: core * 2, height: core * 2)), with: .radialGradient(
            Gradient(colors: [RevontuletColor.core.opacity(alpha), (lit ? RevontuletColor.gold : RevontuletColor.amber).opacity(0.8 * alpha), .clear]),
            center: p, startRadius: 0, endRadius: core))
        // Four tiny sparks spitting off it.
        for i in 0..<4 {
            let a = now * 2.3 + Double(i) * 1.57
            let r = CGFloat(7 + 3 * sin(now * 5 + Double(i))) * S
            let q = CGPoint(x: p.x + CGFloat(cos(a)) * r, y: p.y + CGFloat(sin(a)) * r)
            g.fill(Path(ellipseIn: CGRect(x: q.x - 1, y: q.y - 1, width: 2, height: 2)), with: .color(RevontuletColor.gold.opacity(0.8 * alpha)))
        }
    }

    /// Snow lying on the fox's fur in the warmth beat; brushed-off snow puffs away.
    private func snow(_ ctx: inout GraphicsContext) {
        guard let w = e.warmthAt, now >= w else { return }
        let sq = L.foxSquare(.warm)
        let fox = CGPoint(x: sq.midX, y: sq.midY), size = sq.width
        for (i, s) in art.specks.enumerated() {
            let land = w + 0.25 + s.delay
            guard now >= land - 0.7 else { continue }
            var p = CGPoint(x: fox.x + s.offset.x * size, y: fox.y + s.offset.y * size)
            var alpha = 1.0
            var r = s.radius
            if now < land {
                let k = (land - now) / 0.7
                p.y -= CGFloat(k * k) * 70
                p.x += CGFloat(sin(k * 4 + Double(i))) * 6
                alpha = 1 - k
            }
            if let gone = art.speckGone[i], now >= gone {
                let a = now - gone
                guard a < 0.6 else { continue }
                let side: CGFloat = s.offset.x < 0 ? -1 : 1
                p.x += side * CGFloat(a) * 60
                p.y += CGFloat(a * 40 + 120 * a * a)
                alpha = 1 - a / 0.6
                r *= CGFloat(1 + a)
            }
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r + 0.8, width: r * 2, height: r * 2)),
                     with: .color(Color(red: 0.55, green: 0.62, blue: 0.85).opacity(0.35 * alpha)))
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)), with: .radialGradient(
                Gradient(colors: [Color.white.opacity(alpha), Color.white.opacity(0.85 * alpha), RevontuletColor.frost.opacity(0.4 * alpha)]),
                center: CGPoint(x: p.x - r * 0.3, y: p.y - r * 0.3), startRadius: 0, endRadius: r * 1.2))
        }
    }

    // MARK: Helpers

    private func partial(_ pts: [CGPoint], _ f: Double) -> Path {
        var p = Path()
        guard pts.count > 1 else { return p }
        let total = Double(pts.count - 1) * f
        let whole = Int(total)
        p.move(to: pts[0])
        for i in 1..<min(pts.count, whole + 1) { p.addLine(to: pts[i]) }
        if whole < pts.count - 1 {
            let a = pts[whole], b = pts[whole + 1]
            let r = CGFloat(total - Double(whole))
            p.addLine(to: CGPoint(x: a.x + (b.x - a.x) * r, y: a.y + (b.y - a.y) * r))
        }
        return p
    }

    private func smooth(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let t = min(1, max(0, (x - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }
}
