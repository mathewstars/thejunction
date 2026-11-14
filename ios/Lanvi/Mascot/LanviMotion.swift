import SwiftUI

/// How Lanvi feels. Held with `.lanviMood(_:)`, or played once with `.lanviReaction(_:trigger:)`.
/// Lanvi never looks sad because of the person, so there is no sad mood ("okay" is the
/// gentle "that's fine" for "Not today").
enum LanviMood: String, CaseIterable, Equatable {
    case calm, happy, curious, surprised, sleepy, listening
    case thinking, greeting, proud, okay
}

/// The small performed moments of the idle: one every 6 to 12 seconds, never two at
/// once, never the same twice in a row. Each one eases in, returns exactly to rest.
enum LanviMoment: String, CaseIterable, Equatable {
    case glance, glanceUp, tilt, ears, tailCurl, sniff, slowBlink, invite, yawn

    var duration: Double {
        switch self {
        case .glance: return 2.1
        case .glanceUp: return 2.0
        case .tilt: return 2.2
        case .ears: return 1.3
        case .tailCurl: return 1.9
        case .sniff: return 1.7
        case .slowBlink: return 1.7
        case .invite: return 2.3
        case .yawn: return 3.2
        }
    }
}

extension LanviMood {
    /// How long the one-shot reaction takes, rest to rest.
    var reactionLength: Double {
        switch self {
        case .calm: return 0
        case .happy: return 2.1
        case .curious: return 2.3
        case .surprised: return 1.9
        case .sleepy: return 3.2
        case .listening: return 1.9
        case .thinking: return 2.8
        case .greeting: return 2.4
        case .proud: return 2.8
        case .okay: return 2.4
        }
    }
}

/// Everything the puppet needs to work out one frame. Built fresh every frame by
/// `LanviPuppet` from its state; `frame()` is pure maths on the one clock: nothing is
/// random per frame (every "random" choice is fixed per time slot) and nothing is stored.
///
/// The frame is built in layers that add up: the held mood, the idle (breath, tail
/// drift, a slow drift of where the head faces), where the eyes look, the idle moment,
/// talking, a reaction, a tap, a hop, then the blink. Follow-through (ear tips, tail
/// tip, the head settling) is worked out from the same maths a moment earlier.
struct LanviMotion {
    var t: Double                        // the one clock, seconds
    var seed: Int                        // per fox size, so two foxes never move in sync
    var held: LanviMood                  // mood held right now
    var heldFrom: LanviMood              // the mood before (for a soft change-over)
    var heldSince: Double                // when `held` started
    var reaction: LanviMood?             // one-shot reaction playing
    var reactionAt: Double               // when it started
    var prevReaction: LanviMood? = nil   // the reaction it replaced (fades out)
    var prevReactionAt: Double = -100
    var hopAt: Double                    // last bounceTrigger hop
    var tapAt: Double                    // last tap on the fox
    var tapSide: Double                  // -1 tap on the left half, +1 right
    var look: CGPoint?                   // where the eyes look now (canvas units)
    var lookFrom: CGPoint?               // previous target
    var lookAt: Double                   // when the target changed
    var talking = false                  // `.lanviTalking`
    var talkingSince: Double = -100      // when talking started or stopped
    var mouthOverride: MouthShape? = nil // `.lanviMouth` (a speech bubble driving the mouth)
    var mouthTickAt: Double = -100       // when that mouth last changed
    var moment: LanviMoment? = nil       // a moment asked for by hand (the preview screen)
    var momentAt: Double = -100
    var momentSide: Double = 1
    var appearAt: Double = -100          // when this fox appeared (no idle moment for 3 s)
    var evening = false                  // late: the evening set of idle moments (yawns)
    var reduceMotion: Bool
    var freezeBlink: Double? = nil       // debug: hold a blink at this phase (s)
    var loving = false                   // the `love` pose: soft happy eyes

    /// Between the eyes, in canvas units.
    static let eyesCenter = Rig.headToCanvas(CGPoint(x: 2, y: -15))
    static var bodyHeight: Double { Double(Rig.body.size.height / Rig.unit) }
    private var s: Double { Double(seed % 997) }

    // MARK: - The frame

    /// Past moments sampled for follow-through and cross-fades (seconds before now).
    static let taps: [Double] = [1, 2, 3, 5, 7, 9, 12, 15, 19, 24].map { Double($0) / 60 }
    /// Weights of a soft spring over those taps: the ears' and the tail's lag.
    static let earKernel = kernel(response: 0.3, damping: 0.38)
    static let tailKernel = kernel(response: 0.45, damping: 0.4)
    static let headKernel = kernel(response: 0.22, damping: 0.5)
    /// How the face pictures blend over the last four frames (now first).
    static let faceBlend: [Double] = [0.45, 0.3, 0.17, 0.08]

    func frame() -> RigFrame {
        var f = RigFrame()
        let now = sample(t, face: true)
        f.pose = now.pose
        f.face = now.face

        var past: [(pose: Pose, face: Face)] = []
        past.reserveCapacity(Self.taps.count)
        for (i, tau) in Self.taps.enumerated() {
            past.append(sample(t - tau, face: i < 3))
        }

        // Cross-fade the face pictures over three or four frames, so a swap never pops:
        // the newest picture fades in over the one before it (drawn first, fading out).
        let faces = [now.face] + past.prefix(3).map(\.face)
        f.eyes = Self.fade(faces.map(\.eyes))
        f.mouths = Self.fade(faces.map(\.mouth))
        if reduceMotion { return f }

        // Follow-through: each tip trails where its base was a moment ago, springs past
        // it and settles. Pure sums of the same smooth maths, so it can never jitter.
        func lag(_ k: [Double], _ get: (Pose) -> Double) -> Double {
            var v = 0.0
            for i in k.indices { v += k[i] * get(past[i].pose) }
            return v - get(now.pose)
        }
        let tilt = lag(Self.earKernel) { $0.headTilt + $0.rootTilt }
        let lift = lag(Self.earKernel) { $0.rootY + $0.headY }
        let side = lag(Self.earKernel) { $0.rootX + $0.headX + $0.dirX * 16 }
        let earL = lag(Self.earKernel) { $0.earL }
        let earR = lag(Self.earKernel) { $0.earR }
        // (soft limits: the bands bend cleanly up to about 12 degrees for ears, 22 for the tail)
        f.earLBend = Self.soft(1.1 * tilt - 0.32 * lift + 0.3 * side - 0.8 * earL, 12)
        f.earRBend = Self.soft(1.1 * tilt + 0.32 * lift + 0.3 * side + 0.8 * earR, 12)

        let tailBase = lag(Self.tailKernel) { $0.tail + $0.rootTilt }
        let tailLift = lag(Self.tailKernel) { $0.rootY }
        f.tailBend = Self.soft(now.pose.tailCurl + 1.25 * tailBase - 0.16 * tailLift, 22)

        // The head stretches a hair as it rises and squashes as it settles.
        let settle = lag(Self.headKernel) { $0.rootY + $0.headY }
        let sq = Self.soft(settle * 0.0011, 0.035)
        f.headSY = 1 + sq
        f.headSX = 1 - sq * 0.6
        return f
    }

    /// The pictures to draw for a face part, oldest first, from its last four frames (now
    /// first): the current one with the weight it has built up, and the one it replaced.
    static func fade<T: Equatable>(_ history: [T]) -> [(T, Double)] {
        let now = history[0]
        var w = 0.0
        for (v, b) in zip(history, faceBlend) where v == now { w += b }
        guard w < 0.999, let before = history.first(where: { $0 != now }) else { return [(now, 1)] }
        return [(before, 1 - w), (now, w)]
    }

    /// Soft limit: about `x` for small values, never past `limit`.
    static func soft(_ x: Double, _ limit: Double) -> Double { limit * tanh(x / limit) }

    /// A damped spring's impulse response sampled at `taps`, normalised to sum to 1.
    static func kernel(response: Double, damping: Double) -> [Double] {
        let w = 2 * Double.pi / response, z = damping
        let wd = w * (1 - z * z).squareRoot()
        var out: [Double] = []
        for i in taps.indices {
            let a = i == 0 ? 0 : taps[i - 1]
            let b = i + 1 < taps.count ? taps[i + 1] : taps[i] + (taps[i] - taps[i - 1])
            let g = exp(-z * w * taps[i]) * sin(wd * taps[i])
            out.append(g * (b - a) / 2)
        }
        let sum = out.reduce(0, +)
        return out.map { $0 / sum }
    }

    // MARK: - One moment, all layers

    /// The pose and face at time `x`. `face`: also work out the blink (only needed for
    /// the frames the face pictures blend over).
    func sample(_ x: Double, face withBlink: Bool) -> (pose: Pose, face: Face) {
        var p = Pose()
        var face = Face()
        heldLayer(x, &p, &face)
        idle(x, &p)
        lookLayer(x, &p, &face)
        momentLayer(x, &p, &face)
        talkLayer(x, &p, &face)
        reactionLayer(x, &p, &face)
        tapLayer(x, &p, &face)
        hop(&p, x - hopAt, height: 120)
        if withBlink { blink(x, &p, &face) }
        if loving, face.eyes == .open { face.eyes = .happy }
        rideNeck(x, &p)

        // Depth in miniature: a tilt turns the face a touch towards the low side.
        p.dirX += p.headTilt * 0.012
        p.dirX = max(min(p.dirX, 1), -1)
        p.dirY = max(min(p.dirY, 1), -1)
        // The head's shape moves a little with where it faces.
        p.headX += p.dirX * 5
        p.headY += p.dirY * 3
        if reduceMotion { p = Pose() }
        return (p, face)
    }

    // MARK: Idle base: breath, tail drift, the head never perfectly frozen

    /// How sleepy the breath is, 0...1, blended over 1.2 s when the held mood changes
    /// (so the slower sleepy breath never jumps in).
    private func sleepiness(_ x: Double) -> Double {
        let from = heldFrom == .sleepy ? 1.0 : 0, to = held == .sleepy ? 1.0 : 0
        return from + (to - from) * Motion.smooth(heldSince, heldSince + 1.2, x)
    }

    /// The breath, -1...1: a plain smooth sine, 4.5 s (5.2 s when sleepy).
    private func breathe(_ x: Double) -> Double {
        let z = sleepiness(x)
        let calm = sin(2 * .pi * (x + s) / 4.5), sleepy = sin(2 * .pi * (x + s) / 5.2)
        return calm + (sleepy - calm) * z
    }

    private func breathAmp(_ x: Double) -> Double { 0.014 + 0.002 * sleepiness(x) }

    /// The head stays on the neck: it rides every stretch of the body (yawns, pride,
    /// hops) at once, and the breath 0.18 s late, so it settles a hair after the chest.
    private func rideNeck(_ x: Double, _ p: inout Pose) {
        let b = breathe(x), late = breathe(x - 0.18), amp = breathAmp(x)
        let sy = p.bodySY - amp * b + amp * late
        let chest = p.chest - 0.012 * (b + 1) + 0.012 * (late + 1)
        p.headY -= sy * Self.bodyHeight * 0.85 + 55 * chest
    }

    private func idle(_ x: Double, _ p: inout Pose) {
        // Breath: the chest fills (2.8 % from out to in over 4.5 s, a plain smooth sine)
        // and lifts the shoulders; the head rides it 0.18 s late and lifts its chin a hair.
        let b = breathe(x), amp = breathAmp(x)
        p.bodySY += amp * b
        p.bodySX += amp * 0.4 * b
        p.chest += 0.012 * (b + 1)
        p.dirY -= 0.035 * breathe(x - 0.25)

        // Tail: a slow drift made of two sways of different lengths (never a visible beat).
        p.tail += 3.6 * sin(2 * .pi * (x + s * 1.3) / 6.3) + 2.2 * sin(2 * .pi * (x + s * 0.7) / 9.7 + 1.1)
        // Where the head faces drifts a hair, so the face is never a frozen picture.
        p.dirX += 0.045 * sin(2 * .pi * (x + s) / 8.3) + 0.025 * sin(2 * .pi * (x + s) / 13.1 + 2)
        p.dirY += 0.03 * sin(2 * .pi * (x + s) / 10.7 + 0.5)
    }

    // MARK: Held moods

    private func heldLayer(_ x: Double, _ p: inout Pose, _ face: inout Face) {
        // Faces swap 0.12 s after the change, inside the move that starts it.
        let m = x - heldSince < 0.12 ? heldFrom : held
        switch m {
        case .calm, .curious: break
        case .happy, .greeting: face.mouth = .happy
        case .surprised: face.eyes = .wide; face.mouth = .o
        case .sleepy: face.eyes = .half
        case .listening: face.mouth = .smile
        case .thinking: face.eyes = .up
        case .proud: face.eyes = .happy; face.mouth = .happy
        case .okay: face.eyes = .happy
        }
        let w = Motion.spring(x - heldSince, response: 0.5, damping: 0.75)
        stance(heldFrom, x, &p, weight: 1 - w)
        stance(held, x, &p, weight: w)
    }

    private func stance(_ m: LanviMood, _ x: Double, _ p: inout Pose, weight w: Double) {
        guard abs(w) > 0.0005 else { return }
        switch m {
        case .calm, .greeting: break
        case .happy: p.earL += 3 * w; p.earR += 3 * w
        case .curious: p.headTilt += 7 * w; p.earR -= 4 * w; p.headX += 4 * w; p.dirX += 0.12 * w
        case .surprised:
            p.earL -= 6 * w; p.earR -= 6 * w; p.earLS += 0.05 * w; p.earRS += 0.05 * w; p.headY -= 6 * w
            p.dirY -= 0.1 * w
        case .sleepy: p.earL += 9 * w; p.earR += 9 * w; p.headY += 6 * w; p.headTilt += 3 * w; p.dirY += 0.16 * w
        case .listening:
            // Head tilted, ears forward, eyes down on the text field, small nods now and then.
            p.earL -= 7 * w; p.earR -= 7 * w; p.earLS += 0.06 * w; p.earRS += 0.06 * w
            p.headTilt -= 5 * w; p.headY += 2 * w; p.dirX -= 0.06 * w; p.dirY += 0.24 * w; p.eyeY += 5 * w
            let slot = 2.6
            let k = floor((x + s * 0.3) / slot)
            let start = k * slot + 0.9 * Motion.rnd(Int(k), seed &+ 61) - s * 0.3
            let nod = Motion.bump(x, start, start + 0.45)
            p.headY += 4 * nod * w; p.dirY += 0.1 * nod * w
        case .thinking:
            // Eyes up and to the side, head following, a slow tail swish.
            p.dirX += 0.28 * w; p.dirY -= 0.32 * w; p.headTilt += 4 * w; p.eyeX += 5 * w; p.eyeY -= 2 * w
            p.earL += 4 * w; p.mouthScale -= 0.12 * w
            p.tail += (7 * sin(2 * .pi * (x + s) / 3.7) + 3 * sin(2 * .pi * (x + s) / 5.9 + 0.8)) * w
            p.tailCurl += 4 * sin(2 * .pi * (x + s - 0.3) / 3.7) * w
        case .proud: p.chest += 0.02 * w; p.dirY -= 0.15 * w; p.earL -= 3 * w; p.earR -= 3 * w
        case .okay: p.earL += 3 * w; p.earR += 3 * w; p.headTilt += 3 * w
        }
    }

    // MARK: Look

    /// Head direction, tilt, eye shift and eye set for a target in canvas units.
    private static func lookPose(_ q: CGPoint?) -> (dx: Double, dy: Double, tilt: Double, ex: Double, ey: Double, shape: EyeShape?) {
        guard let q else { return (0, 0, 0, 0, 0, nil) }
        let dx = Double((q.x - eyesCenter.x) / Rig.unit), dy = Double((q.y - eyesCenter.y) / Rig.unit)
        let d = max(hypot(dx, dy), 1)
        let dirX = max(min(dx / 240, 1), -1) * 0.7
        let dirY = max(min(dy / 240, 1), -1) * 0.55
        let tilt = max(min(dx * 0.01, 5), -5)
        let ex = dx / d * 6, ey = dy / d * 6
        guard d > 70 else { return (dirX, dirY, tilt, ex * d / 70, ey * d / 70, .open) }
        let a = atan2(-dy, dx) * 180 / .pi   // 0 = right, 90 = up
        let shape: EyeShape
        switch a {
        case -40..<45: shape = .right
        case 45..<135: shape = .up
        case 135...180, -180 ..< -140: shape = .left
        default: shape = .open   // looking down: open eyes, nudged down
        }
        return (dirX, dirY, tilt, ex, ey + (shape == .open ? 5 : 0), shape)
    }

    private func lookLayer(_ x: Double, _ p: inout Pose, _ face: inout Face) {
        let to = Self.lookPose(look), from = Self.lookPose(lookFrom)
        let lt = x - lookAt
        // Eyes lead: they jump in 70 ms; the head turns after them 0.1 s later, on a spring.
        let e = Motion.easeOut(lt / 0.07)
        let h = Motion.spring(lt - 0.1, response: 0.38, damping: 0.72)
        if let shape = (lt >= 0.035 ? to.shape : from.shape), face.eyes == .open { face.eyes = shape }
        p.eyeX += from.ex + (to.ex - from.ex) * e
        p.eyeY += from.ey + (to.ey - from.ey) * e
        p.dirX += from.dx + (to.dx - from.dx) * h
        p.dirY += from.dy + (to.dy - from.dy) * h
        p.headTilt += from.tilt + (to.tilt - from.tilt) * h
    }

    // MARK: Busy: when the fox is doing something, idle moments wait

    private func window(_ at: Double, _ length: Double, _ x: Double) -> Double {
        Motion.smooth(at - 0.05, at + 0.2, x) * (1 - Motion.smooth(at + length, at + length + 0.6, x))
    }

    /// 0 = free for an idle moment, 1 = busy (a reaction, a tap, a look the screen holds,
    /// listening, thinking, talking). Smooth, so a moment that is cut fades out.
    func busy(_ x: Double) -> Double {
        var b = 0.0
        if let r = reaction { b = max(b, window(reactionAt, r.reactionLength, x)) }
        b = max(b, window(tapAt, 1.6, x))
        b = max(b, window(hopAt, 1.3, x))
        let l0 = lookFrom == nil ? 0.0 : 1, l1 = look == nil ? 0.0 : 1
        b = max(b, l0 + (l1 - l0) * Motion.smooth(lookAt, lookAt + 0.3, x))
        let busyMood: (LanviMood) -> Double = { [.listening, .thinking].contains($0) ? 1 : 0 }
        let w = Motion.smooth(heldSince, heldSince + 0.4, x)
        b = max(b, busyMood(heldFrom) * (1 - w) + busyMood(held) * w)
        let talkW = Motion.smooth(talkingSince, talkingSince + 0.3, x)
        b = max(b, mouthOverride != nil ? 1 : (talking ? talkW : 1 - talkW))
        return b
    }

    // MARK: Idle moments

    /// The moment playing at time `x`, if any: its kind, local time and side.
    func currentMoment(_ x: Double) -> (kind: LanviMoment, lt: Double, side: Double, weight: Double)? {
        // A moment asked for by hand (preview) plays on its own.
        if let m = moment, x - momentAt >= 0, x - momentAt < m.duration {
            return (m, x - momentAt, momentSide, 1)
        }
        if moment != nil, x - momentAt >= -0.5, x - momentAt < moment!.duration + 3 { return nil }
        // Otherwise one per 9 s slot, starting 1 to 4 s into it: 6 to 12 s apart.
        let slot = 9.0
        let off = Double(seed % 97) * 0.731
        let k = Int(floor((x + off) / slot))
        let start = Double(k) * slot + 1 + 3 * Motion.rnd(k, seed &+ 41) - off
        // the evening set if it is late, or if the fox was sleepy when this moment began
        let sleepy = (start >= heldSince ? held : heldFrom) == .sleepy
        let kind = momentKind(k, evening: evening || sleepy)
        guard x >= start, x < start + kind.duration, start > appearAt + 3 else { return nil }
        guard busy(start) < 0.01 else { return nil }   // never start on top of something else
        let w = 1 - busy(x)
        guard w > 0.001 else { return nil }
        return (kind, x - start, Motion.rnd(k, seed &+ 43) < 0.5 ? -1 : 1, w)
    }

    /// Shuffled bags of moments: every moment once per round, never the same twice in a row.
    private func momentKind(_ k: Int, evening: Bool) -> LanviMoment {
        let bag: [LanviMoment] = evening
            ? [.yawn, .slowBlink, .ears, .tailCurl, .glance, .sniff]
            : [.glance, .glanceUp, .tilt, .ears, .tailCurl, .sniff, .slowBlink, .invite]
        let n = bag.count
        let round = Int(floor(Double(k) / Double(n)))
        let i = k - round * n
        func shuffled(_ r: Int) -> [LanviMoment] {
            var a = bag
            for j in stride(from: n - 1, to: 0, by: -1) {
                let pick = Int(Motion.rnd(r &* 31 &+ j, seed &+ 47) * Double(j + 1))
                a.swapAt(j, min(pick, j))
            }
            return a
        }
        var a = shuffled(round)
        if a[0] == shuffled(round - 1)[n - 1] { a.swapAt(0, 1) }
        return a[i]
    }

    private func momentLayer(_ x: Double, _ p: inout Pose, _ face: inout Face) {
        guard let m = currentMoment(x) else { return }
        var q = Pose()
        var fq = face
        perform(m.kind, m.lt, m.side, &q, &fq)
        p.add(q, m.weight)
        if m.weight > 0.5 { face = fq }
    }

    /// One idle moment at local time `lt` (seconds), `side` -1 or +1.
    private func perform(_ m: LanviMoment, _ lt: Double, _ side: Double, _ p: inout Pose, _ face: inout Face) {
        switch m {
        case .glance:
            // Eyes flick to the side and hold a beat; the head turns after them, then back.
            let eyes = Motion.env(lt, 0, 0.07, 1.05, 1.13)
            let head = Motion.pulse(lt, start: 0.1, end: 1.15, response: 0.45, damping: 0.72, settle: 0.85)
            p.eyeX += 7 * side * eyes; p.eyeY -= 1 * eyes
            if eyes > 0.5, face.eyes == .open { face.eyes = side > 0 ? .right : .left }
            returnBlink(lt, at: 1.05, &face)
            p.dirX += 0.42 * side * head; p.dirY -= 0.05 * head
            p.headTilt += 2.5 * side * head
            p.tail -= 2.5 * side * head
        case .glanceUp:
            // Up at a snowflake: eyes first, head after, ears perk a touch.
            let eyes = Motion.env(lt, 0, 0.08, 1.0, 1.1)
            let head = Motion.pulse(lt, start: 0.1, end: 1.1, response: 0.5, damping: 0.7, settle: 0.8)
            p.eyeX += 2 * side * eyes; p.eyeY -= 4 * eyes
            if eyes > 0.5, face.eyes == .open { face.eyes = .up }
            returnBlink(lt, at: 1.0, &face)
            p.dirY -= 0.4 * head; p.dirX += 0.12 * side * head
            p.headTilt += 3 * side * head
            p.earL -= 3 * head; p.earR -= 3 * head
        case .tilt:
            // A slow curious head tilt; the upper ear perks, the eyes look up a little.
            let h = Motion.pulse(lt, start: 0, end: 1.25, response: 0.6, damping: 0.62, back: 0.7, settle: 0.9)
            p.headTilt += 8 * side * h; p.dirX += 0.1 * side * h; p.dirY -= 0.1 * h; p.headX += 3 * side * h
            if side > 0 { p.earL -= 5 * h; p.earR += 2 * h } else { p.earR -= 5 * h; p.earL += 2 * h }
            p.eyeX += 2 * side * h; p.eyeY -= 2 * h
            if h > 0.55, face.eyes == .open { face.eyes = .up }
            p.tail += 3 * side * h
        case .ears:
            // One ear flicks, then the other.
            let a = flick(lt, 0.22), b = flick(lt - 0.36, 0.22)
            if side > 0 { p.earL += 11 * a; p.earR += 11 * b } else { p.earR += 11 * a; p.earL += 11 * b }
            p.headTilt += 0.8 * side * (Motion.bump(lt, 0, 0.5) - Motion.bump(lt, 0.36, 0.86))
        case .tailCurl:
            // The tail lifts and curls, then settles with a small overshoot.
            let h = Motion.pulse(lt, start: 0, end: 0.7, response: 0.45, damping: 0.55, back: 0.6, settle: 1.0)
            p.tail += 9 * h
            p.tailCurl += 12 * h
            p.chest += 0.004 * h
        case .sniff:
            // Nose and head lift, two tiny inhales, settle.
            let lift = Motion.pulse(lt, start: 0, end: 0.95, response: 0.4, damping: 0.75, settle: 0.7)
            let sniffs = Motion.bump(lt, 0.3, 0.46) + Motion.bump(lt, 0.52, 0.68)
            p.dirY -= 0.22 * lift + 0.05 * sniffs
            p.headY -= 3 * lift + 1.4 * sniffs
            p.chest += 0.01 * sniffs
            p.earL -= 3 * lift; p.earR -= 3 * lift
        case .slowBlink:
            // A contented slow blink with a small smile and a soft head tilt.
            let h = Motion.env(lt, 0, 0.35, 1.05, 1.5)
            if Motion.inside(lt, 0.08, 0.22) || Motion.inside(lt, 0.98, 1.16) {
                if face.eyes == .open { face.eyes = .half }
            } else if Motion.inside(lt, 0.22, 0.98), face.eyes == .open || face.eyes == .half {
                face.eyes = .closed
            }
            p.mouthScale += 0.08 * h
            p.headTilt += 3 * side * h; p.headY += 2 * h; p.dirY += 0.08 * h
            p.earL += 4 * h; p.earR += 4 * h
        case .invite:
            // Looks down at the button, then back up at you, brightly, with a small nod.
            let down = Motion.env(lt, 0, 0.12, 0.95, 1.15)
            let head = Motion.pulse(lt, start: 0.08, end: 1.0, response: 0.45, damping: 0.75, settle: 0.6)
            p.eyeY += 7 * down
            p.dirY += 0.4 * head; p.headY += 2 * head
            let up = Motion.pulse(lt, start: 1.05, end: 1.45, response: 0.35, damping: 0.55, settle: 0.7)
            p.dirY -= 0.12 * up; p.headY -= 2 * up; p.earL -= 4 * up; p.earR -= 4 * up
            let nod = Motion.bump(lt, 1.6, 2.0)
            p.headY += 2.5 * nod; p.dirY += 0.08 * nod
            returnBlink(lt, at: 0.97, &face)
        case .yawn:
            yawn(&p, &face, yt: lt)
            if Motion.inside(lt, 1.55, 2.6), face.eyes == .open { face.eyes = .half }
        }
    }

    /// A quick blink as the eyes swing back (animators hide a big eye move, and the eye
    /// picture changing back, inside a blink): half, shut, half, from `at`.
    private func returnBlink(_ lt: Double, at a: Double, _ face: inout Face) {
        guard lt >= a, lt < a + 0.17, [.open, .left, .right, .up, .wide].contains(face.eyes) else { return }
        face.eyes = lt < a + 0.035 || lt >= a + 0.115 ? .half : .closed
    }

    /// An ear flick: out quickly, back with a small overshoot, exactly 0 after 3 x `d`.
    private func flick(_ x: Double, _ d: Double) -> Double {
        Motion.bump(x, 0, 1.2 * d) - 0.25 * Motion.bump(x, 1.0 * d, 2.6 * d)
    }

    /// The yawn: a slow breath in (head tips back, chest fills, ears droop), the mouth
    /// opens wide with the eyes shut, then the breath out slumps a little and settles.
    private func yawn(_ p: inout Pose, _ face: inout Face, yt: Double) {
        guard yt > 0, yt < 3.2 else { return }
        let inhale = Motion.pulse(yt, start: 0, end: 1.35, response: 0.55, damping: 0.85, settle: 1.1)
        let open = Motion.pulse(yt, start: 0.25, end: 1.45, response: 0.45, damping: 0.9, settle: 0.9)
        if Motion.inside(yt, 0.32, 1.5) {
            face.mouth = .yawn; face.eyes = .closed
            p.mouthScale += -0.3 + 0.38 * open
        }
        p.dirY -= 0.32 * inhale; p.headY -= 8 * inhale; p.headTilt -= 3 * inhale
        p.chest += 0.03 * inhale; p.bodySY += 0.02 * inhale
        p.earL += 10 * open; p.earR += 10 * open
        let slump = Motion.bump(yt, 1.4, 2.5)
        p.dirY += 0.12 * slump; p.headY += 2 * slump
    }

    // MARK: Talking

    private func talkLayer(_ x: Double, _ p: inout Pose, _ face: inout Face) {
        if let m = mouthOverride {
            // A speech bubble drives the mouth: each change is a word beat, the head bobs.
            face.mouth = m
            let bob = Motion.bump(x, mouthTickAt, mouthTickAt + 0.22)
            p.headY += 1.6 * bob; p.dirY += 0.04 * bob
            return
        }
        let lt = x - talkingSince
        let on = talking ? Motion.smooth(0, 0.25, lt) : 1 - Motion.smooth(0, 0.25, lt)
        guard on > 0.001 else { return }
        // Syllables of 0.15 s: the mouth opens and closes on each (its size is smooth);
        // the shape changes only between syllables, when the mouth is smallest.
        let len = 0.15
        let k = Int(floor(lt / len))
        let ph = lt / len - Double(k)
        let r = Motion.rnd(k, seed &+ 51)
        let open = sin(.pi * ph)
        if talking, on > 0.5 {
            if r < 0.16 {
                face.mouth = .smile                       // a little pause between words
            } else if r < 0.64 {
                face.mouth = .o; p.mouthScale += -0.35 + 0.45 * open
            } else {
                face.mouth = .happy; p.mouthScale += -0.45 + 0.3 * open
            }
        }
        // Words: a small head bob on some syllables, and the head drifts a touch per word.
        var bob = 0.0
        for j in [k - 1, k] where Motion.rnd(j, seed &+ 52) < 0.3 {
            bob += Motion.bump(lt, Double(j) * len, Double(j) * len + 0.26)
        }
        p.headY += 1.8 * bob * on; p.dirY += 0.05 * bob * on
        let word = Int(floor(lt / 0.9))
        let wp = Motion.smooth(0, 0.35, lt - Double(word) * 0.9)
        let drift = Motion.rnd(word - 1, seed &+ 53) + (Motion.rnd(word, seed &+ 53) - Motion.rnd(word - 1, seed &+ 53)) * wp
        p.dirX += 0.12 * (drift - 0.5) * on
        p.earL -= 2 * on; p.earR -= 2 * on
    }

    // MARK: Reactions

    private func reactionLayer(_ x: Double, _ p: inout Pose, _ face: inout Face) {
        // The reaction this one replaced fades out in 0.3 s instead of stopping dead.
        if let r = prevReaction, x - reactionAt < 0.3 {
            var q = Pose(), fq = face
            react(r, x - prevReactionAt, &q, &fq)
            p.add(q, 1 - Motion.smooth(0, 0.3, x - reactionAt))
        }
        if let r = reaction { react(r, x - reactionAt, &p, &face) }
    }

    /// A tail wag that shrinks, one swing per `period`, gone smoothly by `end`.
    private func wag(_ x: Double, amp: Double, period: Double, end: Double) -> Double {
        guard x > 0, x < end else { return 0 }
        return amp * (1 - exp(-x * 14)) * exp(-x * 1.5) * sin(2 * .pi * x / period) * (1 - Motion.smooth(end - 0.4, end, x))
    }

    /// Each reaction: anticipation, action, overshoot, settle, and back to rest.
    private func react(_ r: LanviMood, _ rt: Double, _ p: inout Pose, _ face: inout Face) {
        guard rt >= 0, rt < r.reactionLength else { return }
        switch r {
        case .happy:
            // A joyful hop: crouch, the head leads up and tips back at the top, a big breath
            // of joy, the ears flop on landing, the tail wags, a little wiggle to settle.
            // Faces swap at the top of the hop, hidden inside the move.
            if Motion.inside(rt, 0.31, 1.65) { face.eyes = .happy; face.mouth = .happy }
            hop(&p, rt - 0.05, height: 110, headLeads: true)
            p.headY += 7 * Motion.bump(rt, 1.55, 1.85)
            p.chest += 0.03 * Motion.bump(rt, 0.02, 0.6)
            p.dirY -= 0.28 * exp(-pow((rt - 0.33) / 0.11, 2))
            p.tail += wag(rt - 0.1, amp: 16, period: 0.34, end: 1.9)
            let st = rt - 0.05 - 0.54
            if st > 0 {
                p.rootTilt += 2.6 * sin(2 * .pi * st / 0.32) * exp(-st * 2.6) * min(st / 0.08, 1) * (1 - Motion.smooth(1.0, 1.4, st))
            }
        case .surprised:
            // A tiny dip, a jolt up with a stretch, ears shoot up, head pulls back, tail puffs.
            if Motion.inside(rt, 0.07, 1.4) { face.eyes = .wide; face.mouth = .o }
            let dip = Motion.bump(rt, 0, 0.1)
            p.rootSY -= 0.03 * dip; p.headY += 3 * dip
            let jolt = Motion.pulse(rt, start: 0.06, end: 0.38, response: 0.16, damping: 0.5, settle: 0.7)
            p.rootY -= 22 * jolt; p.bodySY += 0.03 * jolt; p.rootSY += 0.02 * jolt
            let perk = Motion.pulse(rt, start: 0.05, end: 1.25, response: 0.22, damping: 0.45, settle: 0.55)
            p.earL -= 9 * perk; p.earR -= 9 * perk; p.earLS += 0.08 * perk; p.earRS += 0.08 * perk
            p.headY -= 8 * perk; p.dirY -= 0.18 * perk
            p.tail += 12 * perk; p.tailCurl += 8 * perk
        case .curious:
            let tilt = Motion.pulse(rt, start: 0.05, end: 1.6, response: 0.4, damping: 0.55, settle: 0.65)
            p.headTilt += 9 * tilt; p.dirX += 0.2 * tilt; p.dirY -= 0.12 * tilt; p.headX += 4 * tilt
            p.earR -= 6 * tilt; p.earL += 3 * tilt; p.tail += 4 * tilt
            if look == nil, Motion.inside(rt, 0.05, 1.7), face.eyes == .open {
                face.eyes = .up; p.eyeX += 4 * tilt; p.eyeY -= 3 * tilt
            }
        case .sleepy:
            yawn(&p, &face, yt: rt)
            if Motion.inside(rt, 1.55, 2.6), face.eyes == .open { face.eyes = .half }
        case .listening:
            let perk = Motion.pulse(rt, start: 0, end: 1.4, response: 0.25, damping: 0.5, settle: 0.5)
            p.earL -= 9 * perk; p.earR -= 9 * perk; p.earLS += 0.07 * perk; p.earRS += 0.07 * perk
            p.headTilt -= 5 * perk; p.dirX -= 0.1 * perk; p.dirY += 0.1 * perk
            let nod = Motion.bump(rt, 0.3, 0.75)
            p.headY += 6 * nod; p.dirY += 0.15 * nod
        case .thinking:
            let h = Motion.env(rt, 0, 0.4, 2.0, 2.7)
            if Motion.inside(rt, 0.08, 2.15), face.eyes == .open { face.eyes = .up }
            stance(.thinking, rt, &p, weight: h)
        case .greeting:
            // Hello: a little crouch, a small bounce with the ears shooting up and bright
            // eyes, then a happy look with a tilt and a short wag.
            let crouch = Motion.bump(rt, 0, 0.2)
            p.rootSY -= 0.035 * crouch; p.headY += 4 * crouch; p.earL += 3 * crouch; p.earR += 3 * crouch
            hop(&p, rt - 0.1, height: 45)
            let perk = Motion.pulse(rt, start: 0.12, end: 1.6, response: 0.24, damping: 0.45, settle: 0.6)
            p.earL -= 10 * perk; p.earR -= 10 * perk; p.earLS += 0.08 * perk; p.earRS += 0.08 * perk
            p.dirY -= 0.15 * perk
            if Motion.inside(rt, 0.16, 0.55) { face.eyes = .wide }
            if Motion.inside(rt, 0.55, 1.6) { face.eyes = .happy; face.mouth = .happy }
            p.headTilt += 6 * Motion.pulse(rt, start: 0.5, end: 1.55, response: 0.45, damping: 0.6, settle: 0.7)
            p.tail += 10 * sin(2 * .pi * (rt - 0.3) / 0.4) * Motion.env(rt, 0.3, 0.45, 1.0, 1.4)
            p.chest += 0.02 * Motion.bump(rt, 0.1, 0.8)
        case .proud:
            // A small dip, then chest out, chin up, happy eyes, tail high; hold, settle.
            let dip = Motion.bump(rt, 0, 0.24)
            p.headY += 4 * dip; p.dirY += 0.12 * dip; p.chest -= 0.008 * dip; p.rootSY -= 0.02 * dip
            let up = Motion.pulse(rt, start: 0.18, end: 1.75, response: 0.42, damping: 0.55, back: 0.55, settle: 0.85)
            p.chest += 0.05 * up; p.bodySY += 0.018 * up; p.bodySX += 0.01 * up
            p.dirY -= 0.5 * up; p.headY -= 6 * up; p.headTilt -= 2 * up
            p.tail += 16 * up; p.tailCurl += 10 * up
            p.earL -= 6 * up; p.earR -= 6 * up; p.earLS += 0.05 * up; p.earRS += 0.05 * up
            if Motion.inside(rt, 0.26, 1.8) { face.eyes = .happy; face.mouth = .happy }
        case .okay:
            // "That's okay": soft eyes, a small nod and a tilt, ears relax. Never sad.
            let soft = Motion.env(rt, 0, 0.3, 1.5, 1.9)
            if Motion.inside(rt, 0.1, 0.25) || Motion.inside(rt, 1.55, 1.7) {
                if face.eyes == .open { face.eyes = .half }
            } else if Motion.inside(rt, 0.25, 1.55) { face.eyes = .happy }
            p.mouthScale += 0.1 * soft
            let nod = Motion.pulse(rt, start: 0.35, end: 0.7, response: 0.35, damping: 0.6, settle: 0.8)
            p.headY += 6 * nod; p.dirY += 0.22 * nod
            p.headTilt += 5 * Motion.pulse(rt, start: 0.15, end: 1.5, response: 0.55, damping: 0.7, settle: 0.8)
            p.earL += 5 * soft; p.earR += 5 * soft
            p.tail += 5 * sin(2 * .pi * (rt - 0.2) / 1.4) * Motion.env(rt, 0.2, 0.6, 1.4, 2.0)
        case .calm:
            break
        }
    }

    /// Tap: eyes jump to the finger, the head turns and tilts toward it, a happy squint,
    /// an ear flick, a small hop.
    private func tapLayer(_ x: Double, _ p: inout Pose, _ face: inout Face) {
        let rt = x - tapAt
        guard rt >= 0, rt < 1.7 else { return }
        if Motion.inside(rt, 0.36, 0.95) { face.eyes = .happy; face.mouth = face.mouth == .smile ? .happy : face.mouth }
        let tilt = Motion.pulse(rt, start: 0.08, end: 0.95, response: 0.35, damping: 0.55, settle: 0.7)
        p.headTilt += 7 * tapSide * tilt
        p.dirX += 0.18 * tapSide * tilt
        let fl = 11 * flick(rt - 0.05, 0.13)
        if tapSide < 0 { p.earL += fl } else { p.earR += fl }
        hop(&p, rt - 0.3, height: 45)
        p.tail += 10 * Motion.bump(rt, 0.2, 0.6)
    }

    // MARK: Hop

    /// A hop of the whole fox: crouch, stretch going up, squash on landing with the back
    /// feet spreading, two small settling bounces. The front paws stay planted on the body.
    /// `headLeads`: the joyful hop, where the head leads up and nods a beat after landing.
    private func hop(_ p: inout Pose, _ ht: Double, height: Double, headLeads: Bool = false) {
        guard ht > -0.1, ht < 1.5 else { return }
        let h = Motion.hop(ht, height: height)
        p.rootY -= h.lift
        let sq = (h.squash - 1) * 0.5
        p.rootSY += sq
        p.rootSX -= sq * 0.8
        p.spread += max(1 - h.squash, 0) * 0.9
        p.headY += (1 - h.squash) * 70
        let scale = height / 110
        if headLeads {
            let lead = Motion.hop(ht + 0.05, height: height)
            p.headY += (h.lift - lead.lift) * 0.3
            let top = exp(-pow((ht - 0.27) / 0.08, 2))
            p.headY -= 7 * scale * top
            p.eyeY -= 3 * top
            p.headY += 12 * scale * Motion.bump(ht, 0.47, 0.75)
            p.earL += 5 * scale * Motion.bump(ht, 0.45, 0.85); p.earR += 5 * scale * Motion.bump(ht, 0.45, 0.85)
        } else {
            let late = Motion.hop(ht - 0.07, height: height)
            p.headY += (h.lift - late.lift) * 0.35
        }
    }

    // MARK: Blink

    /// Blinks: every 3 to 6 s (times fixed per slot), soft through the half-closed eyes.
    /// Mostly quick (150 ms), sometimes slow, sometimes double. Never on an eye-set swap.
    private func blink(_ x: Double, _ p: inout Pose, _ face: inout Face) {
        let sleepy = held == .sleepy
        var bt: Double
        var kind: Int   // 0 quick, 1 slow, 2 double
        var start = 0.0
        if let fb = freezeBlink {
            bt = fb; kind = 0
        } else {
            let slot = 4.4
            let off = s * 0.37
            let k = Int(floor((x + off) / slot))
            start = Double(k) * slot + 1.6 * Motion.rnd(k, seed &+ 31) - off
            let r = Motion.rnd(k, seed &+ 32)
            kind = sleepy ? 1 : (r < 0.16 ? 2 : (r < 0.3 ? 1 : 0))
            bt = x - start
        }
        let len = [0.15, 0.42, 0.38][kind]
        guard bt >= 0, bt < len else { return }
        guard [.open, .wide, .left, .right, .up, .half].contains(face.eyes) else { return }
        if freezeBlink == nil {
            // the same eyes just before, at the start and just after (no swap nearby)
            let e = face.eyes
            for y in [start - 0.25, start + len + 0.2] where sample(y, face: false).face.eyes != e { return }
        }
        let shut: Bool
        switch kind {
        case 1: shut = bt >= 0.1 && bt < 0.3
        case 2:
            if bt >= 0.15 && bt < 0.23 { return }       // open between the two blinks
            let b = bt < 0.15 ? bt : bt - 0.23
            shut = b >= 0.033 && b < 0.1
        default: shut = bt >= 0.033 && bt < 0.1
        }
        if shut { face.eyes = .closed } else if face.eyes != .half { face.eyes = .half }
        // The head dips a hair with the lids.
        let dip = Motion.bump(bt, 0, len)
        p.headY += 0.35 * dip
        p.dirY += 0.015 * dip
    }
}
