import SwiftUI

// MARK: - Close button (the chunky round blue one, top-left)

struct HomeCloseButton: View {
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 17, weight: .black))
        }
        .buttonStyle(HomeRoundButtonStyle())
        .accessibilityLabel("Close")
    }
}

/// A round 3D button: blue face on a darker edge, pressed down on tap.
struct HomeRoundButtonStyle: ButtonStyle {
    var fill: Color = Theme.brand
    var edge: Color = Theme.brandEdge
    var diameter: CGFloat = 46

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        configuration.label
            .foregroundStyle(.white)
            .frame(width: diameter, height: diameter)
            .background(
                Circle().fill(LinearGradient(colors: [fill.opacity(0.92), fill], startPoint: .top, endPoint: .bottom))
                    .overlay(Circle().stroke(.white.opacity(0.25), lineWidth: 1.5).padding(1.5))
            )
            .offset(y: pressed ? 4 : 0)
            .background(Circle().fill(edge).offset(y: 4))
            .animation(LanviTiming.press, value: pressed)
            .sensoryFeedback(.impact(weight: .light), trigger: pressed)
    }
}

// MARK: - Speech bubble

/// What Lanvi says on the other screens: the same bubble as Home (outline,
/// chunky bottom edge, one shape with the tail), hugging its words.
struct HomeSpeechBubble: View {
    var text: String
    /// Where the tail sits along the bottom, 0 = left edge, 1 = right edge.
    var pointAt: CGFloat = 0.5
    var size: CGFloat = 17

    @State private var shown: String?
    @State private var visible = true

    var body: some View {
        let text = shown ?? self.text
        return Text(text)
            .font(Theme.rounded(text.count > 64 ? size - 2 : size, .bold))
            .foregroundStyle(Theme.ink)
            .lineSpacing(2)
            .multilineTextAlignment(.leading)
            .lineLimit(4)
            .minimumScaleFactor(0.9)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(GeometryReader { g in
                LanviBubbleBackground(tailX: g.size.width * pointAt,
                                      lean: pointAt > 0.6 ? 1 : (pointAt < 0.4 ? -1 : 0))
            })
            .padding(.bottom, LanviBubbleShape.tailHeight)
            .scaleEffect(visible ? 1 : 0.85, anchor: .bottom)
            .opacity(visible ? 1 : 0)
            .onChange(of: self.text) { _, new in
                // The old line leaves first, then the new one pops in.
                withAnimation(.easeIn(duration: 0.12)) { visible = false }
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(130))
                    shown = new
                    withAnimation(LanviTiming.pop) { visible = true }
                }
            }
    }
}

// MARK: - XP pop

/// "+10 XP" that pops out above Lanvi and floats up.
struct HomeXPPop: View {
    var amount: Int
    @State private var up = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles")
                .foregroundStyle(Color(hex: 0x3FD9A0))
            Text("+\(amount) XP")
        }
        .font(Theme.rounded(22, .black))
        .foregroundStyle(Theme.brand)
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(Capsule().fill(.white))
        .background(Capsule().fill(Theme.line).offset(y: 4))
        .scaleEffect(up ? 1 : 0.4)
        .offset(y: up ? -46 : 0)
        .opacity(up ? 1 : 0)
        .onAppear {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.55)) { up = true }
        }
    }
}
