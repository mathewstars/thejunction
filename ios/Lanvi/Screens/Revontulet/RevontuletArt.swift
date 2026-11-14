import SwiftUI
import UIKit
import CoreImage

/// Everything the game draws that does not change while playing, made once when the game
/// opens: the glass (the night painting blurred, darkened and cooled), the wall's hidden
/// fracture geometry, the shards cut from the wall picture as small sprites, the fault lines
/// as tapered windows, frost, bubbles and the snow on the fox's fur. Kept in step with the
/// engine by `sync`. Visual only: nothing here is measured.
final class RevontuletArt {
    struct Facet {
        var points: [CGPoint]
        var center: CGPoint
        var path: Path
    }

    /// A piece of the wall that flies: its own bit of the wall picture.
    struct Shard {
        var facet: Int
        var center: CGPoint
        /// The outline around `center`.
        var local: Path
        var bounds: CGRect
        var image: CGImage?
        /// One or two edges that catch the light, around `center`.
        var litEdges: [(CGPoint, CGPoint)]
        var size: CGFloat
        var spin: Double
        var tumble: Double
        var phase: Double
        var hue: Int
    }

    struct Crack {
        var points: [CGPoint]
        var width: CGFloat
        var delay: Double
    }

    /// A fault line: a tapered window onto the sky, its centre line, and the points light
    /// pours from.
    struct Fault {
        var window: Path
        var core: Path
        var line: [CGPoint]
        var knots: [CGPoint]
        var center: CGPoint
        var length: CGFloat
    }

    struct Mote {
        var angle: Double
        var speed: Double
        var size: CGFloat
        var life: Double
    }

    struct Glitter {
        var p: CGPoint
        var v: CGVector
        var r: CGFloat
        var life: Double
        var phase: Double
    }

    struct Speck {
        /// From the fox's centre, in fox sizes.
        var offset: CGPoint
        var radius: CGFloat
        var group: Int
        var delay: Double
        var lobes: [CGVector]
    }

    let layout: RevontuletLayout
    let facets: [Facet]
    let shards: [Shard]
    let outline: Path
    /// The jagged top edge, left to right.
    let topEdge: Path
    let faults: [(easy: Fault, hard: Fault)]
    let frost: [(p: CGPoint, r: CGFloat, a: Double, phase: Double)]
    let bubbles: [(p: CGPoint, len: CGFloat, angle: Double, a: Double)]
    let hints: [Path]
    let specks: [Speck]
    let motes: [Mote]
    let glitter: [Glitter]
    /// The night painting blurred and cooled (the glass), and where the painting sits on screen.
    let frostedSky: CGImage?
    let skyRect: CGRect

    /// When each facet fell out (by index).
    private(set) var fallAt: [Int: Double] = [:]
    /// Each fallen facet's broken rim, worked out once when it falls: three weights of edge
    /// (thin, middle, thick) as one path each, the chips, and the stars seen through it.
    struct Rim {
        var edges: [(path: Path, width: CGFloat, lit: Double)]
        var chips: Path
        var stars: [(p: CGPoint, len: CGFloat, phase: Double)]
    }
    private(set) var rims: [Int: Rim] = [:]
    /// Each shard's push when its facet falls or the wall bursts.
    private(set) var push: [CGVector]
    private(set) var cracks: [[Crack]] = []
    private(set) var burstPoint: CGPoint?
    /// When each snow speck was brushed off (by index).
    private(set) var speckGone: [Int: Double] = [:]
    private var impactsSeen = 0
    private var strokesSeen = 0
    private var standingCache: (fallen: Int, burst: Bool, path: Path)?

    init(layout: RevontuletLayout, seed: UInt64 = 11) {
        self.layout = layout
        var rng = Rng(seed: seed)
        func r(_ a: Double, _ b: Double) -> CGFloat { CGFloat(a + (b - a) * rng.next()) }
        let wall = layout.wall
        let frame = WorldFrame(screen: layout.size)
        skyRect = CGRect(x: frame.origin.x, y: frame.origin.y,
                         width: WorldFrame.imageSize.width * frame.scale, height: WorldFrame.imageSize.height * frame.scale)

        // The hidden fracture geometry: a jittered grid, a jagged crystal top, the base buried.
        let cols = 7, rows = 9
        let cw = wall.width / CGFloat(cols), ch = wall.height / CGFloat(rows)
        var grid: [[CGPoint]] = []
        for j in 0...rows {
            var row: [CGPoint] = []
            for i in 0...cols {
                var x = wall.minX + CGFloat(i) * cw
                var y = wall.minY + CGFloat(j) * ch
                if i > 0 && i < cols { x += r(-0.34, 0.34) * cw }
                if j > 0 && j < rows { y += r(-0.3, 0.3) * ch }
                if j == 0 { y += r(-4, 14) }
                row.append(CGPoint(x: x, y: y))
            }
            grid.append(row)
        }
        var crags: [[CGPoint]] = []
        for i in 0..<cols {
            let a = grid[0][i], b = grid[0][i + 1]
            let peak = CGPoint(x: a.x + (b.x - a.x) * r(0.3, 0.7), y: min(a.y, b.y) - r(10, 30))
            let shoulder = CGPoint(x: a.x + (peak.x - a.x) * r(0.4, 0.7), y: a.y - r(2, 10))
            crags.append([shoulder, peak])
        }
        var list: [Facet] = []
        for j in 0..<rows {
            for i in 0..<cols {
                var corners = [grid[j][i]]
                if j == 0 { corners += crags[i] }
                corners += [grid[j][i + 1], grid[j + 1][i + 1], grid[j + 1][i]]
                // Broken, jagged edges inside the pane (the outer edge stays as it is);
                // neighbours share each edge exactly, so nothing gaps.
                var pts: [CGPoint] = []
                for k in 0..<corners.count {
                    let a = corners[k], b = corners[(k + 1) % corners.count]
                    pts.append(a)
                    let outer = (j == 0 && k < corners.count - 3) || (i == cols - 1 && k == corners.count - 3)
                        || (j == rows - 1 && k == corners.count - 2) || (i == 0 && k == corners.count - 1)
                    if !outer { pts += Self.jag(a, b) }
                }
                list.append(Facet(points: pts, center: Self.centroid(corners), path: Self.polygon(pts)))
            }
        }
        facets = list

        var top = Path()
        top.move(to: grid[0][0])
        for i in 0..<cols {
            for c in crags[i] { top.addLine(to: c) }
            top.addLine(to: grid[0][i + 1])
        }
        topEdge = top
        var out = top
        out.addLine(to: CGPoint(x: wall.maxX, y: wall.maxY))
        out.addLine(to: CGPoint(x: wall.minX, y: wall.maxY))
        out.closeSubpath()
        outline = out

        // The glass: made once from the painting, never blurred live.
        frostedSky = Self.frostedWorld(screen: layout.size, skyWidth: skyRect.width)

        // Shards: some pieces stay whole slabs, most split, some into slivers.
        var pieces: [Shard] = []
        for (fi, f) in list.enumerated() {
            let roll = rng.next()
            var polys: [[CGPoint]] = []
            if roll < 0.24 {
                polys = [f.points]
            } else if roll < 0.66 {
                let n = f.points.count
                let k = n / 2
                polys = [Array(f.points[0...k]), Array(f.points[k...]) + [f.points[0]]]
            } else {
                // Slivers: four wedges from the middle, each keeping its stretch of broken edge.
                let c = f.center
                let n = f.points.count
                for q in 0..<4 {
                    let from = q * n / 4, to = (q + 1) * n / 4
                    var wedge = [c]
                    for i in from...to { wedge.append(f.points[i % n]) }
                    polys.append(wedge)
                }
            }
            for poly in polys {
                let c = Self.centroid(poly)
                let local = poly.map { CGPoint(x: $0.x - c.x, y: $0.y - c.y) }
                let path = Self.polygon(local)
                let b = path.boundingRect
                // The edge facing up and left catches the light; slabs sometimes a second.
                var edges: [(CGPoint, CGPoint, CGFloat)] = []
                for i in 0..<local.count {
                    let a = local[i], e = local[(i + 1) % local.count]
                    let mid = CGPoint(x: (a.x + e.x) / 2, y: (a.y + e.y) / 2)
                    edges.append((a, e, -(mid.x + mid.y * 1.4)))
                }
                edges.sort { $0.2 > $1.2 }
                let lit = edges.prefix(poly.count > 3 ? 2 : 1).map { ($0.0, $0.1) }
                pieces.append(Shard(facet: fi, center: c, local: path, bounds: b, image: nil, litEdges: lit,
                                    size: sqrt(b.width * b.height), spin: (rng.next() - 0.5) * 7,
                                    tumble: 2 + rng.next() * 5, phase: rng.next() * 6.28, hue: Int(rng.next() * 3)))
            }
        }
        if let sky = frostedSky {
            let fmt = UIGraphicsImageRendererFormat()
            fmt.scale = 2
            fmt.opaque = false
            let ui = UIImage(cgImage: sky)
            let skyRect = self.skyRect
            for i in pieces.indices {
                let s = pieces[i]
                let bounds = s.bounds.offsetBy(dx: s.center.x, dy: s.center.y).insetBy(dx: -1, dy: -1)
                let path = s.local
                let center = s.center
                pieces[i].image = UIGraphicsImageRenderer(size: bounds.size, format: fmt).image { ctx in
                    let cg = ctx.cgContext
                    cg.translateBy(x: -bounds.minX, y: -bounds.minY)
                    cg.translateBy(x: center.x, y: center.y)
                    cg.addPath(path.cgPath)
                    cg.clip()
                    cg.translateBy(x: -center.x, y: -center.y)
                    ui.draw(in: skyRect.offsetBy(dx: 3, dy: 5))
                    // A cold sheen across the face, darker toward one corner.
                    UIColor(white: 1, alpha: 0.07).setFill()
                    cg.fill(bounds)
                    let colors = [UIColor(red: 0.66, green: 0.84, blue: 0.98, alpha: 0.34).cgColor,
                                  UIColor(red: 0.05, green: 0.1, blue: 0.22, alpha: 0.0).cgColor,
                                  UIColor(red: 0.0, green: 0.02, blue: 0.08, alpha: 0.35).cgColor]
                    if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 0.5, 1]) {
                        cg.drawLinearGradient(g, start: CGPoint(x: bounds.minX, y: bounds.minY),
                                              end: CGPoint(x: bounds.maxX, y: bounds.maxY), options: [])
                    }
                }.cgImage
                pieces[i].bounds = CGRect(x: bounds.minX - center.x, y: bounds.minY - center.y, width: bounds.width, height: bounds.height)
            }
        }
        shards = pieces
        push = Array(repeating: .zero, count: pieces.count)

        // Fault lines as tapered windows: the crack a hairline, the vein wide and branching.
        var fs: [(easy: Fault, hard: Fault)] = []
        for round in 0..<3 {
            let f = layout.faults(round: round)
            // The vein grows round by round: round three's is the big one.
            let veinWidth: CGFloat = [9, 12, 16][round], veinBranches = [3, 4, 6][round]
            fs.append((Self.fault(f.easy, width: 3, branches: 1, seed: Double(round), rng: &rng),
                       Self.fault(f.hard, width: veinWidth, branches: veinBranches, seed: Double(round) + 7, rng: &rng)))
        }
        faults = fs

        // Frost: fine speckle densest just under the jagged top.
        var fr: [(p: CGPoint, r: CGFloat, a: Double, phase: Double)] = []
        let topPts = grid[0]
        for _ in 0..<170 {
            let u = rng.next()
            let i = min(cols - 1, Int(u * Double(cols)))
            let a = topPts[i], b = topPts[i + 1]
            let v = CGFloat(rng.next())
            let depth = CGFloat(pow(rng.next(), 2.2)) * 46
            let p = CGPoint(x: a.x + (b.x - a.x) * v, y: a.y + (b.y - a.y) * v + depth + 3)
            let alpha = (0.2 + rng.next() * 0.5) * Double(1 - depth / 60)
            fr.append((p: p, r: r(0.4, 1.5), a: alpha, phase: rng.next() * 6.28))
        }
        frost = fr
        bubbles = (0..<16).map { _ in
            (p: CGPoint(x: r(0.05, 0.95) * layout.size.width, y: wall.minY + r(0.15, 0.9) * wall.height),
             len: r(4, 11), angle: -1.45 + rng.next() * 0.5, a: 0.1 + rng.next() * 0.16)
        }
        var hs: [Path] = []
        for _ in 0..<5 {
            var p = CGPoint(x: r(0.05, 0.95) * layout.size.width, y: wall.minY + r(0.1, 0.8) * wall.height)
            var a = rng.next() * 6.28
            var path = Path()
            path.move(to: p)
            for _ in 0..<7 {
                a += (rng.next() - 0.5) * 0.6
                p = CGPoint(x: p.x + CGFloat(cos(a)) * r(14, 26), y: p.y + CGFloat(sin(a)) * r(14, 26))
                path.addLine(to: p)
            }
            hs.append(path)
        }
        hints = hs

        // Snow on the fur: soft clumps along the head, the ears, the back and the tail.
        var s: [Speck] = []
        let spots: [(CGFloat, CGFloat)] = [
            (-0.15, -0.31), (-0.08, -0.335), (0.0, -0.345), (0.08, -0.335), (0.15, -0.31),
            (-0.11, -0.27), (0.11, -0.27), (-0.27, -0.42), (0.26, -0.42), (-0.22, -0.36), (0.21, -0.36),
            (-0.24, 0.03), (-0.17, -0.0), (0.19, 0.0), (0.25, 0.04), (-0.05, -0.27), (0.06, -0.265),
            (-0.36, 0.22), (-0.42, 0.28), (-0.3, 0.27),
        ]
        for (k, spot) in spots.enumerated() {
            let lobes = (0..<(3 + k % 3)).map { _ in CGVector(dx: r(-0.9, 0.9), dy: r(-0.5, 0.5)) }
            s.append(Speck(offset: CGPoint(x: spot.0 + r(-0.012, 0.012), y: spot.1 + r(-0.01, 0.01)),
                           radius: r(2.4, 4.2), group: k % 3, delay: rng.next() * 0.9, lobes: lobes))
        }
        specks = s

        motes = (0..<28).map { _ in
            Mote(angle: rng.next() * 6.28, speed: 50 + rng.next() * 170, size: r(0.7, 2.1), life: 0.55 + rng.next() * 0.5)
        }
        glitter = (0..<150).map { _ in
            Glitter(p: CGPoint(x: r(0, 1) * layout.size.width, y: wall.minY + r(0, 1) * wall.height),
                    v: CGVector(dx: r(-40, 40), dy: r(-30, 20)), r: r(0.5, 1.6), life: 1.2 + rng.next() * 1.3, phase: rng.next() * 6.28)
        }
    }

    // MARK: Keeping up with the engine

    func sync(_ e: RevontuletEngine) {
        while impactsSeen < e.impacts.count {
            let k = impactsSeen
            let hit = e.impacts[k]
            var rng = Rng(seed: e.seed &+ UInt64(k * 977 + 13))
            cracks.append(Self.makeCracks(from: hit.point, pieces: hit.pieces, breaking: hit.breaking, rng: &rng))
            if !hit.breaking {
                var near: [(i: Int, d: CGFloat)] = []
                for i in facets.indices where fallAt[i] == nil {
                    near.append((i, dist(facets[i].center, hit.point)))
                }
                near.sort { $0.d < $1.d }
                for (n, item) in near.prefix(hit.pieces).enumerated() {
                    fallAt[item.i] = hit.time + 0.08 + 0.07 * Double(n)
                    rims[item.i] = Self.rim(of: facets[item.i], index: item.i)
                }
                for (i, s) in shards.enumerated() where fallAt[s.facet] != nil && push[i] == .zero {
                    let dx = s.center.x - hit.point.x, dy = s.center.y - hit.point.y
                    let d = max(hypot(dx, dy), 1)
                    let v = 50 + 90 * rng.next()
                    push[i] = CGVector(dx: dx / d * v, dy: dy / d * v - 70)
                }
            } else {
                burstPoint = hit.point
                for (i, s) in shards.enumerated() where fallAt[s.facet] == nil {
                    let dx = s.center.x - hit.point.x, dy = s.center.y - hit.point.y
                    let d = max(hypot(dx, dy), 1)
                    // Small pieces fly further; everything is blown outward and up a little.
                    let v = (160 + 260 * rng.next()) * Double(min(1.6, 40 / max(s.size, 16)))
                    push[i] = CGVector(dx: dx / d * v, dy: dy / d * v - 120 * rng.next())
                }
            }
            impactsSeen += 1
        }
        while strokesSeen < e.strokes.count {
            let now = e.strokes[strokesSeen].startUptime + Double(e.strokes[strokesSeen].durationMs) / 1000
            for (i, s) in specks.enumerated() where s.group == strokesSeen && speckGone[i] == nil {
                speckGone[i] = now + 0.04 * Double(i % 5)
            }
            strokesSeen += 1
        }
    }

    /// A broken, uneven, lit edge for a hole: pieces of edge of three weights (some missing),
    /// small chips, and a few stars inside.
    private static func rim(of f: Facet, index i: Int) -> Rim {
        var buckets = [Path(), Path(), Path()]
        var lits = [0.0, 0.0, 0.0], counts = [0, 0, 0]
        var chips = Path()
        let pts = f.points
        var n = 0
        func noise(_ a: Int, _ k: Double) -> Double { abs(sin(Double(a) * k) * 43758.5453).truncatingRemainder(dividingBy: 1) }
        for k in 0..<pts.count {
            let a = pts[k], b = pts[(k + 1) % pts.count]
            for piece in 0..<3 {
                n += 1
                let r1 = noise(i * 31 + n, 12.9898), r2 = noise(i * 17 + n, 78.233)
                guard r1 > 0.34 else { continue }
                let u0 = CGFloat(piece) / 3, u1 = CGFloat(piece + 1) / 3
                let p0 = CGPoint(x: a.x + (b.x - a.x) * u0, y: a.y + (b.y - a.y) * u0)
                let p1 = CGPoint(x: a.x + (b.x - a.x) * u1, y: a.y + (b.y - a.y) * u1)
                let bucket = r2 < 0.45 ? 0 : r2 < 0.8 ? 1 : 2
                buckets[bucket].move(to: p0)
                buckets[bucket].addLine(to: p1)
                lits[bucket] += 0.2 + 0.7 * r1 * r1
                counts[bucket] += 1
                if r2 > 0.55 {
                    let m = CGPoint(x: (p0.x + p1.x) / 2, y: (p0.y + p1.y) / 2)
                    chips.move(to: CGPoint(x: m.x - 3, y: m.y - 1))
                    chips.addLine(to: CGPoint(x: m.x + 1, y: m.y - 4))
                    chips.addLine(to: CGPoint(x: m.x + 3, y: m.y + 2))
                    chips.closeSubpath()
                }
            }
        }
        let widths: [CGFloat] = [1.6, 4, 7.5]
        let edges = (0..<3).filter { counts[$0] > 0 }.map { (path: buckets[$0], width: widths[$0], lit: lits[$0] / Double(counts[$0])) }
        var stars: [(p: CGPoint, len: CGFloat, phase: Double)] = []
        let box = f.path.boundingRect
        for k in 0..<6 {
            let dk = Double(i * 7 + k)
            let fx = noise(Int(dk * 3 + 1), 12.9898), fy = noise(Int(dk * 5 + 2), 78.233)
            let p = CGPoint(x: box.minX + box.width * CGFloat(fx), y: box.minY + box.height * CGFloat(fy))
            if f.path.contains(p) { stars.append((p: p, len: CGFloat(2 + 2.5 * fy), phase: dk)) }
        }
        return Rim(edges: edges, chips: chips, stars: stars)
    }

    /// When the larger shards of the burst land in the snow, in seconds after the burst,
    /// worked out from the same motion the painter draws (for the burst's haptic ticks).
    func shardLandings(limit: Int = 12) -> [Double] {
        guard !push.isEmpty else { return [] }
        let floor = Double(layout.wall.maxY + layout.size.height * 0.08)
        func tau(_ age: Double) -> Double {
            if age < 0.45 { return 0.3 * age }
            if age < 0.95 { let d = age - 0.45; return 0.135 + 0.3 * d + 0.7 * d * d }
            return 0.46 + (age - 0.95)
        }
        var times: [(Double, CGFloat)] = []
        for (i, s) in shards.enumerated() where fallAt[s.facet] == nil && s.size > 26 {
            let v = push[i]
            var age = 0.0
            while age < 2.4 {
                let t = tau(age)
                let y = Double(s.center.y) + Double(v.dy) * t + 0.5 * 1100 * t * t
                if y >= floor { times.append((age, s.size)); break }
                age += 0.02
            }
        }
        // The biggest pieces first, then in time, never two ticks closer than 60 ms.
        let chosen = times.sorted { $0.1 > $1.1 }.prefix(limit * 2).map(\.0).sorted()
        var out: [Double] = []
        for t in chosen where (out.last.map { t - $0 >= 0.06 } ?? true) { out.append(t) }
        return Array(out.prefix(limit))
    }

    /// Snow directly under a stroking finger comes off at once: a band follows the hand.
    func brush(near p: CGPoint, at now: Double) {
        let sq = layout.foxSquare(.warm)
        for (i, s) in specks.enumerated() where speckGone[i] == nil {
            let q = CGPoint(x: sq.midX + s.offset.x * sq.width, y: sq.midY + s.offset.y * sq.height)
            if abs(q.x - p.x) < sq.width * 0.13, abs(q.y - p.y) < sq.height * 0.1 { speckGone[i] = now }
        }
    }

    /// The pieces still standing at `now` (before the burst), as one path. Rebuilt only
    /// when a piece falls.
    func standing(at now: Double, burstAt: Double?) -> Path {
        let burst = burstAt.map { now >= $0 } ?? false
        var fallen = 0
        for t in fallAt.values where t <= now { fallen += 1 }
        if let c = standingCache, c.fallen == fallen, c.burst == burst { return c.path }
        var p = Path()
        if !burst {
            if fallen == 0 {
                p = outline
            } else {
                for (i, f) in facets.enumerated() where (fallAt[i].map { $0 > now } ?? true) {
                    p.addPath(f.path)
                }
            }
        }
        standingCache = (fallen, burst, p)
        return p
    }

    // MARK: Making things once

    /// The night painting, small, blurred wide, darkened and cooled: the sky seen through
    /// thick ice.
    private static func frostedWorld(screen: CGSize, skyWidth: CGFloat) -> CGImage? {
        guard let ui = UIImage(named: "world-night"), let cg = ui.cgImage else { return nil }
        let w = 300.0
        let k = w / Double(cg.width)
        let small = CGRect(x: 0, y: 0, width: w, height: Double(cg.height) * k)
        let pointsPerPixel = Double(skyWidth) / w
        let input = CIImage(cgImage: cg).transformed(by: CGAffineTransform(scaleX: k, y: k))
        var img = input.clampedToExtent().applyingGaussianBlur(sigma: 12 / pointsPerPixel)
        img = img.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.42, kCIInputBrightnessKey: -0.04,
                                                                 kCIInputContrastKey: 0.92])
        img = img.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0.34, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 0.44, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0.7, w: 0),
            "inputBiasVector": CIVector(x: 0.0, y: 0.02, z: 0.06, w: 0),
        ])
        return CIContext().createCGImage(img.cropped(to: small), from: small)
    }

    private static func fault(_ pts: [CGPoint], width: CGFloat, branches: Int, seed: Double, rng: inout Rng) -> Fault {
        // A natural crack: the zigzag smoothed into a wandering curve, with fine irregularity.
        var line = resample(pts, n: 28)
        for _ in 0..<3 {
            var smoothed = line
            for i in 1..<(line.count - 1) {
                smoothed[i] = CGPoint(x: (line[i - 1].x + line[i].x * 2 + line[i + 1].x) / 4,
                                      y: (line[i - 1].y + line[i].y * 2 + line[i + 1].y) / 4)
            }
            line = smoothed
        }
        for i in 1..<(line.count - 1) {
            line[i].y += CGFloat(sin(Double(i) * 2.3 + seed) * 1.6)
            line[i].x += CGFloat(cos(Double(i) * 1.7 + seed) * 1.0)
        }
        var window = taper(line, width: width, seed: seed)
        var core = Path()
        core.addLines(line)
        // Branches leave from inside the line, thinner, also ending in points.
        for b in 0..<branches {
            let i = 5 + Int(Double(line.count - 10) * (Double(b) + 0.5) / Double(max(branches, 1)))
            let a = line[i], next = line[min(line.count - 1, i + 1)]
            let dir = atan2(Double(next.y - a.y), Double(next.x - a.x)) + (b % 2 == 0 ? -1 : 1) * (0.7 + 0.5 * rng.next())
            var q = a
            var bl: [CGPoint] = [q]
            let len = (14 + 20 * rng.next()) * Double(width / 5)
            var d = dir
            for _ in 0..<5 {
                d += (rng.next() - 0.5) * 0.5
                q = CGPoint(x: q.x + CGFloat(cos(d) * len / 5), y: q.y + CGFloat(sin(d) * len / 5))
                bl.append(q)
            }
            window.addPath(taper(bl, width: width * 0.45, seed: seed + Double(b)))
            core.move(to: bl[0])
            core.addLines(bl)
        }
        var length: CGFloat = 0
        for i in 1..<line.count { length += dist(line[i - 1], line[i]) }
        let knots = [0.22, 0.5, 0.78].map { line[Int(Double(line.count - 1) * $0)] }
        return Fault(window: window, core: core, line: line, knots: knots, center: line[line.count / 2], length: length)
    }

    /// Three jagged points between two corners, the same whichever way the edge is walked.
    private static func jag(_ a: CGPoint, _ b: CGPoint) -> [CGPoint] {
        let flip = (a.x, a.y) > (b.x, b.y)
        let p = flip ? b : a, q = flip ? a : b
        let dx = q.x - p.x, dy = q.y - p.y
        let len = max(hypot(dx, dy), 0.001)
        let nx = -dy / len, ny = dx / len
        var r = Rng(seed: UInt64(abs(Int(p.x * 131 + p.y * 977 + q.x * 7 + q.y * 3))) &+ 99)
        var out: [CGPoint] = []
        for t in [0.22, 0.5, 0.78] {
            let off = CGFloat(r.next() - 0.5) * min(12, len * 0.16)
            let along = CGFloat(t + (r.next() - 0.5) * 0.08)
            out.append(CGPoint(x: p.x + dx * along + nx * off, y: p.y + dy * along + ny * off))
        }
        return flip ? out.reversed() : out
    }

    /// Points evenly spaced along a polyline.
    private static func resample(_ pts: [CGPoint], n: Int) -> [CGPoint] {
        var lengths: [CGFloat] = [0]
        for i in 1..<pts.count { lengths.append(lengths[i - 1] + dist(pts[i - 1], pts[i])) }
        let total = lengths.last ?? 1
        var out: [CGPoint] = []
        var j = 0
        for k in 0..<n {
            let target = total * CGFloat(k) / CGFloat(n - 1)
            while j < pts.count - 2 && lengths[j + 1] < target { j += 1 }
            let seg = max(lengths[j + 1] - lengths[j], 0.0001)
            let u = (target - lengths[j]) / seg
            out.append(CGPoint(x: pts[j].x + (pts[j + 1].x - pts[j].x) * u, y: pts[j].y + (pts[j + 1].y - pts[j].y) * u))
        }
        return out
    }

    /// A crack shape along a line: widest in the middle, irregular, ending in points.
    private static func taper(_ line: [CGPoint], width: CGFloat, seed: Double) -> Path {
        var left: [CGPoint] = [], right: [CGPoint] = []
        let n = line.count
        for i in 0..<n {
            let a = line[max(0, i - 1)], b = line[min(n - 1, i + 1)]
            let dx = b.x - a.x, dy = b.y - a.y
            let len = max(hypot(dx, dy), 0.0001)
            let nx = -dy / len, ny = dx / len
            let t = Double(i) / Double(n - 1)
            let w = width * CGFloat(pow(sin(.pi * t), 0.7) * (0.65 + 0.35 * sin(t * 17 + seed))) / 2
            let skew = CGFloat(0.8 + 0.4 * sin(t * 9 + seed * 2))
            left.append(CGPoint(x: line[i].x + nx * w * skew, y: line[i].y + ny * w * skew))
            right.append(CGPoint(x: line[i].x - nx * w / skew, y: line[i].y - ny * w / skew))
        }
        return polygon(left + right.reversed())
    }

    private static func makeCracks(from p: CGPoint, pieces: Int, breaking: Bool, rng: inout Rng) -> [Crack] {
        var out: [Crack] = []
        let mains = breaking ? 12 : 4 + pieces * 2
        let reach: CGFloat = breaking ? 260 : CGFloat(40 + 26 * pieces)
        for m in 0..<mains {
            let spread: Double = Double(m) / Double(mains) * 2 * Double.pi
            var a: Double = spread + (rng.next() - 0.5) * 0.7
            let length = reach * CGFloat(0.5 + 0.7 * rng.next())
            let segs = 7 + Int(rng.next() * 4)
            var q = p
            var pts = [q]
            for s in 0..<segs {
                a += (rng.next() - 0.5) * 0.7
                let step = length / CGFloat(segs) * CGFloat(0.7 + 0.6 * rng.next())
                q = CGPoint(x: q.x + CGFloat(cos(a)) * step, y: q.y + CGFloat(sin(a)) * step)
                pts.append(q)
                if rng.next() < 0.28 {
                    var b = a + (rng.next() < 0.5 ? -1 : 1) * (0.5 + 0.6 * rng.next())
                    var bq = q
                    var bpts = [bq]
                    for _ in 0..<(2 + Int(rng.next() * 3)) {
                        b += (rng.next() - 0.5) * 0.6
                        let st = length * 0.1 * CGFloat(0.6 + 0.8 * rng.next())
                        bq = CGPoint(x: bq.x + CGFloat(cos(b)) * st, y: bq.y + CGFloat(sin(b)) * st)
                        bpts.append(bq)
                    }
                    out.append(Crack(points: bpts, width: 0.5, delay: 0.2 * Double(s + 1) / Double(segs)))
                }
            }
            out.append(Crack(points: pts, width: breaking ? 1.0 : 0.8, delay: 0))
        }
        return out
    }

    private static func polygon(_ pts: [CGPoint]) -> Path {
        var p = Path()
        p.addLines(pts)
        p.closeSubpath()
        return p
    }

    private static func centroid(_ pts: [CGPoint]) -> CGPoint {
        CGPoint(x: pts.map(\.x).reduce(0, +) / CGFloat(pts.count), y: pts.map(\.y).reduce(0, +) / CGFloat(pts.count))
    }
}

func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }
