import SwiftUI

/// Home: the scene is the screen. The sky and the snow edge to edge, Lanvi
/// large on the snow with the tail glow as real light, one line of speech
/// above, and one action pinned above the home bar. Everything else is small
/// and in the corners: Help top left, the day pill top right.
struct HomeView: View {
    var demo: Bool

    @Environment(AppStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase

    private enum Cover: Identifiable {
        case activity(ActivityKind), help, mind, chat
        var id: String {
            switch self {
            case .activity(let k): return "activity-\(k.rawValue)"
            case .help: return "help"
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
    /// Home's layout: Lanvi's place comes from the shared `FoxStage`.
    private struct Layout {
        let stage: FoxStage
        var size: CGSize { stage.size }
        var compact: Bool { stage.compact }
        var fox: CGFloat { stage.fox }
        var feetY: CGFloat { stage.feetY }
        var buttonY: CGFloat { stage.buttonY }
        var foxCenter: CGPoint { stage.foxCenter }
        var foxTop: CGFloat { stage.foxTop }

        init(size: CGSize, insets: EdgeInsets, away: Bool) {
            stage = FoxStage(size: size, insets: insets)
        }
    }

    @State private var cover: Cover?
    @State private var sheet: Sheet?
    @State private var pose: LanviPose = .curious
    @State private var pop: HomeCelebration?
    @State private var celebrating = false
    @State private var showGrowth = false
    @State private var helpBlock: API.CrisisBlock?
    @State private var size: CGSize = .zero
    @State private var insets = EdgeInsets()
    @State private var haptic = 0
    @State private var arrived = false
    // The living fox: one-off reactions and where it looks.
    @State private var reaction: LanviMood = .happy
    @State private var reactTick = 0
    @State private var look: UnitPoint?
    /// The mouth Lanvi shows while saying a new line (nil = the puppet decides).
    @State private var mouth: MouthShape?
    /// `-bubbleTest`: Lanvi's line changes three times (recordings of the bubble).
    @State private var testLine: String?
    /// What the chat grows out of: the bubble or the round chat button.
    /// A screen to open once the sheet on top has gone.

    var body: some View {
        // Home itself never moves for a keyboard; what is presented over it
        // (the chat) sits beside it and does make room for the keyboard.
        ZStack {
            home
                .ignoresSafeArea(.keyboard)
                // While anything is presented over Home, Home takes no touches at all.
                .allowsHitTesting(cover == nil && sheet == nil)
            // ONE way to present anything over Home: it rises from the bottom on one
            // spring, over one scrim, and goes back down the same way. Home underneath
            // never changes, scales, blurs or snapshots while it moves.
            LanviOverlayHost(
                screen: cover.map { c in AnyView(coverContent(c)) },
                screenID: cover?.id,
                panel: sheet.map { s in AnyView(sheetContent(s)) },
                panelID: sheet?.id,
                onClosePanel: { sheet = nil })
        }
    }

    private var home: some View {
        #if DEBUG
        let _ = FrameMeter.count("Home")
        #endif
        return GeometryReader { geo in
            let w = geo.size.width
            let L = Layout(size: geo.size, insets: geo.safeAreaInsets, away: away)

            ZStack(alignment: .top) {
                PaintedWorld(scene: store.worldScene)

                // Lanvi, settled in the snow of the clearing (the shared fox layout).
                GroundedFox(stage: L.stage, scene: store.worldScene) {
                    LanviView(pose: pose, size: L.fox)
                        // Lanvi leaves the snow only for the reward after an activity.
                        .lanviHops(celebrating)
                        .lanviReaction(reaction, trigger: reactTick)
                        .lanviMood(restingMood)
                        .lanviLookAt(look)
                        .lanviMouth(mouth)
                        // A tap is only the puppet's own touch reaction; growth opens from the Day pill.
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Lanvi")
                .accessibilityIdentifier("home.fox")

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
                        .accessibilityLabel("Help")
                    if store.mode == .live, store.link == .offline {
                        Image(systemName: "icloud.slash.fill")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(Theme.inkSecondary)
                            .padding(.leading, 8)
                            .accessibilityLabel("Offline. Your activities are saved and sent later.")
                    }
                    Spacer()
                    Button { sheet = .growth } label: { dayPill }
                        .buttonStyle(SpeechPressStyle())
                        .accessibilityIdentifier("home.day")
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
                // When today's thing changes, the row swaps by fading at a fixed size,
                // so no button ever animates its width.
                ZStack {
                    actions
                        .id(actionsKey)
                        .transition(.opacity)
                }
                .frame(width: w - 48, height: 60)
                .animation(LanviTiming.swap, value: actionsKey)
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
        .onChange(of: store.celebration) { _, c in
            if let c { celebrate(c) }
        }
        // The moment a game or activity hands back: Lanvi is glad at once.
        .onChange(of: store.cheer) { _, _ in
            react(.happy)
            haptic &+= 1
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
        #if DEBUG
        // PerfProbe: name each change a tap asks for, so it can be timed, and the light.
        .onChange(of: store.worldScene.rawValue, initial: true) { _, w in PerfProbe.shared.world = w }
        .onChange(of: cover?.id) { _, id in FrameMeter.mark("cover \(id ?? "closed")") }
        .onChange(of: sheet?.id) { _, id in FrameMeter.mark("sheet \(id ?? "closed")") }
        .onChange(of: store.chat.messages.count) { _, n in FrameMeter.mark("chat messages \(n)") }
        .onChange(of: actionsKey) { _, k in FrameMeter.mark("today \(k)") }
        #endif
        .onAppear {
            #if DEBUG
            FrameMeter.shared.start()
            PerfProbe.shared.homeAppeared()
            #endif
            settle()
            withAnimation(LanviTiming.screen.delay(0.2)) { arrived = true }
        }
        .task { await runDemo() }
    }

    // MARK: Pieces

    /// Lanvi's line in its speech bubble: up and to the right of the head, the
    /// tail pointing down to the face. During the reward it lifts a little to make
    /// room for "+10 XP" (an offset, so nothing is laid out again while it moves).
    private func speech(_ L: Layout) -> some View {
        let lift: CGFloat = pop != nil ? 58 : 0
        let target = away
            ? CGPoint(x: L.foxCenter.x - L.fox * 0.1, y: L.foxCenter.y - L.fox * 0.55)
            : L.stage.speechTarget
        return HomeSpeech(text: bubbleText, target: target, width: L.size.width, mouth: $mouth) {
            open(.chat)
        }
            .offset(y: -lift)
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
            mainRow(TodayCopy.button(k), short: TodayCopy.shortButton(k)) { open(.activity(k)) }
        case .realWorld(let s):
            // The same row as always (More and the chat at the ends), the two answers between.
            HStack(spacing: 10) {
                moreButton
                Button("I did it") { Task { await store.answerSuggestion(s, didIt: true) } }
                    .buttonStyle(HomePrimaryStyle(padding: 8))
                Button("Not today") { Task { await store.answerSuggestion(s, didIt: false) } }
                    .buttonStyle(HomePrimaryStyle(fill: .white, edge: Theme.line, text: Theme.brand, padding: 8))
                chatButton
            }
        case .done:
            // Done for today is never a dead end: the same row as before, and the
            // game can always be played again.
            mainRow("Play again · 90 sec", short: "Play again") { open(.activity(.focus)) }
        }
    }

    /// Home's row: More, the one real button, the chat. The same shape in every state.
    private func mainRow(_ label: String, short: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            moreButton
            Button(action: action) {
                // The full words when they fit; a shorter form on narrow phones,
                // never a label cut off with "…".
                ViewThatFits(in: .horizontal) {
                    Text(label).fixedSize()
                    Text(short).fixedSize()
                    Text(short)
                }
            }
            .buttonStyle(HomePrimaryStyle())
            .accessibilityIdentifier("home.primary")
            chatButton
        }
    }

    private var moreButton: some View {
        Button { sheet = .more } label: { Image(systemName: "square.grid.2x2.fill") }
            .buttonStyle(HomeQuietRoundStyle())
            .accessibilityLabel("More with Lanvi")
    }

    private var chatButton: some View {
        Button {
            open(.chat)
        } label: { Image(systemName: "bubble.left.fill") }
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
        case .mind:
            HomeMindScreen { cover = nil }
        case .chat:
            HomeChatScreen(onClose: { cover = nil },
                           onHelp: { cover = .help },
                           onActivity: { cover = .activity($0) })
        }
    }

    // MARK: State for the scene

    /// Lanvi never leaves Home (the captain cut the wandering): always home, always full size.
    private var away: Bool { false }

    /// The mood Lanvi holds at rest: sleepy late at night, otherwise the pose decides.
    private var restingMood: LanviMood? {
        guard !celebrating else { return nil }
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
        #if DEBUG
        FrameMeter.mark("glance at bubble")
        #endif
        look = UnitPoint(x: 0.8, y: -0.25)
        Task {
            try? await Task.sleep(for: .seconds(1.3))
            look = nil
        }
    }
    private var isDoneToday: Bool { if case .done = store.todayThing { return true } else { return false } }

    /// Which view the current row of actions is, so it swaps as a whole.
    private var actionsKey: String {
        switch store.todayThing {
        case .game(let k): return "game-\(k.rawValue)"
        case .realWorld(let s): return "real-\(s.id)"
        case .done: return "done"
        }
    }

    /// Lanvi's one line. When today's thing is done, it says so.
    /// In the care voice: Lanvi asks for today's thing; after an activity, the
    /// server's line; when it is done, glad you came; never guilt, never a countdown.
    private var bubbleText: String {
        if let testLine { return testLine }
        if celebrating { return store.line.isEmpty ? " " : store.line }
        if case .done(let d) = store.todayThing {
            return d.restful ? "That's all right. I'm here." : "That was our thing for today. I'm glad you came."
        }
        if store.backAfterGap { return "I kept a spot warm for you." }
        if let s = store.suggestion { return s.text }          // the server's own words
        if case .game(let k) = store.todayThing { return TodayCopy.ask(k, firstTime: store.firstTime) }
        return store.line.isEmpty ? " " : store.line
    }

    // MARK: Moments

    private func open(_ c: Cover) {
        #if DEBUG
        if demo { print("lanvi-demo: open \(c.id), cover now \(cover?.id ?? "none")") }
        #endif
        cover = c
    }

    /// From a panel to a screen: the screen rises over the panel in one move.
    private func openAfterSheet(_ c: Cover) {
        cover = c
        sheet = nil
    }

    @ViewBuilder private func sheetContent(_ s: Sheet) -> some View {
        switch s {
        case .more:
            HomeMoreSheet(onButton: { if case .game(let k) = store.todayThing { return k } else { return nil } }()) { k in
                openAfterSheet(.activity(k))
            }
        case .growth:
            HomeGrowthSheet(stage: store.stage, xp: store.xp, stageStart: store.stageRange.start,
                            nextStageAt: store.stageRange.next, daysTogether: store.daysTogether) {
                openAfterSheet(.mind)
            }
        }
    }

    /// The resting pose for the state Lanvi is in and the time of day. Pose, mood and
    /// look-at are set plainly: the puppet eases its own parts on its own clock, so
    /// Home never wraps them in a second animation.
    private func settle() {
        let next: LanviPose
        if isDoneToday { next = .love }
        else {
            let hour = Calendar.current.component(.hour, from: store.now)
            switch store.dayPart {
            case .morning: next = .cheer        // a morning stretch
            case .day, .evening: next = .curious
            case .night: next = (hour >= 22 || hour < 5) ? .love : .curious   // late: curled up and cosy
            }
        }
        if next != pose {
            pose = next
        }
    }

    /// Opening the app again: Lanvi is pleased to see you.
    private func welcomeBack() {
        guard !celebrating else { return }
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
        #if DEBUG
        FrameMeter.mark("reward start")
        #endif
        celebrating = true
        if c.xpGained > 0 {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) { showGrowth = true }
        }
        Task {
            try? await Task.sleep(for: .milliseconds(c.xpGained > 0 ? 350 : 150))
            #if DEBUG
            FrameMeter.mark("happy + pop")
            #endif
            react(.happy)
            haptic &+= 1
            if c.xpGained > 0 {
                withAnimation(.spring(response: 0.45, dampingFraction: 0.6)) { pop = c }
            }
            try? await Task.sleep(for: .seconds(2.8))
            #if DEBUG
            FrameMeter.mark("pop away")
            #endif
            withAnimation(.easeOut(duration: 0.3)) { pop = nil }
            withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) { showGrowth = false }
            try? await Task.sleep(for: .seconds(0.8))
            while store.grewUp != nil { try? await Task.sleep(for: .milliseconds(200)) }
            #if DEBUG
            FrameMeter.mark("settle")
            #endif
            celebrating = false
            store.celebration = nil
            settle()
        }
    }

    // MARK: Demo and screenshots

    /// `-demo` walk-through (Home part): today's thing, Breathe with Lanvi, the
    /// reward, Lanvi grows up, today is done, then a word in the chat. `-demoPlay <focus|breathing|checkin>` sends one
    /// activity at once; `-demoOpen <help|mind|chat|more|growth|focus|breathing|checkin>`
    /// opens that screen.
    private func runDemo() async {
        await store.start()
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-bubbleTest") {
            for line in ["Hi!", "The ice is thick today, and the lights are waiting behind it. Help me break it?", "Sit with me a minute?"] {
                try? await Task.sleep(for: .seconds(2.2))
                testLine = line
            }
            return
        }
        func value(_ key: String) -> String? {
            guard let i = args.firstIndex(of: key), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        if let what = value("-demoOpen") {
            try? await Task.sleep(for: .milliseconds(600))
            switch what {
            case "help": open(.help)
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
        if args.contains("-flow") { await runFlow(); return }
        if args.contains("-feel") { await runFeel(); return }
        guard demo else { return }

        try? await Task.sleep(for: .seconds(3))
        open(.activity(.focus))
        try? await Task.sleep(for: .seconds(6))
        cover = nil
        try? await Task.sleep(for: .milliseconds(700))
        await store.finish(Self.sample(.focus), kind: .focus)
        // XP, glow, growing up, done for today.
        while celebrating || store.celebration != nil { try? await Task.sleep(for: .milliseconds(200)) }
        try? await Task.sleep(for: .seconds(3))
        // A short word with Lanvi.
        open(.chat)
        while cover != nil { try? await Task.sleep(for: .milliseconds(200)) }
        try? await Task.sleep(for: .seconds(2))
        settle()
    }

    /// `-feel`: opens and closes every overlay twice, at a person's pace, for
    /// every-frame checks of the transitions. Prints `FEEL <step> <time>`.
    private func runFeel() async {
        func wait(_ s: Double) async { try? await Task.sleep(for: .seconds(s)) }
        func mark(_ n: String) { print(String(format: "FEEL %@ %.3f", n, Date().timeIntervalSince1970)) }
        await wait(2.5)
        for round in 1...2 {
            mark("chat.open.\(round)"); open(.chat); await wait(1.6)
            mark("chat.close.\(round)"); cover = nil; await wait(1.4)
            mark("help.open.\(round)"); open(.help); await wait(1.6)
            mark("help.close.\(round)"); cover = nil; await wait(1.4)
            mark("more.open.\(round)"); sheet = .more; await wait(1.6)
            mark("more.close.\(round)"); sheet = nil; await wait(1.4)
            mark("growth.open.\(round)"); sheet = .growth; await wait(1.6)
            mark("growth.close.\(round)"); sheet = nil; await wait(1.4)
            mark("more.pick.\(round)"); sheet = .more; await wait(1.4)
            mark("more.to.activity.\(round)"); openAfterSheet(.activity(.breathing)); await wait(1.8)
            mark("activity.close.\(round)"); cover = nil; await wait(1.6)
        }
        mark("end")
    }

    /// `-flow`: a short tour of Home, opening and closing each screen and sheet.
    private func runFlow() async {
        func wait(_ s: Double) async { try? await Task.sleep(for: .seconds(s)) }
        await wait(3)
        open(.chat)
        await wait(3)
        cover = nil
        await wait(1.8)
        sheet = .more
        await wait(2.2)
        sheet = nil
        await wait(1.6)
        sheet = .growth
        await wait(2.2)
        sheet = nil
        await wait(1.6)
        open(.help)
        await wait(2.4)
        cover = nil
        await wait(2)
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
            .sensoryFeedback(.impact(weight: .light), trigger: configuration.isPressed) { wasDown, isDown in isDown && !wasDown }
    }
}
