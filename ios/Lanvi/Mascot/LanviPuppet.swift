import SwiftUI

/// The paper-puppet fox: separate parts (tail, body, paws, head, ears, eyes, mouth),
/// each moving on its own from one `TimelineView` clock. Use it through `LanviView`.
///
/// Parts only translate, rotate and scale (render transforms, never a rounded layout
/// offset). Depth comes from layers the cut script makes (`LanviArt.layer`): the face
/// markings slide around the head when it turns, the chest bib swells with the breath,
/// and the tail and ears are soft bands that bend along their length.
struct LanviPuppet: View {
    var pose: LanviPose
    var size: CGFloat
    var bounceTrigger: Int

    @Environment(\.lanviMood) private var moodOverride
    @Environment(\.lanviReactionRequest) private var reactionRequest
    @Environment(\.lanviLook) private var lookUnit
    @Environment(\.lanviTalking) private var talking
    @Environment(\.lanviMouth) private var mouthOverride
    @Environment(\.lanviMomentRequest) private var momentRequest
    @Environment(\.lanviTouchRequest) private var touchRequest
    @Environment(\.lanviFollowRequest) private var followRequest
    @Environment(\.lanviHops) private var hops
    @Environment(\.lanviDebugFreeze) private var freeze
    @Environment(\.lanviDebugBounds) private var debugBounds
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Fixed per fox size, so a screen rebuilding the fox never makes it jump.
    private var seed: Int { Int(size * 13) % 997 }
    @State private var heldFrom: LanviMood = .calm
    @State private var heldSince: Double = -100
    @State private var reaction: LanviMood?
    @State private var reactionAt: Double = -100
    @State private var prevReaction: LanviMood?
    @State private var prevReactionAt: Double = -100
    @State private var hopAt: Double = -100
    // Where the eyes look: every change, each springing from where they are.
    @State private var lookSteps: [LookStep] = [LookStep(at: -100, target: nil)]
    @State private var fingerLook = false      // the eyes are on a finger, not the screen's point
    @State private var lookBack = 0            // the latest "look back after a finger" request
    // Touch.
    @State private var touch: LanviTouchAct?
    @State private var touchAt: Double = -100
    @State private var touchSide: Double = 1
    @State private var prevTouch: LanviTouchAct?
    @State private var prevTouchAt: Double = -100
    @State private var lastAct: LanviTouchAct?
    @State private var zoneTurns: [LanviTouchZone: Int] = [:]
    @State private var streak = 0
    @State private var lastTapAt: Double = -100
    @State private var petting = false
    @State private var pettingSince: Double = -100
    @State private var pettingFrom: Double = -100
    @State private var pettingEndedByDrag = false
    @State private var finger: Finger?
    @State private var lastFollowAt: Double = -100
    @State private var follow: Int?                 // preview: a scripted finger path
    @State private var followAt: Double = -100
    @State private var contacts = 0            // a light haptic on each first contact
    @State private var talkingSince: Double = -100
    @State private var mouthTickAt: Double = -100
    @State private var mouthFrom: MouthShape?
    @State private var drivenSince: Double = -100
    @State private var talkStart: Double = -100
    @State private var moment: LanviMoment?
    @State private var momentAt: Double = -100
    @State private var momentSide: Double = 1
    @State private var appearAt: Double = -100
    @State private var lateHour = false

    /// Points per canvas unit (master pixel), and per motion unit.
    private var k: CGFloat { size / Rig.canvas.height }
    private var mu: CGFloat { k * Rig.unit }
    private var held: LanviMood { moodOverride ?? pose.puppetMood }
    /// Between the hind feet, where the fox stands (0...1 of the canvas).
    private static let feet = UnitPoint(x: (Rig.body.center.x - Rig.frame.minX) / Rig.canvas.width, y: 0.995)

    /// The canvas starts here in the view, so the head and body sit on the view's
    /// centre line and the tail overhangs to the left.
    private var canvasOrigin: CGPoint {
        CGPoint(x: size / 2 - (Rig.centerX - Rig.frame.minX) * k, y: size - Rig.canvas.height * k)
    }
    /// How far the centred canvas is moved from a plain centred one.
    private var centring: CGFloat { canvasOrigin.x - (size - Rig.canvas.width * k) / 2 }

    var body: some View {
        TimelineView(.animation) { context in
            let m = motion(at: context.date.timeIntervalSinceReferenceDate)
            let f = m.frame()
            let _ = LanviFrameLog.shared?.record(date: context.date, f, extra: logState(m))
            // (nothing is drawn under him: the captain wants the painted snow as it is)
            ZStack(alignment: .bottom) {
                rig(f)
                    .frame(width: Rig.canvas.width * k, height: Rig.canvas.height * k)
                    .scaleEffect(x: 1 + f.pose.rootSX, y: 1 + f.pose.rootSY, anchor: Self.feet)
                    .rotationEffect(.degrees(f.pose.rootTilt), anchor: Self.feet)
                    // a render transform, never rounded to whole pixels (a layout offset can
                    // be, which shows as a 1-pixel stair-step at slow speeds)
                    .transformEffect(CGAffineTransform(translationX: centring + f.pose.rootX * mu, y: f.pose.rootY * mu))
            }
            .frame(width: size, height: size, alignment: .bottom)
            // One driver per value: the clock. A screen's withAnimation or .animation
            // must never also interpolate the parts (that fights the clock and stutters).
            .transaction { $0.animation = nil; $0.disablesAnimations = true }
        }
        .contentShape(Rectangle())
        // One finger on him: a tap (by place), a long press (petting) or a slow drag
        // (the eyes, then the head, follow it).
        .simultaneousGesture(DragGesture(minimumDistance: 0)
            .onChanged { fingerMoved($0.location) }
            .onEnded { fingerUp($0.location) })
        .sensoryFeedback(.impact(weight: .light, intensity: 0.6), trigger: contacts)
        .onChange(of: touchRequest) { _, new in if let new { requested(new) } }
        .onChange(of: followRequest) { _, new in
            guard let new else { return }
            follow = new.path
            followAt = now
        }
        .onChange(of: bounceTrigger) { hopAt = now }
        .onChange(of: pose) { _, new in
            // cheer and surprised bring their own jump; the rest hop
            switch new {
            case .cheer: play(.happy)
            case .surprised: play(.surprised)
            default: hopAt = now
            }
        }
        .onChange(of: held) { old, _ in heldFrom = old; heldSince = now }
        .onChange(of: reactionRequest) { _, new in if let new { play(new.mood) } }
        .onChange(of: talking) { _, on in
            talkingSince = now
            if on { talkStart = now }
        }
        .onChange(of: mouthOverride) { old, new in
            mouthFrom = old
            mouthTickAt = now
            if (old == nil) != (new == nil) { drivenSince = now }
        }
        .onChange(of: momentRequest) { _, new in
            guard let new else { return }
            moment = new.moment
            momentAt = now
            momentSide = -momentSide
        }
        .onChange(of: lookUnit) { _, new in
            guard !fingerLook else { return }    // a finger has the eyes; look back later
            setLook(new.map(canvasPoint(unit:)))
        }
        .onAppear {
            appearAt = now
            lookSteps = [LookStep(at: -100, target: lookUnit.map(canvasPoint(unit:)))]
            let forced = UserDefaults.standard.string(forKey: "hour").flatMap { Int($0) }
            let hour = forced ?? Calendar.current.component(.hour, from: Date())
            lateHour = hour >= 20 || hour < 5
            if let script = UserDefaults.standard.string(forKey: "puppetDrag") { scriptedDrag(script) }
        }
        .accessibilityElement()
        .accessibilityLabel("Lanvi the fox")
    }

    // MARK: Building one frame

    private var now: Double { Date().timeIntervalSinceReferenceDate }

    private func motion(at clock: Double) -> LanviMotion {
        var m = LanviMotion(t: clock, seed: seed, held: held, heldFrom: heldFrom, heldSince: heldSince,
                            reaction: reaction, reactionAt: reactionAt, hopAt: hopAt, reduceMotion: reduceMotion)
        m.lookSteps = lookSteps
        m.follow = follow
        m.followAt = followAt
        m.touch = touch
        m.touchAt = touchAt
        m.touchSide = touchSide
        m.prevTouch = prevTouch
        m.prevTouchAt = prevTouchAt
        m.petting = petting
        m.pettingSince = pettingSince
        m.pettingFrom = pettingFrom
        m.pettingEndedByDrag = pettingEndedByDrag
        m.prevReaction = prevReaction
        m.prevReactionAt = prevReactionAt
        m.talking = talking
        m.talkingSince = talkingSince
        m.talkStart = talkStart
        m.mouthOverride = mouthOverride
        m.mouthFrom = mouthFrom
        m.mouthTickAt = mouthTickAt
        m.drivenSince = drivenSince
        m.moment = moment
        m.momentAt = momentAt
        m.momentSide = momentSide
        m.appearAt = appearAt
        m.evening = lateHour
        m.hops = hops
        m.loving = moodOverride == nil && pose == .love
        if let freeze {
            // Proof stills: a fixed clock, a reaction or moment held at a chosen moment.
            let base = 1012.1
            m.t = base + freeze.at
            m.seed = 0
            m.reaction = freeze.reaction
            m.reactionAt = freeze.reaction == nil ? -100 : base
            m.prevReaction = nil
            m.moment = freeze.moment
            m.momentAt = freeze.moment == nil ? -100 : base
            m.momentSide = 1
            m.appearAt = .infinity      // no idle moment of its own
            m.freezeBlink = freeze.blink
            m.heldSince = -100
            m.heldFrom = m.held
            m.touch = nil
            m.prevTouch = nil
            m.petting = false
            m.pettingSince = -100
            m.pettingFrom = -100
            m.hopAt = -100
            m.lookSteps = [LookStep(at: -100, target: freeze.look.map(canvasPoint(unit:)))]
        }
        return m
    }

    private func play(_ mood: LanviMood) {
        if let r = reaction, now - reactionAt < r.reactionLength {
            prevReaction = r
            prevReactionAt = reactionAt
        } else {
            prevReaction = nil
        }
        reaction = mood
        reactionAt = now
    }

    private func canvasPoint(unit u: UnitPoint) -> CGPoint {
        CGPoint(x: (u.x * size - canvasOrigin.x) / k, y: (u.y * size - canvasOrigin.y) / k)
    }

    private func viewPoint(canvas p: CGPoint) -> CGPoint {
        CGPoint(x: canvasOrigin.x + p.x * k, y: canvasOrigin.y + p.y * k)
    }

    /// A new place to look, springing from wherever the eyes and head are right now.
    /// Changes older than 2 s have settled and fold into the first one.
    private func setLook(_ p: CGPoint?) {
        var steps = lookSteps
        steps.append(LookStep(at: now, target: p))
        // (only settled changes fold: folding an unsettled one would make it jump)
        while steps.count > 2, now - steps[1].at > 2 || steps.count > 400 {
            steps[0] = LookStep(at: -100, target: steps[1].target)
            steps.remove(at: 1)
        }
        lookSteps = steps
    }

    /// The eyes go to a finger; after `after` seconds they go back to the screen's point.
    private func lookAtFinger(_ p: CGPoint?, back after: Double?) {
        fingerLook = true
        setLook(p)
        guard let after else { return }
        lookBack += 1
        let token = lookBack
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(after))
            guard token == lookBack, finger == nil else { return }
            fingerLook = false
            setLook(lookUnit.map(canvasPoint(unit:)))
        }
    }

    /// Debug (`-puppetLog YES`): the puppet's own state for the frame log.
    private func logState(_ m: LanviMotion) -> String {
        let fingerState = finger.map { $0.dragging ? "drag" : "down" } ?? "-"
        let moment = m.currentMoment(m.t).map { $0.kind.rawValue } ?? "-"
        return "\(petting ? 1 : 0),\(fingerState),\(touch.map { "\($0)" } ?? "-"),\(moment),\(lookSteps.count)," +
            String(format: "%.4f", now - m.t)
    }

    /// Debug (`-puppetDrag hold|quick`): a finger driven through the real touch handlers
    /// at 60 events a second, 3 s after the fox appears, for 6 s: down on the cheek,
    /// (`hold`: resting there 0.6 s first, like a person placing a finger), then dragged
    /// far left, far right, up, down and round in circles across the whole screen, lifted;
    /// then a second drag that moves at once.
    private func scriptedDrag(_ kind: String) {
        let side = size
        func at(_ u: Double) -> CGPoint {
            // a path through the fox's square (0...1), reaching well outside it
            let keys: [(Double, CGPoint)] = [(0, CGPoint(x: 0.62, y: 0.42)), (0.12, CGPoint(x: -0.9, y: 0.4)),
                (0.27, CGPoint(x: 1.9, y: 0.45)), (0.4, CGPoint(x: 0.5, y: -1.2)), (0.52, CGPoint(x: 0.5, y: 1.6)),
                (0.6, CGPoint(x: 0.5, y: 0.4))]
            if u <= 0.6 {
                for j in 1..<keys.count where u <= keys[j].0 {
                    let (ua, a) = keys[j - 1], (ub, b) = keys[j]
                    let e = (u - ua) / (ub - ua)
                    let s = e * e * (3 - 2 * e)
                    return CGPoint(x: (a.x + (b.x - a.x) * s) * side, y: (a.y + (b.y - a.y) * s) * side)
                }
            }
            let a = (u - 0.6) / 0.4 * 2 * 2 * Double.pi
            let r = 0.15 + 0.6 * min((u - 0.6) / 0.1, 1)
            return CGPoint(x: (0.5 + r * sin(a)) * side, y: (0.4 - r * cos(a)) * side)
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            let start = now
            let rest = kind == "hold" ? 0.6 : 0
            fingerMoved(at(0))
            while now - start < rest { try? await Task.sleep(for: .milliseconds(16)) }
            let t0 = now
            while now - t0 < 6 {
                fingerMoved(at((now - t0) / 6))
                try? await Task.sleep(for: .milliseconds(16))
            }
            fingerUp(at(1))
            try? await Task.sleep(for: .seconds(1.2))
            let t1 = now
            fingerMoved(CGPoint(x: 0.3 * side, y: 0.45 * side))
            while now - t1 < 2 {
                let u = (now - t1) / 2
                fingerMoved(CGPoint(x: (0.3 + 0.5 * u) * side, y: (0.45 - 0.3 * sin(u * .pi)) * side))
                try? await Task.sleep(for: .milliseconds(16))
            }
            fingerUp(CGPoint(x: 0.8 * side, y: 0.45 * side))
        }
    }

    // MARK: Touch

    /// A finger on the fox: where it went down, whether it has moved off that spot
    /// (then it is not petting) and whether it is dragging.
    private struct Finger {
        var at: Double
        var start: CGPoint
        var moved = false
        var dragging = false
    }

    private func canvas(_ location: CGPoint) -> CGPoint {
        CGPoint(x: (location.x - canvasOrigin.x) / k, y: (location.y - canvasOrigin.y) / k)
    }

    private func fingerMoved(_ location: CGPoint) {
        let t = now
        guard var f = finger else {
            finger = Finger(at: t, start: location)
            contacts += 1
            // held still for half a second: petting
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(0.5))
                guard let f = finger, f.at == t, !f.moved else { return }
                startPetting(at: canvas(f.start))
            }
            return
        }
        let off = hypot(location.x - f.start.x, location.y - f.start.y)
        if !f.moved, off > 6 {
            f.moved = true
            finger = f
        }
        if !f.dragging, off > 12 {
            f.dragging = true
            finger = f
            if petting { stopPetting(byDrag: true) }
        }
        // a drag: every touch event is a new place to look; the pupils (then the head)
        // follow it on their springs
        if f.dragging, t - lastFollowAt > 1 / 120 {
            lastFollowAt = t
            lookAtFinger(canvas(location), back: nil)
        }
    }

    private func fingerUp(_ location: CGPoint) {
        guard let f = finger else { return }
        finger = nil
        if petting { stopPetting(); lookAtFinger(nil, back: 0.1); return }
        if f.dragging { lookAtFinger(canvas(location), back: 0.7); return }
        tapped(at: canvas(location))
    }

    private func startPetting(at p: CGPoint) {
        touchSide = LanviTouchZone.at(p).side
        petting = true
        pettingSince = now
        pettingFrom = now
    }

    /// `byDrag`: the finger went on to drag, so the eyes open at once to follow it (no
    /// contented slow blink).
    private func stopPetting(byDrag: Bool = false) {
        petting = false
        pettingSince = now
        pettingEndedByDrag = byDrag
    }

    /// A tap at a canvas point: a reaction for that place, never the same twice running.
    /// Quick taps build up (a look, a giggle, a big wriggle, a contented sigh), then calm.
    private func tapped(at p: CGPoint) {
        let t = now
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
        // The eyes go to the finger, unless the reaction aims them itself.
        let aims: Set<LanviTouchAct> = [.boop, .boopGiggle, .boopSniff, .earFlick, .earTickle, .earDouble,
                                        .tailLook, .tailSwish, .tailCurlLook, .pawLift, .pawPat, .pawHold]
        if act == nil || !aims.contains(act!) {
            lookAtFinger(p, back: max(1.1, (act?.duration ?? 1.2) - 0.5))
        }
        guard let act else { return }
        if let a = touch, t - touchAt < a.duration {
            prevTouch = a
            prevTouchAt = touchAt
        } else {
            prevTouch = nil
        }
        touch = act
        touchAt = t
        touchSide = side
        lastAct = act
    }

    /// The next reaction for a place: they take turns, and never repeat the last one.
    private func pick(_ zone: LanviTouchZone) -> LanviTouchAct {
        let acts = zone.acts
        let turn = zoneTurns[zone, default: 0]
        zoneTurns[zone] = turn + 1
        var a = acts[turn % acts.count]
        if a == lastAct { a = acts[(turn + 1) % acts.count] }
        return a
    }

    /// The preview's touch buttons (and the touch demo): a tap at a place, or a hold.
    private func requested(_ r: LanviTouchRequest) {
        let p = LanviTouchZone.point(r.zone, side: r.side)
        contacts += 1
        if let hold = r.hold {
            startPetting(at: p)
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(hold))
                stopPetting()
            }
        } else {
            tapped(at: p)
        }
    }

    // MARK: Drawing

    private func rig(_ f: RigFrame) -> some View {
        ZStack(alignment: .topLeading) {
            tail(f)
            headTurn(f) {
                ear(Rig.earL, left: true, f)
                ear(Rig.earR, left: false, f)
            }
            body(f)
            leg(Rig.legL, lift: f.pose.pawL)
            leg(Rig.legR, lift: f.pose.pawR)
            headTurn(f) {
                head(f)
                eyes(f)
                mouth(f)
            }
        }
    }

    private func image(_ p: Rig.Part) -> some View {
        Image(p.image)
            .resizable()
            .interpolation(.high)
            .frame(width: p.size.width * k, height: p.size.height * k)
    }

    /// One depth layer cut from a part (`LanviArt.layer`), sized to its box in the part.
    private func layerImage(_ name: String, _ p: Rig.Part) -> some View {
        let r = LanviArt.layer[name] ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        return Image("puppet-" + name)
            .resizable()
            .interpolation(.high)
            .frame(width: r.width * p.size.width * k, height: r.height * p.size.height * k)
    }

    /// Where a layer's box centre sits in its part (points from the part's top-left).
    private func layerCentre(_ name: String, _ p: Rig.Part) -> CGPoint {
        let r = LanviArt.layer[name] ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        return CGPoint(x: r.midX * p.size.width * k, y: r.midY * p.size.height * k)
    }

    /// A point of the part (shares) as an anchor inside one of its layers.
    private func anchor(_ u: UnitPoint, in name: String) -> UnitPoint {
        let r = LanviArt.layer[name] ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        return UnitPoint(x: (u.x - r.minX) / r.width, y: (u.y - r.minY) / r.height)
    }

    /// A part built from overlapping bands along its length (tail, ears), base first,
    /// each fading in over the one before. Each band turns around the part's pivot by its
    /// share of `bend`, so the base stays put and the tip curls. At rest the bands rebuild
    /// the painted part exactly.
    private func banded(_ p: Rig.Part, _ prefix: String, count: Int, bend: Double) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(0..<count, id: \.self) { i in
                let name = "\(prefix)-b\(i)"
                let c = layerCentre(name, p)
                layerImage(name, p)
                    .rotationEffect(.degrees(bend * Double(LanviArt.bend[name] ?? 0)), anchor: anchor(p.pivot, in: name))
                    .position(x: c.x, y: c.y)
            }
        }
        .frame(width: p.size.width * k, height: p.size.height * k, alignment: .topLeading)
    }

    /// The tail turns at its hidden base and bends along its length, the tip trailing.
    private func tail(_ f: RigFrame) -> some View {
        let p = Rig.tail
        return banded(p, "tail", count: 12, bend: f.tailBend)
            .rotationEffect(.degrees(f.pose.tail), anchor: p.pivot)
            .position(x: p.local.x * k, y: p.local.y * k)
    }

    /// An ear: its flop or perk at the base, a soft bend above it (the tip trails), and
    /// depth: when the head turns, the near ear comes forward and grows a touch, the far
    /// ear tucks back and narrows.
    private func ear(_ p: Rig.Part, left: Bool, _ f: RigFrame) -> some View {
        let q = f.pose
        let hx = q.dirX, hy = q.dirY
        let near = max(left ? hx : -hx, 0), far = max(left ? -hx : hx, 0)
        // (the perspective turn of the whole head does most of it; this is the ear's own
        // turn on top: the far ear swings round behind the skull)
        let dx = hx * (near > 0 ? 5 : 2)
        let dy = 4 * far + 3 * abs(hy)
        let sx = (1 + 0.04 * near - 0.02 * far) * (1 - 0.1 * far)
        let sy = (1 + 0.04 * near - 0.02 * far) * (1 - 0.05 * abs(hy)) * (1 + (left ? q.earLS : q.earRS))
        let angle = left ? -q.earL : q.earR
        return banded(p, left ? "ear-left" : "ear-right", count: 10, bend: left ? f.earLBend : f.earRBend)
            .scaleEffect(x: sx, y: sy, anchor: p.pivot)
            .rotationEffect(.degrees(angle), anchor: p.pivot)
            .transformEffect(CGAffineTransform(translationX: dx * mu, y: dy * mu))
            .position(x: p.local.x * k, y: p.local.y * k)
    }

    /// The body: stretches from the feet with the breath, the chest bib swells, the back
    /// feet spread on landing, the bib turns a touch against the head.
    private func body(_ f: RigFrame) -> some View {
        let p = Rig.body, q = f.pose
        let bib = layerCentre("body-bib", p)
        return ZStack(alignment: .topLeading) {
            Image("puppet-body-base")
                .resizable()
                .interpolation(.high)
                .frame(width: p.size.width * k, height: p.size.height * k)
                .position(x: p.size.width * k / 2, y: p.size.height * k / 2)
            layerImage("body-bib", p)
                .scaleEffect(1 + q.chest, anchor: anchor(Rig.chestCenter, in: "body-bib"))
                .transformEffect(CGAffineTransform(translationX: -q.dirX * 0.025 * p.size.width * k, y: 0))
                .position(x: bib.x, y: bib.y)
        }
        .frame(width: p.size.width * k, height: p.size.height * k, alignment: .topLeading)
        .scaleEffect(x: 1 + q.bodySX + q.spread * 0.5, y: 1 + q.bodySY, anchor: p.pivot)
        // the body counter-turns a touch against the head
        .rotationEffect(.degrees(-1.2 * q.dirX), anchor: p.pivot)
        .position(x: p.local.x * k, y: p.local.y * k)
    }

    /// A front leg (its top fade is baked into the art). The paws stay planted and never
    /// swing; a touched paw only lifts a few points straight up and sets down.
    private func leg(_ p: Rig.Part, lift: Double) -> some View {
        image(p)
            .transformEffect(CGAffineTransform(translationX: 0, y: -lift * mu))
            .position(x: p.local.x * k, y: p.local.y * k)
    }

    /// Everything that turns with the head (the ears behind the body, and the head,
    /// eyes and mouth in front) gets the same tilt around the neck, shift and settle.
    private func headTurn<Content: View>(_ f: RigFrame, @ViewBuilder _ content: () -> Content) -> some View {
        let neck = UnitPoint(x: Rig.neck.x / Rig.canvas.width, y: Rig.neck.y / Rig.canvas.height)
        let centre = UnitPoint(x: Rig.head.local.x / Rig.canvas.width, y: Rig.head.local.y / Rig.canvas.height)
        return ZStack(alignment: .topLeading) { content() }
            .frame(width: Rig.canvas.width * k, height: Rig.canvas.height * k, alignment: .topLeading)
            // The whole head turns in perspective around its centre (the face, eyes,
            // muzzle and ears as one piece, so nothing slides off it): the near side
            // grows, the far side shrinks and tucks in.
            .rotation3DEffect(.degrees(Rig.turnYaw * f.pose.dirX), axis: (x: 0, y: 1, z: 0),
                              anchor: centre, perspective: Rig.turnPerspective)
            .rotation3DEffect(.degrees(-Rig.turnPitch * f.pose.dirY), axis: (x: 1, y: 0, z: 0),
                              anchor: centre, perspective: Rig.turnPerspective)
            .scaleEffect(x: f.headSX, y: f.headSY, anchor: neck)
            .rotationEffect(.degrees(f.pose.headTilt), anchor: neck)
            .transformEffect(CGAffineTransform(translationX: f.pose.headX * mu, y: f.pose.headY * mu))
    }

    /// The head: the fur (with the markings lifted off) stays; the markings (eye
    /// patches, brow marks, nose) slide around it as it turns, each by how far forward it
    /// sits on the face, and the patches squeeze on the side it turns towards.
    private func head(_ f: RigFrame) -> some View {
        let p = Rig.head, q = f.pose
        return ZStack(alignment: .topLeading) {
            // The head in two halves: the far cheek tucks in a little more than the
            // perspective turn alone gives, and the near one comes forward (each half
            // scales from the middle line).
            ForEach(["head-base-l", "head-base-r"], id: \.self) { name in
                let c = layerCentre(name, p)
                let isFar = (name == "head-base-r") == (q.dirX > 0)
                let a = abs(q.dirX)
                layerImage(name, p)
                    .scaleEffect(x: isFar ? 1 - Rig.farCheekTuck * a : 1 + Rig.nearCheekGrow * a, y: 1,
                                 anchor: anchor(UnitPoint(x: 0.5, y: 0.5), in: name))
                    .position(x: c.x, y: c.y)
            }
            ForEach(Self.markings, id: \.0) { name, depth, squeeze in
                let c = layerCentre(name, p)
                let t = faceShift(markingHome(name), q)
                layerImage(name, p)
                    .overlay { if debugBounds && squeeze { Rectangle().stroke(.yellow, lineWidth: 1) } }
                    .scaleEffect(x: squeeze ? 1 + (t.sx - 1) * 0.8 : 1, y: squeeze ? 1 + (t.sy - 1) * 0.8 : 1)
                    .transformEffect(CGAffineTransform(translationX: t.dx * depth, y: t.dy * depth))
                    .position(x: c.x, y: c.y)
            }
        }
        .frame(width: p.size.width * k, height: p.size.height * k, alignment: .topLeading)
        .position(x: p.local.x * k, y: p.local.y * k)
    }

    /// The face markings: how far forward each sits (1 = on the face sphere) and whether
    /// it squeezes with the turn.
    private static let markings: [(String, CGFloat, Bool)] = [
        ("face-patch-l", 1, true), ("face-patch-r", 1, true),
        ("face-brow-l", 0.95, false), ("face-brow-r", 0.95, false),
        ("face-nose", 1.2, false),
    ]

    /// A marking's centre in head pixels from the head's centre.
    private func markingHome(_ name: String) -> CGPoint {
        let r = LanviArt.layer[name] ?? CGRect(x: 0.5, y: 0.5, width: 0, height: 0)
        let px = LanviArt.px("head")
        return CGPoint(x: (r.midX - 0.5) * px.width, y: (r.midY - 0.5) * px.height)
    }

    /// Where a face point (head pixels from the head's centre) moves with the turn, in
    /// points, and the squeeze there.
    private func faceShift(_ base: CGPoint, _ q: Pose) -> (dx: CGFloat, dy: CGFloat, sx: CGFloat, sy: CGFloat) {
        let t = Rig.faceShift(base, dirX: q.dirX, dirY: q.dirY)
        let s = Rig.head.scale * k
        return (t.dx * s, t.dy * s, t.sx, t.sy)
    }

    /// The eyes. Open, half-closed and shut are one eye under a lid that slides down
    /// (`lidEye`), so a blink never turns the eye see-through. Happy eyes (closed arcs)
    /// come in over the shut lid: the lid closes first, then the arcs take over (and the
    /// other way round). Wide eyes are their own picture, cross-faded.
    private func eyes(_ f: RigFrame) -> some View {
        let lid = f.lid
        let happy = f.eyes.filter { $0.0 == .happy }.reduce(0.0) { $0 + $1.1 }
        let down = max(lid.down, min(1, happy / 0.75))
        let lidded = lid.weight + happy * (1 - Motion.smooth(0.7, 1, happy))
        let others = f.eyes.filter { !$0.0.isLidded }
        return ZStack(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                lidEye(left: true, down: down, f.pose)
                lidEye(left: false, down: down, f.pose)
            }
            .frame(width: Rig.canvas.width * k, height: Rig.canvas.height * k, alignment: .topLeading)
            .opacity(lidded)
            ForEach(Array(others.enumerated()), id: \.offset) { _, layer in
                ZStack(alignment: .topLeading) {
                    eye(layer.0, left: true, f.pose)
                    eye(layer.0, left: false, f.pose)
                }
                .frame(width: Rig.canvas.width * k, height: Rig.canvas.height * k, alignment: .topLeading)
                .opacity(layer.0 == .happy ? Motion.smooth(0.5, 1, happy) : layer.1)
            }
        }
        .frame(width: Rig.canvas.width * k, height: Rig.canvas.height * k, alignment: .topLeading)
    }

    /// Puts something the size of an eye picture (`name`, e.g. "eyes-open-l") where that
    /// eye sits on its patch, moving and squeezing with the head turn.
    private func onPatch<Content: View>(_ name: String, dropY: CGFloat, left: Bool, _ q: Pose,
                                        @ViewBuilder _ content: (CGFloat, CGFloat) -> Content) -> some View {
        let px = LanviArt.px(name)
        let centre = LanviArt.eyeCenter[name] ?? CGPoint(x: px.width / 2, y: px.height / 2)
        let s = Rig.eyeScale * Rig.head.scale * k
        let home = left ? Rig.eyeL : Rig.eyeR
        let base = CGPoint(x: home.x, y: home.y + dropY)
        // the eye rides its patch (so it never slides off the white), and squeezes with it
        let turn = faceShift(markingHome(left ? "face-patch-l" : "face-patch-r"), q)
        let placed = Rig.eyeOnPatch(left: left, dropY: dropY, pose: q).eye
        let c = Rig.headToCanvas(base)
        let hs = Rig.head.scale * k
        let w = px.width * s, h = px.height * s
        return content(w, h)
            .frame(width: w, height: h)
            .overlay { if debugBounds { Rectangle().stroke(.red, lineWidth: 1) } }
            .scaleEffect(x: 1 + (turn.sx - 1) * 0.8, y: 1 + (turn.sy - 1) * 0.8,
                         anchor: UnitPoint(x: centre.x / px.width, y: centre.y / px.height))
            .transformEffect(CGAffineTransform(translationX: (placed.x - base.x) * hs, y: (placed.y - base.y) * hs))
            .position(x: c.x * k + (px.width / 2 - centre.x) * s, y: c.y * k + (px.height / 2 - centre.y) * s)
    }

    /// A closed, happy or wide eye: its own picture.
    private func eye(_ shape: EyeShape, left: Bool, _ q: Pose) -> some View {
        let name = shape.name + (left ? "-l" : "-r")
        return onPatch(name, dropY: shape.dropY, left: left, q) { _, _ in
            Image("puppet-" + name).resizable().interpolation(.high)
        }
    }

    /// One eye under its lid. The open eye in layers: the white, the iris and glints
    /// (moving, clipped to the white so they never leave the eye) and the lid line (it
    /// lowers a hair when looking down). Over it the lid (the fur and lid line cut from
    /// the half-closed eye, clipped to the eye) slides down to half and then stretches to
    /// shut, and the shut eye's lashes come in at the end, over the fur. `down`: 0 open,
    /// 0.5 half, 1 shut.
    private func lidEye(left: Bool, down: Double, _ q: Pose) -> some View {
        let side = left ? "l" : "r"
        let openName = "eyes-open-" + side
        let pupil = Rig.pupil(left: left, pose: q)
        let s = Rig.eyeScale * Rig.head.scale * k
        let hs = Rig.head.scale * k
        let d = min(max(down, 0), 1)
        return onPatch(openName, dropY: EyeShape.open.dropY, left: left, q) { w, h in
            // where another eye picture's frame sits inside the open eye's (points)
            let frameOf: (EyeShape) -> CGRect = { shape in
                let name = shape.name + "-" + side
                let px = LanviArt.px(name)
                let c = LanviArt.eyeCenter[name] ?? CGPoint(x: px.width / 2, y: px.height / 2)
                let c0 = LanviArt.eyeCenter[openName] ?? CGPoint(x: w / s / 2, y: h / s / 2)
                return CGRect(x: (c0.x - c.x) * s, y: (c0.y - c.y) * s + (shape.dropY - EyeShape.open.dropY) * hs,
                              width: px.width * s, height: px.height * s)
            }
            let half = frameOf(.half), lashes = frameOf(.closed)
            let lidBox = LanviArt.layer["eye-halflid-" + side] ?? CGRect(x: 0, y: 0, width: 1, height: 0.5)
            let white = LanviArt.layer["eye-white-" + side] ?? CGRect(x: 0, y: 0, width: 1, height: 1)
            let lidTop = half.minY + lidBox.minY * half.height
            let lidH = lidBox.height * half.height
            // down to half: the lid slides in from above; past half: it stretches from the
            // top of the eye (and widens, so it fills the eye's round sides) until it
            // covers it to the bottom, already at 85 % (a quick blink is shut for only a
            // few frames, and a pupil looking down must never peek out under it)
            let slide = d < 0.5 ? -(1 - d / 0.5) * lidH : 0
            // (stretched just past the bottom, so its own lid line is clipped away under
            // the lashes)
            let full = max((white.maxY * h - lidTop) / lidH, 1) * 1.14
            let shut = min(max((d - 0.5) / 0.35, 0), 1)
            let stretch = 1 + shut * (full - 1)
            let widen = 1 + 0.2 * shut
            ZStack(alignment: .topLeading) {
                piece("eye-white-" + side, w, h)
                ZStack(alignment: .topLeading) {
                    piece("eye-iris-" + side, w, h)
                        .transformEffect(CGAffineTransform(translationX: pupil.x * s, y: pupil.y * s))
                    piece("eye-glint-" + side, w, h)
                        .transformEffect(CGAffineTransform(translationX: pupil.x * s * 0.25, y: pupil.y * s * 0.25))
                }
                .frame(width: w, height: h, alignment: .topLeading)
                .mask {
                    ZStack(alignment: .topLeading) { piece("eye-white-" + side, w, h) }
                        .frame(width: w, height: h, alignment: .topLeading)
                }
                piece("eye-lid-" + side, w, h)
                    .transformEffect(CGAffineTransform(translationX: 0, y: pupil.y * s * 0.12))
                if d > 0.001 {
                    ZStack(alignment: .topLeading) {
                        ZStack(alignment: .topLeading) { piece("eye-halflid-" + side, half.width, half.height) }
                            .frame(width: half.width, height: half.height, alignment: .topLeading)
                            .scaleEffect(x: widen, y: stretch, anchor: UnitPoint(x: lidBox.midX, y: lidBox.minY))
                            .transformEffect(CGAffineTransform(translationX: half.minX, y: half.minY + slide))
                    }
                    .frame(width: w, height: h, alignment: .topLeading)
                    .mask {
                        ZStack(alignment: .topLeading) { piece("eye-white-" + side, w, h) }
                            .frame(width: w, height: h, alignment: .topLeading)
                    }
                    Image("puppet-eyes-closed-" + side)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: lashes.width, height: lashes.height)
                        .opacity(Motion.smooth(0.75, 0.9, d))
                        .transformEffect(CGAffineTransform(translationX: lashes.minX, y: lashes.minY))
                }
            }
            .frame(width: w, height: h, alignment: .topLeading)
        }
    }

    /// A layer cut from an eye picture, placed in that picture's frame (`w` x `h` points).
    private func piece(_ name: String, _ w: CGFloat, _ h: CGFloat) -> some View {
        let r = LanviArt.layer[name] ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        return Image("puppet-" + name)
            .resizable()
            .interpolation(.high)
            .frame(width: r.width * w, height: r.height * h)
            .position(x: r.midX * w, y: r.midY * h)
    }

    private func mouth(_ f: RigFrame) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(f.mouths.enumerated()), id: \.offset) { _, layer in
                mouthPicture(layer.0, f.pose)
                    .frame(width: Rig.canvas.width * k, height: Rig.canvas.height * k, alignment: .topLeading)
                    .opacity(layer.1)
            }
        }
        .frame(width: Rig.canvas.width * k, height: Rig.canvas.height * k, alignment: .topLeading)
    }

    private func mouthPicture(_ m: MouthShape, _ q: Pose) -> some View {
        let px = LanviArt.px(m.name)
        let s = m.scale * Rig.head.scale * k
        let h = px.height * m.scale
        let top = CGPoint(x: Rig.mouthTop.x, y: Rig.mouthTop.y + m.dropY)
        let c = Rig.headToCanvas(CGPoint(x: top.x, y: top.y + h / 2))
        var turn = faceShift(CGPoint(x: top.x, y: top.y + h / 2), q)
        turn.dx *= 1.05; turn.dy *= 1.05
        let size = max(0.3, 1 + q.mouthScale)
        return Image("puppet-" + m.name)
            .resizable()
            .interpolation(.high)
            .frame(width: px.width * s, height: px.height * s)
            .scaleEffect(x: size * (1 + (turn.sx - 1) * 0.8), y: size * (1 + (turn.sy - 1) * 0.8), anchor: .top)
            .transformEffect(CGAffineTransform(translationX: turn.dx, y: turn.dy))
            .position(x: c.x * k, y: c.y * k)
    }
}
