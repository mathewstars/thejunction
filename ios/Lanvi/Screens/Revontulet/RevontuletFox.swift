import SwiftUI
import UIKit

/// The fox on the snow, acting through `LanviView` as it is (never drawn, tinted or lit
/// here). The puppet is the only fox.
struct RevontuletFox: View, Equatable {
    enum Act: Equatable { case playing, celebrating, sleeping }

    var act: Act
    var size: CGFloat
    var reaction: LanviMood
    var reactionTick: Int
    var look: UnitPoint?
    var yawnTick: Int
    var petTick: Int
    /// Held while a stroke asks for it (the third stroke: eyes closed happily).
    var petMood: LanviMood? = nil
    /// A moment of real joy (both embers lit): the fox may hop.
    var joy = false

    var body: some View {
        // One puppet plays every act, so the fox never jumps between them.
        puppet
    }

    /// One puppet for every act (so it never jumps between them): the act only changes
    /// what it is told.
    private var puppet: some View {
        LanviView(pose: .curious, size: size)
            .lanviHops(act == .celebrating || joy)
            .lanviReaction(reaction, trigger: reactionTick)
            // Asleep: it yawns (the moment below), then its eyes close and stay closed (the
            // closed crescent eyes `.okay` holds), breathing on. A true sleeping face would
            // need a held closed-eyes mood from Mascot/ (asked in for-main.md).
            .lanviMood(act == .sleeping ? .okay : petMood)
            .lanviMoment(.yawn, trigger: yawnTick)
            .lanviLookAt(act == .sleeping ? nil : look)
            .lanviTouch(.head, hold: 1.5, trigger: petTick)
    }
}

/// A clear layer that hands every touch to the game with UIKit's own timestamp (the same
/// clock as `CACurrentMediaTime()`), every coalesced sample, and `majorRadius`.
struct RevontuletTouchSurface: UIViewRepresentable {
    var onTouch: (RevontuletInput, Double) -> Void

    func makeUIView(context: Context) -> TouchView {
        let v = TouchView()
        v.backgroundColor = .clear
        v.isMultipleTouchEnabled = false
        v.onTouch = onTouch
        return v
    }

    func updateUIView(_ v: TouchView, context: Context) {
        v.onTouch = onTouch
    }

    final class TouchView: UIView {
        var onTouch: ((RevontuletInput, Double) -> Void)?
        private weak var tracked: UITouch?

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard tracked == nil, let t = touches.first else { return }
            tracked = t
            onTouch?(.down(t.location(in: self), radius: t.majorRadius), t.timestamp)
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard let t = tracked, touches.contains(t) else { return }
            for c in event?.coalescedTouches(for: t) ?? [t] {
                onTouch?(.move(c.location(in: self), radius: c.majorRadius), c.timestamp)
            }
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { lift(touches) }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { lift(touches) }

        private func lift(_ touches: Set<UITouch>) {
            guard let t = tracked, touches.contains(t) else { return }
            tracked = nil
            onTouch?(.up(t.location(in: self)), t.timestamp)
        }
    }
}
