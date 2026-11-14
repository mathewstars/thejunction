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

// MARK: - Top chips

/// Small frosted pill in the sky that presses down like the other buttons.
struct HomeSkyChipStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        configuration.label
            .font(Theme.rounded(16, .heavy))
            .foregroundStyle(.white)
            .padding(.vertical, 9)
            .padding(.horizontal, 14)
            .background(Capsule().fill(.ultraThinMaterial.opacity(0.55)))
            .background(Capsule().fill(.white.opacity(0.16)))
            .overlay(Capsule().stroke(.white.opacity(0.35), lineWidth: 1))
            .offset(y: pressed ? 3 : 0)
            .background(Capsule().fill(Theme.nightTop.opacity(0.45)).offset(y: 3))
            .animation(.spring(response: 0.16, dampingFraction: 0.7), value: pressed)
            .sensoryFeedback(.impact(weight: .light), trigger: pressed)
    }
}

/// Tail glow meter in the sky: a little light that fills, never empties to dark.
struct HomeGlowMeter: View, Animatable {
    var glow: Double
    var animatableData: Double {
        get { glow }
        set { glow = newValue }
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(LinearGradient(colors: [Color(hex: 0xB9FFE4), Theme.aurora],
                                                startPoint: .top, endPoint: .bottom))
                .shadow(color: Color(hex: 0x7CF5C4).opacity(0.8), radius: 6)
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.nightTop.opacity(0.55)).frame(width: 74, height: 12)
                Capsule()
                    .fill(LinearGradient(colors: [Color(hex: 0x7CF5C4), Theme.aurora, Theme.auroraViolet],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(12, 74 * glow), height: 12)
                    .overlay(alignment: .top) {
                        Capsule().fill(.white.opacity(0.55)).frame(height: 3).padding(.horizontal, 4).padding(.top, 2)
                    }
                    .shadow(color: Color(hex: 0x7CF5C4).opacity(0.5 + 0.4 * glow), radius: 4 + 6 * glow)
            }
        }
        .padding(.vertical, 11)
        .padding(.horizontal, 14)
        .background(Capsule().fill(.white.opacity(0.16)))
        .overlay(Capsule().stroke(.white.opacity(0.35), lineWidth: 1))
        .background(Capsule().fill(Theme.nightTop.opacity(0.45)).offset(y: 3))
        .accessibilityLabel("Lanvi's glow")
        .accessibilityValue("\(Int(glow * 100)) percent")
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

// MARK: - Growth (XP and stage)

/// Friendly progress toward the next stage. Counts showing up, never skill.
struct HomeGrowthCard: View {
    var stage: API.Stage
    var xp: Int
    var stageStart: Int
    var nextStageAt: Int?
    var shine: Int   // change to run a light sweep along the bar
    /// Days with something done together; only ever goes up.
    var daysTogether: Int = 0

    @State private var sweep: CGFloat = -0.3
    @State private var daySparkle = 0

    private var progress: Double {
        guard let next = nextStageAt, next > stageStart else { return 1 }
        return min(max(Double(xp - stageStart) / Double(next - stageStart), 0), 1)
    }

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(LinearGradient(colors: [Theme.tint, Color(hex: 0xD3E0FF)], startPoint: .top, endPoint: .bottom))
                Circle().stroke(.white, lineWidth: 2).padding(2)
                Image(systemName: "pawprint.fill")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(LinearGradient(colors: [Theme.brand, Theme.brandEdge], startPoint: .top, endPoint: .bottom))
            }
            .frame(width: 46, height: 46)

            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline) {
                    Text(Self.name(stage))
                        .font(Theme.rounded(17, .heavy))
                        .foregroundStyle(Theme.ink)
                    Spacer(minLength: 6)
                    Group {
                        if let next = nextStageAt {
                            HStack(spacing: 0) {
                                Text("\(xp)").contentTransition(.numericText(value: Double(xp)))
                                Text(" / \(next) XP").foregroundStyle(Theme.inkSecondary)
                            }
                        } else {
                            Text("\(xp) XP").contentTransition(.numericText(value: Double(xp)))
                        }
                    }
                    .font(Theme.rounded(15, .heavy))
                    .foregroundStyle(Theme.brand)
                    .monospacedDigit()
                }
                GeometryReader { geo in
                    let w = geo.size.width
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.tint)
                            .overlay(Capsule().stroke(Theme.line, lineWidth: 1.5))
                        Capsule()
                            .fill(LinearGradient(colors: [Theme.brand, Color(hex: 0x6E8BFF), Theme.auroraViolet],
                                                 startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(16, w * progress))
                            .overlay(alignment: .top) {
                                Capsule().fill(.white.opacity(0.45)).frame(height: 4).padding(.horizontal, 6).padding(.top, 3)
                            }
                            .overlay {
                                LinearGradient(colors: [.clear, .white.opacity(0.7), .clear], startPoint: .leading, endPoint: .trailing)
                                    .frame(width: 40)
                                    .offset(x: sweep * w)
                                    .opacity(sweep > -0.25 && sweep < 1.15 ? 1 : 0)
                                    .blendMode(.plusLighter)
                            }
                            .clipShape(Capsule())
                    }
                }
                .frame(height: 16)
                HStack(spacing: 5) {
                    Image(systemName: "sparkle")
                        .font(.system(size: 11, weight: .black))
                        .foregroundStyle(Color(hex: 0x2FB98A))
                        .scaleEffect(daySparkle > 0 ? 1 : 0.9)
                        .keyframeAnimator(initialValue: CGFloat(1), trigger: daySparkle) { v, k in
                            v.scaleEffect(k).rotationEffect(.degrees(Double(k - 1) * 90))
                        } keyframes: { _ in
                            SpringKeyframe(1.9, duration: 0.25, spring: .snappy)
                            SpringKeyframe(1, duration: 0.5, spring: .bouncy)
                        }
                    Text("Days together: \(daysTogether)")
                        .contentTransition(.numericText(value: Double(daysTogether)))
                }
                .font(Theme.rounded(13, .bold))
                .foregroundStyle(Theme.inkSecondary)
                .lineLimit(1)
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .black))
                .foregroundStyle(Theme.brand.opacity(0.7))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(.white))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Theme.line, lineWidth: 2))
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Theme.line).offset(y: 4))
        .onChange(of: daysTogether) { old, new in
            if new > old { daySparkle += 1 }
        }
        .onChange(of: shine) {
            sweep = -0.3
            withAnimation(.easeInOut(duration: 1.1).delay(0.5)) { sweep = 1.2 }
        }
        .accessibilityElement(children: .combine)
    }

    static func name(_ s: API.Stage) -> String {
        switch s {
        case .kit: return "Little kit"
        case .youngFox: return "Young fox"
        case .grownFox: return "Grown fox"
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
        .shadow(color: Color(hex: 0x7CF5C4).opacity(0.7), radius: 16)
        .scaleEffect(up ? 1 : 0.4)
        .offset(y: up ? -46 : 0)
        .opacity(up ? 1 : 0)
        .onAppear {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.55)) { up = true }
        }
    }
}
