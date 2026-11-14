import SwiftUI

/// Words and icons for today's one thing, shared by Home, its sheets and the chat.
enum TodayCopy {
    /// What Lanvi asks for, in the care voice (the activities are things done for him).
    static func ask(_ k: ActivityKind, firstTime: Bool) -> String {
        switch k {
        case .focus: return "The ice is thick today. Help me break it?"
        case .breathing: return firstTime ? "Breathe with me. I'm still a bit cold." : "Sit with me a minute?"
        case .checkin: return "Tell me three good things. I'll keep them."
        }
    }

    static func button(_ k: ActivityKind) -> String {
        switch k {
        case .breathing: return "Sit with me a minute · 1 min"
        case .focus: return "Break the ice with me · 90 sec"
        case .checkin: return "Three good things · 1 min"
        }
    }

    /// The button's words on a narrow phone.
    static func shortButton(_ k: ActivityKind) -> String {
        switch k {
        case .breathing: return "Sit with me · 1 min"
        case .focus: return "Break the ice · 90 sec"
        case .checkin: return "Three good things · 1 min"
        }
    }

    static func title(_ k: ActivityKind) -> String {
        switch k {
        case .breathing: return "Sit with me a minute"
        case .focus: return "Break the ice with me"
        case .checkin: return "Tell me three good things"
        }
    }

    static func duration(_ k: ActivityKind) -> String {
        switch k {
        case .breathing: return "1 minute, the calm one"
        case .focus: return "90 seconds"
        case .checkin: return "1 minute, before bed"
        }
    }

    static func stageName(_ s: API.Stage) -> String {
        switch s {
        case .kit: return "Little kit"
        case .youngFox: return "Young fox"
        case .grownFox: return "Grown fox"
        }
    }

    static func icon(_ k: ActivityKind) -> String {
        switch k {
        case .focus: return "snowflake"
        case .breathing: return "wind"
        case .checkin: return "moon.stars.fill"
        }
    }
}

// MARK: - Home's primary button

/// The one big action on Home: the same 3D press as the rest of the app, in
/// sentence case on one line so the time fits inside it.
struct HomePrimaryStyle: ButtonStyle {
    var fill: Color = Theme.brand
    var edge: Color = Theme.brandEdge
    var text: Color = .white
    var padding: CGFloat = 14

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        configuration.label
            .font(Theme.rounded(17, .heavy))
            .foregroundStyle(text)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .padding(.horizontal, padding)
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background(shape.fill(fill))
            .overlay(alignment: .top) {
                shape.fill(LinearGradient(colors: [.white.opacity(0.18), .clear], startPoint: .top, endPoint: .center))
                    .allowsHitTesting(false)
            }
            .offset(y: pressed ? 5 : 0)
            .background(shape.fill(edge).offset(y: 5))
            .animation(LanviTiming.press, value: pressed)
            .sensoryFeedback(.impact(weight: .light), trigger: pressed)
    }
}

// MARK: - Small round buttons

/// The small round Help button in the corner: solid white, navy icon, so it
/// reads on every sky.
struct HomeCornerRoundStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        configuration.label
            .font(.system(size: 18, weight: .bold))
            .foregroundStyle(Theme.ink)
            .frame(width: 44, height: 44)
            .background(Circle().fill(Color(hex: 0xFFFEFB)).shadow(color: Theme.ink.opacity(0.12), radius: 8, y: 3))
            .scaleEffect(pressed ? 0.94 : 1)
            .animation(LanviTiming.press, value: pressed)
            .sensoryFeedback(.impact(weight: .light), trigger: pressed)
    }
}

/// A round white 3D button beside the primary one (more, chat).
struct HomeQuietRoundStyle: ButtonStyle {
    var diameter: CGFloat = 52
    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        configuration.label
            .font(.system(size: 20, weight: .bold))
            .foregroundStyle(Theme.brand)
            .frame(width: diameter, height: diameter)
            .background(Circle().fill(.white))
            .overlay(Circle().stroke(Theme.line, lineWidth: 2))
            .offset(y: pressed ? 5 : 0)
            .background(Circle().fill(Theme.line).offset(y: 5))
            .animation(LanviTiming.press, value: pressed)
            .sensoryFeedback(.impact(weight: .light), trigger: pressed)
    }
}

// MARK: - More with Lanvi (bottom sheet)

/// The three activities as three large rows. Always there, never locked.
struct HomeMoreSheet: View {
    /// The activity already on Home's button (left out here), if any.
    var onButton: ActivityKind? = nil
    var onPick: (ActivityKind) -> Void

    /// Revontulet and the check-in (whichever is not on the button), then Breathe,
    /// the calm one. Sparks and snow is no longer offered.
    private var rows: [ActivityKind] {
        [ActivityKind.focus, .checkin].filter { $0 != onButton } + [.breathing]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("More with Lanvi")
                .font(Theme.rounded(24, .heavy))
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, 24)
                .padding(.top, 28)
                .padding(.bottom, 8)
            ForEach(rows) { k in
                Button { onPick(k) } label: {
                    HStack(spacing: 16) {
                        ZStack {
                            Circle().fill(LinearGradient(colors: [Color(hex: 0x7C9BFF), Theme.brand],
                                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                            Circle().fill(LinearGradient(colors: [.white.opacity(0.4), .clear], startPoint: .top, endPoint: .center))
                                .padding(4)
                            Image(systemName: TodayCopy.icon(k))
                                .font(.system(size: 22, weight: .bold))
                                .foregroundStyle(.white)
                        }
                        .frame(width: 56, height: 56)
                        .shadow(color: Theme.brand.opacity(0.35), radius: 8, y: 4)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(TodayCopy.title(k))
                                .font(Theme.rounded(18, .heavy))
                                .foregroundStyle(Theme.ink)
                            Text(TodayCopy.duration(k))
                                .font(Theme.rounded(15, .semibold))
                                .foregroundStyle(Theme.inkSecondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 14, weight: .black))
                            .foregroundStyle(Theme.brand.opacity(0.6))
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(SheetRowStyle())
            }
            Color.clear.frame(height: 20)
        }
    }
}

/// Rows highlight softly while pressed.
private struct SheetRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Theme.tint.opacity(configuration.isPressed ? 1 : 0))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.8), value: configuration.isPressed)
            .sensoryFeedback(.impact(weight: .light), trigger: configuration.isPressed)
    }
}

// MARK: - Growing (bottom sheet)

/// How Lanvi is growing: the stage, one bar toward the next one, the days
/// together, and what Lanvi has noticed. Off Home on purpose.
struct HomeGrowthSheet: View {
    var stage: API.Stage
    var xp: Int
    var stageStart: Int
    var nextStageAt: Int?
    var daysTogether: Int
    var onNoticed: () -> Void

    private var progress: Double {
        guard let next = nextStageAt, next > stageStart else { return 1 }
        return min(max(Double(xp - stageStart) / Double(next - stageStart), 0), 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .bottom, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(TodayCopy.stageName(stage))
                        .font(Theme.rounded(28, .heavy))
                        .foregroundStyle(Theme.ink)
                    Text(nextStageAt.map { "\(xp) of \($0) XP" } ?? "\(xp) XP, fully grown")
                        .font(Theme.rounded(16, .semibold))
                        .foregroundStyle(Theme.inkSecondary)
                }
                Spacer()
                LanviView(pose: .love, size: 88)
            }
            HomeProgressBar(progress: progress, height: 16)
            Text("Day \(daysTogether) together. Growth only ever goes up.")
                .font(Theme.rounded(16, .semibold))
                .foregroundStyle(Theme.inkSecondary)
            Button(action: onNoticed) {
                HStack {
                    Text("What I've noticed")
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 14, weight: .black))
                }
                .padding(.horizontal, 20)
            }
            // The rim is part of the face, so it goes down with the press.
            .buttonStyle(ChunkyButtonStyle(fill: .white, edge: Theme.line, text: Theme.brand, outline: Theme.line))
            .padding(.top, 8)
            Color.clear.frame(height: 20)
        }
        .padding(.horizontal, 24)
        .padding(.top, 32)
    }
}

/// One soft bar: a light track with a glossy blue fill.
struct HomeProgressBar: View, Animatable {
    var progress: Double
    var height: CGFloat = 12
    var onDark = false

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(onDark ? .white.opacity(0.22) : Theme.tint)
                Capsule()
                    .fill(LinearGradient(colors: onDark ? [.white, Color(hex: 0xCFE0FF)] : [Theme.brand, Color(hex: 0x7C9BFF)],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(height, geo.size.width * progress))
                    .overlay(alignment: .top) {
                        Capsule().fill(.white.opacity(0.45)).frame(height: height * 0.25)
                            .padding(.horizontal, height * 0.4).padding(.top, height * 0.18)
                    }
            }
        }
        .frame(height: height)
    }
}
