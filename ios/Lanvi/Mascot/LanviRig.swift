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

    /// The tail's second joint (0...1 of the tail): the tip turns around it a beat late.
    static let tailMid = UnitPoint(x: 0.55, y: 0.55)

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

// MARK: - One frame of the puppet

/// Everything that moves, for one frame. Angles in degrees, distances in motion units (`Rig.unit`).
struct RigFrame {
    var rootX: CGFloat = 0
    var rootY: CGFloat = 0
    /// The whole fox squashes and stretches from the feet (gently), so no part distorts.
    var rootSX: CGFloat = 1
    var rootSY: CGFloat = 1
    /// The whole fox leans this many degrees around its feet (the happy wiggle).
    var rootTilt: Double = 0
    var bodySX: CGFloat = 1
    var bodySY: CGFloat = 1
    var headDX: CGFloat = 0
    var headDY: CGFloat = 0
    var headTilt: Double = 0
    /// Positive = the ear flops outward, negative = perks up and in.
    var earL: Double = 0
    var earR: Double = 0
    var earLStretch: CGFloat = 1
    var earRStretch: CGFloat = 1
    var tail: Double = 0
    var tailTip: Double = 0
    var eyes: EyeShape = .open
    var eyeOpen: CGFloat = 1
    var eyeDX: CGFloat = 0
    var eyeDY: CGFloat = 0
    var mouth: MouthShape = .smile
    var mouthScale: CGFloat = 1
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
        if t < 0.09 { return (0, 1 - 0.08 * easeOut(t / 0.09)) }
        if t < 0.27 { let p = (t - 0.09) / 0.18; return (height * s2(p * .pi / 2), 0.92 + 0.15 * sin(p * .pi / 2)) }
        if t < 0.42 { let p = (t - 0.27) / 0.15; return (height * (1 - s2(p * .pi / 2)), 1.07 - 0.07 * p) }
        // Landing squash, then two small settling bounces. Each bounce starts while the
        // squash before it is still springing back, so the motion never pauses.
        var lift = 0.0, squash = 1.0
        if t < 0.54 { squash -= 0.09 * sin((t - 0.42) / 0.12 * .pi) }
        if t >= 0.49 && t < 0.67 { lift += height * 0.09 * s2((t - 0.49) / 0.18 * .pi) }
        if t >= 0.64 && t < 0.72 { squash -= 0.035 * sin((t - 0.64) / 0.08 * .pi) }
        if t >= 0.69 && t < 0.81 { lift += height * 0.03 * s2((t - 0.69) / 0.12 * .pi) }
        return (lift, squash)
    }

}
