// Lanvi's motion, measured without a simulator: runs the puppet's own maths
// (`LanviMotion`, `LanviRig`, `LanviArt`) at 60 frames per second and writes one CSV
// per scene (idle, each idle moment, each reaction, talking, held moods).
//
//   swiftc -O ios/Lanvi/Mascot/LanviArt.swift ios/Lanvi/Mascot/LanviRig.swift \
//       ios/Lanvi/Mascot/LanviMotion.swift ios/tools/motion_check/main.swift -o /tmp/motion_check
//   /tmp/motion_check OUTDIR
//   python3 ios/tools/motion_check/report.py OUTDIR
//
// Columns: time, every pose channel, follow-through, the face pictures, and where the
// left pupil lands on screen (points, fox 300 pt tall) as a video tracker would see it.

import CoreGraphics
import Foundation

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "motion"
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

let foxSize: CGFloat = 300
let k = foxSize / Rig.canvas.height

/// Where the left eye's centre lands, in points inside the fox's square.
func pupil(_ f: RigFrame) -> CGPoint {
    let q = f.pose
    // the eye rides its patch around the head sphere
    let r = LanviArt.layer["face-patch-l"] ?? .zero
    let px = LanviArt.px("head")
    let patch = CGPoint(x: (r.midX - 0.5) * px.width, y: (r.midY - 0.5) * px.height)
    let t = Rig.turn(Rig.sphere(patch), yaw: q.dirX * Rig.maxYaw, pitch: q.dirY * Rig.maxPitch)
    let to = Rig.headPixels(t.p)
    var e = Rig.headToCanvas(CGPoint(x: Rig.eyeL.x + q.eyeX + (to.x - patch.x), y: Rig.eyeL.y + q.eyeY + (to.y - patch.y)))
    // the head group: settle around the neck, tilt around the neck, shift
    let n = Rig.neck
    e = CGPoint(x: n.x + (e.x - n.x) * f.headSX, y: n.y + (e.y - n.y) * f.headSY)
    let a = q.headTilt * .pi / 180
    let d = CGPoint(x: e.x - n.x, y: e.y - n.y)
    e = CGPoint(x: n.x + d.x * cos(a) - d.y * sin(a), y: n.y + d.x * sin(a) + d.y * cos(a))
    e.x += q.headX * Rig.unit; e.y += q.headY * Rig.unit
    // the whole fox around its feet
    let feet = CGPoint(x: Rig.body.center.x - Rig.frame.minX, y: Rig.canvas.height * 0.995)
    e = CGPoint(x: feet.x + (e.x - feet.x) * (1 + q.rootSX), y: feet.y + (e.y - feet.y) * (1 + q.rootSY))
    let b = q.rootTilt * .pi / 180
    let g = CGPoint(x: e.x - feet.x, y: e.y - feet.y)
    e = CGPoint(x: feet.x + g.x * cos(b) - g.y * sin(b), y: feet.y + g.x * sin(b) + g.y * cos(b))
    e.x += q.rootX * Rig.unit; e.y += q.rootY * Rig.unit
    return CGPoint(x: e.x * k, y: e.y * k)
}

func motion(_ t: Double) -> LanviMotion {
    LanviMotion(t: t, seed: Int(foxSize * 13) % 997, held: .calm, heldFrom: .calm, heldSince: -100,
                reaction: nil, reactionAt: -100, hopAt: -100, tapAt: -100, tapSide: 1,
                look: nil, lookFrom: nil, lookAt: -100, reduceMotion: false)
}

func numbers(_ f: RigFrame) -> [Double] {
    let q = f.pose
    let p = pupil(f)
    return [q.rootY, q.rootSY, q.rootTilt, q.bodySY, q.chest, q.spread, q.headX, q.headY,
            q.headTilt, q.dirX, q.dirY, q.earL, q.earR, f.earLBend, f.earRBend, q.tail, f.tailBend,
            f.headSY, q.eyeX, q.eyeY, q.mouthScale, Double(p.x), Double(p.y)]
}

/// One scene. `rest` is the largest gap between the scene and the same clock with no
/// event (the plain idle underneath): it must end at 0 (back exactly to rest).
func write(_ name: String, from t0: Double, seconds: Double, _ configure: (inout LanviMotion) -> Void) {
    var rows = ["t,rootY,rootSY,rootTilt,bodySY,chest,spread,headX,headY,headTilt,dirX,dirY,earL,earR,earLBend,earRBend,tail,tailBend,headSY,eyeX,eyeY,mouthScale,pupilX,pupilY,rest,eyes,mouth,eyeFade,mouthFade"]
    let frames = Int(seconds * 60)
    for i in 0..<frames {
        let t = t0 + Double(i) / 60
        var m = motion(t)
        configure(&m)
        let f = m.frame()
        var plain = motion(t)
        plain.appearAt = m.appearAt
        plain.evening = m.evening
        let nums = numbers(f)
        let rest = zip(nums, numbers(plain.frame())).map { abs($0 - $1) }.max() ?? 0
        let face = "\(f.face.eyes),\(f.face.mouth),\(f.eyes.count > 1 ? f.eyes[1].1 : 1),\(f.mouths.count > 1 ? f.mouths[1].1 : 1)"
        rows.append(([Double(i) / 60] + nums + [rest]).map { String(format: "%.4f", $0) }.joined(separator: ",") + "," + face)
    }
    try? rows.joined(separator: "\n").write(toFile: "\(out)/\(name).csv", atomically: true, encoding: .utf8)
}

let base = CommandLine.arguments.count > 2 ? Double(CommandLine.arguments[2]) ?? 50_000 : 50_000.0   // any clock time (try a real one: 816_000_000)

// Idle, day and evening: 40 s each, the moments pick themselves.
write("idle", from: base, seconds: 40) { $0.appearAt = base - 10 }
write("idle-evening", from: base, seconds: 40) { $0.appearAt = base - 10; $0.evening = true }
// The base idle alone (no moments): what the fox does between moments.
write("idle-base", from: base, seconds: 20) { $0.appearAt = .infinity }

// Each idle moment, forced, with half a second of rest either side.
for m in LanviMoment.allCases {
    write("moment-\(m.rawValue)", from: base - 0.5, seconds: m.duration + 1.2) {
        $0.appearAt = .infinity; $0.moment = m; $0.momentAt = base; $0.momentSide = 1
    }
}
// Each reaction.
for r in LanviMood.allCases where r != .calm {
    write("reaction-\(r.rawValue)", from: base - 0.5, seconds: r.reactionLength + 1.2) {
        $0.appearAt = .infinity; $0.reaction = r; $0.reactionAt = base
    }
}
// The joyful hop from a bounce, and a tap on the right.
write("hop", from: base - 0.5, seconds: 2.2) { $0.appearAt = .infinity; $0.hopAt = base }
write("tap", from: base - 0.5, seconds: 2.4) { $0.appearAt = .infinity; $0.tapAt = base; $0.tapSide = 1 }
// Held: listening, thinking, sleepy (blending in at 0.5 s), and talking for 4 s.
for h in [LanviMood.listening, .thinking, .sleepy] {
    write("held-\(h.rawValue)", from: base - 0.5, seconds: 8) {
        $0.appearAt = .infinity; $0.held = h; $0.heldFrom = .calm; $0.heldSince = base
    }
}
write("talking", from: base - 0.5, seconds: 5.5) {
    $0.appearAt = .infinity
    $0.talking = $0.t >= base && $0.t < base + 4
    $0.talkingSince = $0.t < base + 4 ? base : base + 4
    $0.talkStart = base
}
// A speech bubble driving the mouth: open, closed, open... every 0.12 s for 2 s.
write("bubble", from: base - 0.5, seconds: 3.5) {
    $0.appearAt = .infinity
    let t = $0.t
    guard t >= base else { return }
    let n = Int(floor((min(t, base + 2) - base) / 0.12))
    let shape = { (i: Int) -> MouthShape in i % 2 == 0 ? .o : .smile }
    if t < base + 2 {
        $0.mouthOverride = shape(n); $0.mouthFrom = n == 0 ? nil : shape(n - 1)
        $0.mouthTickAt = base + Double(n) * 0.12; $0.drivenSince = base
    } else {
        $0.mouthOverride = nil; $0.mouthFrom = shape(n); $0.mouthTickAt = base + 2; $0.drivenSince = base + 2
    }
}
// A look to the right and back.
write("look", from: base - 0.5, seconds: 3.5) {
    $0.appearAt = .infinity
    let right = CGPoint(x: 1700, y: 700)
    if $0.t < base + 1.5 { $0.look = right; $0.lookFrom = nil; $0.lookAt = base }
    else { $0.look = nil; $0.lookFrom = right; $0.lookAt = base + 1.5 }
}
print("wrote \(out)")
