import SwiftUI

/// The shapes the game draws, worked out once per screen: the pane of ice as real fracture
/// pieces (the same pieces fall out on impacts and fly apart in the burst), the cracks each
/// impact leaves, and the snow on the fox's fur. Kept in step with the engine by `sync`.
/// Visual only: nothing here is measured.
final class RevontuletArt {
    struct Facet {
        var points: [CGPoint]
        var center: CGPoint
        var path: Path
        /// −1...1: a little lighter or darker than its neighbours.
        var shade: Double
        /// 0...1: how much its edges catch the light.
        var glint: Double
        var spin: Double
        var tumble: Double
        var phase: Double
    }

    struct Crack {
        var points: [CGPoint]
        var width: CGFloat
        var delay: Double
    }

    struct Mote {
        var angle: Double
        var speed: Double
        var size: CGFloat
        var life: Double
    }

    struct Speck {
        /// From the fox's centre, in fox sizes.
        var offset: CGPoint
        var radius: CGFloat
        var group: Int
        var delay: Double
    }

    let layout: RevontuletLayout
    let facets: [Facet]
    let outline: Path
    let frost: [(p: CGPoint, r: CGFloat, a: Double, phase: Double)]
    let specks: [Speck]
    let motes: [Mote]

    /// When each facet fell out (by index).
    private(set) var fallAt: [Int: Double] = [:]
    /// The cracks of each impact, and where the burst started.
    private(set) var cracks: [[Crack]] = []
    private(set) var burstPush: [CGVector] = []
    /// When each snow speck was brushed off (by index).
    private(set) var speckGone: [Int: Double] = [:]
    private var impactsSeen = 0
    private var strokesSeen = 0

    init(layout: RevontuletLayout, seed: UInt64 = 11) {
        self.layout = layout
        var rng = Rng(seed: seed)
        let wall = layout.wall
        let cols = 6, rows = 10
        let cw = wall.width / CGFloat(cols), ch = wall.height / CGFloat(rows)
        func r(_ a: Double, _ b: Double) -> CGFloat { CGFloat(a + (b - a) * rng.next()) }

        // A jittered grid: inner points wander, the top edge is ragged, the base is buried.
        var grid: [[CGPoint]] = []
        for j in 0...rows {
            var row: [CGPoint] = []
            for i in 0...cols {
                var x = wall.minX + CGFloat(i) * cw
                var y = wall.minY + CGFloat(j) * ch
                if i > 0 && i < cols { x += r(-0.34, 0.34) * cw } else { x += r(-4, 4) }
                if j > 0 && j < rows { y += r(-0.32, 0.32) * ch }
                if j == 0 { y += r(-6, 16) }
                row.append(CGPoint(x: x, y: y))
            }
            grid.append(row)
        }
        // Crags along the top: an extra point raised between each pair.
        var crags: [CGPoint] = []
        for i in 0..<cols {
            let a = grid[0][i], b = grid[0][i + 1]
            crags.append(CGPoint(x: (a.x + b.x) / 2 + r(-0.2, 0.2) * cw, y: min(a.y, b.y) - r(6, 30)))
        }

        var list: [Facet] = []
        for j in 0..<rows {
            for i in 0..<cols {
                var pts = [grid[j][i]]
                if j == 0 { pts.append(crags[i]) }
                pts += [grid[j][i + 1], grid[j + 1][i + 1], grid[j + 1][i]]
                let c = CGPoint(x: pts.map(\.x).reduce(0, +) / CGFloat(pts.count),
                                y: pts.map(\.y).reduce(0, +) / CGFloat(pts.count))
                var path = Path()
                path.addLines(pts)
                path.closeSubpath()
                list.append(Facet(points: pts, center: c, path: path, shade: rng.next() * 2 - 1, glint: rng.next(),
                                  spin: (rng.next() - 0.5) * 4.4, tumble: 1.4 + rng.next() * 3.2, phase: rng.next() * 6.28))
            }
        }
        facets = list

        var out = Path()
        out.move(to: grid[0][0])
        for i in 0..<cols {
            out.addLine(to: crags[i])
            out.addLine(to: grid[0][i + 1])
        }
        for j in 1...rows { out.addLine(to: grid[j][cols]) }
        for i in stride(from: cols - 1, through: 0, by: -1) { out.addLine(to: grid[rows][i]) }
        for j in stride(from: rows - 1, through: 1, by: -1) { out.addLine(to: grid[j][0]) }
        out.closeSubpath()
        outline = out

        // Frost: fine specks hugging the top and the sides.
        var f: [(p: CGPoint, r: CGFloat, a: Double, phase: Double)] = []
        for k in 0..<110 {
            let side = k % 3
            let u = rng.next()
            let p: CGPoint
            switch side {
            case 0:
                let i = min(cols - 1, Int(u * Double(cols)))
                let a = grid[0][i], b = grid[0][i + 1]
                let v = CGFloat(rng.next())
                p = CGPoint(x: a.x + (b.x - a.x) * v, y: a.y + (b.y - a.y) * v + r(0, 18))
            case 1:
                p = CGPoint(x: wall.minX + r(0, 16), y: wall.minY + CGFloat(u) * wall.height * 0.9)
            default:
                p = CGPoint(x: wall.maxX - r(0, 16), y: wall.minY + CGFloat(u) * wall.height * 0.9)
            }
            let alpha = 0.25 + rng.next() * 0.5
            let ph = rng.next() * 6.28
            f.append((p: p, r: r(0.5, 1.7), a: alpha, phase: ph))
        }
        frost = f

        // Snow on the fur: across the head between the ears, the ears, the shoulders.
        var s: [Speck] = []
        let spots: [(CGFloat, CGFloat)] = [
            (-0.15, -0.31), (-0.09, -0.335), (-0.03, -0.345), (0.03, -0.345), (0.09, -0.335), (0.15, -0.31),
            (-0.12, -0.28), (0.0, -0.3), (0.12, -0.28), (-0.27, -0.41), (0.26, -0.41), (-0.22, -0.36), (0.21, -0.36),
            (-0.24, 0.02), (-0.18, -0.01), (0.2, 0.0), (0.25, 0.03), (-0.05, -0.27), (0.06, -0.265),
        ]
        for (k, spot) in spots.enumerated() {
            s.append(Speck(offset: CGPoint(x: spot.0 + r(-0.012, 0.012), y: spot.1 + r(-0.01, 0.01)),
                           radius: r(1.6, 3.2), group: k % 3, delay: rng.next() * 0.9))
        }
        specks = s

        motes = (0..<28).map { _ in
            Mote(angle: rng.next() * 6.28, speed: 50 + rng.next() * 170, size: r(0.7, 2.1), life: 0.55 + rng.next() * 0.5)
        }
    }

    // MARK: Keeping up with the engine

    func sync(_ e: RevontuletEngine) {
        while impactsSeen < e.impacts.count {
            let k = impactsSeen
            let hit = e.impacts[k]
            var rng = Rng(seed: e.seed &+ UInt64(k * 977 + 13))
            cracks.append(Self.makeCracks(from: hit.point, pieces: hit.pieces, breaking: hit.breaking, wall: layout.wall, rng: &rng))
            if !hit.breaking {
                var near: [(i: Int, d: CGFloat)] = []
                for i in facets.indices where fallAt[i] == nil {
                    near.append((i, dist(facets[i].center, hit.point)))
                }
                near.sort { $0.d < $1.d }
                let order = near.map(\.i)
                for (n, i) in order.prefix(hit.pieces).enumerated() {
                    fallAt[i] = hit.time + 0.2 + 0.11 * Double(n)
                }
            } else {
                burstPush = facets.map { f in
                    let dx = f.center.x - hit.point.x, dy = f.center.y - hit.point.y
                    let d = max(hypot(dx, dy), 1)
                    let v = 70 + 170 * rng.next()
                    return CGVector(dx: dx / d * v, dy: dy / d * v - 60 * rng.next())
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

    /// Snow directly under a stroking finger comes off at once (`p` in scene points).
    func brush(near p: CGPoint, at now: Double) {
        let L = layout
        for (i, s) in specks.enumerated() where speckGone[i] == nil {
            let q = CGPoint(x: L.foxCenter.x + s.offset.x * L.foxSize, y: L.foxCenter.y + s.offset.y * L.foxSize)
            if dist(q, p) < L.foxSize * 0.09 { speckGone[i] = now }
        }
    }

    /// The pieces still standing at `now` (before the burst), as one path.
    func standing(at now: Double, burstAt: Double?) -> Path {
        var p = Path()
        if let b = burstAt, now >= b { return p }
        for (i, f) in facets.enumerated() where (fallAt[i].map { $0 > now } ?? true) {
            p.addPath(f.path)
        }
        return p
    }

    // MARK: Cracks

    private static func makeCracks(from p: CGPoint, pieces: Int, breaking: Bool, wall: CGRect, rng: inout Rng) -> [Crack] {
        var out: [Crack] = []
        let mains = breaking ? 10 : 3 + pieces * 2
        let reach: CGFloat = breaking ? wall.width * 0.75 : CGFloat(34 + 22 * pieces)
        for m in 0..<mains {
            let spread: Double = Double(m) / Double(mains) * 2 * Double.pi
            var a: Double = spread + (rng.next() - 0.5) * 0.7
            let length = reach * CGFloat(0.55 + 0.6 * rng.next())
            let segs = 6 + Int(rng.next() * 4)
            var q = p
            var pts = [q]
            for s in 0..<segs {
                a += (rng.next() - 0.5) * 0.75
                let step = length / CGFloat(segs) * CGFloat(0.7 + 0.6 * rng.next())
                q = CGPoint(x: q.x + CGFloat(cos(a)) * step, y: q.y + CGFloat(sin(a)) * step)
                pts.append(q)
                if rng.next() < 0.32 {
                    var b = a + (rng.next() < 0.5 ? -1 : 1) * (0.5 + 0.6 * rng.next())
                    var bq = q
                    var bpts = [bq]
                    for _ in 0..<(2 + Int(rng.next() * 3)) {
                        b += (rng.next() - 0.5) * 0.6
                        let st = length * 0.12 * CGFloat(0.6 + 0.8 * rng.next())
                        bq = CGPoint(x: bq.x + CGFloat(cos(b)) * st, y: bq.y + CGFloat(sin(b)) * st)
                        bpts.append(bq)
                    }
                    out.append(Crack(points: bpts, width: 0.7, delay: 0.32 * Double(s + 1) / Double(segs)))
                }
            }
            out.append(Crack(points: pts, width: breaking ? 1.7 : 1.3, delay: 0))
        }
        return out
    }
}

func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }
