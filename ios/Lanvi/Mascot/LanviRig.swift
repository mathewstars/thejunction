import SwiftUI

// The paper puppet's layout and its motion maths. No views here: `LanviPuppet`
// draws the parts; this file says where they sit and how they move at a time t.
//
// Units: "canvas units" are pixels of the reference fox on the captain's parts
// sheet (815 x 977). Every part was placed by hand until the puppet at rest
// matched that reference (see ios/tools/cut_puppet_parts.py for the cut).

enum Rig {
    static let canvas = CGSize(width: 815, height: 977)

    /// One drawn part: image name, its pixel size on the sheet, where its centre
    /// sits on the canvas, its scale, and the point it turns around (0...1 of the part).
    struct Part {
        var image: String
        var px: CGSize
        var center: CGPoint
        var scale: CGFloat
        var pivot: UnitPoint
        /// Extra height stretch (the body is drawn a little short at the neck).
        var stretchY: CGFloat = 1
        /// Turned this much (degrees, around its centre) at rest.
        var rest: Double = 0
        var size: CGSize { CGSize(width: px.width * scale, height: px.height * scale * stretchY) }
        var origin: CGPoint { CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2) }
        /// The pivot in canvas units.
        var pivotPoint: CGPoint {
            CGPoint(x: origin.x + pivot.x * size.width, y: origin.y + pivot.y * size.height)
        }
    }

    // Back to front: tail, body, head group (ears, head, eyes, mouth), paws.
    // The tail is the sheet's tail mirrored, so it curls out on the viewer's left
    // like the reference; its base hides behind the body.
    static let tail = Part(image: "puppet-tail", px: CGSize(width: 466, height: 376),
                           center: CGPoint(x: 205, y: 742), scale: 1.05, pivot: UnitPoint(x: 0.86, y: 0.76))
    static let body = Part(image: "puppet-body", px: CGSize(width: 493, height: 415),
                           center: CGPoint(x: 515, y: 718), scale: 1.12, pivot: UnitPoint(x: 0.5, y: 1.0),
                           stretchY: 1.045)
    static let earL = Part(image: "puppet-ear-left", px: CGSize(width: 240, height: 315),
                           center: CGPoint(x: 290, y: 182), scale: 1.15, pivot: UnitPoint(x: 0.72, y: 0.86))
    static let earR = Part(image: "puppet-ear-right", px: CGSize(width: 239, height: 312),
                           center: CGPoint(x: 690, y: 172), scale: 1.15, pivot: UnitPoint(x: 0.28, y: 0.86))
    static let head = Part(image: "puppet-head", px: CGSize(width: 519, height: 425),
                           center: CGPoint(x: 500, y: 352), scale: 1.27, pivot: UnitPoint(x: 0.5, y: 0.9))
    static let pawL = Part(image: "puppet-paw-left", px: CGSize(width: 217, height: 222),
                           center: CGPoint(x: 462, y: 868), scale: 0.92, pivot: UnitPoint(x: 0.24, y: 0.14),
                           rest: 14)
    static let pawR = Part(image: "puppet-paw-right", px: CGSize(width: 224, height: 213),
                           center: CGPoint(x: 584, y: 868), scale: 0.92, pivot: UnitPoint(x: 0.76, y: 0.14),
                           rest: -14)

    /// The tail's second joint (0...1 of the mirrored tail): the tip turns around it.
    static let tailMid = UnitPoint(x: 0.56, y: 0.6)

    /// Where the head turns: the bottom centre of the head, inside the neck ruff.
    static var neck: CGPoint { head.pivotPoint }

    /// Face parts are placed in head pixels from the head's centre (then scaled with the head).
    static let eyeL = CGPoint(x: -110, y: -30)
    static let eyeR = CGPoint(x: 114, y: -30)
    static let eyeScale: CGFloat = 0.95
    static let mouthTop = CGPoint(x: 5, y: 58)

    static func headToCanvas(_ p: CGPoint) -> CGPoint {
        CGPoint(x: head.center.x + p.x * head.scale, y: head.center.y + p.y * head.scale)
    }

    /// The tail's white tip at rest, in canvas units (for the fox-fire glow).
    static var tailTip: CGPoint {
        let o = tail.origin, s = tail.size
        return CGPoint(x: o.x + 0.16 * s.width, y: o.y + 0.30 * s.height)
    }
}

// MARK: - Face pieces

enum EyeShape: Equatable {
    case open, half, happy, wide, right, rightUp, up, left, leftUp, closed

    /// Image for the eye on the viewer's left / right, and whether it is drawn mirrored.
    /// Looking left is the sheet's looking-right pair mirrored (mirroring, not new art).
    func image(left: Bool) -> (name: String, flipX: Bool, flipY: Bool) {
        let side = left ? "l" : "r", other = left ? "r" : "l"
        switch self {
        case .open: return ("puppet-eye-open-\(side)", false, false)
        case .half: return ("puppet-eye-half-\(side)", false, false)
        case .happy: return ("puppet-eye-happy-\(side)", false, false)
        case .wide: return ("puppet-eye-wide-\(side)", false, false)
        case .right: return ("puppet-eye-right-\(side)", false, false)
        case .rightUp: return ("puppet-eye-right-up-\(side)", false, false)
        case .up: return ("puppet-eye-up-\(side)", false, false)
        case .left: return ("puppet-eye-right-\(other)", true, false)
        case .leftUp: return ("puppet-eye-right-up-\(other)", true, false)
        // A shut eye: the happy arc turned upside down, a soft closed lid.
        case .closed: return ("puppet-eye-happy2-\(side)", false, true)
        }
    }

    /// Pixel size on the sheet and how far its centre sits below the open eye's centre,
    /// so every shape lines up with the open eye's bottom edge.
    var px: CGSize {
        switch self {
        case .open: return CGSize(width: 114, height: 138)
        case .half: return CGSize(width: 116, height: 92)
        case .happy: return CGSize(width: 112, height: 66)
        case .closed: return CGSize(width: 112, height: 74)
        case .wide: return CGSize(width: 112, height: 119)
        default: return CGSize(width: 108, height: 120)
        }
    }
    var dropY: CGFloat {
        switch self {
        case .open, .wide: return 0
        case .half: return 23
        case .happy: return -6
        case .closed: return 30
        default: return 8
        }
    }
}

enum MouthShape: Equatable {
    case smile, o, happy, yawn, flat
    var image: String {
        switch self {
        case .smile: return "puppet-mouth-smile"
        case .o: return "puppet-mouth-o"
        case .happy: return "puppet-mouth-happy"
        case .yawn: return "puppet-mouth-yawn"
        case .flat: return "puppet-mouth-flat"
        }
    }
    var px: CGSize {
        switch self {
        case .smile: return CGSize(width: 110, height: 47)
        case .o: return CGSize(width: 64, height: 70)
        case .happy: return CGSize(width: 142, height: 111)
        case .yawn: return CGSize(width: 90, height: 97)
        case .flat: return CGSize(width: 83, height: 26)
        }
    }
    var scale: CGFloat {
        switch self {
        case .smile: return 0.55
        case .o: return 0.5
        case .happy: return 0.52
        case .yawn: return 0.6
        case .flat: return 0.5
        }
    }
    /// Extra drop below the nose, in head pixels.
    var dropY: CGFloat {
        switch self {
        case .smile: return 2
        case .flat: return 14
        default: return 0
        }
    }
}

// MARK: - One frame of the puppet

/// Everything that moves, for one frame. Angles in degrees, distances in canvas units.
struct RigFrame {
    var rootX: CGFloat = 0
    var rootY: CGFloat = 0
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
    /// Positive = paw lifts up toward the chest.
    var pawL: Double = 0
    var pawR: Double = 0
    var pawLX: CGFloat = 0   // negative = outward
    var pawRX: CGFloat = 0   // positive = outward
    var pawLY: CGFloat = 0
    var pawRY: CGFloat = 0
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

    /// The jump: crouch 90 ms, up 180 ms, fall 150 ms, land squash 120 ms, wobble 0.4 s.
    /// Returns (lift, squash) where squash < 1 is squashed, > 1 stretched.
    static func hop(_ t: Double, height: Double) -> (lift: Double, squash: Double) {
        guard t >= 0, t < 1.0 else { return (0, 1) }
        if t < 0.09 { return (0, 1 - 0.08 * easeOut(t / 0.09)) }
        if t < 0.27 { let p = easeOut((t - 0.09) / 0.18); return (height * p, 0.92 + 0.15 * p) }
        if t < 0.42 { let p = easeIn((t - 0.27) / 0.15); return (height * (1 - p), 1.07 - 0.04 * p) }
        if t < 0.54 { let p = (t - 0.42) / 0.12; return (0, 1 - 0.09 * sin(p * .pi / 2)) }
        let p = t - 0.54
        return (0, 1 - 0.09 * cos(p / 0.4 * .pi * 1.5) * exp(-p * 7))
    }
}
