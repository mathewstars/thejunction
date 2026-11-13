import SwiftUI

/// The poses we have art for. Image names match the asset catalog.
enum LanviPose: String, CaseIterable {
    case cheer, curious, meh, run, love, surprised, grumpy, peek

    var imageName: String { "lanvi-\(rawValue)" }
}

private struct Bounce {
    var sx: CGFloat = 1
    var sy: CGFloat = 1
    var y: CGFloat = 0
}

/// Lanvi with always-on idle motion and Duolingo-style reactions.
///
/// Idle: slow breathing (squash and stretch from the feet) and a gentle sway.
/// Reaction: change `bounceTrigger` (or the pose) and Lanvi does a little jump:
/// anticipation squash, stretch up, land squash, springy settle.
struct LanviView: View {
    var pose: LanviPose
    var size: CGFloat = 220
    var bounceTrigger: Int = 0

    @State private var poseBounce = 0

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let breathe = sin(t * 2 * .pi / 3.2)
            let sway = sin(t * 2 * .pi / 5.0)

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
                            .offset(y: v.y)
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
