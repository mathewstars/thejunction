import SwiftUI

/// The paper-puppet fox: separate parts (tail, body, paws, head, ears, eyes, mouth),
/// each moving on its own from one `TimelineView` clock. Use it through `LanviView`.
struct LanviPuppet: View {
    var pose: LanviPose
    var size: CGFloat
    var bounceTrigger: Int

    @Environment(\.lanviMood) private var moodOverride
    @Environment(\.lanviReactionRequest) private var reactionRequest
    @Environment(\.lanviLook) private var lookUnit
    @Environment(\.lanviDebugFreeze) private var freeze
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var seed = Int.random(in: 0..<100_000)
    @State private var heldFrom: LanviMood = .calm
    @State private var heldSince: Double = -100
    @State private var reaction: LanviMood?
    @State private var reactionAt: Double = -100
    @State private var hopAt: Double = -100
    @State private var tapAt: Double = -100
    @State private var tapSide: Double = 1
    @State private var tapLook: CGPoint?
    @State private var lookFrom: CGPoint?
    @State private var lookTo: CGPoint?
    @State private var lookAt: Double = -100

    private var k: CGFloat { size / Rig.canvas.height }
    private var held: LanviMood { moodOverride ?? pose.puppetMood }
    private var canvasOrigin: CGPoint {
        CGPoint(x: (size - Rig.canvas.width * k) / 2, y: size - Rig.canvas.height * k)
    }

    var body: some View {
        TimelineView(.animation) { context in
            let f = motion(at: context.date.timeIntervalSinceReferenceDate).frame()
            ZStack(alignment: .bottom) {
                shadow(f)
                rig(f)
                    .frame(width: Rig.canvas.width * k, height: Rig.canvas.height * k)
                    .offset(x: f.rootX * k, y: f.rootY * k)
            }
            .frame(width: size, height: size, alignment: .bottom)
        }
        .contentShape(Rectangle())
        .simultaneousGesture(SpatialTapGesture().onEnded { tapped(at: $0.location) })
        .onChange(of: bounceTrigger) { hopAt = now }
        .onChange(of: pose) { _, new in
            hopAt = now
            switch new {
            case .cheer: play(.happy)
            case .surprised: play(.surprised)
            default: break
            }
        }
        .onChange(of: held) { old, _ in heldFrom = old; heldSince = now }
        .onChange(of: reactionRequest) { _, new in if let new { play(new.mood) } }
        .onChange(of: lookUnit) { _, new in
            guard tapLook == nil else { return }
            setLook(new.map(canvasPoint(unit:)))
        }
        .onAppear { if let lookUnit { lookTo = canvasPoint(unit: lookUnit) } }
        .accessibilityElement()
        .accessibilityLabel("Lanvi the fox")
    }

    // MARK: Building one frame

    private var now: Double { Date().timeIntervalSinceReferenceDate }

    private func motion(at clock: Double) -> LanviMotion {
        var m = LanviMotion(t: clock, seed: seed, held: held, heldFrom: heldFrom, heldSince: heldSince,
                            reaction: reaction, reactionAt: reactionAt, hopAt: hopAt, tapAt: tapAt,
                            tapSide: tapSide, look: tapLook ?? lookTo, lookFrom: lookFrom, lookAt: lookAt,
                            reduceMotion: reduceMotion)
        m.loving = moodOverride == nil && pose == .love
        if let freeze {
            // Proof stills: a fixed clock, a reaction held at a chosen moment.
            m.t = 1012.1 + freeze.at
            m.seed = 0
            m.reaction = freeze.reaction
            m.reactionAt = freeze.reaction == nil ? -100 : 1012.1
            m.freezeBlink = freeze.blink ?? -1
            m.heldSince = -100
            m.heldFrom = m.held
        }
        return m
    }

    private func play(_ mood: LanviMood) {
        reaction = mood
        reactionAt = now
    }

    private func canvasPoint(unit u: UnitPoint) -> CGPoint {
        CGPoint(x: (u.x * size - canvasOrigin.x) / k, y: (u.y * size - canvasOrigin.y) / k)
    }

    private func setLook(_ p: CGPoint?) {
        lookFrom = tapLook ?? lookTo
        lookTo = p
        lookAt = now
    }

    private func tapped(at location: CGPoint) {
        let p = CGPoint(x: (location.x - canvasOrigin.x) / k, y: (location.y - canvasOrigin.y) / k)
        tapSide = p.x < LanviMotion.eyesCenter.x ? -1 : 1
        lookFrom = tapLook ?? lookTo
        tapLook = p
        lookAt = now
        tapAt = now
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.3))
            guard now - tapAt >= 1.25 else { return }
            lookFrom = tapLook
            tapLook = nil
            lookTo = lookUnit.map(canvasPoint(unit:))
            lookAt = now
        }
    }

    // MARK: Drawing

    private func shadow(_ f: RigFrame) -> some View {
        let lift = max(-f.rootY, 0) / 140
        return Ellipse()
            .fill(Theme.ink.opacity(0.13 * (1 - 0.5 * lift)))
            .frame(width: size * 0.5 * (1 - 0.25 * lift) * f.bodySX, height: size * 0.06)
            .offset(y: size * 0.02)
    }

    private func rig(_ f: RigFrame) -> some View {
        ZStack(alignment: .topLeading) {
            tail(f)
            part(Rig.body, sx: f.bodySX, sy: f.bodySY)
            headGroup(f)
            part(Rig.pawL, rotate: -f.pawL, dy: f.pawLY + (f.bodySY - 1) * 40)
            part(Rig.pawR, rotate: f.pawR, dy: f.pawRY + (f.bodySY - 1) * 40)
        }
    }

    private func part(_ p: Rig.Part, rotate: Double = 0, sx: CGFloat = 1, sy: CGFloat = 1,
                      dx: CGFloat = 0, dy: CGFloat = 0) -> some View {
        Image(p.image)
            .resizable()
            .interpolation(.high)
            .frame(width: p.size.width * k, height: p.size.height * k)
            .scaleEffect(x: sx, y: sy, anchor: p.pivot)
            .rotationEffect(.degrees(rotate), anchor: p.pivot)
            .position(x: (p.center.x + dx) * k, y: (p.center.y + dy) * k)
    }

    /// The tail turns at its hidden base; the tip turns again around the tail's middle
    /// a beat later, so the tip trails behind (one picture, so no seam can open).
    private func tail(_ f: RigFrame) -> some View {
        let p = Rig.tail
        return Image(p.image)
            .resizable()
            .interpolation(.high)
            .frame(width: p.size.width * k, height: p.size.height * k)
            .scaleEffect(x: -1, y: 1)
            .rotationEffect(.degrees(f.tailTip), anchor: Rig.tailMid)
            .rotationEffect(.degrees(f.tail), anchor: p.pivot)
            .position(x: p.center.x * k, y: p.center.y * k)
    }

    /// Ears, head, eyes and mouth turn together around the neck.
    private func headGroup(_ f: RigFrame) -> some View {
        let neck = UnitPoint(x: Rig.neck.x / Rig.canvas.width, y: Rig.neck.y / Rig.canvas.height)
        return ZStack(alignment: .topLeading) {
            part(Rig.earL, rotate: -f.earL, sy: f.earLStretch)
            part(Rig.earR, rotate: f.earR, sy: f.earRStretch)
            part(Rig.head)
            eye(f, left: true)
            eye(f, left: false)
            mouth(f)
        }
        .frame(width: Rig.canvas.width * k, height: Rig.canvas.height * k)
        .rotationEffect(.degrees(f.headTilt), anchor: neck)
        .offset(x: f.headDX * k, y: f.headDY * k)
    }

    private func eye(_ f: RigFrame, left: Bool) -> some View {
        let shape = f.eyes
        let img = shape.image(left: left)
        let s = Rig.eyeScale * Rig.head.scale * k
        let base = left ? Rig.eyeL : Rig.eyeR
        let c = Rig.headToCanvas(CGPoint(x: base.x + f.eyeDX, y: base.y + shape.dropY + f.eyeDY))
        return Image(img.name)
            .resizable()
            .interpolation(.high)
            .frame(width: shape.px.width * s, height: shape.px.height * s)
            .scaleEffect(x: img.flipX ? -1 : 1, y: img.flipY ? -1 : 1)
            .scaleEffect(x: 1, y: f.eyeOpen, anchor: UnitPoint(x: 0.5, y: 0.62))
            .position(x: c.x * k, y: c.y * k)
    }

    private func mouth(_ f: RigFrame) -> some View {
        let m = f.mouth
        let s = m.scale * Rig.head.scale * k
        let h = m.px.height * m.scale
        let c = Rig.headToCanvas(CGPoint(x: Rig.mouthTop.x, y: Rig.mouthTop.y + m.dropY + h / 2))
        return Image(m.image)
            .resizable()
            .interpolation(.high)
            .frame(width: m.px.width * s, height: m.px.height * s)
            .scaleEffect(f.mouthScale, anchor: .top)
            .position(x: c.x * k, y: c.y * k)
    }
}
