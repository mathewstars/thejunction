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

    /// Between the eyes, in canvas units.
    static let eyesCenter = Rig.headToCanvas(CGPoint(x: 2, y: -15))
    private static var bodyHeight: CGFloat { Rig.body.size.height / Rig.unit }

    func frame() -> RigFrame {
        var f = core()
        // --- Blink (always, even with Reduce Motion) ---
        // Never on the same moment as an eye-set swap, nor in a reaction's wind-up:
        // skip a blink that would land within 0.35 s of a swap.
        if freezeBlink != nil || (eyes(at: t - 0.3) == f.eyes && eyes(at: t + 0.35) == f.eyes) {
            applyBlink(&f, sleepy: held == .sleepy)
        }
        return f
    }

    /// The eye set this fox shows at another moment (for keeping blinks off swaps).
    private func eyes(at x: Double) -> EyeShape {
        var m = self
        m.t = x
        return m.core().eyes
    }

    /// Everything except the blink.
    private func core() -> RigFrame {
        var f = RigFrame()
        let sleepy = held == .sleepy
        let s = Double(seed % 997)

        // Held-mood face and stance (soft change-over for the motion parts).
        applyHeld(&f)

        // --- Idle loops (all on the one clock, each its own length, none on a beat) ---
        if !reduceMotion {
            // Breathing: in a little quicker than out, the rhythm drifting slightly.
            let breathPeriod = sleepy ? 4.5 : 3.6
            let breathAmp = sleepy ? 0.018 : 0.012
            let breath = { (x: Double) -> Double in
                let phase = (x + s) / breathPeriod + 0.05 * sin(2 * .pi * (x + s) / 23.0)
                return Motion.breath(phase)
            }
            let b = breath(t)
            f.bodySY += CGFloat(breathAmp * b)
            f.bodySX += CGFloat(breathAmp * 0.45 * b)
            // The head rides the chest a beat late.
            f.headDY -= CGFloat(breathAmp * breath(t - 0.15)) * Self.bodyHeight * 0.85

            // Tail: two swings of different lengths; the tip follows 0.25 s later.
            let fast = held == .happy ? 0.68 : 1.0
            let sway = { (x: Double) -> Double in
                let y = x + s * 0.7
                return 6 * sin(2 * .pi * y / (3.3 * fast)) + 3 * sin(2 * .pi * y / (5.7 * fast) + 1.1)
            }
            f.tail += sway(t)
            f.tailTip += 1.7 * (sway(t - 0.25) - sway(t))

            // Weight shifts: the whole fox leans a little, the head follows late.
            let shift = { (x: Double) -> Double in
                3.0 * sin(2 * .pi * (x + s) / 8.9) + 1.5 * sin(2 * .pi * (x + s * 1.9) / 13.3)
            }
            f.rootX += CGFloat(shift(t))
            f.headDX += CGFloat(shift(t - 0.15) - shift(t)) * 1.5

            // Small head tilts and drift, never repeating exactly.
            let tiltA: Double = 1.8 * sin(2 * .pi * (t + s) / 7.3)
            let tiltB: Double = 1.0 * sin(2 * .pi * (t + s * 1.3) / 11.9)
            f.headTilt += tiltA + tiltB
            let drift: Double = 2.5 * sin(2 * .pi * (t + s) / 9.7)
            f.headDX += CGFloat(drift)

            // Ear twitches: one ear, every 4 to 9 s.
            let earSlot = 6.5
            let k = Int(floor((t + s * 1.7) / earSlot))
            let start = Double(k) * earSlot + 2.5 * Motion.rnd(k, seed &+ 11) - s * 1.7
            let e = Motion.flick(t - start, duration: 0.12) * 7
            if Motion.rnd(k, seed &+ 12) < 0.5 { f.earL += e; f.earLStretch -= CGFloat(e) * 0.004 }
            else { f.earR += e; f.earRStretch -= CGFloat(e) * 0.004 }

            // Glances: now and then the eyes look somewhere and come back.
            applyGlance(&f, s: s)

            // A fidget every 15 to 30 s.
            applyFidget(&f, s: s)
        }

        // --- Look ---
        applyLook(&f)

        // --- Reactions on top (the idle never stops) ---
        if let r = reaction { applyReaction(r, &f, rt: t - reactionAt) }
        applyTap(&f, rt: t - tapAt)
        if !reduceMotion { hop(&f, t - hopAt, height: 120) }

        // The head stays on the neck when the chest breathes or yawns.
        f.headDY -= (f.bodySY - 1) * Self.bodyHeight * 0.85
        return f
    }

    /// A hop of the whole fox: anticipation crouch, stretch going up, squash on landing,
    /// two small settling bounces. The fox squashes as a whole (gently) so no part
    /// distorts, and the front paws stay planted relative to the body.
    /// `headLeads`: the joyful hop, where the head leads up, tips back at the top and
    /// nods down a beat after the landing. Otherwise the head lags like a passenger.
    private func hop(_ f: inout RigFrame, _ ht: Double, height: Double, headLeads: Bool = false) {
        guard ht > -0.1, ht < 1.5 else { return }
        let h = Motion.hop(ht, height: height)
        f.rootY -= CGFloat(h.lift)
        let sq = 1 + (h.squash - 1) * 0.5
        f.rootSY *= CGFloat(sq)
        f.rootSX *= CGFloat(1 + (1 - sq) * 0.8)
        // The head sinks into every squash (crouch and landings).
        f.headDY += CGFloat((1 - h.squash) * 70)
        let scale = height / 110
        if headLeads {
            let lead = Motion.hop(ht + 0.05, height: height)
            f.headDY += CGFloat((h.lift - lead.lift) * 0.3)
            // tips back at the top of the hop...
            let top = exp(-pow((ht - 0.27) / 0.08, 2))
            f.headDY -= CGFloat(7 * scale * top)
            f.eyeDY -= CGFloat(3 * top)
            // ...and nods down a beat after the body lands
            f.headDY += CGFloat(12 * scale * Motion.flick(ht - 0.47, duration: 0.15))
        } else {
            let late = Motion.hop(ht - 0.07, height: height)
            f.headDY += CGFloat((h.lift - late.lift) * 0.35)
        }
        earsLag(&f, lift: h.lift, t: ht, landing: headLeads ? 0.5 : 0.42, flop: headLeads ? 11 * scale : 6)
    }

    // MARK: Held moods

    private func applyHeld(_ f: inout RigFrame) {
        // Face swaps are instant (crisp) but wait 0.12 s, so they land inside the
        // hop's crouch that a pose change starts; stance changes spring in.
        let face = (!reduceMotion && t - heldSince < 0.12) ? heldFrom : held
        switch face {
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

    // MARK: Glances

    private func applyGlance(_ f: inout RigFrame, s: Double) {
        guard look == nil, reaction == nil || t - reactionAt > 2.5, t - tapAt > 1.8 else { return }
        let slot = 6.1
        let k = Int(floor((t + s * 2.3) / slot))
        guard Motion.rnd(k, seed &+ 41) < 0.55 else { return }
        let start = Double(k) * slot + 2.0 * Motion.rnd(k, seed &+ 42) - s * 2.3
        let length = 0.6 + 0.5 * Motion.rnd(k, seed &+ 43)
        let gt = t - start
        guard gt > 0, gt < length + 0.8 else { return }
        let pick = Motion.rnd(k, seed &+ 44)
        let (shape, dir): (EyeShape, Double) = pick < 0.4 ? (.right, 1) : (pick < 0.8 ? (.left, -1) : (.up, 0))
        // Eyes lead; the head follows 0.1 s later with a spring, then both come back.
        if gt < length, f.eyes == .open { f.eyes = shape }
        let follow = Motion.hold(gt, start: 0.1, end: length + 0.05, response: 0.4, damping: 0.7)
        f.headDX += CGFloat(5 * dir * follow)
        f.headTilt += 2.5 * dir * follow
        if dir == 0 { f.headDY -= CGFloat(4 * follow) }
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
            else if Motion.inside(ft, 1.0, 1.8) { f.eyes = .left }
            let side = Motion.hold(ft, start: 0.25, end: 1.0, response: 0.35) - Motion.hold(ft, start: 1.05, end: 1.8, response: 0.35)
            f.headDX += CGFloat(10 * side)
            f.headTilt += 4 * side
        case 1: yawn(&f, yt: ft)
        case 2: // a small happy bounce (paws stay planted)
            hop(&f, ft - 0.05, height: 32, headLeads: true)
            if Motion.inside(ft, 0.31, 1.0) { f.eyes = .happy }
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
        let dx = (p.x - eyesCenter.x) / Rig.unit, dy = (p.y - eyesCenter.y) / Rig.unit
        let d = max(hypot(dx, dy), 1)
        let headDX = max(min(dx * 0.04, 12), -12)
        let tilt = Double(max(min(dx * 0.012, 6), -6))
        let ex = dx / d * 6, ey = dy / d * 6
        guard d > 70 else { return (headDX, tilt, ex * d / 70, ey * d / 70, .open) }
        let a = atan2(-Double(dy), Double(dx)) * 180 / .pi   // 0 = right, 90 = up
        let shape: EyeShape
        switch a {
        case -40..<45: shape = .right
        case 45..<135: shape = .up
        case 135...180, -180 ..< -140: shape = .left
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
            // Joy from the whole body; the front paws stay planted on the snow.
            // Faces swap at the top of the hop, hidden inside the move.
            // Back to the normal face inside a small nod at 1.65 s.
            if Motion.inside(rt, 0.31, 1.65) { f.eyes = .happy; f.mouth = .happy }
            guard m else { return }
            hop(&f, rt - 0.05, height: 110, headLeads: true)
            f.headDY += CGFloat(7 * Motion.flick(rt - 1.58, duration: 0.14))
            // Tail wags fast: four swings that shrink, the tip clearly trailing.
            let wag = { (x: Double) -> Double in
                guard x > 0 else { return 0 }
                return 16 * (1 - exp(-x * 14)) * exp(-x * 1.5) * sin(2 * .pi * x / 0.34)
            }
            f.tail += wag(rt - 0.1)
            f.tailTip += 1.5 * (wag(rt - 0.17) - wag(rt - 0.1))
            // A tiny side-to-side wiggle of the whole fox while it settles.
            let st = rt - 0.05 - 0.54
            if st > 0 { f.rootTilt += 2.6 * sin(2 * .pi * st / 0.32) * exp(-st * 2.6) * min(st / 0.08, 1) }
        case .surprised:
            guard rt < 1.8 else { return }
            if Motion.inside(rt, 0.07, 1.4) || (!m && rt < 1.4) { f.eyes = .wide; f.mouth = .o }
            guard m else { return }
            f.rootY += CGFloat(6 * Motion.flick(rt, duration: 0.06))
            let perk = Motion.hold(rt, start: 0.05, end: 1.3, response: 0.22, damping: 0.45)
            f.earL -= 9 * perk; f.earR -= 9 * perk
            f.earLStretch += CGFloat(0.08 * perk); f.earRStretch += CGFloat(0.08 * perk)
            let jolt = Motion.hold(rt, start: 0.05, end: 0.4, response: 0.16, damping: 0.5)
            f.rootY -= CGFloat(24 * jolt)
            f.headDY -= CGFloat(10 * perk)
            f.bodySY += CGFloat(0.03 * jolt)
            f.tail -= 10 * perk
        case .curious:
            guard rt < 2.2 else { return }
            if look == nil, Motion.inside(rt, 0.05, 1.7), f.eyes == .open { f.eyes = .up; f.eyeDX += 4; f.eyeDY -= 3 }
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
        if Motion.inside(rt, 0.36, 0.95) { f.eyes = .happy; f.mouth = f.mouth == .smile ? .happy : f.mouth }
        guard !reduceMotion else { return }
        let tilt = Motion.hold(rt, start: 0.08, end: 0.95, response: 0.35, damping: 0.55)
        f.headTilt += 7 * tapSide * tilt
        let flick = Motion.flick(rt - 0.05, duration: 0.13) * 11
        if tapSide < 0 { f.earL += flick } else { f.earR += flick }
        hop(&f, rt - 0.3, height: 45)
        f.tail += 10 * Motion.flick(rt - 0.2, duration: 0.2)
    }

    /// Ears trail the body: they fold out a little on the way up, flop on landing (a beat
    /// after it) and spring back with an overshoot.
    private func earsLag(_ f: inout RigFrame, lift: Double, t: Double, landing: Double = 0.42, flop: Double = 6) {
        guard t > 0, t < 1.4 else { return }
        let rise = lift / 120 * 7
        let land = t > landing ? flop * sin((t - landing) / 0.16 * .pi) * exp(-(t - landing) * 6) : 0
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
            if bt >= 0 && bt < 0.15 * len { phase = bt / len }
            else if Motion.rnd(k, seed &+ 32) < 0.2, bt >= 0.27 * len, bt < 0.42 * len { phase = (bt - 0.27 * len) / len }   // the odd double blink
        }
        guard let p = phase, p >= 0, p < 0.15 else { return }
        // close 50 ms, shut 35 ms, open 65 ms: open, half closed, closed, half closed, open
        let o: Double = p < 0.05 ? 1 - Motion.easeIn(p / 0.05) : (p < 0.085 ? 0 : Motion.easeOut((p - 0.085) / 0.065))
        if !reduceMotion { f.headDY += CGFloat(2.5 * (1 - o)) }
        switch f.eyes {
        case .happy, .closed: return
        case .half:
            if o < 0.5 { f.eyes = .closed }
        default:
            if o < 0.22 { f.eyes = .closed } else if o < 0.7 { f.eyes = .half }
        }
    }
}
