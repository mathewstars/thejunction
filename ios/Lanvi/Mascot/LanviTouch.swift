import SwiftUI

// Touching Lanvi feels like touching a small animal: what he does depends on WHERE you
// touch, and it is never the same twice in a row. There is no hop on a touch (the hop
// is kept for real joy). Quick repeated taps build up (a look, a giggle, a big wriggle,
// a contented sigh) and then he calms. A long press is petting; a slow drag is followed
// by the eyes, then the head. Every reaction starts on the touch and returns to rest.

/// One change of where the eyes look: from `at` on, look at `target` (canvas units; nil =
/// straight ahead).
struct LookStep: Equatable {
    var at: Double
    var target: CGPoint?
}

/// Where a touch landed.
enum LanviTouchZone: String, CaseIterable {
    case head, nose, ear, cheek, belly, tail, paw, near

    /// The reactions a touch here can play (they take turns, never the same twice running).
    var acts: [LanviTouchAct] {
        switch self {
        case .head: return [.petLean, .nod, .petNuzzle, .petWiggle]
        case .nose: return [.boop, .boopGiggle, .boopSniff]
        case .ear: return [.earFlick, .earTickle, .earDouble]
        case .cheek: return [.giggle, .giggleShy, .giggleSqueeze]
        case .belly: return [.tickle, .tickleCurl, .tickleBig]
        case .tail: return [.tailLook, .tailSwish, .tailCurlLook]
        case .paw: return [.pawLift, .pawPat, .pawHold]
        case .near: return [.look, .lookPerk]
        }
    }

    /// A point in the middle of a place (canvas units), for the preview's touch buttons.
    static func point(_ zone: LanviTouchZone, side s: Double) -> CGPoint {
        let left = s < 0
        switch zone {
        case .head: return CGPoint(x: Rig.head.local.x + (left ? -120 : 120), y: 430)
        case .nose: return Rig.headToCanvas(Rig.marking("face-nose"))
        case .ear: return CGPoint(x: left ? 600 : 1350, y: 250)
        case .cheek: return CGPoint(x: Rig.head.local.x + (left ? -330 : 330), y: 1060)
        case .belly: return CGPoint(x: Rig.body.local.x + (left ? -80 : 80), y: 1450)
        case .tail: return CGPoint(x: 280, y: 1420)
        case .paw: return CGPoint(x: left ? Rig.legL.local.x : Rig.legR.local.x, y: 1790)
        case .near: return CGPoint(x: left ? -120 : 1720, y: 820)
        }
    }

    /// Which zone a point (canvas units) falls in, and which side (-1 the viewer's left).
    /// Generous targets, measured on the rest pose.
    static func at(_ q: CGPoint) -> (zone: LanviTouchZone, side: Double) {
        let headX = Rig.head.local.x, bodyX = Rig.body.local.x
        let nose = Rig.headToCanvas(Rig.marking("face-nose"))
        let side: Double
        func within(_ x0: CGFloat, _ x1: CGFloat, _ y0: CGFloat, _ y1: CGFloat) -> Bool {
            q.x >= x0 && q.x <= x1 && q.y >= y0 && q.y <= y1
        }
        if hypot(q.x - nose.x, q.y - nose.y) < 120 { return (.nose, q.x < nose.x ? -1 : 1) }
        side = q.x < headX ? -1 : 1
        if within(380, 1600, -60, 470), q.x < headX - 230 || q.x > headX + 230 { return (.ear, side) }
        if within(400, 1550, 160, 800) { return (.head, side) }
        if within(370, 1580, 800, 1300) { return (.cheek, side) }
        let bodySide: Double = q.x < bodyX ? -1 : 1
        if q.y > 1640, within(510, 810, 0, 1900) || within(940, 1240, 0, 1900) { return (.paw, bodySide) }
        if q.y > 1720, within(470, 560, 0, 1900) || within(1240, 1480, 0, 1900) { return (.paw, bodySide) }
        if within(0, 560, 1000, 1880) { return (.tail, -1) }
        if within(470, 1480, 940, 1880) { return (.belly, bodySide) }
        return (.near, side)
    }
}

/// The one owner of the touch reactions: which reaction a tap plays (by place, never the
/// same twice running; quick taps build up, then calm), and which one it replaces. The
/// newest tap always wins: a reaction it replaces fades out in 0.3 s, and a calm tap
/// (after many quick ones) ends the reaction in flight, so the eyes are back to normal
/// open eyes within 0.6 s of the last reaction (never left in a squint or a sigh while
/// the taps go on).
struct LanviTapper {
    var touch: LanviTouchAct?
    var touchAt: Double = -100
    var touchSide: Double = 1
    var prevTouch: LanviTouchAct?
    var prevTouchAt: Double = -100
    var lastAct: LanviTouchAct?
    var zoneTurns: [LanviTouchZone: Int] = [:]
    var streak = 0
    var lastTapAt: Double = -100

    /// Reactions that aim the eyes themselves (the others look at the finger).
    static let aims: Set<LanviTouchAct> = [.boop, .boopGiggle, .boopSniff, .earFlick, .earTickle, .earDouble,
                                           .tailLook, .tailSwish, .tailCurlLook, .pawLift, .pawPat, .pawHold,
                                           .nod, .giggleShy]

    /// A tap at `p` (canvas units) at time `t`: the reaction it starts (nil = calm, the
    /// eyes only follow the finger).
    mutating func tap(at p: CGPoint, time t: Double) -> LanviTouchAct? {
        let (zone, side) = LanviTouchZone.at(p)
        streak = t - lastTapAt < 1.4 ? streak + 1 : 1
        lastTapAt = t
        var act: LanviTouchAct?
        switch streak {
        case 1:
            act = pick(zone)
            if zone == .head, let last = lastAct, [.petLean, .petNuzzle].contains(last), t - touchAt < 3 {
                act = .petWiggle                 // a second pet soon after: a happy wiggle
            }
        case 2: act = lastAct == .giggle ? .giggleSqueeze : .giggle
        case 3: act = lastAct == .tickleBig ? .tickle : .tickleBig
        case 4: act = .sigh
        default: act = nil                     // calm now: the eyes only follow the finger
        }
        // the reaction in flight (if any) gives way to the newest tap and fades out
        if let a = touch, t - touchAt < a.duration {
            prevTouch = a
            prevTouchAt = touchAt
            touch = nil
            touchAt = t
        } else {
            prevTouch = nil
        }
        guard let act else { return nil }
        touch = act
        touchAt = t
        touchSide = side
        lastAct = act
        return act
    }

    private mutating func pick(_ zone: LanviTouchZone) -> LanviTouchAct {
        let acts = zone.acts
        let turn = zoneTurns[zone, default: 0]
        zoneTurns[zone] = turn + 1
        var a = acts[turn % acts.count]
        if a == lastAct { a = acts[(turn + 1) % acts.count] }
        return a
    }
}

/// One touch reaction.
enum LanviTouchAct: String, CaseIterable, Equatable {
    case petLean, petNuzzle, petWiggle, nod
    case boop, boopGiggle, boopSniff
    case earFlick, earTickle, earDouble
    case giggle, giggleShy, giggleSqueeze
    case tickle, tickleCurl, tickleBig
    case tailLook, tailSwish, tailCurlLook
    case pawLift, pawPat, pawHold
    case look, lookPerk
    case sigh

    var duration: Double {
        switch self {
        case .petLean, .petNuzzle: return 2.0
        case .petWiggle: return 1.7
        case .nod: return 1.5
        case .boop, .boopGiggle: return 1.7
        case .boopSniff: return 1.8
        case .earFlick, .earDouble: return 1.5
        case .earTickle: return 1.6
        case .giggle, .giggleSqueeze: return 1.5
        case .giggleShy: return 2.0
        case .tickle: return 1.8
        case .tickleCurl: return 1.9
        case .tickleBig: return 2.0
        case .tailLook: return 2.3
        case .tailSwish: return 1.8
        case .tailCurlLook: return 2.2
        case .pawLift, .pawPat: return 1.9
        case .pawHold: return 2.0
        case .look, .lookPerk: return 1.6
        case .sigh: return 2.4
        }
    }
}

extension Rig {
    /// A face marking's centre in head pixels from the head's centre.
    static func marking(_ name: String) -> CGPoint {
        let r = LanviArt.layer[name] ?? CGRect(x: 0.5, y: 0.5, width: 0, height: 0)
        let px = LanviArt.px("head")
        return CGPoint(x: (r.midX - 0.5) * px.width, y: (r.midY - 0.5) * px.height)
    }
}

extension LanviMotion {
    // MARK: Touch reactions

    func touchLayer(_ x: Double, _ p: inout Pose, _ face: inout Face) {
        // The touch this one replaced fades out in 0.3 s; the new one starts on the touch.
        if let a = prevTouch, x - touchAt < 0.3 {
            var q = Pose(), fq = face
            act(a, x - prevTouchAt, side: touchSide, &q, &fq)
            p.add(q, 1 - Motion.smooth(0, 0.3, x - touchAt))
        }
        if let a = touch { act(a, x - touchAt, side: touchSide, &p, &face) }
    }

    /// A finger resting on him: he leans into it with slow content breaths and happy eyes
    /// for as long as it stays, and gives a soft slow blink when it lifts.
    func pettingLayer(_ x: Double, _ p: inout Pose, _ face: inout Face) {
        let w = petting ? Motion.smooth(pettingSince, pettingSince + 0.35, x)
                        : 1 - Motion.smooth(pettingSince, pettingSince + 0.6, x)
        if w > 0.001 {
            let s = touchSide
            p.headTilt += 8 * s * w; p.dirX += 0.12 * s * w; p.dirY -= 0.1 * w; p.headY -= 2.5 * w
            p.earL += 7 * w; p.earR += 7 * w
            let lt = x - pettingSince
            let slow = petting ? 0.5 - 0.5 * cos(2 * .pi * max(lt, 0) / 2.6) : 0
            p.chest += (0.012 + 0.012 * slow) * w; p.bodySY += 0.005 * slow * w
            p.mouthScale += 0.1 * w
            // happy eyes while petted (once the lean has settled, so a finger that rests a
            // moment before dragging gets the lean, not a squint), and in the frames just
            // before the finger lifted
            if (petting && lt > 0.3) || (!petting && lt < 0 && pettedLong) { face.eyes = .happy }
        }
        // after: the lids open from the squint (shut, half, open); when the finger lifted
        // (not when it went on to drag), one soft slow blink a moment later
        if !petting, pettingSince > 0, pettedLong {
            let lt = x - pettingSince
            if Motion.inside(lt, 0, 0.06) { face.eyes = .closed }
            else if Motion.inside(lt, 0.06, 0.16) { face.eyes = .half }
            else if !pettingEndedByDrag {
                if Motion.inside(lt, 0.55, 0.72) || Motion.inside(lt, 1.0, 1.18) {
                    face.eyes = .half
                } else if Motion.inside(lt, 0.72, 1.0) { face.eyes = .closed }
            }
        }
    }

    /// Shoulder bounces of a giggle: `n` small bounces from `start`, each smaller.
    private func bounces(_ t: Double, start: Double, n: Int, every: Double = 0.17) -> Double {
        var b = 0.0
        for i in 0..<n {
            let a = start + Double(i) * every
            b += Motion.bump(t, a, a + every) * (1 - 0.2 * Double(i))
        }
        return b
    }

    /// Eyes: half, shut, half from `at` (a quick blink as part of a reaction).
    private func blinkAt(_ t: Double, _ at: Double, _ face: inout Face) {
        guard t >= at, t < at + 0.15 else { return }
        face.eyes = t < at + 0.035 || t >= at + 0.1 ? .half : .closed
    }

    private func act(_ a: LanviTouchAct, _ t: Double, side s: Double, _ p: inout Pose, _ face: inout Face) {
        guard t >= 0, t < a.duration else { return }
        switch a {
        // --- Head: petting ---
        case .petLean:
            // He leans his head into the finger, eyes close happy, ears soften back, a slow
            // content breath.
            let lean = Motion.pulse(t, start: 0.02, end: 1.2, response: 0.45, damping: 0.7, settle: 0.75)
            p.headTilt += 8 * s * lean; p.dirX += 0.14 * s * lean; p.dirY -= 0.12 * lean; p.headY -= 2.5 * lean
            p.earL += 7 * lean; p.earR += 7 * lean
            p.chest += 0.025 * Motion.bump(t, 0.1, 1.5)
            p.mouthScale += 0.1 * lean
            if Motion.inside(t, 0.12, 1.25) { face.eyes = .happy }
        case .petNuzzle:
            // He rubs his head against the finger, one way then the other.
            let env = Motion.env(t, 0.02, 0.25, 1.4, 1.9)
            let rub = sin(2 * .pi * t / 1.0) * env
            p.headTilt += 7 * rub; p.dirX += 0.1 * rub; p.headY -= 1.5 * env
            p.earL += 6 * env; p.earR += 6 * env
            p.chest += 0.015 * Motion.bump(t, 0.2, 1.6)
            if Motion.inside(t, 0.1, 1.5) { face.eyes = .happy }
        case .petWiggle:
            // A happy little wiggle of the head and a tail swish.
            let env = Motion.env(t, 0.02, 0.12, 0.8, 1.2)
            let wig = sin(2 * .pi * t / 0.36) * env
            p.headTilt += 6 * wig; p.dirX += 0.08 * wig; p.earL += 4 * env; p.earR += 4 * env
            p.tail += 9 * sin(2 * .pi * (t - 0.05) / 0.5) * Motion.env(t, 0.05, 0.2, 1.0, 1.5)
            if Motion.inside(t, 0.06, 1.3) { face.eyes = .happy }
            if Motion.inside(t, 0.1, 1.2) { face.mouth = .happy; p.mouthScale -= 0.3 }

        case .nod:
            // A happy nod, twice ("yes!"): the head dips quickly toward you and comes back
            // up more slowly, the eyes stay on you, the ears follow, a smile.
            let nod = Motion.env(t, 0.04, 0.16, 0.19, 0.42) + 0.75 * Motion.env(t, 0.46, 0.57, 0.6, 0.86)
            p.dirY += 0.55 * nod; p.headY += 9 * nod; p.headTilt += 2 * s * nod
            p.eyeY -= 4 * nod
            p.earL -= 4 * nod; p.earR -= 4 * nod
            p.chest += 0.006 * nod
            let smile = Motion.env(t, 0.06, 0.2, 1.05, 1.35)
            if smile > 0.5 { face.mouth = .happy; p.mouthScale -= 0.42 }

        // --- Nose: boop ---
        case .boop:
            // Eyes go wide and cross toward the nose, a tiny recoil with a squash, two quick
            // blinks, then a small smile.
            let cross = Motion.env(t, 0.02, 0.09, 0.42, 0.55)
            if Motion.inside(t, 0.03, 0.5) { face.eyes = .wide }
            p.eyeCross += 7 * cross; p.eyeY += 5 * cross
            let recoil = Motion.pulse(t, start: 0, end: 0.25, response: 0.18, damping: 0.5, settle: 0.6)
            p.headY -= 4 * recoil; p.dirY -= 0.15 * recoil; p.earL -= 5 * recoil; p.earR -= 5 * recoil
            p.headSquash += 0.045 * Motion.bump(t, 0, 0.22)
            blinkAt(t, 0.62, &face); blinkAt(t, 0.84, &face)
            let smile = Motion.env(t, 0.95, 1.1, 1.4, 1.65)
            if smile > 0.5 { face.mouth = .happy; p.mouthScale -= 0.42 }
        case .boopGiggle:
            // Boop: a startled little "o", then a giggle.
            let cross = Motion.env(t, 0.02, 0.09, 0.36, 0.48)
            if Motion.inside(t, 0.03, 0.42) { face.eyes = .wide; face.mouth = .o }
            p.eyeCross += 6 * cross; p.eyeY += 4 * cross
            p.headSquash += 0.04 * Motion.bump(t, 0, 0.2)
            let b = bounces(t, start: 0.45, n: 3)
            p.bodySY += 0.012 * b; p.headY -= 2.5 * b; p.chest += 0.008 * b
            if Motion.inside(t, 0.48, 1.35) { face.eyes = .happy; face.mouth = .happy; p.mouthScale += -0.3 + 0.15 * b }
        case .boopSniff:
            // He sniffs the finger: eyes cross down at it, head forward, two sniffs, a smile.
            let look = Motion.env(t, 0.02, 0.12, 1.0, 1.2)
            p.eyeCross += 5 * look; p.eyeY += 6 * look
            let lean = Motion.pulse(t, start: 0.05, end: 1.05, response: 0.4, damping: 0.75, settle: 0.7)
            p.dirY += 0.22 * lean; p.headY += 2 * lean
            let sniffs = Motion.bump(t, 0.4, 0.55) + Motion.bump(t, 0.62, 0.77)
            p.headY -= 1.4 * sniffs; p.chest += 0.01 * sniffs
            if Motion.inside(t, 0.38, 0.8) { face.eyes = .half }
            if Motion.inside(t, 1.05, 1.55) { face.mouth = .happy; p.mouthScale -= 0.42 }
            returnBlink(t, at: 1.0, &face)

        // --- Ears ---
        case .earFlick, .earDouble:
            // The touched ear flicks away and springs back with a wobble; the head tilts
            // toward it and the eyes glance up at it.
            let wobble = { (u: Double) -> Double in
                guard u > 0 else { return 0 }
                return sin(2 * .pi * u / 0.3) * exp(-u * 4.5) * (1 - exp(-u * 40)) * (1 - Motion.smooth(0.9, 1.25, u))
            }
            let f = a == .earFlick ? 18 * wobble(t) : 13 * (wobble(t) + wobble(t - 0.32))
            if s < 0 { p.earL += f; p.earR += 0.25 * f } else { p.earR += f; p.earL += 0.25 * f }
            let tilt = Motion.pulse(t, start: 0.05, end: 0.9, response: 0.4, damping: 0.65, settle: 0.55)
            p.headTilt += 6 * s * tilt; p.dirX += 0.1 * s * tilt
            let eyes = Motion.env(t, 0.03, 0.1, 0.9, 1.0)
            p.eyeX += 4 * s * eyes; p.eyeY -= 3 * eyes
            if eyes > 0.5, face.eyes == .open { face.eyes = .up }
            returnBlink(t, at: 0.9, &face)
        case .earTickle:
            // Ticklish: the ear flattens out, he shrugs toward it with a squint, then it
            // springs back.
            let flat = Motion.pulse(t, start: 0, end: 0.6, response: 0.2, damping: 0.45, settle: 0.9)
            if s < 0 { p.earL += 20 * flat } else { p.earR += 20 * flat }
            let shrug = Motion.pulse(t, start: 0.03, end: 0.8, response: 0.3, damping: 0.6, settle: 0.7)
            p.headTilt += 8 * s * shrug; p.headY += 2 * shrug; p.bodySY += 0.01 * shrug
            if Motion.inside(t, 0.08, 1.0) { face.eyes = .happy; face.mouth = .happy; p.mouthScale -= 0.4 }

        // --- Cheeks and chin: a giggle ---
        case .giggle:
            let b = bounces(t, start: 0.03, n: 3)
            let env = Motion.env(t, 0.02, 0.15, 0.9, 1.3)
            p.bodySY += 0.012 * b; p.headY -= 2.5 * b; p.chest += 0.01 * b
            p.headTilt += 4 * s * env
            if Motion.inside(t, 0.04, 1.2) { face.eyes = .happy }
            if Motion.inside(t, 0.06, 1.15) { face.mouth = .happy; p.mouthScale += -0.25 + 0.15 * b }
        case .giggleShy:
            // Shy: a little giggle, then he looks away and down from the finger with a
            // small smile, ears soft, and peeks back at you (the eyes first).
            if Motion.inside(t, 0.03, 0.3) { face.eyes = .happy }
            let b = bounces(t, start: 0.04, n: 2, every: 0.14)
            p.headY -= 1.5 * b; p.bodySY += 0.006 * b
            let away = Motion.pulse(t, start: 0.12, end: 1.15, response: 0.42, damping: 0.72, settle: 0.65)
            p.dirX -= 0.32 * s * away; p.dirY += 0.22 * away; p.headTilt -= 6 * s * away; p.headY += 1.5 * away
            p.earL += 5 * away; p.earR += 5 * away
            let eyes = Motion.env(t, 0.26, 0.36, 1.0, 1.12)
            p.eyeX -= 5 * s * eyes; p.eyeY += 4 * eyes
            if Motion.inside(t, 0.3, 1.55) { face.mouth = .happy; p.mouthScale -= 0.35 }
            returnBlink(t, at: 1.08, &face)
        case .giggleSqueeze:
            // Eyes squeeze, shoulders up, two squashy giggles, ears back.
            let up = Motion.env(t, 0.02, 0.15, 0.9, 1.3)
            p.bodySY += 0.015 * up; p.headY += 1.5 * up; p.earL += 6 * up; p.earR += 6 * up
            p.headSquash += 0.03 * (Motion.bump(t, 0.1, 0.3) + Motion.bump(t, 0.35, 0.55))
            if Motion.inside(t, 0.04, 1.2) { face.eyes = .happy; face.mouth = .happy; p.mouthScale -= 0.3 }

        // --- Belly and chest: a tickle ---
        case .tickle, .tickleBig:
            // A wriggle from side to side, a laugh, the tail thumps.
            let big = a == .tickleBig
            let env = Motion.env(t, 0.02, 0.15, big ? 1.2 : 1.0, big ? 1.7 : 1.5)
            let wr = sin(2 * .pi * t / 0.3) * env
            p.rootTilt += (big ? 4.5 : 3) * wr
            p.headTilt -= (big ? 3 : 2) * wr
            p.earL += (big ? 9 : 5) * env; p.earR += (big ? 9 : 5) * env
            p.chest += 0.01 * env * (0.5 + 0.5 * sin(2 * .pi * t / 0.3))
            let thumps = Motion.bump(t, 0.25, 0.4) + Motion.bump(t, 0.6, 0.75) + (big ? Motion.bump(t, 0.95, 1.1) : 0)
            p.tail -= 9 * thumps
            if Motion.inside(t, 0.05, big ? 1.65 : 1.45) {
                face.eyes = .happy; face.mouth = .happy
                p.mouthScale += -0.2 + 0.15 * (0.5 + 0.5 * sin(2 * .pi * t / 0.3))
            }
        case .tickleCurl:
            // He curls up around the tickle, then unfurls laughing.
            let curl = Motion.pulse(t, start: 0.02, end: 0.7, response: 0.3, damping: 0.7, settle: 0.9)
            p.dirY += 0.35 * curl; p.headY += 4 * curl; p.chest -= 0.01 * curl; p.rootSY -= 0.02 * curl
            p.earL += 6 * curl; p.earR += 6 * curl
            let wr = sin(2 * .pi * t / 0.32) * Motion.env(t, 0.75, 0.9, 1.2, 1.6)
            p.rootTilt += 2.5 * wr
            if Motion.inside(t, 0.05, 1.6) { face.eyes = .happy }
            if Motion.inside(t, 0.7, 1.55) { face.mouth = .happy; p.mouthScale -= 0.25 }

        // --- Tail ---
        case .tailLook:
            // The tail swishes out from under the finger, he looks back over his shoulder
            // at it (eyes first, head after), then back to you with a curious tilt.
            p.tail += 14 * Motion.pulse(t, start: 0, end: 0.35, response: 0.22, damping: 0.5, settle: 1.2)
            let eyes = Motion.env(t, 0.03, 0.1, 1.0, 1.1)
            p.eyeX -= 6 * eyes; p.eyeY += 3 * eyes
            if eyes > 0.5, face.eyes == .open { face.eyes = .left }
            let look = Motion.pulse(t, start: 0.13, end: 1.05, response: 0.42, damping: 0.72, settle: 0.6)
            p.dirX -= 0.45 * look; p.dirY += 0.1 * look; p.headTilt -= 4 * look
            returnBlink(t, at: 1.0, &face)
            let tilt = Motion.pulse(t, start: 1.25, end: 1.85, response: 0.45, damping: 0.6, settle: 0.45)
            p.headTilt += 7 * tilt; p.eyeX += 3 * tilt; p.eyeY -= 2 * tilt
            if tilt > 0.5, face.eyes == .open { face.eyes = .up }
        case .tailSwish:
            // Two quick swishes and a quick glance back at it.
            p.tail += 11 * sin(2 * .pi * t / 0.5) * Motion.env(t, 0, 0.08, 0.9, 1.3)
            let eyes = Motion.env(t, 0.05, 0.12, 0.75, 0.85)
            p.eyeX -= 6 * eyes; p.eyeY += 2 * eyes
            if eyes > 0.5, face.eyes == .open { face.eyes = .left }
            p.dirX -= 0.2 * Motion.pulse(t, start: 0.15, end: 0.8, response: 0.4, damping: 0.72, settle: 0.6)
            p.mouthScale += 0.12 * Motion.env(t, 0.8, 1.0, 1.4, 1.75)
        case .tailCurlLook:
            // The tail curls up around him and he turns to admire it.
            let curl = Motion.pulse(t, start: 0, end: 1.0, response: 0.4, damping: 0.6, settle: 1.1)
            p.tail += 10 * curl; p.tailCurl += 16 * curl
            let eyes = Motion.env(t, 0.06, 0.14, 1.0, 1.1)
            p.eyeX -= 5 * eyes; p.eyeY += 2 * eyes
            if eyes > 0.5, face.eyes == .open { face.eyes = .left }
            let look = Motion.pulse(t, start: 0.16, end: 1.05, response: 0.45, damping: 0.72, settle: 0.7)
            p.dirX -= 0.4 * look; p.headTilt -= 3 * look
            returnBlink(t, at: 1.0, &face)
            if Motion.inside(t, 1.2, 1.9) { face.mouth = .happy; p.mouthScale -= 0.42 }

        // --- Paws ---
        case .pawLift, .pawPat, .pawHold:
            // He looks down at the paw, lifts it a few points and sets it down (a tiny tap,
            // never a swing), and looks back up.
            let eyes = Motion.env(t, 0.03, 0.1, 1.15, 1.25)
            p.eyeX += 3 * s * eyes; p.eyeY += 7 * eyes
            let look = Motion.pulse(t, start: 0.08, end: 1.2, response: 0.42, damping: 0.75, settle: 0.6)
            p.dirY += 0.38 * look; p.dirX += 0.12 * s * look; p.headY += 2 * look
            let lift: Double
            switch a {
            case .pawPat: lift = 10 * (Motion.bump(t, 0.3, 0.55) + Motion.bump(t, 0.62, 0.87))
            case .pawHold: lift = 12 * Motion.env(t, 0.3, 0.5, 1.0, 1.25)
            default: lift = 12 * Motion.bump(t, 0.35, 0.75) + 3 * Motion.bump(t, 0.8, 1.0)
            }
            if s < 0 { p.pawL += lift } else { p.pawR += lift }
            returnBlink(t, at: 1.15, &face)
            let up = Motion.pulse(t, start: 1.25, end: 1.5, response: 0.3, damping: 0.6, settle: 0.4)
            p.dirY -= 0.08 * up; p.earL -= 3 * up; p.earR -= 3 * up
            if a == .pawHold, Motion.inside(t, 1.3, 1.85) { face.eyes = .happy }

        // --- Near him: the eyes follow the finger (the look itself is set by the touch) ---
        case .look, .lookPerk:
            // A curious tilt toward the finger (the eyes are already on it).
            let tilt = Motion.pulse(t, start: 0.15, end: 1.0, response: 0.45, damping: 0.6, settle: 0.55)
            p.headTilt += 10 * s * tilt; p.headX += 2 * s * tilt
            let perk = a == .lookPerk ? Motion.pulse(t, start: 0.05, end: 0.9, response: 0.25, damping: 0.5, settle: 0.6) : 0
            p.earL -= (3 + 5 * perk) * tilt + 4 * perk; p.earR -= (3 + 5 * perk) * tilt + 4 * perk
            if a == .lookPerk, Motion.inside(t, 0.06, 0.5) { face.eyes = .wide }

        // --- After many quick taps: a contented sigh, then calm ---
        case .sigh:
            let breath = Motion.pulse(t, start: 0, end: 0.9, response: 0.6, damping: 0.85, settle: 1.4)
            p.chest += 0.035 * breath; p.bodySY += 0.02 * breath; p.dirY -= 0.15 * breath
            let slump = Motion.bump(t, 0.9, 2.3)
            p.headY += 3 * slump; p.dirY += 0.15 * slump
            p.earL += 6 * Motion.env(t, 0.5, 1.0, 1.8, 2.3); p.earR += 6 * Motion.env(t, 0.5, 1.0, 1.8, 2.3)
            if Motion.inside(t, 0.3, 0.6) || Motion.inside(t, 1.5, 1.75) { if face.eyes == .open { face.eyes = .half } }
            else if Motion.inside(t, 0.6, 1.5) { face.eyes = .closed }
            p.mouthScale += 0.1 * Motion.env(t, 0.4, 0.8, 1.8, 2.3)
        }
    }
}
