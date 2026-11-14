import SwiftUI

// MARK: - How to use Lanvi (read this first)
//
//   LanviView(pose: .curious, size: 200, bounceTrigger: bounce)   // same as always
//       .lanviMood(.sleepy)                       // held while set (nil = from the pose)
//       .lanviReaction(.proud, trigger: xp)       // plays once each time `xp` changes
//       .lanviLookAt(UnitPoint(x: 0.9, y: -0.3))  // eyes, then head, turn to a point
//       .lanviTalking(isSpeaking)                 // mouth and head talk while true
//       .lanviMouth(.o)                           // or drive the mouth shape yourself
//
// - The fox is a paper puppet with depth: tail, body, paws, head, ears, eyes and mouth
//   are separate pictures. When the head turns, the painted face slides around it in
//   space (the near ear comes forward, the far ear tucks back), the chest swells with
//   each breath, and the tail and ears bend along their length with follow-through.
// - At rest: a slow breath (4.5 s), a slow tail drift, soft blinks (sometimes slow or
//   double), and every 6 to 12 s one small performed moment (`LanviMoment`): a glance
//   to the side or up, a curious tilt, ear flicks, a tail curl, a sniff, a contented
//   slow blink, a look down at the button and back up at you; yawns in the evening.
//   Never two at once, never the same twice in a row. Nothing to call.
// - The big fox greets you when it appears (ears up, bright eyes, a little bounce).
// - Moods (`LanviMood`), held with `.lanviMood` or played once with `.lanviReaction`:
//     happy      a joyful hop: big breath, head leads, ears flop, tail wags, wiggle
//     proud      after XP: chest out, chin up, happy eyes, tail high
//     okay       for "Not today": soft eyes, a small nod. Never sad.
//     greeting   hello: ears up, bright eyes, a small bounce, a happy look
//     listening  while the person types: head tilted, ears forward, eyes down, nods
//     thinking   while waiting for a reply: eyes up to the side, a slow tail swish
//     curious    head tilt, eyes look up
//     surprised  a jolt: ears shoot up, wide eyes, small "o", tail puffs
//     sleepy     a yawn, then droopy eyes (held: half-closed eyes, slow breath)
//   Reactions play on top of the idle, which never stops, and return exactly to rest.
// - `.lanviLookAt` takes a point in the fox's own square (0,0 top-left, 1,1 bottom-
//   right; it can be outside, e.g. y: -0.4 is above his head). nil = straight ahead.
// - The fox ignores the screen's withAnimation/.animation for its own parts (its clock
//   is their only driver), so a spring on the screen never makes it stutter.
// - Layout: the square is centred on the fox's head and body; the tail hangs out
//   past the left edge, so centre the view and the fox looks centred.
// - Tapping the fox: eyes jump to the finger, head turns and tilts toward it, happy
//   squint, ear flick, a small hop. Works next to the screen's own `.onTapGesture`.
// - Poses: curious, cheer, love and surprised are the puppet (cheer = happy face and
//   a happy reaction, love = soft happy eyes, surprised = surprised face). Changing
//   the pose or `bounceTrigger` makes it hop. run, peek, grumpy and meh are still the
//   old single pictures.
// - Reduce Motion: only blinks and face changes, no movement.
// - Debug: `-puppetLog YES` writes every frame's part transforms to tmp/puppet-frames.csv;
//   `-screen puppet` has a button for every moment and reaction; `-screen puppet -plain
//   YES` shows the fox alone on flat green for measuring.
// - The fox fire: `LanviView.puppetTailTip(foxSize:)` is the tail tip's offset from
//   the centre of the fox's square, like `HomeTailGlow.tailOffset`.

/// The poses we have art for. Image names match the asset catalog.
enum LanviPose: String, CaseIterable {
    case cheer, curious, meh, run, love, surprised, grumpy, peek

    var imageName: String { "lanvi-\(rawValue)" }

    /// Drawn as the paper puppet (the others are still single pictures).
    var isPuppet: Bool {
        switch self {
        case .curious, .cheer, .love, .surprised: return true
        default: return false
        }
    }

    /// The mood the puppet holds for this pose when no `.lanviMood` is set.
    var puppetMood: LanviMood {
        switch self {
        case .cheer: return .happy
        case .surprised: return .surprised
        default: return .calm
        }
    }
}

/// Lanvi. See the note at the top of this file.
struct LanviView: View {
    var pose: LanviPose
    var size: CGFloat = 220
    var bounceTrigger: Int = 0

    var body: some View {
        ZStack {
            if pose.isPuppet {
                LanviPuppet(pose: pose, size: size, bounceTrigger: bounceTrigger)
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.82, anchor: .bottom).combined(with: .opacity),
                        removal: .opacity.animation(.easeOut(duration: 0.1))))
            } else {
                LanviPicture(pose: pose, size: size, bounceTrigger: bounceTrigger)
                    .transition(.opacity.animation(.easeOut(duration: 0.1)))
            }
        }
        .frame(width: size, height: size)
    }

    /// Where the puppet's tail tip is at rest, from the centre of the fox's square.
    static func puppetTailTip(foxSize s: CGFloat) -> CGPoint {
        let k = s / Rig.canvas.height
        let x0 = s / 2 - (Rig.centerX - Rig.frame.minX) * k
        let tip = Rig.tailTip
        return CGPoint(x: x0 + tip.x * k - s / 2, y: tip.y * k - s / 2)
    }
}

// MARK: - Moods, reactions and looking, passed down to the fox

struct LanviReactionRequest: Equatable {
    var mood: LanviMood
    var token: AnyHashable
    /// Only a new trigger value plays the reaction again.
    static func == (a: Self, b: Self) -> Bool { a.token == b.token }
}

/// For proof stills only: hold a reaction (or a blink) at a fixed moment.
struct LanviDebugFreeze: Equatable {
    var reaction: LanviMood?
    var at: Double
    var blink: Double?
    var moment: LanviMoment? = nil
    /// Hold the eyes and head on a point (head-turn stills).
    var look: UnitPoint? = nil
}

private struct MoodKey: EnvironmentKey { static let defaultValue: LanviMood? = nil }
private struct ReactionKey: EnvironmentKey { static let defaultValue: LanviReactionRequest? = nil }
private struct LookKey: EnvironmentKey { static let defaultValue: UnitPoint? = nil }
private struct MouthKey: EnvironmentKey { static let defaultValue: MouthShape? = nil }
private struct FreezeKey: EnvironmentKey { static let defaultValue: LanviDebugFreeze? = nil }

extension EnvironmentValues {
    var lanviMood: LanviMood? {
        get { self[MoodKey.self] }
        set { self[MoodKey.self] = newValue }
    }
    var lanviReactionRequest: LanviReactionRequest? {
        get { self[ReactionKey.self] }
        set { self[ReactionKey.self] = newValue }
    }
    var lanviMouth: MouthShape? {
        get { self[MouthKey.self] }
        set { self[MouthKey.self] = newValue }
    }
    var lanviLook: UnitPoint? {
        get { self[LookKey.self] }
        set { self[LookKey.self] = newValue }
    }
    var lanviDebugFreeze: LanviDebugFreeze? {
        get { self[FreezeKey.self] }
        set { self[FreezeKey.self] = newValue }
    }
}

extension View {
    /// Hold a mood on every Lanvi inside this view (nil = the pose decides).
    func lanviMood(_ mood: LanviMood?) -> some View {
        environment(\.lanviMood, mood)
    }

    /// Play `mood` once each time `trigger` changes. The idle keeps going underneath.
    func lanviReaction<T: Hashable>(_ mood: LanviMood, trigger: T) -> some View {
        environment(\.lanviReactionRequest, LanviReactionRequest(mood: mood, token: AnyHashable(trigger)))
    }

    /// Show one of the existing mouth shapes while set (talking); nil = the puppet decides.
    func lanviMouth(_ mouth: MouthShape?) -> some View {
        environment(\.lanviMouth, mouth)
    }

    /// Make Lanvi look at a point in his own square (can be outside 0...1). nil = ahead.
    func lanviLookAt(_ point: UnitPoint?) -> some View {
        environment(\.lanviLook, point)
    }
}

// MARK: - Talking and idle moments

struct LanviMomentRequest: Equatable {
    var moment: LanviMoment
    var token: AnyHashable
    static func == (a: Self, b: Self) -> Bool { a.token == b.token }
}

private struct TalkingKey: EnvironmentKey { static let defaultValue = false }
private struct MomentKey: EnvironmentKey { static let defaultValue: LanviMomentRequest? = nil }

extension EnvironmentValues {
    var lanviTalking: Bool {
        get { self[TalkingKey.self] }
        set { self[TalkingKey.self] = newValue }
    }
    var lanviMomentRequest: LanviMomentRequest? {
        get { self[MomentKey.self] }
        set { self[MomentKey.self] = newValue }
    }
}

extension View {
    /// While true, Lanvi talks: the mouth opens and closes in syllables with small head
    /// bobs on the words. Set it while a speech bubble's words arrive.
    func lanviTalking(_ talking: Bool) -> some View {
        environment(\.lanviTalking, talking)
    }

    /// Play one idle moment now (each time `trigger` changes), instead of waiting for
    /// the next one. The idle plays them by itself every 6 to 12 seconds.
    func lanviMoment<T: Hashable>(_ moment: LanviMoment, trigger: T) -> some View {
        environment(\.lanviMomentRequest, LanviMomentRequest(moment: moment, token: AnyHashable(trigger)))
    }
}

// MARK: - The old single-picture fox (run, peek, grumpy, meh)

private struct Bounce {
    var sx: CGFloat = 1
    var sy: CGFloat = 1
    var y: CGFloat = 0
}

/// One picture, breathing and swaying as a whole, with a squash-and-stretch jump.
private struct LanviPicture: View {
    var pose: LanviPose
    var size: CGFloat
    var bounceTrigger: Int

    @State private var poseBounce = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let breathe = reduceMotion ? 0 : sin(t * 2 * .pi / 3.2)
            let sway = reduceMotion ? 0 : sin(t * 2 * .pi / 5.0)

            ZStack(alignment: .bottom) {
                Ellipse()
                    .fill(Theme.ink.opacity(0.10))
                    .frame(width: size * 0.5, height: size * 0.06)
                    .scaleEffect(x: 1 + 0.03 * breathe)
                    .offset(y: size * 0.02)

                Image(pose.imageName)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(maxWidth: size, maxHeight: size)
                    .frame(width: size, height: size, alignment: .bottom)
                    .id(pose)
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.82, anchor: .bottom).combined(with: .opacity),
                        removal: .opacity.animation(.easeOut(duration: 0.1))))
                    .scaleEffect(x: 1 - 0.012 * breathe, y: 1 + 0.024 * breathe, anchor: .bottom)
                    .rotationEffect(.degrees(1.2 * sway), anchor: .bottom)
                    .keyframeAnimator(initialValue: Bounce(), trigger: bounceTrigger &+ poseBounce) { content, v in
                        content
                            .scaleEffect(x: v.sx, y: v.sy, anchor: .bottom)
                            .offset(y: reduceMotion ? 0 : v.y)
                    } keyframes: { _ in
                        KeyframeTrack(\.sy) {
                            CubicKeyframe(0.86, duration: 0.09)
                            SpringKeyframe(1.10, duration: 0.18, spring: .snappy)
                            CubicKeyframe(0.92, duration: 0.12)
                            SpringKeyframe(1.0, duration: 0.4, spring: .bouncy)
                        }
                        KeyframeTrack(\.sx) {
                            CubicKeyframe(1.12, duration: 0.09)
                            SpringKeyframe(0.93, duration: 0.18, spring: .snappy)
                            CubicKeyframe(1.08, duration: 0.12)
                            SpringKeyframe(1.0, duration: 0.4, spring: .bouncy)
                        }
                        KeyframeTrack(\.y) {
                            CubicKeyframe(0, duration: 0.09)
                            SpringKeyframe(-size * 0.16, duration: 0.18, spring: .snappy)
                            CubicKeyframe(0, duration: 0.12)
                            SpringKeyframe(0, duration: 0.4, spring: .bouncy)
                        }
                    }
            }
            .frame(width: size, height: size)
        }
        .onChange(of: pose) { poseBounce &+= 1 }
    }
}
