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
            .animation(.spring(response: 0.16, dampingFraction: 0.7), value: pressed)
            .sensoryFeedback(.impact(weight: .light), trigger: pressed)
    }
}

// MARK: - Speech bubble

/// What Lanvi says, in a white bubble whose point aims down at the fox.
struct HomeSpeechBubble: View {
    var text: String
    /// Horizontal position of the point, 0 = left edge, 1 = right edge.
    var pointAt: CGFloat = 0.5

    var body: some View {
        Text(text)
            .font(Theme.rounded(19, .heavy))
            .foregroundStyle(Theme.ink)
            .multilineTextAlignment(.center)
            .lineLimit(4)
            .minimumScaleFactor(0.8)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .frame(maxWidth: 320)
            .background(HomeBubbleShape(pointAt: pointAt).fill(.white))
            .background(HomeBubbleShape(pointAt: pointAt).fill(Theme.line).offset(y: 4))
            .shadow(color: Theme.nightTop.opacity(0.25), radius: 14, y: 8)
            .id(text)
            .transition(.asymmetric(insertion: .scale(scale: 0.7, anchor: .bottom).combined(with: .opacity),
                                    removal: .opacity))
    }
}

private struct HomeBubbleShape: Shape {
    var pointAt: CGFloat
    func path(in rect: CGRect) -> Path {
        var p = Path(roundedRect: rect, cornerRadius: 22, style: .continuous)
        let x = rect.minX + max(0.15, min(0.85, pointAt)) * rect.width
        p.move(to: CGPoint(x: x - 12, y: rect.maxY - 1))
        p.addQuadCurve(to: CGPoint(x: x + 2, y: rect.maxY + 14), control: CGPoint(x: x - 2, y: rect.maxY + 4))
        p.addQuadCurve(to: CGPoint(x: x + 12, y: rect.maxY - 1), control: CGPoint(x: x + 6, y: rect.maxY + 4))
        p.closeSubpath()
        return p
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
        .shadow(color: Color(hex: 0x7CF5C4).opacity(0.7), radius: 16)
        .scaleEffect(up ? 1 : 0.4)
        .offset(y: up ? -46 : 0)
        .opacity(up ? 1 : 0)
        .onAppear {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.55)) { up = true }
        }
    }
}
