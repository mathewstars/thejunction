import SwiftUI

/// Home: the scene is the screen. The sky and the snow edge to edge, Lanvi
/// large on the snow with the tail glow as real light, one line of speech
/// above, and one action pinned above the home bar. Everything else is small
/// and in the corners: Help top left, the day pill top right.
struct HomeView: View {
    var demo: Bool

    @Environment(AppStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    @Namespace private var zoom

    private enum Cover: Identifiable {
        case activity(ActivityKind), help, story, mind, chat
        var id: String {
            switch self {
            case .activity(let k): return "activity-\(k.rawValue)"
            case .help: return "help"
            case .story: return "story"
            case .mind: return "mind"
            case .chat: return "chat"
            }
        }
    }

    private enum Sheet: String, Identifiable {
        case more, growth
        var id: String { rawValue }
    }

    /// Where things sit, for a screen size. Shared by the drawing and the moments.
    private struct Layout {
        var size: CGSize
        var compact: Bool
        var fox: CGFloat
        var feetY: CGFloat
        var hill: CGFloat
        var buttonY: CGFloat      // centre of the primary button
        var foxCenter: CGPoint

        init(size: CGSize, away: Bool) {
            self.size = size
            compact = size.height < 700
            let bottomGap: CGFloat = compact ? 16 : 8
            buttonY = size.height - bottomGap - 30
            let big = min(size.height * 0.46, size.width * 0.86)
            fox = away ? big * 0.34 : big
            feetY = buttonY - 30 - 32
            hill = feetY - big * 0.34
            if away {
                foxCenter = CGPoint(x: size.width * 0.76, y: hill - fox / 2 + 4)
            } else {
                foxCenter = CGPoint(x: size.width / 2, y: feetY - fox / 2)
            }
        }

        var foxTop: CGFloat { foxCenter.y - fox / 2 }
    }

    @State private var cover: Cover?
    @State private var sheet: Sheet?
    @State private var pose: LanviPose = .curious
    @State private var bounce = 0
    @State private var burst: Date?
    @State private var pop: HomeCelebration?
    @State private var celebrating = false
    @State private var showGrowth = false
    @State private var helpBlock: API.CrisisBlock?
    @State private var stream: (from: CGPoint, to: CGPoint, start: Date)?
    @State private var size: CGSize = .zero
    @State private var entrance: CGFloat = 0
    @State private var haptic = 0
    @State private var storyAutoAnswer: String?
    @State private var chatDemoMessage: String?
    @State private var arrived = false

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let L = Layout(size: geo.size, away: away)

            ZStack(alignment: .top) {
                // The sky's own gradient, with a stop at the horizon so dawn stays clean.
                LinearGradient(stops: [
                    .init(color: sky.top, location: 0),
                    .init(color: sky.mid, location: max(0.05, L.hill / max(L.size.height, 1) * 0.55)),
                    .init(color: sky.horizon, location: L.hill / max(L.size.height, 1)),
                    .init(color: sky.horizon, location: 1),
                ], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                SkyScene(top: .clear, bottom: .clear, hillTop: L.hill)
                if sky.aurora > 0 {
                    HomeAuroraBoost(strength: sky.aurora, height: L.hill)
                        .allowsHitTesting(false)
                }

                // Lanvi, large on the snow, with the fox fire behind the tail.
                ZStack {
                    HomeTailGlow(pose: pose, glow: store.glow, foxSize: L.fox, burst: burst)
                    LanviView(pose: pose, size: L.fox, bounceTrigger: bounce)
                        .onTapGesture { tapFox() }
                }
                .frame(width: L.fox * 2, height: L.fox * 2)
                .position(x: L.foxCenter.x + entrance, y: L.foxCenter.y)
                .accessibilityLabel("Lanvi")
                .accessibilityHint("Shows how Lanvi is growing")

                // What Lanvi says: one line of large type on the sky. Tap to talk.
                speech(L)

                if let pop {
                    HomeXPPop(amount: pop.xpGained)
                        .id(pop.id)
                        .position(x: L.foxCenter.x, y: L.foxTop + L.fox * 0.12)
                        .allowsHitTesting(false)
                }

                // Top corners: Help, and the day pill.
                HStack {
                    Button { open(.help) } label: { Image(systemName: "lifepreserver.fill") }
                        .buttonStyle(HomeSkyRoundStyle())
                        .homeZoomSource("help", in: zoom)
                        .accessibilityLabel("Help")
                    if store.mode == .live, store.link == .offline {
                        Image(systemName: "icloud.slash.fill")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white.opacity(0.8))
                            .padding(.leading, 8)
                            .accessibilityLabel("Offline. Your activities are saved and sent later.")
                    }
                    Spacer()
                    Button { sheet = .growth } label: { dayPill }
                        .buttonStyle(SpeechPressStyle())
                        .accessibilityLabel("Day \(store.daysTogether) together. Shows how Lanvi is growing.")
                }
                .padding(.horizontal, 24)
                .padding(.top, 8)

                // The XP moment: growth shows itself, then steps back.
                if showGrowth {
                    growthStrip
                        .position(x: w / 2, y: L.buttonY - 64)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                // One action, pinned above the home bar.
                // The zoom source is the whole action area, which is always there:
                // closing a screen must never zoom back into a button that is gone.
                actions
                    .frame(width: w - 48)
                    .homeZoomSource("today", in: zoom)
                    .position(x: w / 2, y: L.buttonY)
                    .opacity(arrived && !showGrowth ? 1 : 0)
                    .offset(y: arrived ? 0 : 24)

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
            .animation(.spring(response: 0.55, dampingFraction: 0.8), value: store.todayThing)
            .onAppear { size = geo.size }
            .onChange(of: geo.size) { _, s in size = s }
        }
        .sensoryFeedback(.success, trigger: haptic)
        .fullScreenCover(item: $cover) { c in
            coverContent(c)
                .homeZoomTarget(zoomSource(for: c), in: zoom)
        }
        .sheet(item: $sheet) { s in
            switch s {
            case .more:
                HomeMoreSheet { k in openAfterSheet(.activity(k)) }
            case .growth:
                HomeGrowthSheet(stage: store.stage, xp: store.xp, stageStart: store.stageRange.start,
                                nextStageAt: store.stageRange.next, daysTogether: store.daysTogether) {
                    openAfterSheet(.mind)
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
            withAnimation(.spring(response: 0.7, dampingFraction: 0.82).delay(0.25)) { arrived = true }
        }
        .task { await runDemo() }
    }

    // MARK: Pieces

    private func speech(_ L: Layout) -> some View {
        let top: CGFloat = L.compact ? 64 : 80
        // Clear air above the ear tips (and the little marks) in every pose.
        let bottom = max(away ? L.hill - 70 : L.foxTop - 28, top + 90)
        return VStack {
            Spacer(minLength: 0)
            Button { open(.chat) } label: {
                Text(bubbleText)
                    .font(Theme.rounded(L.compact ? 24 : 26, .heavy))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
                    .minimumScaleFactor(0.85)
                    .shadow(color: Theme.nightTop.opacity(0.45), radius: 10, y: 2)
                    .frame(maxWidth: .infinity)
                    .id(bubbleText)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 10)),
                                            removal: .opacity))
            }
            .buttonStyle(SpeechPressStyle())
            .homeZoomSource("speech", in: zoom)
            .accessibilityHint("Opens a chat with Lanvi")
        }
        .padding(.horizontal, 24)
        .frame(height: bottom - top)
        .padding(.top, top)
        .animation(.spring(response: 0.5, dampingFraction: 0.8), value: bubbleText)
        .opacity(arrived ? 1 : 0)
    }

    private var dayPill: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkle")
                .font(.system(size: 14, weight: .black))
                .foregroundStyle(Color(hex: 0xB9FFE4))
                .shadow(color: Color(hex: 0x7CF5C4).opacity(0.5 + 0.5 * store.glow), radius: 4 + 6 * store.glow)
            Text("Day \(store.daysTogether)")
                .font(Theme.rounded(17, .heavy))
                .foregroundStyle(.white)
                .contentTransition(.numericText(value: Double(store.daysTogether)))
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(Capsule().fill(.white.opacity(0.18)))
        .overlay(Capsule().stroke(.white.opacity(0.35), lineWidth: 1))
        .animation(.spring(response: 0.5, dampingFraction: 0.7), value: store.daysTogether)
    }

    /// Stage and XP, shown only in the XP moment: type and one bar on the snow, no box.
    private var growthStrip: some View {
        let range = store.stageRange
        let progress: Double = {
            guard let next = range.next, next > range.start else { return 1 }
            return min(max(Double(store.xp - range.start) / Double(next - range.start), 0), 1)
        }()
        return VStack(spacing: 8) {
            HStack {
                Text(TodayCopy.stageName(store.stage))
                Spacer()
                Text(range.next.map { "\(store.xp) / \($0) XP" } ?? "\(store.xp) XP")
                    .contentTransition(.numericText(value: Double(store.xp)))
            }
            .font(Theme.rounded(17, .heavy))
            .foregroundStyle(Theme.ink)
            HomeProgressBar(progress: progress, height: 12)
        }
        .frame(width: max(size.width - 48, 200))
    }

    @ViewBuilder private var actions: some View {
        switch store.todayThing {
        case .game(let k):
            HStack(spacing: 12) {
                moreButton
                Button(TodayCopy.button(k)) { open(.activity(k)) }
                    .buttonStyle(HomePrimaryStyle())
                chatButton
            }
        case .story:
            HStack(spacing: 12) {
                moreButton
                Button("Hear my story") { open(.story) }
                    .buttonStyle(HomePrimaryStyle())
                chatButton
            }
        case .realWorld(let s):
            HStack(spacing: 16) {
                Button("I did it") { Task { await store.answerSuggestion(s, didIt: true) } }
                    .buttonStyle(HomePrimaryStyle())
                Button("Not today") { Task { await store.answerSuggestion(s, didIt: false) } }
                    .buttonStyle(HomePrimaryStyle(fill: .white, edge: Theme.line, text: Theme.brand))
            }
        case .done:
            Button { sheet = .more } label: {
                Text("Do something more")
                    .font(Theme.rounded(17, .heavy))
                    .foregroundStyle(Theme.brand)
                    .padding(.vertical, 14)
                    .padding(.horizontal, 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(SpeechPressStyle())
        }
    }

    private var moreButton: some View {
        Button { sheet = .more } label: { Image(systemName: "square.grid.2x2.fill") }
            .buttonStyle(HomeQuietRoundStyle())
            .accessibilityLabel("More with Lanvi")
    }

    private var chatButton: some View {
        Button { open(.chat) } label: { Image(systemName: "bubble.left.fill") }
            .buttonStyle(HomeQuietRoundStyle())
            .accessibilityLabel("Talk to Lanvi")
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
                           onActivity: { cover = .activity($0) },
                           demoMessage: chatDemoMessage)
        }
    }

    // MARK: State for the scene

    private var away: Bool { store.wandering?.state == .away && !celebrating }
    private var isDoneToday: Bool { if case .done = store.todayThing { return true } else { return false } }

    private func zoomSource(for c: Cover) -> String {
        switch c {
        case .activity(let k):
            if case .game(let g) = store.todayThing, g == k { return "today" }
            return "speech"
        case .story: return "today"
        case .help: return "help"
        case .mind, .chat: return "speech"
        }
    }

    /// Sky colours and extra aurora for the time of day; the evening aurora follows the glow.
    private var sky: (top: Color, mid: Color, horizon: Color, aurora: Double) {
        switch store.dayPart {
        // A clean, luminous dawn: soft blue into a little warm peach at the horizon.
        case .morning: return (Color(hex: 0x4F87EC), Color(hex: 0x8DB8F8), Color(hex: 0xFFDCC8), 0)
        case .day: return (Color(hex: 0x2C5FDB), Color(hex: 0x5E8FEE), Color(hex: 0xB4D2FF), 0)
        case .evening: return (Theme.nightTop, Color(hex: 0x2B47A8), Theme.nightBottom, 0.45 + 0.45 * store.glow)
        case .night: return (Color(hex: 0x0D1B52), Color(hex: 0x1B2F7A), Color(hex: 0x33519E), 0.55 + 0.45 * store.glow)
        }
    }

    /// Lanvi's one line. When today's thing is done, it says so.
    private var bubbleText: String {
        if store.wandering?.state == .away, !celebrating {
            if let back = API.date(from: store.wandering?.returnsAt), back > Date() {
                return "I'm off wandering across Lapland. Back around \(back.formatted(date: .omitted, time: .shortened))."
            }
            return "I'm off wandering across Lapland. Back soon."
        }
        if case .done(let d) = store.todayThing, !d.restful, !celebrating {
            return "That's our thing for today."
        }
        return store.line.isEmpty ? " " : store.line
    }

    // MARK: Moments

    private func open(_ c: Cover) {
        #if DEBUG
        if demo { print("lanvi-demo: open \(c.id), cover now \(cover?.id ?? "none")") }
        #endif
        cover = c
    }

    private func openAfterSheet(_ c: Cover) {
        sheet = nil
        Task {
            try? await Task.sleep(for: .milliseconds(380))
            cover = c
        }
    }

    /// The resting pose for the state Lanvi is in and the time of day.
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

    /// Tapping Lanvi: a happy hop, then how it is growing.
    private func tapFox() {
        bounce &+= 1
        Task {
            try? await Task.sleep(for: .milliseconds(350))
            sheet = .growth
        }
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
        let L = Layout(size: size, away: false)
        let tail = HomeTailGlow.tailOffset(pose: .cheer, foxSize: L.fox)
        let to = CGPoint(x: L.foxCenter.x + tail.x, y: L.foxCenter.y + tail.y)
        withAnimation(.spring(response: 0.42, dampingFraction: 0.62)) { pose = .surprised }
        if c.xpGained > 0 {
            stream = (CGPoint(x: size.width / 2, y: L.buttonY), to, Date())
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) { showGrowth = true }
        }
        Task {
            if c.xpGained > 0 { try? await Task.sleep(for: .seconds(HomeLightStream.duration - 0.1)) }
            // The light arrives: cheer, burst, +XP, the bar fills.
            withAnimation(.spring(response: 0.42, dampingFraction: 0.62)) { pose = c.xpGained > 0 ? .cheer : .love }
            bounce &+= 1
            burst = Date()
            haptic &+= 1
            if c.xpGained > 0 { pop = c }
            try? await Task.sleep(for: .milliseconds(800))
            stream = nil
            bounce &+= 1
            try? await Task.sleep(for: .seconds(2.2))
            withAnimation(.easeOut(duration: 0.3)) { pop = nil }
            withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) { showGrowth = false }
            withAnimation(.spring(response: 0.42, dampingFraction: 0.62)) { pose = .love }
            try? await Task.sleep(for: .seconds(1.2))
            while store.grewUp != nil { try? await Task.sleep(for: .milliseconds(200)) }
            celebrating = false
            store.celebration = nil
            settle()
        }
    }

    // MARK: Demo and screenshots

    /// `-demo` walk-through (Home part): today's thing, Breathe with Lanvi, the light
    /// flows into the tail, Lanvi grows up, today is done, Lanvi runs off to wander
    /// and comes back with a story. `-demoPlay <focus|breathing|checkin>` sends one
    /// activity at once; `-demoOpen <help|story|mind|chat|more|growth|focus|breathing|checkin>`
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
            case "more": sheet = .more
            case "growth": sheet = .growth
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

        try? await Task.sleep(for: .seconds(3))
        open(.activity(.breathing))
        try? await Task.sleep(for: .seconds(6))
        cover = nil
        try? await Task.sleep(for: .milliseconds(700))
        await store.finish(Self.sample(.breathing), kind: .breathing)
        // XP, glow, growing up, done for today, then Lanvi runs off to wander.
        while celebrating || store.celebration != nil { try? await Task.sleep(for: .milliseconds(200)) }
        try? await Task.sleep(for: .seconds(3))
        await store.demoComeBack()
        try? await Task.sleep(for: .seconds(3))
        storyAutoAnswer = "a"
        open(.story)
        while cover != nil { try? await Task.sleep(for: .milliseconds(200)) }
        try? await Task.sleep(for: .seconds(2))
        // A short word with Lanvi.
        chatDemoMessage = "The coffee outside was nice today"
        open(.chat)
        while cover != nil { try? await Task.sleep(for: .milliseconds(200)) }
        try? await Task.sleep(for: .seconds(2))
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

/// The speech line and quiet links give a little when pressed.
private struct SpeechPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.spring(response: 0.18, dampingFraction: 0.7), value: configuration.isPressed)
            .sensoryFeedback(.impact(weight: .light), trigger: configuration.isPressed)
    }
}
