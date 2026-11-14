import SwiftUI

/// Home: Lanvi on a snowy hill under the night sky, saying today's line, with
/// the tail glow from the server, three activities on the snow and how far the
/// fox has grown. After an activity, light flows from the card into the tail,
/// the glow rises, the XP bar fills and Lanvi cheers with the returned line.
struct HomeView: View {
    var demo: Bool

    @Environment(AppStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    @Namespace private var zoom

    private enum Cover: Identifiable {
        case activity(ActivityKind), help, story, mind, chat
        var id: String {
            switch self {
            case .chat: return "chat"
            case .activity(let k): return "activity-\(k.rawValue)"
            case .help: return "help"
            case .story: return "story"
            case .mind: return "mind"
            }
        }
    }

    /// Where things sit, for a screen size. Shared by the drawing and the moments.
    private struct Layout {
        var size: CGSize
        var hill: CGFloat
        var fox: CGFloat
        var foxCenter: CGPoint
        var cardsTop: CGFloat
        var compact: Bool

        init(size: CGSize, away: Bool, snowContent: CGFloat) {
            self.size = size
            compact = size.height < 700
            let gap: CGFloat = compact ? 16 : 22
            // The horizon sits as low as the card, the chips and the growth bar allow,
            // so everything on the snow always ends above the home bar.
            let fits = size.height - snowContent - gap - 6
            hill = max(size.height * 0.34, min(size.height * (compact ? 0.47 : 0.53), fits))
            if away {
                fox = compact ? 80 : 96
                foxCenter = CGPoint(x: size.width * 0.78, y: hill - fox / 2 - 6)
            } else {
                fox = compact ? 140 : 196
                foxCenter = CGPoint(x: size.width / 2, y: hill - fox / 2 + 14)
            }
            cardsTop = hill + gap
        }

        var foxTop: CGFloat { foxCenter.y - fox / 2 }

        /// Where the light starts after an activity: the middle of today's card.
        var cardCenter: CGPoint { CGPoint(x: size.width / 2, y: cardsTop + 70) }
    }

    @State private var cover: Cover?
    @State private var pose: LanviPose = .curious
    @State private var bounce = 0
    @State private var burst: Date?
    @State private var pop: HomeCelebration?
    @State private var shine = 0
    @State private var celebrating = false
    @State private var helpBlock: API.CrisisBlock?
    @State private var stream: (from: CGPoint, to: CGPoint, start: Date)?
    @State private var size: CGSize = .zero
    /// Measured height of the card, chips and growth bar: the horizon is placed above it.
    @State private var snowHeight: CGFloat = 330
    @State private var entrance: CGFloat = 0        // run-in offset when Lanvi comes back
    @State private var haptic = 0
    @State private var wasAway = false
    @State private var storyAutoAnswer: String?

    private let cyclePoses: [LanviPose] = [.curious, .love, .surprised, .cheer, .peek]

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let L = Layout(size: geo.size, away: away, snowContent: snowHeight)

            ZStack(alignment: .top) {
                SkyScene(top: sky.top, bottom: sky.bottom, hillTop: L.hill)
                    .animation(.easeInOut(duration: 1.2), value: store.dayPart)
                if sky.aurora > 0 {
                    HomeAuroraBoost(strength: sky.aurora, height: L.hill)
                        .allowsHitTesting(false)
                }

                // Lanvi, with the fox fire behind the tail.
                ZStack {
                    HomeTailGlow(pose: pose, glow: store.glow, foxSize: L.fox, burst: burst)
                    LanviView(pose: pose, size: L.fox, bounceTrigger: bounce)
                        .onTapGesture { tapFox() }
                }
                .frame(width: L.fox * 2, height: L.fox * 2)
                .position(x: L.foxCenter.x + entrance, y: L.foxCenter.y)
                .accessibilityLabel("Lanvi")

                // What Lanvi says, above the fox.
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    Button { open(.chat) } label: {
                        HomeSpeechBubble(text: bubbleText, pointAt: away ? 0.78 : 0.5)
                            .overlay(alignment: .topTrailing) {
                                // So people find it: the bubble opens a chat with Lanvi.
                                HStack(spacing: 4) {
                                    Image(systemName: "bubble.left.and.text.bubble.right.fill")
                                        .font(.system(size: 11, weight: .bold))
                                    Text("Talk to Lanvi")
                                        .font(Theme.rounded(12, .heavy))
                                }
                                .foregroundStyle(.white)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Capsule().fill(Theme.brand))
                                .background(Capsule().fill(Theme.brandEdge).offset(y: 2))
                                .offset(x: 6, y: -14)
                            }
                    }
                    .buttonStyle(BubblePressStyle())
                    .homeZoomSource("bubble", in: zoom)
                    .animation(.spring(response: 0.45, dampingFraction: 0.7), value: bubbleText)
                    .accessibilityHint("Opens a chat with Lanvi")
                }
                .frame(width: w - 40, height: max(L.foxTop - (L.compact ? 62 : 70) + (away ? 0 : 0), 60))
                .padding(.top, L.compact ? 58 : 64)

                if let pop {
                    HomeXPPop(amount: pop.xpGained)
                        .id(pop.id)
                        .position(x: min(L.foxCenter.x + L.fox * 0.5, w - 86), y: L.foxTop + L.fox * 0.42)
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
                    .homeZoomSource("help", in: zoom)
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

                // On the snow: today's one thing, a little more, and how Lanvi is growing.
                VStack(spacing: 12) {
                    HomeTodayCard(thing: store.todayThing, compact: L.compact, bubbleText: bubbleText,
                                  onGo: { open(.activity($0)) },
                                  onStory: { open(.story) },
                                  onAnswer: { didIt in
                                      guard case .realWorld(let s) = store.todayThing else { return }
                                      Task { await store.answerSuggestion(s, didIt: didIt) }
                                  })
                        .homeZoomSource("today", in: zoom)
                        .animation(.spring(response: 0.55, dampingFraction: 0.8), value: store.todayThing)
                    HomeMoreChips(exclude: chipsExclude, done: isDoneToday, zoom: zoom) { open(.activity($0)) }
                    Button { open(.mind) } label: {
                        HomeGrowthCard(stage: store.stage, xp: store.xp, stageStart: store.stageRange.start,
                                       nextStageAt: store.stageRange.next, shine: shine,
                                       daysTogether: store.daysTogether)
                    }
                    .buttonStyle(GrowthPressStyle())
                    .homeZoomSource("mind", in: zoom)
                    .accessibilityHint("Shows what Lanvi has noticed")
                }
                .padding(.horizontal, 20)
                .background {
                    GeometryReader { g in
                        Color.clear
                            .onAppear { snowHeight = g.size.height }
                            .onChange(of: g.size.height) { _, h in
                                withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) { snowHeight = h }
                            }
                    }
                }
                .padding(.top, L.cardsTop)

                if let stream {
                    HomeLightStream(from: stream.from, to: stream.to, start: stream.start)
                        .ignoresSafeArea()
                }

                if let stage = store.grewUp {
                    HomeGrowUpMoment(stage: stage) { store.grewUp = nil }
                        .transition(.opacity)
                        .zIndex(10)
                }
            }
            .animation(.spring(response: 0.7, dampingFraction: 0.8), value: away)
            .onAppear { size = geo.size }
            .onChange(of: geo.size) { _, s in size = s }
        }
        .sensoryFeedback(.success, trigger: haptic)
        .fullScreenCover(item: $cover) { c in
            coverContent(c)
                .homeZoomTarget(zoomSource(for: c), in: zoom)
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
        .onChange(of: store.wandering?.state) { old, new in
            if new == .back, old != .back { runIn() } else if !celebrating { settle() }
        }
        .onChange(of: store.cheerTick) { _, _ in
            withAnimation(.spring(response: 0.42, dampingFraction: 0.62)) { pose = .cheer }
            bounce &+= 1
            burst = Date()
            haptic &+= 1
            Task {
                try? await Task.sleep(for: .seconds(2.2))
                if !celebrating { settle() }
            }
        }
        .onChange(of: isDoneToday) { _, _ in if !celebrating { settle() } }
        .onChange(of: scenePhase) { old, phase in
            if phase == .active, old == .background { welcomeBack() }
        }
        .onAppear {
            if store.wandering?.state == .back { runIn() } else { settle() }
        }
        .task { await runDemo() }
    }

    @ViewBuilder private func coverContent(_ c: Cover) -> some View {
        switch c {
        case .activity(let kind):
            ActivityRouter(kind: kind, checkinOptions: store.checkinOptions, planToAsk: store.planToAsk,
                           onHelp: { cover = .help }) { record in
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
                HomeStoryScreen(story: story, autoAnswer: storyAutoAnswer,
                                onAnswer: { await store.answerStory($0) }) { cover = nil }
            } else {
                Color.clear.onAppear { cover = nil }
            }
        case .mind:
            HomeMindScreen { cover = nil }
        case .chat:
            HomeChatScreen(onClose: { cover = nil },
                           onHelp: { cover = .help },
                           onActivity: { cover = .activity($0) })
        }
    }

    // MARK: Pieces

    private var away: Bool { store.wandering?.state == .away && !celebrating }
    private var storyWaiting: Bool { store.wandering?.state == .back && store.wandering?.story != nil }
    private var isDoneToday: Bool { if case .done = store.todayThing { return true } else { return false } }

    /// The chips leave out the activity the card already offers.
    private var chipsExclude: ActivityKind? { if case .game(let k) = store.todayThing { return k } else { return nil } }

    private func zoomSource(for c: Cover) -> String {
        switch c {
        case .activity(let k): return chipsExclude == k ? "today" : "chip-\(k.rawValue)"
        case .story: return "today"
        case .help: return "help"
        case .mind: return "mind"
        case .chat: return "bubble"
        }
    }

    /// Sky colours and extra aurora for the time of day; the evening aurora follows the glow.
    private var sky: (top: Color, bottom: Color, aurora: Double) {
        switch store.dayPart {
        case .morning: return (Color(hex: 0x4B67CF), Color(hex: 0xF6C9CF), 0)
        case .day: return (Color(hex: 0x2C5FDB), Color(hex: 0x9EC4FF), 0)
        case .evening: return (Theme.nightTop, Theme.nightBottom, 0.45 + 0.45 * store.glow)
        case .night: return (Color(hex: 0x0D1B52), Color(hex: 0x33519E), 0.55 + 0.45 * store.glow)
        }
    }

    private var bubbleText: String {
        if store.wandering?.state == .away, !celebrating {
            if let back = API.date(from: store.wandering?.returnsAt), back > Date() {
                return "I'm off wandering across Lapland. Back around \(back.formatted(date: .omitted, time: .shortened))."
            }
            return "I'm off wandering across Lapland. Back soon."
        }
        return store.line.isEmpty ? " " : store.line
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
        default:
            if isDoneToday { next = .love }
            else {
                switch store.dayPart {
                case .morning: next = .cheer        // a morning stretch
                case .day, .evening: next = .curious
                case .night: next = .love           // curled up and cosy
                }
            }
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

    /// Back from the wandering: Lanvi runs in from the side, then looks up, a story to tell.
    private func runIn() {
        let w = max(size.width, 400)
        pose = .run
        entrance = -w
        withAnimation(.easeOut(duration: 1.1)) { entrance = 0 }
        Task {
            try? await Task.sleep(for: .milliseconds(1100))
            withAnimation(.spring(response: 0.42, dampingFraction: 0.62)) { pose = .surprised }
            bounce &+= 1
            haptic &+= 1
        }
    }

    /// Opening the app again: Lanvi is pleased to see you.
    private func welcomeBack() {
        guard !celebrating, store.wandering?.state != .away else { return }
        withAnimation(.spring(response: 0.42, dampingFraction: 0.62)) { pose = .love }
        bounce &+= 1
        Task {
            try? await Task.sleep(for: .seconds(1.8))
            if !celebrating { settle() }
        }
    }

    private func celebrate(_ c: HomeCelebration) {
        celebrating = true
        let L = Layout(size: size, away: false, snowContent: snowHeight)
        let tail = HomeTailGlow.tailOffset(pose: .cheer, foxSize: L.fox)
        let to = CGPoint(x: L.foxCenter.x + tail.x, y: L.foxCenter.y + tail.y)
        withAnimation(.spring(response: 0.42, dampingFraction: 0.62)) { pose = .surprised }
        if c.xpGained > 0 {
            stream = (L.cardCenter, to, Date())
        }
        Task {
            if c.xpGained > 0 { try? await Task.sleep(for: .seconds(HomeLightStream.duration - 0.1)) }
            // The light arrives: cheer, burst, +XP, the bar fills.
            withAnimation(.spring(response: 0.42, dampingFraction: 0.62)) { pose = c.xpGained > 0 ? .cheer : .love }
            bounce &+= 1
            burst = Date()
            haptic &+= 1
            if c.xpGained > 0 { pop = c }
            try? await Task.sleep(for: .milliseconds(300))
            shine &+= 1
            try? await Task.sleep(for: .milliseconds(500))
            stream = nil
            bounce &+= 1
            try? await Task.sleep(for: .seconds(2.2))
            withAnimation(.easeOut(duration: 0.3)) { pop = nil }
            withAnimation(.spring(response: 0.42, dampingFraction: 0.62)) { pose = .love }
            try? await Task.sleep(for: .seconds(1.6))
            while store.grewUp != nil { try? await Task.sleep(for: .milliseconds(200)) }
            celebrating = false
            store.celebration = nil
            settle()
        }
    }

    // MARK: Demo and screenshots

    /// `-demo` walk-through (Home part): play Breathe with Lanvi, the light flows
    /// into the tail, Lanvi grows up, runs off to wander, comes back with a story,
    /// and the story is answered. `-demoPlay <focus|breathing|checkin>` sends one
    /// activity at once; `-demoOpen <help|story|mind|focus|breathing|checkin>`
    /// opens that screen; `-demoAnswer a|b` answers the waiting story.
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
            case "mind": open(.mind)
            case "chat": open(.chat)
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

        try? await Task.sleep(for: .seconds(2.5))
        tapFox()
        try? await Task.sleep(for: .seconds(1.5))
        open(.activity(.breathing))
        try? await Task.sleep(for: .seconds(7))
        cover = nil
        try? await Task.sleep(for: .milliseconds(700))
        await store.finish(Self.sample(.breathing), kind: .breathing)
        // XP, glow, growing up, then Lanvi runs off to wander.
        while celebrating || store.celebration != nil { try? await Task.sleep(for: .milliseconds(200)) }
        try? await Task.sleep(for: .seconds(4))
        await store.demoComeBack()
        try? await Task.sleep(for: .seconds(3.5))
        storyAutoAnswer = "a"
        open(.story)
        while cover != nil { try? await Task.sleep(for: .milliseconds(200)) }
        try? await Task.sleep(for: .seconds(2))
        for _ in 0..<3 {
            tapFox()
            try? await Task.sleep(for: .seconds(1.4))
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

/// The speech bubble gives a little when pressed.
private struct BubblePressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .offset(y: configuration.isPressed ? 2 : 0)
            .animation(.spring(response: 0.18, dampingFraction: 0.7), value: configuration.isPressed)
            .sensoryFeedback(.impact(weight: .light), trigger: configuration.isPressed)
    }
}

/// The growth card presses down onto its edge like every other card.
private struct GrowthPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .offset(y: configuration.isPressed ? 4 : 0)
            .animation(.spring(response: 0.16, dampingFraction: 0.7), value: configuration.isPressed)
            .sensoryFeedback(.impact(weight: .light), trigger: configuration.isPressed)
    }
}
