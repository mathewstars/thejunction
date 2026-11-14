import SwiftUI

/// Lanvi as video clips, in exactly the puppet's place: the same square, ears at the
/// top edge, paws on the bottom edge, head and body on the centre line, the same soft
/// contact shadow. Takes the same inputs as the puppet (`.lanviMood`,
/// `.lanviReaction`, `.lanviLookAt`, `.lanviMouth`, `bounceTrigger`, taps), so no
/// screen changes. Use it through `LanviView` (with `-foxClips YES`).
///
/// - Idle plays the idle clip with a look, a nod or a listen between (a yawn in the
///   evening), picked as each clip starts, so it never loops on a 5-second beat.
/// - A reaction plays after the current clip, or cross-fades in at once while the fox
///   is idling. A tap always cross-fades in: `pet` on the head, `giggle` elsewhere,
///   or `look` when that would repeat the last tap.
/// - `bounceTrigger` never hops: it picks a fitting reaction, never the same twice.
/// - Muted, paused in the background; with Reduce Motion it shows the rest picture.
struct LanviClipView: View {
    var pose: LanviPose
    var size: CGFloat
    var bounceTrigger: Int

    @Environment(\.lanviMood) private var moodOverride
    @Environment(\.lanviReactionRequest) private var reactionRequest
    @Environment(\.lanviLook) private var look
    @Environment(\.lanviMouth) private var mouth
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.foxClipRequest) private var testRequest

    @StateObject private var director = FoxClipDirector()
    @State private var lastTap: FoxClip?
    @State private var lastBounce: FoxClip?
    /// When the last reaction was asked for: a screen often fires a reaction, a pose
    /// change and a bounce together; only the first of those plays.
    @State private var reactedAt = Date.distantPast

    /// The clip frame, in points, placed so the rest fox fills the view's square.
    private var side: CGFloat { size / (FoxClipArt.feet - FoxClipArt.earTop) }
    private var origin: CGPoint {
        CGPoint(x: size / 2 - FoxClipArt.centerX * side, y: -FoxClipArt.earTop * side)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Ellipse()
                .fill(Theme.ink.opacity(0.13))
                .frame(width: size * 0.56, height: size * 0.06)
                .offset(y: size * 0.02)

            ZStack(alignment: .topLeading) {
                Image("fox-clip-rest")
                    .resizable()
                    .interpolation(.high)
                    .frame(width: side, height: side)
                    .opacity(reduceMotion || !director.showing ? 1 : 0)
                if !reduceMotion {
                    FoxClipLayers(director: director)
                        .frame(width: side, height: side)
                }
            }
            .frame(width: side, height: side)
            .offset(x: origin.x + side / 2 - size / 2, y: origin.y + side / 2 - size / 2)
            .frame(width: size, height: size)
        }
        .frame(width: size, height: size)
        .transaction { $0.animation = nil }
        .contentShape(Rectangle())
        .simultaneousGesture(SpatialTapGesture().onEnded { tapped(at: $0.location) })
        .onAppear {
            director.held = held
            if !reduceMotion { director.start() }
        }
        .onDisappear { director.stop() }
        #if DEBUG
        .task {
            // `-clipsTaps YES` (recordings): a tap on the head at 7 s, on the body at 11 s.
            guard UserDefaults.standard.bool(forKey: "clipsTaps") else { return }
            try? await Task.sleep(for: .seconds(7))
            tapped(at: CGPoint(x: size * 0.5, y: size * 0.25))
            try? await Task.sleep(for: .seconds(4))
            tapped(at: CGPoint(x: size * 0.5, y: size * 0.85))
        }
        #endif
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { if !reduceMotion { director.resume() } } else { director.pause() }
        }
        .onChange(of: reduceMotion) { _, on in on ? director.stop() : director.start() }
        .onChange(of: held) { old, new in
            director.held = new
            if new == .talking, old != .talking { react(.talk) }
        }
        .onChange(of: reactionRequest) { _, new in
            if let new, let clip = FoxClip.forReaction(new.mood) { react(clip) }
        }
        .onChange(of: pose) { _, new in
            switch new {
            case .cheer: react(.happy)
            case .surprised: react(.giggle)
            default: break
            }
        }
        .onChange(of: bounceTrigger) { bounced() }
        .onChange(of: look) { _, new in if new != nil { react(.look) } }
        .onChange(of: testRequest) { _, new in if let new { director.request(new.clip, urgent: true) } }
        .accessibilityElement()
        .accessibilityLabel("Lanvi the fox")
    }

    private var held: FoxClipDirector.Held {
        if mouth != nil { return .talking }
        switch (moodOverride ?? pose.puppetMood).rawValue {
        case "sleepy": return .sleepy
        case "listening": return .listening
        default: return .calm
        }
    }

    /// A reaction: cross-faded in at once while idling (the idle sits close to the rest
    /// pose, so the fade is invisible), otherwise right after the current clip.
    private func react(_ clip: FoxClip) {
        guard Date().timeIntervalSince(reactedAt) > 0.4 else { return }
        reactedAt = Date()
        director.request(clip, urgent: director.current == .idle)
    }

    /// `bounceTrigger` used to make the puppet hop. Now: a fitting reaction, varied.
    private func bounced() {
        guard Date().timeIntervalSince(reactedAt) > 0.4 else { return }
        reactedAt = Date()
        var options: [FoxClip] = pose == .cheer ? [.happy, .giggle] : [.happy, .giggle, .nod, .look]
        options = options.filter { $0.resolved != lastBounce?.resolved }
        let clip = options.randomElement() ?? .happy
        lastBounce = clip
        director.request(clip, urgent: true)
    }

    /// The head (top half, between the ears) gets a pet, anywhere else a giggle; a tap
    /// that would repeat the last tap's clip gets a look instead (never twice running).
    private func tapped(at p: CGPoint) {
        guard !reduceMotion else { return }
        let onHead = p.y < size * 0.55 && abs(p.x - size / 2) < size * 0.36
        var clip: FoxClip = onHead ? .pet : .giggle
        if clip.resolved == lastTap?.resolved { clip = .look }
        lastTap = clip
        director.request(clip, urgent: true)
    }
}

/// The director's two player layers, as a SwiftUI view.
private struct FoxClipLayers: UIViewRepresentable {
    let director: FoxClipDirector
    func makeUIView(context: Context) -> FoxClipLayersView { director.view }
    func updateUIView(_ view: FoxClipLayersView, context: Context) {}
}
