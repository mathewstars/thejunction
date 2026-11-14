import SwiftUI

/// Home's one big card: today's one thing, picked by Lanvi. A story waiting,
/// one of the three activities, a real-world suggestion with "I did it" /
/// "Not today", or, once done, a calm "That's our thing for today".
struct HomeTodayCard: View {
    var thing: TodayThing
    var compact: Bool
    var onGo: (ActivityKind) -> Void
    var onStory: () -> Void
    var onAnswer: (Bool) -> Void

    @State private var answering = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 12 : 14) {
            Text(label)
                .font(Theme.rounded(12, .black))
                .textCase(.uppercase)
                .tracking(0.9)
                .foregroundStyle(isDone ? Color(hex: 0x2FB98A) : Theme.brand)

            HStack(alignment: .center, spacing: 14) {
                disc
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(Theme.rounded(titleSize, .heavy))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(3)
                        .minimumScaleFactor(0.85)
                        .fixedSize(horizontal: false, vertical: true)
                    if let subtitle {
                        Text(subtitle)
                            .font(Theme.rounded(15, .bold))
                            .foregroundStyle(Theme.inkSecondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }

            buttons
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
        .id(cardID)
        .transition(.asymmetric(insertion: .scale(scale: 0.92).combined(with: .opacity),
                                removal: .opacity))
    }

    // MARK: Content

    private var isDone: Bool { if case .done = thing { return true } else { return false } }

    private var cardID: String {
        switch thing {
        case .story: return "story"
        case .game(let k): return "game-\(k.rawValue)"
        case .realWorld(let s): return "real-\(s.id)"
        case .done(let d): return "done-\(d.kind)-\(d.restful)"
        }
    }

    private var label: String {
        switch thing {
        case .done: return "Today with Lanvi"
        default: return "For today"
        }
    }

    private var title: String {
        switch thing {
        case .story: return "I brought you a story"
        case .game(let k): return Self.gameTitle(k)
        case .realWorld(let s): return s.text
        case .done(let d): return d.restful ? "Resting is part of it too" : "That's our thing for today"
        }
    }

    private var titleSize: CGFloat {
        if case .realWorld = thing { return compact ? 17 : 18 }
        return compact ? 21 : 23
    }

    private var subtitle: String? {
        switch thing {
        case .story: return "From my trip across Lapland"
        case .game(let k): return Self.gameDuration(k)
        case .realWorld: return nil
        case .done(let d): return d.restful ? "I'll be right here." : (d.log.isEmpty ? nil : d.log)
        }
    }

    static func gameTitle(_ k: ActivityKind) -> String {
        switch k {
        case .breathing: return "Breathe with me"
        case .focus: return "Catch sparks with me"
        case .checkin: return "Tell me three good things"
        }
    }

    static func gameDuration(_ k: ActivityKind) -> String {
        switch k {
        case .breathing: return "1 minute"
        case .focus: return "45 seconds"
        case .checkin: return "1 minute, before bed"
        }
    }

    static func icon(_ k: ActivityKind) -> String {
        switch k {
        case .focus: return "sparkles"
        case .breathing: return "wind"
        case .checkin: return "moon.stars.fill"
        }
    }

    static func icon(action: String) -> String {
        switch action {
        case "walk_10min": return "figure.walk"
        case "daylight_10min": return "sun.max.fill"
        default: return "phone.fill"
        }
    }

    // MARK: Pieces

    private var disc: some View {
        let size: CGFloat = compact ? 54 : 62
        return ZStack {
            Circle()
                .fill(LinearGradient(colors: discColors, startPoint: .topLeading, endPoint: .bottomTrailing))
            Circle().stroke(.white.opacity(0.7), lineWidth: 2).padding(2.5)
            Circle()
                .fill(LinearGradient(colors: [.white.opacity(0.45), .clear], startPoint: .top, endPoint: .center))
                .padding(5)
            discSymbol
        }
        .frame(width: size, height: size)
        // Soft light behind the disc, outside its own layout space.
        .background {
            Circle()
                .fill(RadialGradient(colors: [glowColor.opacity(0.55), .clear], center: .center,
                                     startRadius: 0, endRadius: size * 0.75))
                .frame(width: size * 1.5, height: size * 1.5)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder private var discSymbol: some View {
        switch thing {
        case .story:
            LanviView(pose: .love, size: compact ? 44 : 50)
                .offset(y: -2)
        case .game(let k):
            Image(systemName: Self.icon(k))
                .font(.system(size: compact ? 22 : 26, weight: .bold))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, Color(hex: 0xC9F5FF))
                .shadow(color: .white.opacity(0.6), radius: 4)
        case .realWorld(let s):
            Image(systemName: Self.icon(action: s.action))
                .font(.system(size: compact ? 22 : 26, weight: .bold))
                .foregroundStyle(.white)
                .shadow(color: .white.opacity(0.6), radius: 4)
        case .done(let d):
            Image(systemName: d.restful ? "leaf.fill" : "checkmark")
                .font(.system(size: compact ? 22 : 26, weight: .black))
                .foregroundStyle(.white)
                .shadow(color: .white.opacity(0.7), radius: 4)
        }
    }

    private var discColors: [Color] {
        switch thing {
        case .done: return [Color(hex: 0x7CF0C4), Color(hex: 0x2FB98A)]
        case .realWorld: return [Color(hex: 0xFFC27A), Color(hex: 0xF08A4B)]
        case .story: return [Color(hex: 0xDCE6FF), Color(hex: 0xA9BEFF)]
        case .game: return [Color(hex: 0x7C9BFF), Theme.brand]
        }
    }

    private var glowColor: Color {
        switch thing {
        case .done: return Color(hex: 0x3EE6A8)
        case .realWorld: return Color(hex: 0xFFB45C)
        default: return Color(hex: 0x9FB8FF)
        }
    }

    @ViewBuilder private var buttons: some View {
        switch thing {
        case .story:
            Button("Hear it", action: onStory)
                .buttonStyle(ChunkyButtonStyle())
        case .game(let k):
            Button("Let's go") { onGo(k) }
                .buttonStyle(ChunkyButtonStyle())
        case .realWorld:
            HStack(spacing: 10) {
                Button("I did it") { answer(true) }
                    .buttonStyle(ChunkyButtonStyle())
                Button("Not today") { answer(false) }
                    .buttonStyle(ChunkyButtonStyle(fill: .white, edge: Theme.line, text: Theme.brand))
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(Theme.line, lineWidth: 2).allowsHitTesting(false)
                    }
            }
            .disabled(answering)
        case .done:
            EmptyView()
        }
    }

    private var cardBackground: some View {
        let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)
        return ZStack {
            shape.fill(Theme.line).offset(y: 5)
            shape.fill(isDone
                       ? AnyShapeStyle(LinearGradient(colors: [Color(hex: 0xF2FFF9), .white], startPoint: .top, endPoint: .bottom))
                       : AnyShapeStyle(Color.white))
            shape.stroke(isDone ? Color(hex: 0xBFEFDC) : Theme.line, lineWidth: 2)
        }
    }

    private func answer(_ didIt: Bool) {
        answering = true
        onAnswer(didIt)
    }
}

/// "More with Lanvi": the other activities, always there, never locked.
struct HomeMoreChips: View {
    var exclude: ActivityKind?
    var done: Bool
    var zoom: Namespace.ID
    var onPick: (ActivityKind) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(done ? "Want more? Anytime." : "More with Lanvi")
                .font(Theme.rounded(13, .heavy))
                .foregroundStyle(Theme.inkSecondary)
            HStack(spacing: 8) {
                ForEach(ActivityKind.allCases.filter { $0 != exclude }) { k in
                    Button { onPick(k) } label: {
                        HStack(spacing: 6) {
                            Image(systemName: HomeTodayCard.icon(k))
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(Theme.brand)
                            Text(Self.name(k))
                                .font(Theme.rounded(15, .heavy))
                                .foregroundStyle(Theme.ink)
                                .lineLimit(1)
                                .minimumScaleFactor(0.85)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 42)
                    }
                    .buttonStyle(ChipPressStyle())
                    .homeZoomSource("chip-\(k.rawValue)", in: zoom)
                }
            }
        }
    }

    static func name(_ k: ActivityKind) -> String {
        switch k {
        case .focus: return "Sparks"
        case .breathing: return "Breathe"
        case .checkin: return "Check-in"
        }
    }
}

private struct ChipPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        configuration.label
            .background(shape.fill(.white))
            .overlay(shape.stroke(Theme.line, lineWidth: 2))
            .offset(y: pressed ? 4 : 0)
            .background(shape.fill(Theme.line).offset(y: 4))
            .animation(.spring(response: 0.16, dampingFraction: 0.7), value: pressed)
            .sensoryFeedback(.impact(weight: .light), trigger: pressed)
    }
}
