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
/// tail pointing to the face. It pops from the tail tip, the words appear one
/// at a time while Lanvi's mouth opens and closes, and an old line shrinks
/// back to the mouth before a new one arrives. Tap opens the chat.
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
    @State private var scale: CGFloat = 0.6
    @State private var opacity: Double = 0
    @State private var size: CGSize = .zero
    @State private var speaking: Task<Void, Never>?

    private var maxWidth: CGFloat { width * 0.72 }
    private var long: Bool { shown.count > 64 }

    var body: some View {
        let bw = max(size.width, 1), bh = max(size.height, 1)
        // Sit up and to the right of the head, but stay on screen.
        let minX = min(max(target.x - 34, 20), width - 20 - bw)
        let tailX = min(max(target.x - minX + 6, 30), bw - 30)
        let bottom = target.y - LanviBubbleShape.tailHeight
        let tip = CGPoint(x: tailX - 12, y: bh + LanviBubbleShape.tailHeight)

        Button(action: onTap) {
            words
                .font(Theme.rounded(long ? 15 : 17, .bold))
                .foregroundStyle(Theme.ink)
                .lineSpacing(2)
                .multilineTextAlignment(.leading)
                .lineLimit(shown.count > 90 ? 4 : (long ? 3 : 2))
                .minimumScaleFactor(0.9)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(LanviBubbleBackground(tailX: tailX))
                .background(GeometryReader { g in
                    Color.clear.preference(key: BubbleSizeKey.self, value: g.size)
                })
        }
        .buttonStyle(BubblePress())
        .frame(width: maxWidth, alignment: .leading)
        .onPreferenceChange(BubbleSizeKey.self) { size = $0 }
        .scaleEffect(scale, anchor: UnitPoint(x: tip.x / maxWidth, y: tip.y / bh))
        .opacity(opacity)
        .position(x: minX + maxWidth / 2, y: bottom - bh / 2)
        .accessibilityLabel(shown)
        .accessibilityHint(hint ?? "")
        .onAppear { speak(text) }
        .onChange(of: text) { _, t in speak(t) }
    }

    /// The whole line is laid out from the start (so the bubble never resizes);
    /// words not yet said are transparent.
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
            if opacity > 0 {
                // The old line shrinks back to the mouth first.
                withAnimation(.easeIn(duration: 0.14)) { scale = 0.6; opacity = 0 }
                try? await Task.sleep(for: .milliseconds(150))
            }
            guard !Task.isCancelled else { return }
            shown = t
            revealed = 0
            try? await Task.sleep(for: .milliseconds(40))   // let it measure itself
            guard !Task.isCancelled else { return }
            withAnimation(.spring(response: 0.34, dampingFraction: 0.6)) { scale = 1; opacity = 1 }
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

private struct BubbleSizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
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
