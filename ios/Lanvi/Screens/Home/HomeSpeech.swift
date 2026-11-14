import SwiftUI

/// Lanvi's speech bubble: one continuous shape, the body and a curved tail
/// drawn as a single path. `tailX` is where the tail leaves the bottom edge
/// (points from the left); `lean` sends the tip left (-1), straight (0) or
/// right (1).
struct LanviBubbleShape: Shape {
    var tailX: CGFloat
    var lean: CGFloat = -1
    var radius: CGFloat = 22

    static let tailHeight: CGFloat = 15

    func path(in rect: CGRect) -> Path {
        let r = min(radius, rect.height / 2)
        let base: CGFloat = 20                                  // width of the tail where it joins
        let x0 = min(max(tailX - base / 2, rect.minX + r), rect.maxX - r - base)
        let x1 = x0 + base
        let tip = CGPoint(x: (x0 + x1) / 2 + lean * 12, y: rect.maxY + Self.tailHeight)

        var p = Path()
        p.move(to: CGPoint(x: rect.minX + r, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        p.addArc(center: CGPoint(x: rect.maxX - r, y: rect.minY + r), radius: r,
                 startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        p.addArc(center: CGPoint(x: rect.maxX - r, y: rect.maxY - r), radius: r,
                 startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        // Bottom edge, then the tail as one smooth curve out and back.
        p.addLine(to: CGPoint(x: x1, y: rect.maxY))
        p.addCurve(to: tip,
                   control1: CGPoint(x: x1 - base * 0.25, y: rect.maxY + 2),
                   control2: CGPoint(x: tip.x + (lean >= 0 ? -1 : 1) * 2, y: tip.y - 4))
        p.addCurve(to: CGPoint(x: x0, y: rect.maxY),
                   control1: CGPoint(x: tip.x + (lean >= 0 ? -1 : 1) * 4, y: tip.y - 6),
                   control2: CGPoint(x: x0 + base * 0.1, y: rect.maxY + 3))
        p.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        p.addArc(center: CGPoint(x: rect.minX + r, y: rect.maxY - r), radius: r,
                 startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        p.addArc(center: CGPoint(x: rect.minX + r, y: rect.minY + r), radius: r,
                 startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        p.closeSubpath()
        return p
    }
}

/// The bubble's look, Duolingo-like in our colours: white, a soft blue-grey
/// outline, a slightly thicker darker bottom edge (the chunky 3D language of
/// our buttons), no blur shadow.
struct LanviBubbleBackground: View {
    var tailX: CGFloat
    var lean: CGFloat = -1

    static let outline = Color(hex: 0xCDD8EC)
    static let edge = Color(hex: 0xB9C7E2)

    var body: some View {
        let shape = LanviBubbleShape(tailX: tailX, lean: lean)
        ZStack {
            shape.fill(Self.edge).offset(y: 3)
            shape.fill(Color.white)
            shape.stroke(Self.outline, lineWidth: 2)
        }
    }
}

/// Home's speech: the bubble sits up and to one side of Lanvi's head with its
/// tail pointing to the face. The tail's tip never moves. A new line fades the old
/// words out, the bubble resizes to the new line in one smooth spring (placed by a
/// layout, never by a size measured a frame late), then the words appear one at a
/// time while Lanvi's mouth opens and closes. Tap opens the chat.
struct HomeSpeech: View {
    var text: String
    /// Where the tail tip points, in the parent's coordinates.
    var target: CGPoint
    var width: CGFloat
    @Binding var mouth: MouthShape?
    /// What a tap does, for VoiceOver; nil on pages where the bubble only speaks.
    var hint: String? = "Opens a chat with Lanvi"
    var onTap: () -> Void

    @State private var shown = ""
    @State private var revealed = 0
    @State private var wordsOpacity: Double = 1
    @State private var appeared = false
    @State private var speaking: Task<Void, Never>?

    private var long: Bool { shown.count > 64 }
    private static let space = "lanvi.speech"

    var body: some View {
        SpeechLayout(leftX: target.x - 34,
                     bottom: target.y - LanviBubbleShape.tailHeight,
                     maxWidth: width * 0.72) {
            Button(action: onTap) {
                words
                    .font(Theme.rounded(long ? 15 : 17, .bold))
                    .foregroundStyle(Theme.ink)
                    .opacity(wordsOpacity)
                    .lineSpacing(2)
                    .multilineTextAlignment(.leading)
                    .lineLimit(shown.count > 90 ? 4 : (long ? 3 : 2))
                    .minimumScaleFactor(0.9)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(GeometryReader { g in
                        let minX = g.frame(in: .named(Self.space)).minX
                        LanviBubbleBackground(tailX: min(max(target.x - minX + 6, 30), g.size.width - 30))
                    })
            }
            .buttonStyle(BubblePress())
            .scaleEffect(appeared ? 1 : 0.8, anchor: UnitPoint(x: 0.2, y: 1))
            .opacity(appeared ? 1 : 0)
            .accessibilityLabel(shown)
            .accessibilityHint(hint ?? "")
            .accessibilityIdentifier("home.speech")
        }
        .coordinateSpace(name: Self.space)
        .onAppear { speak(text) }
        .onChange(of: text) { _, t in speak(t) }
    }

    /// The whole line is laid out from the start (so the bubble never resizes
    /// while the words appear); words not yet said are transparent.
    private var words: Text {
        let parts = shown.split(separator: " ", omittingEmptySubsequences: true)
        var a = AttributedString()
        for (i, w) in parts.enumerated() {
            var s = AttributedString(String(w) + (i < parts.count - 1 ? " " : ""))
            if i >= revealed { s.foregroundColor = .clear }
            a += s
        }
        return Text(a)
    }

    private func speak(_ t: String) {
        speaking?.cancel()
        speaking = Task { @MainActor in
            if appeared, !shown.isEmpty {
                // The old words fade; the bubble itself stays where it is.
                withAnimation(.easeOut(duration: 0.12)) { wordsOpacity = 0 }
                try? await Task.sleep(for: .milliseconds(130))
                guard !Task.isCancelled else { return }
                // One smooth spring to the new line's size; the tail tip stays put.
                withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) {
                    shown = t
                    revealed = 0
                }
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled else { return }
                wordsOpacity = 1
            } else {
                shown = t
                revealed = 0
                wordsOpacity = 1
                withAnimation(.spring(response: 0.34, dampingFraction: 0.7)) { appeared = true }
            }
            let n = max(t.split(separator: " ").count, 1)
            let start = Date()
            var open = false
            var lastMouth = Date.distantPast
            while revealed < n || Date().timeIntervalSince(start) < 0.6 {
                guard !Task.isCancelled else { mouth = nil; return }
                let p = min(Date().timeIntervalSince(start) / 0.6, 1)
                revealed = max(revealed, Int((p * Double(n)).rounded(.up)))
                if Date().timeIntervalSince(lastMouth) >= 0.12 {
                    open.toggle()
                    mouth = open ? .o : .smile
                    lastMouth = Date()
                }
                if p >= 1 { break }
                try? await Task.sleep(for: .milliseconds(30))
            }
            revealed = n
            mouth = nil
        }
    }
}

/// Places the bubble: its left edge just left of the face (or pulled in so it stays
/// 20 points from the screen's right edge), its bottom on the tail's line. It takes
/// the whole parent, so the coordinates are the parent's.
private struct SpeechLayout: Layout {
    var leftX: CGFloat
    var bottom: CGFloat
    var maxWidth: CGFloat
    var edge: CGFloat = 20

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let bubble = subviews.first else { return }
        let size = bubble.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
        let x = max(min(leftX, bounds.width - edge - size.width), edge)
        bubble.place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + bottom - size.height),
                     anchor: .topLeading,
                     proposal: ProposedViewSize(width: size.width, height: size.height))
    }
}

/// The bubble gives a little when pressed.
private struct BubblePress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.18, dampingFraction: 0.7), value: configuration.isPressed)
            .sensoryFeedback(.impact(weight: .light), trigger: configuration.isPressed) { wasDown, isDown in isDown && !wasDown }
    }
}
