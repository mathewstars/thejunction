import SwiftUI

/// Extra aurora curtains over the sky that swell with the breath.
/// `level` 0 is faint, 1 is a full bright aurora (used for the finish).
struct BreatheAurora: View {
    var level: CGFloat

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack(alignment: .topLeading) {
                Capsule()
                    .fill(Theme.aurora)
                    .frame(width: w * 1.3, height: h * 0.34)
                    .rotationEffect(.degrees(-14))
                    .offset(x: -w * 0.18, y: h * 0.30)
                    .blur(radius: 26)
                    .opacity(0.10 + 0.42 * level)
                Capsule()
                    .fill(Theme.auroraViolet)
                    .frame(width: w * 1.1, height: h * 0.22)
                    .rotationEffect(.degrees(-9))
                    .offset(x: w * 0.05, y: h * 0.54)
                    .blur(radius: 22)
                    .opacity(0.06 + 0.36 * level)
                Capsule()
                    .fill(Color(hex: 0xB6F5DA))
                    .frame(width: w * 0.9, height: h * 0.16)
                    .rotationEffect(.degrees(-18))
                    .offset(x: -w * 0.05, y: h * 0.16)
                    .blur(radius: 24)
                    .opacity(0.04 + 0.30 * level)
            }
            .scaleEffect(x: 1, y: 0.75 + 0.45 * level, anchor: .top)
        }
        .allowsHitTesting(false)
    }
}

/// The soft ring of light behind Lanvi. Grows and brightens on the in-breath.
struct GlowRing: View {
    var breath: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [Theme.glow.opacity(0.55), Theme.glow.opacity(0.18), .clear],
                                     center: .center, startRadius: 0, endRadius: 170))
            Circle()
                .stroke(Theme.aurora.opacity(0.55), lineWidth: 16)
                .blur(radius: 12)
            Circle()
                .stroke(.white.opacity(0.85), lineWidth: 2.5)
                .blur(radius: 0.8)
                .padding(6)
        }
        .scaleEffect(0.72 + 0.36 * breath)
        .opacity(0.35 + 0.65 * breath)
        // Fade the bottom so the ring sinks softly into the snow instead of cutting across it.
        // The mask gets room around the ring so the soft blur is never cut into a square.
        .padding(80)
        .mask(LinearGradient(stops: [.init(color: .black, location: 0),
                                     .init(color: .black, location: 0.66),
                                     .init(color: .clear, location: 0.84)],
                             startPoint: .top, endPoint: .bottom))
        .padding(-80)
        .allowsHitTesting(false)
    }
}

/// Breaths left, as small dots on the snow. Done dots fill in, the current one breathes.
struct BreathDots: View {
    var total: Int
    var done: Int
    var breath: CGFloat

    var body: some View {
        HStack(spacing: 12) {
            ForEach(0..<total, id: \.self) { i in
                ZStack {
                    Circle().fill(Theme.tint)
                    Circle()
                        .fill(Theme.brand)
                        .scaleEffect(i < done ? 1 : 0.001)
                    if i == done {
                        Circle()
                            .fill(Theme.glow)
                            .scaleEffect(0.35 + 0.5 * breath)
                    }
                }
                .frame(width: 12, height: 12)
                .animation(.spring(response: 0.45, dampingFraction: 0.55), value: done)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 16)
        .background(Capsule().fill(.white))
        .overlay(Capsule().stroke(Theme.line, lineWidth: 2))
        .accessibilityElement()
        .accessibilityLabel("\(max(0, total - done)) breaths left")
    }
}

/// Round see-through button for the top corner, with a soft press.
struct BreatheCornerButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .heavy))
            .foregroundStyle(.white)
            .frame(width: 40, height: 40)
            .background(Circle().fill(.white.opacity(configuration.isPressed ? 0.30 : 0.18)))
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.6), value: configuration.isPressed)
            .contentShape(Circle())
    }
}

/// A little burst of sparks that float up from Lanvi's tail when the session ends.
struct SparkBurst: View {
    var fired: Bool

    private let sparks: [(x: CGFloat, rise: CGFloat, size: CGFloat, delay: Double)] = [
        (-70, 120, 16, 0.00), (-34, 160, 11, 0.12), (6, 140, 18, 0.05),
        (42, 170, 12, 0.18), (76, 120, 15, 0.08), (-96, 90, 10, 0.22), (100, 96, 10, 0.26),
    ]

    var body: some View {
        ZStack {
            ForEach(sparks.indices, id: \.self) { i in
                let s = sparks[i]
                Image(systemName: "sparkle")
                    .font(.system(size: s.size, weight: .bold))
                    .foregroundStyle(i.isMultiple(of: 2) ? Theme.aurora : .white)
                    .shadow(color: Theme.glow, radius: 6)
                    .offset(x: fired ? s.x : s.x * 0.3, y: fired ? -s.rise : 0)
                    .scaleEffect(fired ? 1 : 0.2)
                    .opacity(fired ? 0 : 1)
                    .animation(.easeOut(duration: 1.8).delay(s.delay), value: fired)
            }
        }
        .opacity(fired ? 1 : 0)
        .allowsHitTesting(false)
    }
}
