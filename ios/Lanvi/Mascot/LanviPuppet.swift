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

    /// Points per canvas unit (master pixel), and per motion unit.
    private var k: CGFloat { size / Rig.canvas.height }
    private var mu: CGFloat { k * Rig.unit }
    private var held: LanviMood { moodOverride ?? pose.puppetMood }
    /// Between the hind feet, where the fox stands (0...1 of the canvas).
    private static let feet = UnitPoint(x: (Rig.body.center.x - Rig.frame.minX) / Rig.canvas.width, y: 0.995)

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
                    .scaleEffect(x: f.rootSX, y: f.rootSY, anchor: Self.feet)
                    .offset(x: f.rootX * mu, y: f.rootY * mu)
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
            .frame(width: size * 0.56 * (1 - 0.25 * lift) * f.bodySX, height: size * 0.06)
            .offset(x: size * 0.08, y: size * 0.02)
    }

    private func rig(_ f: RigFrame) -> some View {
        ZStack(alignment: .topLeading) {
            tail(f)
            headTurn(f) {
                part(Rig.earL, rotate: -f.earL, sy: f.earLStretch)
                part(Rig.earR, rotate: f.earR, sy: f.earRStretch)
            }
            part(Rig.body, sx: f.bodySX, sy: f.bodySY)
            leg(Rig.legL, rotate: f.pawL, dx: f.pawLX, dy: f.pawLY, bodySY: f.bodySY)
            leg(Rig.legR, rotate: -f.pawR, dx: f.pawRX, dy: f.pawRY, bodySY: f.bodySY)
            headTurn(f) {
                head()
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

    private func part(_ p: Rig.Part, rotate: Double = 0, sx: CGFloat = 1, sy: CGFloat = 1) -> some View {
        image(p)
            .scaleEffect(x: sx, y: sy, anchor: p.pivot)
            .rotationEffect(.degrees(rotate), anchor: p.pivot)
            .position(x: p.local.x * k, y: p.local.y * k)
    }

    /// A front leg: its top fades into the chest fur so it grows out of the body.
    private func leg(_ p: Rig.Part, rotate: Double, dx: CGFloat, dy: CGFloat, bodySY: CGFloat) -> some View {
        image(p)
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0),
                                         .init(color: .black, location: Rig.legFade)],
                                 startPoint: .top, endPoint: .bottom))
            .rotationEffect(.degrees(rotate), anchor: p.pivot)
            .position(x: p.local.x * k + dx * mu, y: p.local.y * k + dy * mu + (bodySY - 1) * 30 * mu)
    }

    /// The tail turns at its hidden base; the tip turns again around the tail's middle
    /// a beat later, so the tip trails behind (one picture, so no seam can open).
    private func tail(_ f: RigFrame) -> some View {
        let p = Rig.tail
        return image(p)
            .rotationEffect(.degrees(-f.tailTip), anchor: Rig.tailMid)
            .rotationEffect(.degrees(-f.tail), anchor: p.pivot)
            .position(x: p.local.x * k, y: p.local.y * k)
    }

    /// Everything that turns with the head (the ears behind the body, and the head,
    /// eyes and mouth in front) gets the same tilt around the neck and the same shift.
    private func headTurn<Content: View>(_ f: RigFrame, @ViewBuilder _ content: () -> Content) -> some View {
        let neck = UnitPoint(x: Rig.neck.x / Rig.canvas.width, y: Rig.neck.y / Rig.canvas.height)
        return ZStack(alignment: .topLeading) { content() }
            .frame(width: Rig.canvas.width * k, height: Rig.canvas.height * k, alignment: .topLeading)
            .rotationEffect(.degrees(f.headTilt), anchor: neck)
            .offset(x: f.headDX * mu, y: f.headDY * mu)
    }

    /// The head, with its neck stub fading out under the chin.
    private func head() -> some View {
        let p = Rig.head
        return image(p)
            .mask(LinearGradient(stops: [.init(color: .black, location: 0),
                                         .init(color: .black, location: Rig.neckFade.from),
                                         .init(color: .clear, location: Rig.neckFade.to)],
                                 startPoint: .top, endPoint: .bottom))
            .position(x: p.local.x * k, y: p.local.y * k)
    }

    /// One eye-pair image, drawn as two halves so each eye sits on its own patch.
    private func eyes(_ f: RigFrame) -> some View {
        let shape = f.eyes
        let px = LanviArt.px(shape.name)
        let split = LanviArt.eyeSplit[shape.name] ?? (px.width / 2, CGPoint(x: px.width / 4, y: px.height / 2),
                                                      CGPoint(x: px.width * 3 / 4, y: px.height / 2))
        let s = Rig.eyeScale * Rig.head.scale * k
        let shift = CGPoint(x: f.eyeDX, y: shape.dropY + f.eyeDY)
        let l = Rig.headToCanvas(CGPoint(x: Rig.eyeL.x + shift.x, y: Rig.eyeL.y + shift.y))
        let r = Rig.headToCanvas(CGPoint(x: Rig.eyeR.x + shift.x, y: Rig.eyeR.y + shift.y))
        let full = Image("puppet-" + shape.name)
            .resizable()
            .interpolation(.high)
            .frame(width: px.width * s, height: px.height * s)
        return ZStack(alignment: .topLeading) {
            full
                .frame(width: split.split * s, height: px.height * s, alignment: .leading)
                .clipped()
                .position(x: l.x * k + (split.split / 2 - split.left.x) * s,
                          y: l.y * k + (px.height / 2 - split.left.y) * s)
            full
                .frame(width: (px.width - split.split) * s, height: px.height * s, alignment: .trailing)
                .clipped()
                .position(x: r.x * k + ((split.split + px.width) / 2 - split.right.x) * s,
                          y: r.y * k + (px.height / 2 - split.right.y) * s)
        }
    }

    private func mouth(_ f: RigFrame) -> some View {
        let m = f.mouth
        let px = LanviArt.px(m.name)
        let s = m.scale * Rig.head.scale * k
        let h = px.height * m.scale
        let c = Rig.headToCanvas(CGPoint(x: Rig.mouthTop.x, y: Rig.mouthTop.y + m.dropY + h / 2))
        return Image("puppet-" + m.name)
            .resizable()
            .interpolation(.high)
            .frame(width: px.width * s, height: px.height * s)
            .scaleEffect(f.mouthScale, anchor: .top)
            .position(x: c.x * k, y: c.y * k)
    }
}
