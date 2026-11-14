import SwiftUI

/// The one way anything is presented over Home (the captain: "the feel of the
/// app"). Full screens (chat, Help, What I've noticed, the activities) and
/// bottom panels (More, growing) all rise from the bottom edge on the same
/// spring over the same scrim, and go back down the same way, with no bounce.
///
/// Home underneath is never snapshotted, scaled, blurred or faded: the scrim is
/// its own layer between Home and what rises. No zoom transitions, no system
/// sheet or cover transitions mixed in.
struct LanviOverlayHost: View {
    var screen: AnyView?
    var screenID: String?
    var panel: AnyView?
    var panelID: String?
    var onClosePanel: () -> Void

    @State private var drag: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            // Slide by the whole screen plus its safe areas, so nothing of a closing
            // screen is left at the bottom edge when the move ends.
            let away = geo.size.height + geo.safeAreaInsets.top + geo.safeAreaInsets.bottom + 40
            stack(away: away)
        }
    }

    private func stack(away: CGFloat) -> some View {
        ZStack(alignment: .bottom) {
            if screenID != nil || panelID != nil {
                Color.black.opacity(screenID != nil ? 0.22 : 0.28)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { if screenID == nil { onClosePanel() } }
                    .transition(.opacity)
                    .zIndex(0)
            }
            if let panel, let panelID {
                PanelChrome(drag: $drag, onClose: onClosePanel) { panel }
                    .id(panelID)
                    .transition(.offset(y: away))
                    .zIndex(1)
            }
            if let screen, let screenID {
                screen
                    .id(screenID)
                    .transition(.offset(y: away))
                    .zIndex(2)
            }
        }
        .animation(LanviTiming.overlay, value: screenID)
        .animation(LanviTiming.overlay, value: panelID)
    }
}

/// A bottom panel: white, rounded on top, a grab handle, drag down to close.
private struct PanelChrome<Content: View>: View {
    @Binding var drag: CGFloat
    var onClose: () -> Void
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Theme.line)
                .frame(width: 40, height: 5)
                .padding(.top, 10)
            content()
        }
        .frame(maxWidth: .infinity)
        .background(
            UnevenRoundedRectangle(topLeadingRadius: 32, topTrailingRadius: 32, style: .continuous)
                .fill(Color.white)
                .ignoresSafeArea(edges: .bottom)
        )
        .offset(y: max(drag, 0))
        .gesture(
            DragGesture()
                .onChanged { drag = $0.translation.height }
                .onEnded { v in
                    if v.translation.height > 90 || v.predictedEndTranslation.height > 220 {
                        onClose()
                        drag = 0
                    } else {
                        withAnimation(LanviTiming.overlay) { drag = 0 }
                    }
                }
        )
    }
}

/// A presented screen's own fox shows once the screen has risen over Home, and is
/// hidden the moment the screen starts to close: Home's fox and the screen's fox
/// are never on screen together.
///
/// The wait is an animation delay run by the system (no task to cancel, no
/// completion to miss): the fox starts fading in 0.32 s after the screen appears,
/// when the rise (LanviTiming.overlay) is about 97% done, and is fully there by
/// 0.5 s, every time.
private struct ShowsAfterRise: ViewModifier {
    var closing: Bool
    @State private var risen = false

    func body(content: Content) -> some View {
        content
            .opacity(risen && !closing ? 1 : 0)
            // Hiding for the close is never animated (no half-faded fox).
            .animation(nil, value: closing)
            .onAppear {
                withAnimation(.easeOut(duration: 0.18).delay(0.32)) { risen = true }
            }
    }
}

extension View {
    /// For a fox drawn by a screen presented over Home (see `ShowsAfterRise`).
    func showsAfterRise(closing: Bool) -> some View { modifier(ShowsAfterRise(closing: closing)) }
}
