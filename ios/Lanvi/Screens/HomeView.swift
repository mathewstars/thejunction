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
        /// The story travels with the screen, so answering it (which clears it on
        /// the server) never pulls the screen out from under the person.
        case activity(ActivityKind), help, story(API.StoryOut), mind, chat
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

        init(size: CGSize, insets: EdgeInsets, away: Bool) {
            self.size = size
            compact = size.height < 700
            let bottomGap: CGFloat = compact ? 16 : 8
            buttonY = size.height - bottomGap - 30
            // Where the painting's hollow lands on this screen: Lanvi sits in it.
            let screen = CGSize(width: size.width, height: size.height + insets.top + insets.bottom)
            let world = WorldFrame(screen: screen)
            let hollow = world.point(WorldFrame.hollow.x, WorldFrame.hollow.y)
            let big = min(size.height * 0.46, size.width * 0.86)
            fox = away ? big * 0.30 : big
            feetY = min(hollow.y - insets.top + big * 0.03, buttonY - 30 - 24)
            hill = world.point(0.5, 0.56).y - insets.top
            if away {
                // Off in the distance, by the pines on the right.
                let far = world.point(0.80, 0.60)
                foxCenter = CGPoint(x: far.x, y: far.y - insets.top - fox / 2)
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
    @State private var pop: HomeCelebration?
    @State private var celebrating = false
    @State private var showGrowth = false
    @State private var helpBlock: API.CrisisBlock?
    @State private var size: CGSize = .zero
    @State private var insets = EdgeInsets()
    @State private var entrance: CGFloat = 0
    @State private var haptic = 0
    @State private var storyAutoAnswer: String?
    @State private var arrived = false
    // The living fox: one-off reactions and where it looks.
    @State private var reaction: LanviMood = .happy
    @State private var reactTick = 0
    @State private var look: UnitPoint?

    var body: some View {
        #if DEBUG
        let _ = FrameMeter.count("Home")
        #endif
        GeometryReader { geo in
            let w = geo.size.width
            let L = Layout(size: geo.size, insets: geo.safeAreaInsets, away: away)

            ZStack(alignment: .top) {
                PaintedWorld(scene: store.worldScene)

                // Lanvi, large on the snow, with the fox fire behind the tail.
                ZStack {
                    LanviView(pose: pose, size: L.fox, bounceTrigger: bounce)
                        .lanviReaction(reaction, trigger: reactTick)
                        .lanviMood(restingMood)
                        .lanviLookAt(look)
                        .onTapGesture { tapFox() }
                }
                .frame(width: L.fox * 2, height: L.fox * 2)
                .position(x: L.foxCenter.x + entrance, y: L.foxCenter.y)
                // Only moves when Lanvi sets off wandering or comes home; never every frame.
                .animation(.spring(response: 0.7, dampingFraction: 0.8), value: away)
                .accessibilityLabel("Lanvi")
                .accessibilityHint("Shows how Lanvi is growing")

                // What Lanvi says, in one soft bubble above it. Tap to talk.
                speech(L)

                if let pop {
                    HomeXPPop(amount: pop.xpGained)
                        .id(pop.id)
                        // Floats up from the top of the head to sit centred above it.
                        .position(x: L.foxCenter.x, y: L.foxTop + 16)
                        .allowsHitTesting(false)
                }

                // Top corners: Help, and the day pill.
                HStack {
                    Button { open(.help) } label: { Image(systemName: "lifepreserver.fill") }
                        .buttonStyle(HomeCornerRoundStyle())
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
                    .animation(.spring(response: 0.55, dampingFraction: 0.8), value: store.todayThing)
                    .frame(width: w - 48)
                    .homeZoomSource("today", in: zoom)
                    .position(x: w / 2, y: L.buttonY)
                    .opacity(arrived && !showGrowth ? 1 : 0)
                    .offset(y: arrived ? 0 : 24)


                if let stage = store.grewUp {
                    HomeGrowUpMoment(stage: stage) { store.grewUp = nil }
                        .transition(.opacity)
                        .zIndex(10)
                }
            }
            .onAppear { size = geo.size; insets = geo.safeAreaInsets }
            .onChange(of: geo.size) { _, s in size = s; insets = geo.safeAreaInsets }
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
            pose = .cheer
            react(.happy)
            haptic &+= 1
            Task {
                try? await Task.sleep(for: .seconds(2.2))
                if !celebrating { settle() }
            }
        }
        .onChange(of: isDoneToday) { _, _ in if !celebrating { settle() } }
        .onChange(of: bubbleText) { _, _ in glanceAtBubble() }
        .onChange(of: scenePhase) { old, phase in
            if phase == .active, old == .background { welcomeBack() }
        }
        .onAppear {
            #if DEBUG
            FrameMeter.shared.start()
            #endif
            if store.wandering?.state == .back { runIn() } else { settle() }
            withAnimation(.spring(response: 0.7, dampingFraction: 0.82).delay(0.25)) { arrived = true }
        }
        .task { await runDemo() }
    }

    // MARK: Pieces

    private func speech(_ L: Layout) -> some View {
        let top: CGFloat = L.compact ? 64 : 80
        // Clear air above the ear tips (and the little marks) in every pose.
        // During the reward the bubble lifts a little to make room for "+10 XP".
        let lift: CGFloat = pop != nil ? 58 : 0
        let bottom = max(away ? L.foxCenter.y - L.fox / 2 - 14 : L.foxTop - 14 - lift, top + 90)
        return VStack {
            Spacer(minLength: 0)
            Button { open(.chat) } label: {
                HomeSpeechBubble(text: bubbleText, pointAt: away ? 0.78 : 0.5, size: L.compact ? 20 : 21)
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

    /// Solid white pill, navy type: reads on the pale dawn and the deep night alike.
    private var dayPill: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkle")
                .font(.system(size: 14, weight: .black))
                .foregroundStyle(Theme.brand)
            Text("Day \(store.daysTogether)")
                .font(Theme.rounded(17, .heavy))
                .foregroundStyle(Theme.ink)
                .contentTransition(.numericText(value: Double(store.daysTogether)))
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .background(Capsule().fill(Color(hex: 0xFFFEFB)).shadow(color: Theme.ink.opacity(0.12), radius: 8, y: 3))
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
                Button("Hear my story") { openStory() }
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
        case .story(let story):
            HomeStoryScreen(story: story, autoAnswer: storyAutoAnswer,
                            onAnswer: { await store.answerStory($0) }) {
                if case .story = cover { cover = nil }
            }
        case .mind:
            HomeMindScreen { cover = nil }
        case .chat:
            HomeChatScreen(onClose: { cover = nil },
                           onHelp: { cover = .help },
                           onActivity: { cover = .activity($0) })
        }
    }

    // MARK: State for the scene

    private var away: Bool { store.wandering?.state == .away && !celebrating }

    /// The mood Lanvi holds at rest: sleepy late at night, otherwise the pose decides.
    private var restingMood: LanviMood? {
        guard !celebrating, store.wandering?.state != .back else { return nil }
        let hour = Calendar.current.component(.hour, from: store.now)
        return (hour >= 22 || hour < 5) ? .sleepy : nil
    }

    /// Play one reaction on the living fox (the idle keeps going underneath).
    private func react(_ mood: LanviMood) {
        reaction = mood
        reactTick &+= 1
    }

    /// Eyes up to the bubble when Lanvi says something new, then back.
    private func glanceAtBubble() {
        look = UnitPoint(x: 0.5, y: -0.35)
        Task {
            try? await Task.sleep(for: .seconds(1.3))
            look = nil
        }
    }
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

    private func openStory() {
        if let s = store.wandering?.story { open(.story(s)) }
    }

    private func openAfterSheet(_ c: Cover) {
        sheet = nil
        Task {
            try? await Task.sleep(for: .milliseconds(380))
            cover = c
        }
    }

    /// The resting pose for the state Lanvi is in and the time of day. Pose, mood and
    /// look-at are set plainly: the puppet eases its own parts on its own clock, so
    /// Home never wraps them in a second animation.
    private func settle() {
        let next: LanviPose
        switch store.wandering?.state {
        case .away: next = .run
        case .back: next = .surprised
        default:
            if isDoneToday { next = .love }
            else {
                let hour = Calendar.current.component(.hour, from: store.now)
                switch store.dayPart {
                case .morning: next = .cheer        // a morning stretch
                case .day, .evening: next = .curious
                case .night: next = (hour >= 22 || hour < 5) ? .love : .curious   // late: curled up and cosy
                }
            }
        }
        if next != pose {
            pose = next
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
            pose = .surprised
            react(.surprised)
            haptic &+= 1
        }
    }

    /// Opening the app again: Lanvi is pleased to see you.
    private func welcomeBack() {
        guard !celebrating, store.wandering?.state != .away else { return }
        pose = .love
        react(.happy)
        Task {
            try? await Task.sleep(for: .seconds(1.8))
            if !celebrating { settle() }
        }
    }

    /// The reward: the growth bar slides up, Lanvi hops for joy, "+10 XP" pops,
    /// the bar fills and the day count ticks. No light effects on the fox.
    private func celebrate(_ c: HomeCelebration) {
        celebrating = true
        if c.xpGained > 0 {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) { showGrowth = true }
        }
        Task {
            try? await Task.sleep(for: .milliseconds(c.xpGained > 0 ? 350 : 150))
            react(.happy)
            haptic &+= 1
            if c.xpGained > 0 {
                withAnimation(.spring(response: 0.45, dampingFraction: 0.6)) { pop = c }
            }
            try? await Task.sleep(for: .seconds(2.8))
            withAnimation(.easeOut(duration: 0.3)) { pop = nil }
            withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) { showGrowth = false }
            try? await Task.sleep(for: .seconds(0.8))
            while store.grewUp != nil { try? await Task.sleep(for: .milliseconds(200)) }
            celebrating = false
            store.celebration = nil
            settle()
        }
    }

    // MARK: Demo and screenshots

    /// `-demo` walk-through (Home part): today's thing, Breathe with Lanvi, the
    /// reward, Lanvi grows up, today is done, Lanvi runs off to wander and comes
    /// back with a story, then a word in the chat. `-demoPlay <focus|breathing|checkin>` sends one
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
            case "story": openStory()
            case "mind": open(.mind)
            case "chat": open(.chat)
            case "more": sheet = .more
            case "growth": sheet = .growth
            default: if let k = ActivityKind(rawValue: what) { open(.activity(k)) }
            }
        }
        if let what = value("-demoPlay"), let kind = ActivityKind(rawValue: what) {
            // `-demoDelay 6`: a few seconds of idle life first (for recordings).
            try? await Task.sleep(for: .seconds(value("-demoDelay").flatMap(Double.init) ?? 0.9))
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
        openStory()
        while cover != nil { try? await Task.sleep(for: .milliseconds(200)) }
        try? await Task.sleep(for: .seconds(2))
        // A short word with Lanvi.
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
