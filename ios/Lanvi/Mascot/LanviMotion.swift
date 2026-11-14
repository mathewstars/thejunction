import SwiftUI

/// How Lanvi feels. Held with `.lanviMood(_:)`, or played once with `.lanviReaction(_:trigger:)`.
/// Lanvi never looks sad because of the person, so there is no sad mood.
enum LanviMood: String, CaseIterable, Equatable {
    case calm, happy, curious, surprised, sleepy, listening
}

/// Everything the puppet needs to work out one frame. Built fresh every frame
/// by `LanviPuppet` from its state; `frame(at:)` is pure maths on the one clock.
struct LanviMotion {
    var t: Double                        // the one clock, seconds
    var seed: Int                        // per fox, so two foxes never move in sync
    var held: LanviMood                  // mood held right now
    var heldFrom: LanviMood              // the mood before (for a soft change-over)
    var heldSince: Double                // when `held` started
    var reaction: LanviMood?             // one-shot reaction playing
    var reactionAt: Double               // when it started
    var hopAt: Double                    // last bounceTrigger hop
    var tapAt: Double                    // last tap on the fox
    var tapSide: Double                  // -1 tap on the left half, +1 right
    var look: CGPoint?                   // where the eyes look now (canvas units)
    var lookFrom: CGPoint?               // previous target
    var lookAt: Double                   // when the target changed
    var reduceMotion: Bool
    var freezeBlink: Double? = nil       // debug: hold a blink at this phase (s)
    var loving = false                   // the `love` pose: soft happy eyes

    static let eyesCenter = Rig.headToCanvas(CGPoint(x: 2, y: -30))

    func frame() -> RigFrame {
        var f = RigFrame()
        let sleepy = held == .sleepy
        let s = Double(seed % 997)

        // Held-mood face and stance (soft change-over for the motion parts).
        applyHeld(&f)

        // --- Idle loops (all on the one clock, each its own length) ---
        if !reduceMotion {
            let breathPeriod = sleepy ? 4.5 : 3.6
            let breathAmp = sleepy ? 0.018 : 0.012
            let b = sin(2 * .pi * (t + s) / breathPeriod)
            let bLate = sin(2 * .pi * (t + s - 0.15) / breathPeriod)
            f.bodySY += CGFloat(breathAmp * b)
            f.bodySX += CGFloat(breathAmp * 0.45 * b)
            // The head rides the chest a beat late.
            f.headDY -= CGFloat(breathAmp * bLate) * Rig.body.size.height * 0.85

            // Tail: base sways, the tip follows 0.25 s later.
            let tailPeriod = held == .happy ? 2.2 : 3.3
            let sway = { (x: Double) in 8 * sin(2 * .pi * (x + s * 0.7) / tailPeriod) }
            f.tail += sway(t)
            f.tailTip += 1.6 * (sway(t - 0.25) - sway(t))

            // Small head tilts and drift, never repeating exactly.
            let tiltA: Double = 1.8 * sin(2 * .pi * (t + s) / 7.3)
            let tiltB: Double = 1.0 * sin(2 * .pi * (t + s * 1.3) / 11.9)
            f.headTilt += tiltA + tiltB
            let drift: Double = 3 * sin(2 * .pi * (t + s) / 9.7)
            f.headDX += CGFloat(drift)

            // Ear twitches: one ear, every 4 to 9 s.
            let earSlot = 6.5
            let k = Int(floor((t + s * 1.7) / earSlot))
            let start = Double(k) * earSlot + 2.5 * Motion.rnd(k, seed &+ 11) - s * 1.7
            let e = Motion.flick(t - start, duration: 0.12) * 7
            if Motion.rnd(k, seed &+ 12) < 0.5 { f.earL += e; f.earLStretch -= CGFloat(e) * 0.004 }
            else { f.earR += e; f.earRStretch -= CGFloat(e) * 0.004 }

            // A fidget every 15 to 30 s.
            applyFidget(&f, s: s)
        }

        // --- Look ---
        applyLook(&f)

        // --- Reactions on top (the idle never stops) ---
        if let r = reaction { applyReaction(r, &f, rt: t - reactionAt) }
        applyTap(&f, rt: t - tapAt)
        if !reduceMotion {
            let h = Motion.hop(t - hopAt, height: 120)
            f.rootY -= CGFloat(h.lift)
            f.bodySY *= CGFloat(h.squash)
            f.bodySX *= CGFloat(1 + (1 - h.squash) * 0.6)
            earsLag(&f, lift: h.lift, t: t - hopAt)
        }

        // The head stays on the neck when the body squashes or stretches.
        f.headDY -= (f.bodySY - 1) * Rig.body.size.height * 0.85

        // --- Blink (always, even with Reduce Motion) ---
        applyBlink(&f, sleepy: sleepy)
        return f
    }

    // MARK: Held moods

    private func applyHeld(_ f: inout RigFrame) {
        // Face swaps are instant (crisp); stance changes spring in.
        switch held {
        case .calm: break
        case .happy: f.mouth = .happy
        case .curious: break
        case .surprised: f.eyes = .wide; f.mouth = .o
        case .sleepy: f.eyes = .half
        case .listening: f.mouth = .smile
        }
        if loving { f.eyes = .happy }
        if reduceMotion { return }
        let p = Motion.spring(t - heldSince, response: 0.5, damping: 0.75)
        stance(heldFrom, &f, weight: 1 - p)
        stance(held, &f, weight: p)
    }

    private func stance(_ m: LanviMood, _ f: inout RigFrame, weight w: Double) {
        let c = CGFloat(w)
        switch m {
        case .calm: break
        case .happy: f.earL += 3 * w; f.earR += 3 * w
        case .curious: f.headTilt += 7 * w; f.earR -= 4 * w; f.headDX += 6 * c
        case .surprised: f.earL -= 6 * w; f.earR -= 6 * w; f.earLStretch += 0.05 * c; f.earRStretch += 0.05 * c; f.headDY -= 6 * c
        case .sleepy: f.earL += 9 * w; f.earR += 9 * w; f.headDY += 8 * c; f.headTilt += 3 * w
        case .listening: f.earL -= 7 * w; f.earR -= 7 * w; f.earLStretch += 0.06 * c; f.earRStretch += 0.06 * c; f.headTilt -= 4 * w; f.headDY += 3 * c
        }
    }

    // MARK: Fidgets

    private func applyFidget(_ f: inout RigFrame, s: Double) {
        let slot = 22.0
        let k = Int(floor((t + s * 3.1) / slot))
        let start = Double(k) * slot + 8 * Motion.rnd(k, seed &+ 21) - s * 3.1
        let ft = t - start
        guard ft > 0, ft < 2.6, reaction == nil || t - reactionAt > 2.5 else { return }
        var kind = Int(Motion.rnd(k, seed &+ 22) * 4)
        if held == .sleepy && Motion.rnd(k, seed &+ 23) < 0.6 { kind = 1 }   // sleepy: mostly yawns
        switch kind {
        case 0: // look around
            if Motion.inside(ft, 0.2, 1.0) { f.eyes = .right }
            else if Motion.inside(ft, 1.0, 1.8) { f.eyes = .leftUp }
            let side = Motion.hold(ft, start: 0.25, end: 1.0, response: 0.35) - Motion.hold(ft, start: 1.05, end: 1.8, response: 0.35)
            f.headDX += CGFloat(10 * side)
            f.headTilt += 4 * side
        case 1: yawn(&f, yt: ft)
        case 2: // paw wave
            let up = Motion.hold(ft, start: 0.0, end: 1.6, response: 0.35, damping: 0.6)
            f.pawR += 48 * up + 12 * up * sin(ft * 2 * .pi / 0.42)
            f.pawRY -= CGFloat(18 * up)
            if Motion.inside(ft, 0.15, 1.6) { f.eyes = .happy }
            f.headTilt -= 4 * up
        default: // happy squint
            if Motion.inside(ft, 0.1, 0.9) { f.eyes = .happy }
            let p = Motion.hold(ft, start: 0.1, end: 0.9, response: 0.3)
            f.earL += 4 * p; f.earR += 4 * p
            f.headTilt += 3 * p
        }
    }

    private func yawn(_ f: inout RigFrame, yt: Double) {
        guard yt > 0, yt < 2.2 else { return }
        let open = Motion.hold(yt, start: 0.15, end: 1.5, response: 0.45, damping: 0.9)
        if Motion.inside(yt, 0.3, 1.55) { f.mouth = .yawn; f.eyes = .closed }
        f.mouthScale *= CGFloat(0.7 + 0.35 * open)
        f.headDY -= CGFloat(10 * open)
        f.headTilt -= 3 * open
        f.earL += 10 * open; f.earR += 10 * open
        f.bodySY += CGFloat(0.02 * open)
    }

    // MARK: Look

    /// Head turn, tilt, eye offset and eye shape for a target in canvas units.
    private static func lookPose(_ p: CGPoint?) -> (dx: CGFloat, tilt: Double, ex: CGFloat, ey: CGFloat, shape: EyeShape?) {
        guard let p else { return (0, 0, 0, 0, nil) }
        let dx = p.x - eyesCenter.x, dy = p.y - eyesCenter.y
        let d = max(hypot(dx, dy), 1)
        let headDX = max(min(dx * 0.04, 12), -12)
        let tilt = Double(max(min(dx * 0.012, 6), -6))
        let ex = dx / d * 6, ey = dy / d * 6
        guard d > 70 else { return (headDX, tilt, ex * d / 70, ey * d / 70, .open) }
        let a = atan2(-Double(dy), Double(dx)) * 180 / .pi   // 0 = right, 90 = up
        let shape: EyeShape
        switch a {
        case -35..<28: shape = .right
        case 28..<68: shape = .rightUp
        case 68..<112: shape = .up
        case 112..<152: shape = .leftUp
        case 152...180, -180 ..< -145: shape = .left
        default: shape = .open   // looking down: open eyes, nudged down
        }
        return (headDX, tilt, ex, ey + (shape == .open ? 4 : 0), shape)
    }

    private func applyLook(_ f: inout RigFrame) {
        let to = Self.lookPose(look), from = Self.lookPose(lookFrom)
        let lt = t - lookAt
        // Eyes jump in 70 ms; the head follows 0.1 s later with a spring.
        let eyeP = CGFloat(Motion.easeOut(lt / 0.07))
        let headP = reduceMotion ? 1 : Motion.spring(lt - 0.1, response: 0.35, damping: 0.7)
        if let shape = (lt >= 0.035 ? to.shape : from.shape), f.eyes == .open { f.eyes = shape }
        f.eyeDX += from.ex + (to.ex - from.ex) * eyeP
        f.eyeDY += from.ey + (to.ey - from.ey) * eyeP
        if !reduceMotion {
            f.headDX += from.dx + (to.dx - from.dx) * CGFloat(headP)
            f.headTilt += from.tilt + (to.tilt - from.tilt) * headP
        }
    }

    // MARK: Reactions

    private func applyReaction(_ r: LanviMood, _ f: inout RigFrame, rt: Double) {
        let m = !reduceMotion
        switch r {
        case .happy:
            guard rt < 2.0 else { return }
            if Motion.inside(rt, 0.06, 1.6) { f.eyes = .happy }
            if rt < 1.75 { f.mouth = .happy }
            guard m else { return }
            let h = Motion.hop(rt - 0.05, height: 110)
            f.rootY -= CGFloat(h.lift)
            f.bodySY *= CGFloat(h.squash)
            f.bodySX *= CGFloat(1 + (1 - h.squash) * 0.6)
            earsLag(&f, lift: h.lift, t: rt - 0.05)
            let paws = Motion.hold(rt, start: 0.08, end: 1.35, response: 0.32, damping: 0.55)
            f.pawL += 62 * paws; f.pawR += 62 * paws
            f.pawLY -= CGFloat(26 * paws); f.pawRY -= CGFloat(26 * paws)
            // Tail wags fast, three-ish times, with the tip whipping behind.
            let wagEnv = Motion.hold(rt, start: 0.0, end: 1.3, response: 0.25, damping: 0.9)
            let wag = { (x: Double) in 15 * sin(2 * .pi * x / 0.34) }
            f.tail += wagEnv * wag(rt)
            f.tailTip += wagEnv * 1.2 * (wag(rt - 0.06) - wag(rt))
            f.headTilt += 4 * sin(2 * .pi * rt / 0.68) * wagEnv
        case .surprised:
            guard rt < 1.8 else { return }
            if rt < 1.4 { f.eyes = .wide; f.mouth = .o }
            guard m else { return }
            let perk = Motion.hold(rt, start: 0, end: 1.3, response: 0.22, damping: 0.45)
            f.earL -= 9 * perk; f.earR -= 9 * perk
            f.earLStretch += CGFloat(0.08 * perk); f.earRStretch += CGFloat(0.08 * perk)
            let jolt = Motion.hold(rt, start: 0, end: 0.35, response: 0.16, damping: 0.5)
            f.rootY -= CGFloat(24 * jolt)
            f.headDY -= CGFloat(10 * perk)
            f.bodySY += CGFloat(0.03 * jolt)
            f.tail -= 10 * perk
            f.pawL += 14 * jolt; f.pawR += 14 * jolt
        case .curious:
            guard rt < 2.2 else { return }
            if look == nil, Motion.inside(rt, 0.05, 1.7), f.eyes == .open { f.eyes = .rightUp; f.eyeDX += 4; f.eyeDY -= 3 }
            guard m else { return }
            let tilt = Motion.hold(rt, start: 0.05, end: 1.6, response: 0.4, damping: 0.55)
            f.headTilt += 9 * tilt
            f.headDX += CGFloat(8 * tilt)
            f.earR -= 6 * tilt
            f.earL += 3 * tilt
            f.tail += 4 * tilt
        case .sleepy:
            guard rt < 2.6 else { return }
            yawn(&f, yt: rt)
            if rt >= 1.55 && rt < 2.4 { f.eyes = .half }
        case .listening:
            guard rt < 2.0 else { return }
            guard m else { return }
            let perk = Motion.hold(rt, start: 0, end: 1.6, response: 0.25, damping: 0.5)
            f.earL -= 9 * perk; f.earR -= 9 * perk
            f.earLStretch += CGFloat(0.07 * perk); f.earRStretch += CGFloat(0.07 * perk)
            f.headDY += CGFloat(4 * perk)
            // A small nod: I'm here.
            f.headDY += CGFloat(6 * sin(min(max(rt - 0.3, 0), 0.5) / 0.5 * .pi))
            f.headTilt -= 4 * perk
        case .calm:
            break
        }
    }

    /// Tap: eyes jump to the finger, head tilts toward it, a happy squint, an ear flick, a small hop.
    private func applyTap(_ f: inout RigFrame, rt: Double) {
        guard rt >= 0, rt < 1.6 else { return }
        if Motion.inside(rt, 0.28, 0.95) { f.eyes = .happy; f.mouth = f.mouth == .smile ? .happy : f.mouth }
        guard !reduceMotion else { return }
        let tilt = Motion.hold(rt, start: 0.08, end: 0.95, response: 0.35, damping: 0.55)
        f.headTilt += 7 * tapSide * tilt
        let flick = Motion.flick(rt - 0.05, duration: 0.13) * 11
        if tapSide < 0 { f.earL += flick } else { f.earR += flick }
        let h = Motion.hop(rt - 0.3, height: 45)
        f.rootY -= CGFloat(h.lift)
        f.bodySY *= CGFloat(h.squash)
        earsLag(&f, lift: h.lift, t: rt - 0.3)
        f.tail += 10 * Motion.flick(rt - 0.2, duration: 0.2)
    }

    /// Ears trail the body: they fold out a little on the way up and spring on landing.
    private func earsLag(_ f: inout RigFrame, lift: Double, t: Double) {
        guard t > 0, t < 1.2 else { return }
        let rise = lift / 120 * 7
        let land = t > 0.42 ? 6 * sin((t - 0.42) / 0.16 * .pi) * exp(-(t - 0.42) * 6) : 0
        f.earL += rise + land
        f.earR += rise + land
        f.tailTip += lift / 120 * 6
    }

    // MARK: Blink

    private func applyBlink(_ f: inout RigFrame, sleepy: Bool) {
        let len = sleepy ? 1.9 : 1.0   // slow blinks when sleepy
        var phase: Double? = freezeBlink
        if phase == nil {
            let slot = 4.2
            let k = Int(floor(t / slot))
            let start = Double(k) * slot + 2.6 * Motion.rnd(k, seed &+ 31)
            let bt = t - start
            if bt >= 0 && bt < 0.18 * len { phase = bt / len }
            else if Motion.rnd(k, seed &+ 32) < 0.2, bt >= 0.3 * len, bt < 0.48 * len { phase = (bt - 0.3 * len) / len }   // the odd double blink
        }
        guard let p = phase, p >= 0, p < 0.18 else { return }
        // close 60 ms, shut 40 ms, open 80 ms
        let o: Double = p < 0.06 ? 1 - p / 0.06 : (p < 0.10 ? 0 : Motion.easeOut((p - 0.10) / 0.08))
        switch f.eyes {
        case .happy, .closed: return
        case .half:
            if o < 0.45 { f.eyes = .closed } else { f.eyeOpen = CGFloat(0.55 + 0.45 * o) }
        default:
            if o < 0.2 { f.eyes = .closed }
            else if o < 0.6 { f.eyes = .half; f.eyeOpen = CGFloat(0.75 + 0.25 * (o - 0.2) / 0.4) }
            else { f.eyeOpen = CGFloat(0.55 + 0.45 * (o - 0.6) / 0.4) }
        }
    }
}
