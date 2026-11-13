import SwiftUI

/// Home: Lanvi on a snowy hill under the night sky, saying today's line, with
/// the tail glow from the server, three activities on the snow and how far the
/// fox has grown. After an activity: the XP pop, the glow rising, Lanvi cheering.
struct HomeView: View {
    var demo: Bool

    @Environment(AppStore.self) private var store

    private enum Cover: Identifiable {
        case activity(ActivityKind), help, story
        var id: String {
            switch self {
            case .activity(let k): return "activity-\(k.rawValue)"
            case .help: return "help"
            case .story: return "story"
            }
        }
    }

    @State private var cover: Cover?
    @State private var pose: LanviPose = .curious
    @State private var bounce = 0
    @State private var burst: Date?
    @State private var pop: HomeCelebration?
    @State private var shine = 0
    @State private var celebrating = false
    @State private var helpBlock: API.CrisisBlock?

    private let cyclePoses: [LanviPose] = [.curious, .love, .surprised, .cheer, .peek]

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let compact = h < 700
            let extraRow = store.wandering?.state == .back && store.wandering?.story != nil
                || (store.suggestion != nil && store.suggestion?.text != store.line)
            let hill = h * (compact ? (extraRow ? 0.47 : 0.545) : (extraRow ? 0.535 : 0.60))
            let fox: CGFloat = away ? (compact ? 120 : 140) : (compact ? 168 : 212)
            let foxY = hill - fox / 2 + 14
            let foxTop = hill + 14 - fox

            ZStack(alignment: .top) {
                SkyScene(top: Theme.nightTop, bottom: Theme.nightBottom, hillTop: hill)

                // Lanvi, with the fox fire behind the tail.
                ZStack {
                    HomeTailGlow(pose: pose, glow: store.glow, foxSize: fox, burst: burst)
                    LanviView(pose: pose, size: fox, bounceTrigger: bounce)
                        .onTapGesture { tapFox() }
                }
                .frame(width: fox * 2, height: fox * 2)
                .position(x: away ? w * 0.72 : w / 2, y: foxY)
                .animation(.spring(response: 0.6, dampingFraction: 0.8), value: away)
                .accessibilityLabel("Lanvi")

                // What Lanvi says, above the fox.
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    HomeSpeechBubble(text: bubbleText, pointAt: away ? 0.72 : 0.5)
                        .animation(.spring(response: 0.45, dampingFraction: 0.7), value: bubbleText)
                }
                .frame(width: w - 40, height: max(foxTop - (compact ? 62 : 70), 60))
                .padding(.top, compact ? 58 : 64)

                if let pop {
                    HomeXPPop(amount: pop.xpGained)
                        .id(pop.id)
                        .position(x: min(w / 2 + fox * 0.5, w - 86), y: foxTop + fox * 0.42)
                        .allowsHitTesting(false)
                }

                // Top: Help (always there) and the glow meter.
                HStack(spacing: 10) {
                    Button { open(.help) } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "lifepreserver.fill")
                            Text("Help")
                        }
                    }
                    .buttonStyle(HomeSkyChipStyle())
                    .accessibilityHint("Shows who to contact")
                    if store.mode == .live, store.link == .offline {
                        Image(systemName: "icloud.slash.fill")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.white.opacity(0.85))
                            .padding(9)
                            .background(Circle().fill(.white.opacity(0.16)))
                            .accessibilityLabel("Offline. Your activities are saved and sent later.")
                    }
                    Spacer()
                    HomeGlowMeter(glow: store.glow)
                }
                .padding(.horizontal, 20)
                .padding(.top, 6)

                // On the snow: the story, the activities, how Lanvi is growing.
                VStack(spacing: compact ? 12 : 16) {
                    if store.wandering?.state == .back, store.wandering?.story != nil {
                        storyBanner
                    } else if let s = store.suggestion, s.text != bubbleText {
                        suggestionLine(s.text)
                    }
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(ActivityKind.allCases) { kind in
                            HomeActivityCard(kind: kind, highlighted: store.suggestedKind == kind) {
                                open(.activity(kind))
                            }
                        }
                    }
                    HomeGrowthCard(stage: store.stage, xp: store.xp, stageStart: store.stageRange.start,
                                   nextStageAt: store.stageRange.next, shine: shine)
                }
                .padding(.horizontal, 20)
                .padding(.top, hill + (compact ? 22 : 30))
            }
        }
        .fullScreenCover(item: $cover) { c in
            switch c {
            case .activity(let kind):
                ActivityRouter(kind: kind, checkinOptions: store.checkinOptions, planToAsk: store.planToAsk) { record in
                    cover = nil
                    guard let record else { return }
                    Task { await store.finish(record, kind: kind) }
                }
            case .help:
                HomeHelpScreen(crisis: helpBlock ?? store.crisis) {
                    cover = nil
                    helpBlock = nil
                }
            case .story:
                if let story = store.wandering?.story {
                    HomeStoryScreen(story: story, onAnswer: { await store.answerStory($0) }) { cover = nil }
                } else {
                    Color.clear.onAppear { cover = nil }
                }
            }
        }
        .onChange(of: store.celebration) { _, c in
            if let c { celebrate(c) }
        }
        .onChange(of: store.crisisNow) { _, block in
            guard let block else { return }
            helpBlock = block
            store.crisisNow = nil
            Task {
                try? await Task.sleep(for: .milliseconds(500))
                cover = .help
            }
        }
        .onChange(of: store.wandering?.state) { _, _ in
            if !celebrating { settle() }
        }
        .onAppear { settle() }
        .task { await runDemo() }
    }

    // MARK: Pieces

    private var away: Bool { store.wandering?.state == .away && !celebrating }

    private var bubbleText: String {
        if store.wandering?.state == .away, !celebrating {
            if let back = API.date(from: store.wandering?.returnsAt), back > Date() {
                return "I'm off wandering across Lapland. Back around \(back.formatted(date: .omitted, time: .shortened))."
            }
            return store.line.isEmpty ? "I'm off wandering across Lapland. Back soon." : store.line
        }
        return store.line.isEmpty ? " " : store.line
    }

    private var storyBanner: some View {
        Button { open(.story) } label: {
            HStack(spacing: 12) {
                Image(systemName: "book.closed.fill")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white, Color(hex: 0xB9FFE4))
                    .frame(width: 42, height: 42)
                    .background(Circle().fill(.white.opacity(0.18)))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Lanvi brought a story")
                        .font(Theme.rounded(17, .heavy))
                    Text("Tap to hear it")
                        .font(Theme.rounded(13, .bold))
                        .opacity(0.8)
                }
                .foregroundStyle(.white)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 15, weight: .black))
                    .foregroundStyle(.white.opacity(0.85))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(StoryBannerStyle())
        .transition(.scale(scale: 0.9).combined(with: .opacity))
    }

    private func suggestionLine(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .foregroundStyle(Color(hex: 0x3FD9A0))
            Text(text)
                .font(Theme.rounded(16, .heavy))
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Moments

    private func open(_ c: Cover) {
        cover = c
    }

    /// The resting pose for the state Lanvi is in.
    private func settle() {
        let next: LanviPose
        switch store.wandering?.state {
        case .away: next = .run
        case .back: next = .surprised
        default: next = .curious
        }
        if next != pose {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.62)) { pose = next }
        }
    }

    private func tapFox() {
        let i = cyclePoses.firstIndex(of: pose) ?? 0
        bounce &+= 1
        withAnimation(.spring(response: 0.42, dampingFraction: 0.62)) { pose = cyclePoses[(i + 1) % cyclePoses.count] }
    }

    private func celebrate(_ c: HomeCelebration) {
        celebrating = true
        withAnimation(.spring(response: 0.42, dampingFraction: 0.62)) { pose = c.xpGained > 0 ? .cheer : .love }
        bounce &+= 1
        burst = Date()
        if c.xpGained > 0 { pop = c }
        Task {
            try? await Task.sleep(for: .milliseconds(700))
            shine &+= 1
            bounce &+= 1
            try? await Task.sleep(for: .seconds(2.4))
            withAnimation(.easeOut(duration: 0.3)) { pop = nil }
            withAnimation(.spring(response: 0.42, dampingFraction: 0.62)) { pose = .love }
            try? await Task.sleep(for: .seconds(1.6))
            celebrating = false
            store.celebration = nil
            settle()
        }
    }

    // MARK: Demo and screenshots

    /// `-demo`: after the welcome, a breathing minute "finishes" and Home shows
    /// the XP gain and the glow rising. `-demoPlay <focus|breathing|checkin>` does
    /// the same at once; `-demoOpen <help|story>` opens that screen.
    private func runDemo() async {
        await store.start()
        let args = ProcessInfo.processInfo.arguments
        func value(_ key: String) -> String? {
            guard let i = args.firstIndex(of: key), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        if let what = value("-demoOpen") {
            try? await Task.sleep(for: .milliseconds(600))
            switch what {
            case "help": open(.help)
            case "story": open(.story)
            default: if let k = ActivityKind(rawValue: what) { open(.activity(k)) }
            }
        }
        if let what = value("-demoPlay"), let kind = ActivityKind(rawValue: what) {
            try? await Task.sleep(for: .milliseconds(900))
            await store.finish(Self.sample(kind), kind: kind)
        }
        if let answer = value("-demoAnswer") {
            try? await Task.sleep(for: .milliseconds(900))
            _ = await store.answerStory(answer)
        }
        guard demo else { return }
        try? await Task.sleep(for: .seconds(2.0))
        await store.finish(Self.sample(.breathing), kind: .breathing)
        try? await Task.sleep(for: .seconds(5.5))
        for _ in 0..<4 {
            tapFox()
            try? await Task.sleep(for: .seconds(1.6))
        }
        settle()
    }

    private static func sample(_ kind: ActivityKind) -> API.ActivityIn {
        let started = API.isoString(Date().addingTimeInterval(-62))
        switch kind {
        case .breathing:
            return AppStore.sampleBreathing()
        case .focus:
            return API.ActivityIn(id: API.ActivityIn.newId(), type: .focus, startedAt: started, durationS: 45,
                                  completed: true, endedBy: .finished, correctTaps: 17, wrongTaps: 1, misses: 2,
                                  reactionMs: (0..<17).map { 470 + ($0 * 41) % 150 })
        case .checkin:
            return API.ActivityIn(id: API.ActivityIn.newId(), type: .checkin, startedAt: started, durationS: 55,
                                  completed: true, endedBy: .finished,
                                  goodThings: [.init(catalogId: "walked"), .init(catalogId: "laughed")],
                                  plan: .init(catalogId: "coffee_outside"), planDone: .notAsked)
        }
    }
}

/// The story banner: a deep blue card on a darker edge, pressed down on tap.
private struct StoryBannerStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        configuration.label
            .background(shape.fill(LinearGradient(colors: [Color(hex: 0x4E6FE6), Theme.nightTop],
                                                  startPoint: .topLeading, endPoint: .bottomTrailing)))
            .overlay(shape.stroke(.white.opacity(0.2), lineWidth: 1.5))
            .offset(y: pressed ? 4 : 0)
            .background(shape.fill(Color(hex: 0x0E1E55)).offset(y: 4))
            .animation(.spring(response: 0.16, dampingFraction: 0.7), value: pressed)
            .sensoryFeedback(.impact(weight: .light), trigger: pressed)
    }
}
