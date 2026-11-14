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

/// What Lanvi says: one soft white bubble with a small tail toward Lanvi,
/// navy type, no border, a very light shadow. The only container on Home.
struct HomeSpeechBubble: View {
    var text: String
    /// Horizontal position of the tail, 0 = left edge, 1 = right edge.
    var pointAt: CGFloat = 0.5
    var size: CGFloat = 21

    var body: some View {
        Text(text)
            .font(Theme.rounded(size, .heavy))
            .foregroundStyle(Theme.ink)
            .multilineTextAlignment(.center)
            .lineSpacing(1)
            .lineLimit(4)
            .minimumScaleFactor(0.85)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 22)
            .padding(.vertical, 16)
            .background(
                HomeBubbleShape(pointAt: pointAt)
                    .fill(Color(hex: 0xFFFEFB))
                    .shadow(color: Theme.ink.opacity(0.10), radius: 12, y: 4)
            )
            .padding(.bottom, 12)   // room for the tail
            .id(text)
            .transition(.asymmetric(insertion: .scale(scale: 0.92, anchor: .bottom).combined(with: .opacity),
                                    removal: .opacity))
    }
}

/// A generously rounded bubble with a small, soft tail at the bottom.
struct HomeBubbleShape: Shape {
    var pointAt: CGFloat
    func path(in rect: CGRect) -> Path {
        let body = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
        var p = Path(roundedRect: body, cornerRadius: min(26, body.height / 2), style: .continuous)
        let x = body.minX + max(0.2, min(0.8, pointAt)) * body.width
        let base = body.maxY - 1
        p.move(to: CGPoint(x: x - 13, y: base))
        p.addCurve(to: CGPoint(x: x - 1, y: base + 12),
                   control1: CGPoint(x: x - 6, y: base + 1), control2: CGPoint(x: x - 3, y: base + 8))
        p.addQuadCurve(to: CGPoint(x: x + 2, y: base + 12), control: CGPoint(x: x + 0.5, y: base + 14))
        p.addCurve(to: CGPoint(x: x + 13, y: base),
                   control1: CGPoint(x: x + 4, y: base + 8), control2: CGPoint(x: x + 7, y: base + 1))
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
