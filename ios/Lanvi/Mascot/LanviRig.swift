import SwiftUI

// The paper puppet's layout and its motion maths. No views here: `LanviPuppet`
// draws the parts; this file says where they sit and how they move at a time t.
//
// Units: pixels of the painted master fox (`master-1.png`, 2048 x 2048). Every part
// was placed by overlaying the assembled puppet on the master at half opacity until
// the two lined up. Part sizes come from `LanviArt` (written by the cut script).

enum Rig {
    /// The part of the master the fox fills (tail tip to haunch, ear tip to paws).
    static let frame = CGRect(x: 110, y: 60, width: 1604, height: 1870)
    static var canvas: CGSize { frame.size }
    /// Motion distances (`RigFrame`, `LanviMotion`) are in "motion units", tuned on the
    /// first rig; one motion unit is this many master pixels.
    static let unit: CGFloat = 1870.0 / 977.0

    /// One drawn part: its art, where its centre sits on the master, its scale,
    /// and the point it turns around (0...1 of the part).
    struct Part {
        var name: String
        var center: CGPoint
        var scale: CGFloat
        var pivot: UnitPoint
        var image: String { "puppet-" + name }
        var px: CGSize { LanviArt.px(name) }
        var size: CGSize { CGSize(width: px.width * scale, height: px.height * scale) }
        var origin: CGPoint { CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2) }
        /// Centre in canvas units (the canvas starts at `Rig.frame.origin`).
        var local: CGPoint { CGPoint(x: center.x - Rig.frame.minX, y: center.y - Rig.frame.minY) }
        /// The pivot in canvas units.
        var pivotPoint: CGPoint {
            CGPoint(x: origin.x + pivot.x * size.width - Rig.frame.minX,
                    y: origin.y + pivot.y * size.height - Rig.frame.minY)
        }
    }

    // Back to front: tail, ears, body, front legs, head, eyes, mouth. The front legs
    // never swing: the paws stay planted and move only with the whole fox.
    // The tail's flat tab (its base) tucks behind the body on the right.
    static let tail = Part(name: "tail", center: CGPoint(x: 570, y: 1500), scale: 1.25, pivot: UnitPoint(x: 0.88, y: 0.66))
    static let earL = Part(name: "ear-left", center: CGPoint(x: 782, y: 492), scale: 1.3, pivot: UnitPoint(x: 0.36, y: 0.8))
    static let earR = Part(name: "ear-right", center: CGPoint(x: 1419, y: 492), scale: 1.3, pivot: UnitPoint(x: 0.64, y: 0.8))
    static let body = Part(name: "body", center: CGPoint(x: 1084, y: 1466), scale: 1.31, pivot: UnitPoint(x: 0.5, y: 1.0))
    static let legL = Part(name: "leg-left", center: CGPoint(x: 772, y: 1640), scale: 1.06, pivot: .center)
    static let legR = Part(name: "leg-right", center: CGPoint(x: 1196, y: 1640), scale: 1.06, pivot: .center)
    /// The head turns low in its neck stub, under the chin, so tilting never opens a gap.
    static let head = Part(name: "head", center: CGPoint(x: 1086, y: 832), scale: 1.5, pivot: UnitPoint(x: 0.5, y: 0.85))

    /// The fox's visual centre (head and body, not the tail), in master pixels. The
    /// view centres on this; the tail overhangs to the left.
    static let centerX: CGFloat = 1085

    /// Where the head turns, in canvas units.
    static var neck: CGPoint { head.pivotPoint }

    /// Face parts sit in head pixels from the head's centre (then scale with the head).
    static let eyeL = CGPoint(x: -144, y: -15)
    static let eyeR = CGPoint(x: 148, y: -15)
    static let eyeScale: CGFloat = 1.033
    static let mouthTop = CGPoint(x: 1, y: 91)

    static func headToCanvas(_ p: CGPoint) -> CGPoint {
        let c = head.local
        return CGPoint(x: c.x + p.x * head.scale, y: c.y + p.y * head.scale)
    }

    /// The tail's white tip at rest, in canvas units (for the fox-fire glow).
    static var tailTip: CGPoint {
        let o = tail.origin, s = tail.size
        return CGPoint(x: o.x + 0.14 * s.width - frame.minX, y: o.y + 0.22 * s.height - frame.minY)
    }
}

// MARK: - Face pieces

/// Eye sets from the face sheet. Each pair is saved as two halves (`<name>-l`, `-r`)
/// so each eye sits on its own white patch on the head.
enum EyeShape: Equatable {
    case open, half, closed, happy, left, right, up, wide

    var name: String {
        switch self {
        case .open: return "eyes-open"
        case .half: return "eyes-half"
        case .closed: return "eyes-closed"
        case .happy: return "eyes-happy"
        case .left: return "eyes-left"
        case .right: return "eyes-right"
        case .up: return "eyes-up"
        case .wide: return "eyes-wide"
        }
    }

    /// How far this shape's centre sits below the open eye's centre (head pixels),
    /// so lids and arcs land where the open eye was.
    var dropY: CGFloat {
        switch self {
        case .closed: return 22
        case .happy: return -4
        case .half: return 4
        case .up: return -4
        default: return 0
        }
    }
}

enum MouthShape: Equatable {
    case smile, o, happy, yawn, flat
    var name: String {
        switch self {
        case .smile: return "mouth-smile"
        case .o: return "mouth-o"
        case .happy: return "mouth-happy"
        case .yawn: return "mouth-yawn"
        case .flat: return "mouth-flat"
        }
    }
    /// Scale relative to the head.
    var scale: CGFloat {
        switch self {
        case .smile: return 0.453
        case .o: return 0.42
        case .happy: return 0.6
        case .yawn: return 0.55
        case .flat: return 0.42
        }
    }
    /// Extra drop below the mouth line, in head pixels.
    var dropY: CGFloat {
        switch self {
        case .flat: return 10
        case .o: return 2
        default: return 0
        }
    }
}

// MARK: - Depth and bends (measured on the painted parts)

extension Rig {
    /// The head turns in space around this sphere: its centre and radii as shares of
    /// the head picture (the round skull and face). The face markings (`LanviArt.layer`)
    /// and the eyes and mouth move as points on it; the head's outline stays.
    static let headSphereCenter = UnitPoint(x: 0.5, y: 0.467)
    static let headSphereRadius = CGSize(width: 0.418, height: 0.387)
    /// Head pixels (as `eyeL`, `mouthTop`) to sphere units (-1...1).
    static func sphere(_ p: CGPoint) -> CGPoint {
        let w = LanviArt.px("head").width, h = LanviArt.px("head").height
        return CGPoint(x: (p.x + w / 2 - headSphereCenter.x * w) / (headSphereRadius.width * w),
                       y: (p.y + h / 2 - headSphereCenter.y * h) / (headSphereRadius.height * h))
    }
    /// Sphere units back to head pixels from the head's centre.
    static func headPixels(_ u: CGPoint) -> CGPoint {
        let w = LanviArt.px("head").width, h = LanviArt.px("head").height
        return CGPoint(x: u.x * headSphereRadius.width * w + headSphereCenter.x * w - w / 2,
                       y: u.y * headSphereRadius.height * h + headSphereCenter.y * h - h / 2)
    }
    /// Biggest turn (radians) at a head direction of 1 (the direction is kept inside the
    /// unit circle). Chosen so the eyes and their white patches move at most 0.06 of the
    /// head's width sideways and 0.04 up or down: the face never slides off the head.
    static let maxYaw = 0.15
    static let maxPitch = 0.11
    /// The whole head's perspective turn at a head direction of 1 (degrees), and how
    /// strong the perspective is (SwiftUI's relative vanishing point). Chosen so the head's
    /// outline moves at most 0.03 of its width.
    static let turnYaw = 10.0
    static let turnPitch = 6.0
    static let turnPerspective: CGFloat = 0.7
    /// On top of it, the far half of the head tucks in and the near half grows (shares of
    /// its width, at a full turn).
    static let farCheekTuck: CGFloat = 0.02
    static let nearCheekGrow: CGFloat = 0.01

    /// How far the head's left and right edges move at a head direction `dirX` (shares of
    /// the head's width; + = to the viewer's right): the perspective turn (SwiftUI's
    /// `rotation3DEffect` projects x to x cos a / (1 + x sin a m), m = perspective / the
    /// frame's longer side, as measured), the cheek halves and the head's shift.
    static func headEdges(dirX: Double) -> (left: CGFloat, right: CGFloat) {
        let w = head.size.width
        let a = turnYaw * dirX * .pi / 180
        let m = Double(turnPerspective / max(canvas.width, canvas.height))
        func project(_ x: Double) -> Double { x * cos(a) / (1 + x * sin(a) * m) }
        let half = Double(w / 2)
        let shift = dirX * 5 * Double(unit)               // `sample`: headX += dirX * 5
        let tuck = Double(farCheekTuck), grow = Double(nearCheekGrow)
        let l = project(-half) + half + (dirX > 0 ? -grow : tuck) * abs(dirX) * half + shift
        let r = project(half) - half + (dirX > 0 ? -tuck : grow) * abs(dirX) * half + shift
        return (CGFloat(l) / w, CGFloat(r) / w)
    }

    /// The most a look shifts each eye on its white patch (head pixels), on top of the
    /// patch's own move. The pupils carry the look now, so the eyes themselves stay put.
    static let eyeTravel = CGSize(width: 0, height: 0)

    /// How far each pupil (iris and glints) moves inside its eye at a full look, in the
    /// eye picture's pixels; the glints move a quarter as far.
    static let pupilTravel = CGSize(width: 24, height: 15)

    /// Where the pupil sits inside the eye for a pose, from rest (eye picture pixels).
    /// `eyeX`, `eyeY` are where the eyes look (about -7...7 head pixels; `eyeCross` pulls
    /// the two pupils toward each other, for a near target or a boop). Soft-limited, so
    /// the iris never leaves the white.
    static func pupil(left: Bool, pose q: Pose) -> CGPoint {
        let gx = tanh((q.eyeX + (left ? q.eyeCross : -q.eyeCross)) / 7)
        let gy = tanh(q.eyeY / 6)
        return CGPoint(x: gx * pupilTravel.width, y: gy * pupilTravel.height)
    }

    /// Where a face point (head pixels from the head's centre) moves when the head faces
    /// `dirX`, `dirY` (head pixels), and how much the face squeezes there.
    static func faceShift(_ base: CGPoint, dirX: Double, dirY: Double) -> (dx: CGFloat, dy: CGFloat, sx: CGFloat, sy: CGFloat) {
        let t = turn(sphere(base), yaw: dirX * maxYaw, pitch: dirY * maxPitch)
        let to = headPixels(t.p)
        return (to.x - base.x, to.y - base.y, t.sx, t.sy)
    }

    /// Where an eye's centre and its white patch's centre sit for a pose (head pixels from
    /// the head's centre). The eye rides its patch, plus a small look shift that is
    /// limited by `eyeTravel`. The puppet draws with this; the eye tests check it.
    static func eyeOnPatch(left: Bool, dropY: CGFloat, pose q: Pose) -> (eye: CGPoint, patch: CGPoint) {
        let patchHome = marking(left ? "face-patch-l" : "face-patch-r")
        let s = faceShift(patchHome, dirX: q.dirX, dirY: q.dirY)
        let home = left ? eyeL : eyeR
        let w = Double(eyeTravel.width), h = Double(eyeTravel.height)
        let gx = w > 0 ? CGFloat(w * tanh((q.eyeX + (left ? q.eyeCross : -q.eyeCross)) / w)) : 0
        let gy = h > 0 ? CGFloat(h * tanh(q.eyeY / h)) : 0
        return (CGPoint(x: home.x + gx + s.dx, y: home.y + dropY + gy + s.dy),
                CGPoint(x: patchHome.x + s.dx, y: patchHome.y + s.dy))
    }

    /// The chest bib swells around this point of the body picture when breathing in.
    static let chestCenter = UnitPoint(x: 0.496, y: 0.36)

    /// Where a point on the face sphere lands after the head turns (yaw, pitch in
    /// radians), and how much the face is squeezed or opened there (x, y scale).
    static func turn(_ u: CGPoint, yaw: Double, pitch: Double) -> (p: CGPoint, sx: CGFloat, sy: CGFloat) {
        let h = Double.pi / 2
        let x = Double(u.x), y = Double(u.y)
        let ry = (1 - min(y * y, 0.999)).squareRoot()
        let lon = asin(max(min(x / ry, 1), -1))
        let lon2 = max(min(lon + yaw, h), -h)
        let x2 = ry * sin(lon2)
        let rx = (1 - min(x2 * x2, 0.999)).squareRoot()
        let lat = asin(max(min(y / rx, 1), -1))
        let lat2 = max(min(lat + pitch, h), -h)
        let y2 = rx * sin(lat2)
        let sx = cos(lon2) / max(cos(lon), 0.2)
        let sy = cos(lat2) / max(cos(lat), 0.2)
        return (CGPoint(x: x2, y: y2), CGFloat(max(min(sx, 1.4), 0.6)), CGFloat(max(min(sy, 1.4), 0.6)))
    }
}

// MARK: - One frame of the puppet

/// One layer of motion. Every number is a change from the rest pose (0 = rest), so
/// layers simply add up. Angles in degrees, distances in motion units (`Rig.unit`),
/// scales as fractions (0.02 = 2 % bigger).
struct Pose {
    // The whole fox, around its feet.
    var rootX = 0.0, rootY = 0.0, rootSX = 0.0, rootSY = 0.0, rootTilt = 0.0
    // The body: stretch from the feet, chest swell, feet spread on landing.
    var bodySX = 0.0, bodySY = 0.0, chest = 0.0, spread = 0.0
    // The head: shift, tilt around the neck (degrees, + = clockwise), and where it faces.
    var headX = 0.0, headY = 0.0, headTilt = 0.0
    /// Where the head faces, -1...1: + x to the viewer's right, + y down.
    var dirX = 0.0, dirY = 0.0
    /// Ears: + = flops outward, - = perks up and in. Stretch along their length.
    var earL = 0.0, earR = 0.0, earLS = 0.0, earRS = 0.0
    /// Tail: base angle (+ = clockwise, the tail lifts) and curl along its length.
    var tail = 0.0, tailCurl = 0.0
    /// Eyes shift (head pixels), mouth size; `eyeCross` moves the two eyes toward each
    /// other (looking at the nose).
    var eyeX = 0.0, eyeY = 0.0, mouthScale = 0.0, eyeCross = 0.0
    /// The head squashes (a boop); a front paw lifts a few points (motion units, never swings).
    var headSquash = 0.0, pawL = 0.0, pawR = 0.0

    mutating func add(_ o: Pose, _ w: Double = 1) {
        rootX += o.rootX * w; rootY += o.rootY * w; rootSX += o.rootSX * w; rootSY += o.rootSY * w
        rootTilt += o.rootTilt * w
        bodySX += o.bodySX * w; bodySY += o.bodySY * w; chest += o.chest * w; spread += o.spread * w
        headX += o.headX * w; headY += o.headY * w; headTilt += o.headTilt * w
        dirX += o.dirX * w; dirY += o.dirY * w
        earL += o.earL * w; earR += o.earR * w; earLS += o.earLS * w; earRS += o.earRS * w
        tail += o.tail * w; tailCurl += o.tailCurl * w
        eyeX += o.eyeX * w; eyeY += o.eyeY * w; mouthScale += o.mouthScale * w; eyeCross += o.eyeCross * w
        headSquash += o.headSquash * w; pawL += o.pawL * w; pawR += o.pawR * w
    }
}

/// The face pictures for one moment.
struct Face: Equatable {
    var eyes: EyeShape = .open
    var mouth: MouthShape = .smile
}

/// Everything the puppet draws for one frame: the summed pose, the follow-through
/// bends, and the face pictures with their cross-fade weights.
struct RigFrame {
    var pose = Pose()
    /// Follow-through: how far the ear tips and the tail tip trail (degrees, + = clockwise).
    var earLBend = 0.0, earRBend = 0.0, tailBend = 0.0
    /// The head squashes a hair as it settles (scale around the neck).
    var headSX = 1.0, headSY = 1.0
    /// Eye and mouth pictures with weights (they cross-fade over three or four frames).
    var eyes: [(EyeShape, Double)] = [(.open, 1)]
    var mouths: [(MouthShape, Double)] = [(.smile, 1)]
    var face = Face()
    /// How the eyes are drawn (the one decision the view follows).
    var eyeDraw = EyeDraw()

    /// The eye under its lid: how much of the face it is (1 unless fading to happy or
    /// wide eyes) and how far the lid is down (0 open, 0.5 half, 1 shut), blended over
    /// the same frames as the pictures. A blink moves the lid; the eye never fades.
    var lid: (weight: Double, down: Double) {
        let l = eyes.filter { $0.0.isLidded }
        let w = l.reduce(0) { $0 + $1.1 }
        let d = w > 0.001 ? l.reduce(0) { $0 + $1.1 * $1.0.lidDown } / w : 0
        return (w, d)
    }
}

/// How the eyes are drawn in one frame. One eye set at a time, never two: the eye under
/// its lid (open, a blink, half-closed, shut), or the happy arcs, or the wide eyes. A shut
/// eye is the painted lashes on the face (the open eye and its lid fade out at the very
/// end of shutting, so it never shows a blank pale disc in a ring).
struct EyeDraw: Equatable {
    enum Kind: Equatable { case lidded, happy, wide }
    var kind: Kind = .lidded
    /// The lid: 0 open, 0.5 half, 1 shut.
    var down = 0.0
    /// The wide eyes' pop as they open (extra size, settling to 0).
    var pop = 0.0
    /// The open eye and its lid.
    var eyeOpacity: Double { kind == .lidded ? 1 - Motion.smooth(0.85, 1, down) : 0 }
    /// The shut eye's painted lashes.
    var lashOpacity: Double { kind == .lidded ? Motion.smooth(0.75, 0.9, down) : 0 }
    /// The normal open eyes, lids fully open, every layer at full opacity.
    var isNormalOpen: Bool { kind == .lidded && down < 0.001 }
}

extension EyeShape {
    /// Open, half-closed and shut are one eye under a lid (looking left, right or up is
    /// the open eye with its pupils moved).
    var isLidded: Bool { [.open, .half, .closed, .left, .right, .up].contains(self) }
    /// How far the lid is down for this shape.
    var lidDown: Double { self == .half ? 0.5 : self == .closed ? 1 : 0 }
}

// MARK: - Small motion helpers

enum Motion {
    /// A spring step from 0 to 1 that starts at t = 0 (0 before). `response` is
    /// roughly the time to get there, `damping` < 1 overshoots.
    static func spring(_ t: Double, response: Double = 0.35, damping: Double = 0.62) -> Double {
        guard t > 0 else { return 0 }
        let w = 2 * .pi / response
        let z = min(damping, 0.999)
        let wd = w * sqrt(1 - z * z)
        return 1 - exp(-z * w * t) * (cos(wd * t) + z * w / wd * sin(wd * t))
    }

    /// Rise with a spring at `start`, fall back with a spring at `end`.
    static func hold(_ t: Double, start: Double, end: Double, response: Double = 0.3, damping: Double = 0.6) -> Double {
        spring(t - start, response: response, damping: damping) - spring(t - end, response: response * 1.3, damping: 0.8)
    }

    /// A quick flick that springs back: 0 at t = 0, out to 1 and back with a little overshoot.
    static func flick(_ t: Double, duration: Double = 0.25) -> Double {
        guard t > 0, t < duration * 2.4 else { return 0 }
        return sin(t / duration * .pi) * exp(-t / duration * 1.1)
    }

    /// A breath, -1...1 over one cycle: in over 40 % of the time, out over 60 %, eased.
    static func breath(_ phase: Double) -> Double {
        let x = phase - floor(phase)
        let v = x < 0.4 ? easeInOut(x / 0.4) : 1 - easeInOut((x - 0.4) / 0.6)
        return 2 * v - 1
    }

    /// 0 before `a`, 1 after `b`, eased (zero speed and zero acceleration at both ends).
    static func smooth(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let c = min(max((x - a) / (b - a), 0), 1)
        return c * c * c * (c * (c * 6 - 15) + 10)
    }

    /// A soft bump: 0 at `a`, 1 in the middle, 0 at `b` (sine squared, zero speed at the ends).
    static func bump(_ x: Double, _ a: Double, _ b: Double) -> Double {
        guard x > a, x < b else { return 0 }
        let s = sin((x - a) / (b - a) * .pi)
        return s * s
    }

    /// Rise from `a` to `b`, hold, fall from `c` to `d` (all eased, exactly 0 outside).
    static func env(_ x: Double, _ a: Double, _ b: Double, _ c: Double, _ d: Double) -> Double {
        smooth(a, b, x) * (1 - smooth(c, d, x))
    }

    /// Spring in at `start`, spring back out at `end`, and exactly 0 again by `end + settle`
    /// (the springs are all but settled by then, so the cut-off is invisible).
    static func pulse(_ x: Double, start: Double, end: Double, response: Double = 0.35,
                      damping: Double = 0.6, back: Double? = nil, settle: Double = 0.9) -> Double {
        guard x > start, x < end + settle else { return 0 }
        let v = spring(x - start, response: response, damping: damping)
            - spring(x - end, response: back ?? response * 1.2, damping: 0.75)
        return v * (1 - smooth(end + settle - 0.25, end + settle, x))
    }

    static func easeOut(_ p: Double) -> Double { let c = min(max(p, 0), 1); return 1 - pow(1 - c, 3) }
    static func easeIn(_ p: Double) -> Double { let c = min(max(p, 0), 1); return c * c * c }
    static func easeInOut(_ p: Double) -> Double {
        let c = min(max(p, 0), 1)
        return c < 0.5 ? 4 * c * c * c : 1 - pow(-2 * c + 2, 3) / 2
    }
    static func inside(_ t: Double, _ a: Double, _ b: Double) -> Bool { t >= a && t < b }

    /// Smooth 0...1 noise from an integer slot (same input, same output).
    static func rnd(_ i: Int, _ salt: Int) -> Double {
        var x = UInt64(bitPattern: Int64(i &* 73_856_093 ^ salt &* 19_349_663 &+ 0x9E37))
        x ^= x >> 33; x &*= 0xff51afd7ed558ccd
        x ^= x >> 33; x &*= 0xc4ceb9fe1a85ec53
        x ^= x >> 33
        return Double(x % 100_000) / 100_000
    }

    /// The jump: crouch 90 ms, up 180 ms, fall 150 ms, land squash 120 ms, then two small
    /// settling bounces.
    /// Returns (lift, squash) where squash < 1 is squashed, > 1 stretched.
    static func hop(_ t: Double, height: Double) -> (lift: Double, squash: Double) {
        guard t >= 0, t < 1.2 else { return (0, 1) }
        // Every airborne curve starts, peaks and ends at zero speed (sin squared), so the
        // spacing between frames grows and shrinks smoothly; the squash sells the impact.
        let s2 = { (x: Double) -> Double in let v = sin(x); return v * v }
        // The crouch and the stretch ease in and out, so the head riding the squash never kinks.
        if t < 0.09 { return (0, 1 - 0.08 * easeInOut(t / 0.09)) }
        if t < 0.27 { let p = (t - 0.09) / 0.18; return (height * s2(p * .pi / 2), 0.92 + 0.15 * smooth(0, 1, p)) }
        if t < 0.42 { let p = (t - 0.27) / 0.15; return (height * (1 - s2(p * .pi / 2)), 1.07 - 0.07 * smooth(0, 1, p)) }
        // Landing squash, then two small settling bounces. Each bounce starts while the
        // squash before it is still springing back, so the motion never pauses.
        var lift = 0.0, squash = 1.0
        // the landing hits at speed and eases out of the squash
        if t < 0.54 { let u = (t - 0.42) / 0.12; squash -= 0.095 * sin(u * .pi) * (1 - pow(u, 4)) }
        if t >= 0.49 && t < 0.67 { lift += height * 0.09 * s2((t - 0.49) / 0.18 * .pi) }
        if t >= 0.62 && t < 0.74 { squash -= 0.035 * s2((t - 0.62) / 0.12 * .pi) }
        if t >= 0.69 && t < 0.81 { lift += height * 0.03 * s2((t - 0.69) / 0.12 * .pi) }
        return (lift, squash)
    }

}
