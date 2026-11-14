import SwiftUI

/// The evening check-in: (yesterday's plan, if any) → three good things → one small thing for tomorrow → goodnight.
/// Calls `onDone(result)` from the goodnight step, or `onDone(nil)` when the person leaves early.
///
/// It happens in Lanvi's world at night, not on a form: the choices are chunky night tiles
/// that press down and light up, each good thing becomes a little light, the aurora grows
/// with them, and Lanvi watches and reacts as you pick. At goodnight the lights drift up
/// into the sky and Lanvi yawns.
struct CheckinView: View {
    let options: CheckinOptions
    let askAboutPlan: CheckinPlanQuestion?
    let onDone: (CheckinResult?) -> Void
    /// Shows a Help chip in the top bar when set (the app wires it to its help screen).
    var onHelp: (() -> Void)?

    init(options: CheckinOptions, askAboutPlan: CheckinPlanQuestion?, onDone: @escaping (CheckinResult?) -> Void) {
        self.options = options
        self.askAboutPlan = askAboutPlan
        self.onDone = onDone
        _step = State(initialValue: askAboutPlan == nil ? .goodThings : .planQuestion)
    }

    enum Step: Int, Comparable {
        case planQuestion, goodThings, plan, goodnight
        static func < (a: Step, b: Step) -> Bool { a.rawValue < b.rawValue }

        /// The step's name for game moments.
        var moment: GameCheckinStep {
            switch self {
            case .planQuestion: .planQuestion
            case .goodThings: .goodThings
            case .plan: .plan
            case .goodnight: .goodnight
            }
        }
    }

    enum TypingFor { case goodThing, plan }

    @State private var step: Step
    @State private var forward = true
    @State private var planDone: CheckinPlanDone = .notAsked
    @State private var goodThings: [CheckinItem] = []
    @State private var plan: CheckinItem?
    @State private var typing: TypingFor?
    @State private var draft = ""
    @State private var pose: LanviPose = .curious
    @State private var bounce = 0
    @State private var reaction: LanviMood = .happy
    @State private var reactTick = 0
    @State private var look: UnitPoint?
    @State private var lookToken = 0
    @State private var nudge = 0
    @State private var startedAt = Date()
    @State private var finished = false
    @State private var appeared = false
    @FocusState private var fieldFocused: Bool

    private var steps: [Step] { askAboutPlan == nil ? [.goodThings, .plan, .goodnight] : [.planQuestion, .goodThings, .plan, .goodnight] }
    private var progress: CGFloat {
        let i = steps.firstIndex(of: step) ?? 0
        return CGFloat(i + 1) / CGFloat(steps.count)
    }

    /// The evening aurora: faint at first, a little fuller with each good thing, full at goodnight.
    private var auroraLevel: Double {
        step == .goodnight ? 0.95 : 0.16 + 0.17 * Double(goodThings.count) + (plan == nil ? 0 : 0.1)
    }

    /// Where things sit for the current step, in full-screen points.
    private struct Frame {
        var fox: CGFloat
        var feet: CGFloat
        var compact: Bool
        var foxTop: CGFloat { feet - fox }
    }

    private func frame(_ s: GameStage) -> Frame {
        let compact = s.compact
        let buttonsTop = s.buttonY - 27
        switch step {
        case .planQuestion:
            let fox: CGFloat = compact ? 140 : 196
            let reserve: CGFloat = planDone == .notAsked ? 54 + 12 + 54 + 16 : 54 + 22
            return Frame(fox: fox, feet: s.feet(fox: fox, reserve: reserve), compact: compact)
        case .goodThings, .plan:
            let fox: CGFloat = compact ? 112 : 150
            let feet = compact ? buttonsTop - 6 : min(s.hollow.y + 5, buttonsTop - 14)
            return Frame(fox: fox, feet: feet, compact: compact)
        case .goodnight:
            let fox: CGFloat = compact ? 150 : 206
            return Frame(fox: fox, feet: s.feet(fox: fox, reserve: 54 + 22), compact: compact)
        }
    }

    var body: some View {
        GeometryReader { geo in
            let s = GameStage(geo)
            let f = frame(s)

            ZStack(alignment: .topLeading) {
                GameBackdrop(scene: .night, stage: s)

                GameAuroraView(level: auroraLevel)
                    .frame(width: s.width, height: s.height)
                    .animation(.easeInOut(duration: 1.4), value: auroraLevel)

                if step == .goodnight {
                    RisingLights(originY: f.feet - 14, ceiling: s.top + 90, width: s.width, count: max(3, goodThings.count * 2 + 2))
                        .transition(.opacity)
                }

                LanviView(pose: pose, size: f.fox, bounceTrigger: bounce)
                    .lanviReaction(reaction, trigger: reactTick)
                    .lanviLookAt(look)
                    .lanviMood(typing != nil ? .listening : nil)
                    .frame(width: f.fox, height: f.fox)
                    .position(x: s.width / 2, y: f.feet - f.fox / 2)
                    .onTapGesture { react(pose) }
                    .accessibilityHidden(true)

                Group {
                    stepContent(s, f)
                        .id(step)
                        .transition(.asymmetric(
                            insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                            removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity)))

                    topBar(s)
                }
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 14)

                if let typing {
                    TypingCard(
                        prompt: typing == .goodThing ? "A good thing from today" : "A small thing for tomorrow",
                        placeholder: typing == .goodThing ? "A few words" : "Something nice and easy",
                        draft: $draft,
                        focused: $fieldFocused,
                        onAdd: commitDraft,
                        onCancel: closeTyping,
                        topInset: s.top)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(2)
                }
            }
            .frame(width: s.width, height: s.height)
            .ignoresSafeArea()
            .animation(.spring(response: 0.55, dampingFraction: 0.84), value: step)
            .animation(.spring(response: 0.5, dampingFraction: 0.84), value: planDone)
        }
        .ignoresSafeArea(.keyboard)
        .sensoryFeedback(.selection, trigger: goodThings)
        .sensoryFeedback(.selection, trigger: plan)
        .sensoryFeedback(.warning, trigger: nudge)
        .sensoryFeedback(.success, trigger: finished)
        .onAppear {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.86).delay(0.1)) { appeared = true }
        }
        .task {
            GameMoments.emit(.checkinStarted)
            GameMoments.emit(.checkinStep(step.moment))
            await debugShot()
        }
    }

    // MARK: Top bar

    private func topBar(_ s: GameStage) -> some View {
        HStack(spacing: 14) {
            GameCloseButton(label: "Leave the check-in") {
                GameMoments.emit(.checkinEnded(finished: false))
                onDone(nil)
            }
            CheckinProgress(progress: progress)
            if let onHelp {
                Button(action: onHelp) {
                    HStack(spacing: 6) {
                        Image(systemName: "lifepreserver.fill")
                        Text("Help")
                    }
                    .font(Theme.rounded(15, .heavy))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .frame(height: 36)
                }
                .buttonStyle(CheckinGlassPillStyle())
            }
        }
        .padding(.horizontal, 20)
        .frame(width: s.width)
        .position(x: s.width / 2, y: s.barY)
        .opacity(typing == nil ? 1 : 0)
    }

    // MARK: Steps

    @ViewBuilder
    private func stepContent(_ s: GameStage, _ f: Frame) -> some View {
        switch step {
        case .planQuestion: planQuestion(s, f)
        case .goodThings: goodThingsStep(s, f)
        case .plan: planStep(s, f)
        case .goodnight: goodnight(s, f)
        }
    }

    private func planQuestion(_ s: GameStage, _ f: Frame) -> some View {
        let label = askAboutPlan?.label ?? ""
        return ZStack(alignment: .topLeading) {
            VStack(spacing: f.compact ? 12 : 18) {
                switch planDone {
                case .notAsked:
                    Text("Yesterday you planned")
                        .font(Theme.rounded(17, .bold))
                        .foregroundStyle(CheckinEvening.skyText)
                    PlanTicket(label: label, icon: icon(forPlan: askAboutPlan?.planId))
                    Text("Did it happen?")
                        .font(Theme.rounded(f.compact ? 28 : 32, .heavy))
                        .foregroundStyle(.white)
                case .yes:
                    replyText(title: "Yay, you did it!", body: "\(label). That was a kind thing to do for yourself.", f)
                case .no:
                    replyText(title: "That's okay.", body: "Some days go another way. You're here now, and that counts.", f)
                }
            }
            .gameLegible(GameInk.sky(.night))
            .frame(width: s.width - 48)
            .position(x: s.width / 2, y: (s.belowBar + f.foxTop) / 2 + 4)

            bottomButtons(s) {
                if planDone == .notAsked {
                    Button("Yes, it did") { answerPlan(.yes) }
                        .buttonStyle(ChunkyButtonStyle())
                    Button("Not this time") { answerPlan(.no) }
                        .buttonStyle(CheckinQuietButtonStyle())
                } else {
                    Button("Continue") { go(to: .goodThings) }
                        .buttonStyle(ChunkyButtonStyle())
                        .transition(.scale(scale: 0.9).combined(with: .opacity))
                }
            }
        }
        .frame(width: s.width, height: s.height)
    }

    /// Buttons stacked from the bottom up, the last one on the usual primary spot.
    private func bottomButtons<Content: View>(_ s: GameStage, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 14) { content() }
            .padding(.horizontal, 24)
            .frame(width: s.width, height: s.buttonY + 27, alignment: .bottom)
    }

    private func replyText(title: String, body: String, _ f: Frame) -> some View {
        VStack(spacing: 10) {
            Text(title)
                .font(Theme.rounded(f.compact ? 30 : 34, .heavy))
                .foregroundStyle(.white)
            Text(body)
                .font(Theme.rounded(18, .semibold))
                .foregroundStyle(CheckinEvening.skyText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .transition(.scale(scale: 0.92).combined(with: .opacity))
    }

    private func goodThingsStep(_ s: GameStage, _ f: Frame) -> some View {
        let full = goodThings.count >= 3
        let subtitle: String = switch goodThings.count {
        case 0: "Small things count. Tap up to three."
        case 1: "Nice. That's one little light."
        case 2: "Lovely. One more, if you like."
        default: "Three little lights for today."
        }
        let typed = goodThings.compactMap(\.typedText)
        return tileStep(s, f, title: "Three good things today", subtitle: subtitle, showTray: true) {
            Button { full ? fullNudge() : openTyping(.goodThing) } label: {
                CheckinTileLabel(text: "Write my own", symbol: "plus", selected: false)
            }
            .buttonStyle(CheckinTileStyle(selected: false, dimmed: full, dashed: true, compact: f.compact))
            ForEach(Array(typed.enumerated()), id: \.element) { i, text in
                Button { toggleGood(.text(text), at: 1 + i) } label: {
                    CheckinTileLabel(text: text, symbol: "pencil", selected: true)
                }
                .buttonStyle(CheckinTileStyle(selected: true, compact: f.compact))
            }
            ForEach(Array(options.goodThings.enumerated()), id: \.element.id) { i, option in
                let on = goodThings.contains(.catalog(option.id))
                Button { toggleGood(.catalog(option.id), at: 1 + typed.count + i) } label: {
                    CheckinTileLabel(text: option.label, symbol: icon(forGood: option.id), selected: on)
                }
                .buttonStyle(CheckinTileStyle(selected: on, dimmed: full && !on, compact: f.compact))
            }
        } button: {
            if goodThings.isEmpty {
                Button("Skip for tonight") { go(to: .plan) }.buttonStyle(CheckinQuietButtonStyle())
            } else {
                Button("Continue") { go(to: .plan) }.buttonStyle(ChunkyButtonStyle())
            }
        }
    }

    private func planStep(_ s: GameStage, _ f: Frame) -> some View {
        let subtitle = plan == nil ? "Something nice and easy. I'll ask you tomorrow." : "Good one. I'll ask how it went."
        let typed = plan?.typedText
        return tileStep(s, f, title: "One small thing for tomorrow", subtitle: subtitle, showTray: false) {
            Button { openTyping(.plan) } label: {
                CheckinTileLabel(text: "Write my own", symbol: "plus", selected: false)
            }
            .buttonStyle(CheckinTileStyle(selected: false, dashed: true, compact: f.compact))
            if let typed {
                Button { togglePlan(.text(typed), at: 1) } label: {
                    CheckinTileLabel(text: typed, symbol: "pencil", selected: true)
                }
                .buttonStyle(CheckinTileStyle(selected: true, compact: f.compact))
            }
            ForEach(Array(options.plans.enumerated()), id: \.element.id) { i, option in
                let on = plan == .catalog(option.id)
                Button { togglePlan(.catalog(option.id), at: (typed == nil ? 1 : 2) + i) } label: {
                    CheckinTileLabel(text: option.label, symbol: icon(forPlan: option.id), selected: on)
                }
                .buttonStyle(CheckinTileStyle(selected: on, compact: f.compact))
            }
        } button: {
            if plan == nil {
                Button("Skip for tonight") { go(to: .goodnight) }.buttonStyle(CheckinQuietButtonStyle())
            } else {
                Button("Continue") { go(to: .goodnight) }.buttonStyle(ChunkyButtonStyle())
            }
        }
    }

    /// A title on the sky, a two-column grid of chunky tiles, Lanvi below them, and one button.
    private func tileStep<Tiles: View, Bottom: View>(_ s: GameStage, _ f: Frame, title: String, subtitle: String, showTray: Bool,
                                                     @ViewBuilder tiles: () -> Tiles,
                                                     @ViewBuilder button: () -> Bottom) -> some View {
        let headerTop = s.belowBar + 2
        let gridTop = headerTop + (f.compact ? 62 : 74)
        let gridHeight = max(120, f.foxTop - 4 - gridTop)
        return ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(Theme.rounded(f.compact ? 24 : 28, .heavy))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                HStack(alignment: .center) {
                    Text(subtitle)
                        .font(Theme.rounded(f.compact ? 15 : 16, .semibold))
                        .foregroundStyle(CheckinEvening.skyText)
                        .lineLimit(2)
                        .contentTransition(.opacity)
                        .animation(.easeInOut(duration: 0.3), value: subtitle)
                    Spacer(minLength: 8)
                    if showTray { CheckinSparkTray(count: goodThings.count) }
                }
            }
            .gameLegible(GameInk.sky(.night))
            .padding(.horizontal, 24)
            .frame(width: s.width, alignment: .leading)
            .offset(y: headerTop)

            ScrollView(.vertical, showsIndicators: false) {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
                          spacing: f.compact ? 9 : 12) { tiles() }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 14)
                    .frame(minHeight: gridHeight, alignment: .center)
            }
            .scrollBounceBehavior(.basedOnSize)
            .mask {
                VStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: 8)
                    Color.black
                    LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 14)
                }
            }
            .frame(width: s.width, height: gridHeight)
            .offset(y: gridTop)

            bottomButtons(s) {
                button()
                    .animation(.spring(response: 0.3, dampingFraction: 0.75), value: goodThings.isEmpty)
                    .animation(.spring(response: 0.3, dampingFraction: 0.75), value: plan == nil)
            }
        }
        .frame(width: s.width, height: s.height, alignment: .topLeading)
    }

    private func goodnight(_ s: GameStage, _ f: Frame) -> some View {
        let body = goodThings.isEmpty
            ? "Thanks for stopping by tonight. Showing up is what counts."
            : "Thanks for telling me about your day. I'll keep those lights safe."
        return ZStack(alignment: .topLeading) {
            VStack(spacing: f.compact ? 10 : 14) {
                Text("Goodnight")
                    .font(Theme.rounded(f.compact ? 40 : 46, .black))
                    .foregroundStyle(.white)
                    .shadow(color: GameAurora.mint.opacity(0.45), radius: 16)
                Text(body)
                    .font(Theme.rounded(f.compact ? 17 : 18, .semibold))
                    .foregroundStyle(CheckinEvening.skyText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                if let plan {
                    TomorrowLine(label: label(for: plan), icon: icon(for: plan))
                        .padding(.top, 4)
                }
            }
            .gameLegible(GameInk.sky(.night))
            .background(GameShade())
            .frame(width: s.width - 48)
            .position(x: s.width / 2, y: (s.belowBar + f.foxTop) / 2 + 6)

            bottomButtons(s) {
                Button("Done", action: finish)
                    .buttonStyle(ChunkyButtonStyle())
            }
        }
        .frame(width: s.width, height: s.height)
    }

    // MARK: Words and icons

    private func label(for item: CheckinItem) -> String {
        switch item {
        case .catalog(let id): options.planLabel(id) ?? options.goodThingLabel(id) ?? id
        case .text(let t): t
        }
    }

    private func icon(for item: CheckinItem) -> String {
        switch item {
        case .catalog(let id): icon(forPlan: id)
        case .text: "pencil"
        }
    }

    /// A small picture for each catalog id, so a tile reads at a glance. Unknown ids get a sparkle.
    private func icon(forGood id: String) -> String {
        switch id {
        case "walked": "figure.walk"
        case "outside": "tree.fill"
        case "good_food": "fork.knife"
        case "talked_to_someone": "bubble.left.and.bubble.right.fill"
        case "music": "music.note"
        case "rested": "bed.double.fill"
        case "got_something_done": "checkmark.seal.fill"
        case "laughed": "face.smiling.inverse"
        case "kind_moment": "heart.fill"
        default: "sparkle"
        }
    }

    private func icon(forPlan id: String?) -> String {
        switch id ?? "" {
        case "walk": "figure.walk"
        case "coffee_outside": "cup.and.saucer.fill"
        case "call_someone": "phone.fill"
        case "music": "music.note"
        case "cook_something": "frying.pan.fill"
        case "daylight": "sun.max.fill"
        case "tidy_one_thing": "sparkles"
        case "rest_early": "moon.zzz.fill"
        case "": "pencil"
        default: "sun.max.fill"
        }
    }

    // MARK: Actions

    private func answerPlan(_ answer: CheckinPlanDone) {
        withAnimation(.spring(response: 0.42, dampingFraction: 0.7)) { planDone = answer }
        if answer == .yes { react(.cheer) } else { play(.happy); glance(nil) }
    }

    private func toggleGood(_ item: CheckinItem, at index: Int? = nil) {
        if goodThings.contains(item) {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { goodThings.removeAll { $0 == item } }
            if goodThings.count < 3 { calm() }
        } else if goodThings.count < 3 {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { goodThings.append(item) }
            if goodThings.count == 3 { react(.cheer) } else { play(.happy) }
            glance(index)
        } else {
            fullNudge()
        }
    }

    private func togglePlan(_ item: CheckinItem, at index: Int? = nil) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { plan = plan == item ? nil : item }
        if plan != nil { play(.happy); glance(index) } else { calm() }
    }

    /// Lanvi looks toward the tile that was just picked (left or right column), then back.
    private func glance(_ index: Int?) {
        lookToken += 1
        let token = lookToken
        let target: UnitPoint? = index.map { UnitPoint(x: $0.isMultiple(of: 2) ? -0.2 : 1.2, y: -0.7) }
        withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) { look = target }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            guard token == lookToken else { return }
            withAnimation(.spring(response: 0.7, dampingFraction: 0.85)) { look = nil }
        }
    }

    /// Back to the curious idle pose, no jump.
    private func calm() {
        withAnimation(.spring(response: 0.42, dampingFraction: 0.75)) { pose = .curious }
    }

    private func fullNudge() {
        nudge += 1
        play(.surprised)
    }

    /// A one-off reaction on top of Lanvi's idle (a hop, a yawn, perked ears).
    private func play(_ mood: LanviMood) {
        reaction = mood
        reactTick += 1
    }

    private func openTyping(_ target: TypingFor) {
        draft = ""
        withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) { typing = target }
        fieldFocused = true
    }

    private func closeTyping() {
        fieldFocused = false
        withAnimation(.spring(response: 0.34, dampingFraction: 0.85)) { typing = nil }
    }

    private func commitDraft() {
        guard let item = CheckinItem.typed(draft), let target = typing else { return }
        closeTyping()
        switch target {
        case .goodThing:
            guard !goodThings.contains(item), goodThings.count < 3 else { return }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { goodThings.append(item) }
            if goodThings.count == 3 { react(.cheer) } else { play(.happy) }
        case .plan:
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { plan = item }
            play(.happy)
        }
    }

    private func go(to next: Step) {
        forward = next > step
        withAnimation(.spring(response: 0.55, dampingFraction: 0.86)) { step = next }
        GameMoments.emit(.checkinStep(next.moment))
        switch next {
        case .planQuestion: react(.curious)
        case .goodThings: react(goodThings.isEmpty ? .curious : .love)
        case .plan: react(plan == nil ? .curious : .love)
        case .goodnight:
            react(.love)
            // A sleepy yawn once the lights have started to rise.
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.4))
                guard step == .goodnight else { return }
                play(.sleepy)
            }
        }
    }

    private func react(_ newPose: LanviPose) {
        if newPose == pose { play(.happy); return }
        withAnimation(.spring(response: 0.42, dampingFraction: 0.62)) { pose = newPose }
    }

    private func finish() {
        finished = true
        GameMoments.emit(.checkinEnded(finished: true))
        let result = CheckinResult(
            goodThings: Array(goodThings.prefix(3)),
            plan: plan,
            planDone: askAboutPlan == nil ? .notAsked : planDone,
            startedAt: startedAt,
            endedAt: Date())
        #if DEBUG
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(result), let json = String(data: data, encoding: .utf8) {
            print("CHECKIN_RESULT \(json)")
        }
        #endif
        onDone(result)
    }
}

// MARK: - Pieces

/// Yesterday's plan, shown as a big raised night tile on the sky.
private struct PlanTicket: View {
    var label: String
    var icon: String

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        HStack(spacing: 14) {
            CheckinIconBubble(symbol: icon, lit: true, size: 44)
            Text(label)
                .font(Theme.rounded(21, .heavy))
                .foregroundStyle(.white)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 14)
        .padding(.leading, 14)
        .padding(.trailing, 24)
        .background(shape.fill(CheckinEvening.tileFill))
        .overlay(shape.strokeBorder(LinearGradient(colors: [GameAurora.mint.opacity(0.8), Theme.aurora.opacity(0.5)],
                                                   startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 2))
        .background(shape.fill(CheckinEvening.tileEdge).offset(y: 5))
        .shadow(color: GameAurora.mint.opacity(0.28), radius: 18)
    }
}

/// Tomorrow's plan on the goodnight step: a small icon and the words, right on the sky.
private struct TomorrowLine: View {
    var label: String
    var icon: String

    var body: some View {
        HStack(spacing: 10) {
            CheckinIconBubble(symbol: icon, lit: true, size: 34)
            (Text("Tomorrow: ").foregroundStyle(CheckinEvening.skyText) + Text(label).foregroundStyle(.white))
                .lineLimit(2)
        }
        .font(Theme.rounded(17, .heavy))
    }
}

/// The text box for "something else". Sits at the top so the keyboard never covers it or its buttons.
private struct TypingCard: View {
    var prompt: String
    var placeholder: String
    @Binding var draft: String
    var focused: FocusState<Bool>.Binding
    var onAdd: () -> Void
    var onCancel: () -> Void
    var topInset: CGFloat

    private var canAdd: Bool { CheckinItem.typed(draft) != nil }
    private var left: Int { CheckinItem.maxTextLength - draft.count }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 26, style: .continuous)
        ZStack(alignment: .top) {
            Color(hex: 0x050B2C).opacity(0.55)
                .onTapGesture(perform: onCancel)

            VStack(alignment: .leading, spacing: 14) {
                Text(prompt)
                    .font(Theme.rounded(22, .heavy))
                    .foregroundStyle(.white)
                    .padding(.trailing, 76)
                TextField("", text: $draft, prompt: Text(placeholder).foregroundStyle(CheckinEvening.skyText.opacity(0.6)), axis: .vertical)
                    .font(Theme.rounded(18, .semibold))
                    .foregroundStyle(.white)
                    .tint(GameAurora.mint)
                    .lineLimit(1...3)
                    .submitLabel(.done)
                    .focused(focused)
                    .padding(.vertical, 14)
                    .padding(.horizontal, 16)
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(hex: 0x0B1546).opacity(0.75)))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(GameAurora.mint.opacity(0.75), lineWidth: 2))
                    .overlay(alignment: .bottomTrailing) {
                        if left <= 20 {
                            Text("\(left)")
                                .font(Theme.rounded(13, .heavy))
                                .foregroundStyle(CheckinEvening.skyText)
                                .padding(8)
                        }
                    }
                    .onChange(of: draft) { _, new in
                        if new.contains("\n") {
                            draft = new.replacingOccurrences(of: "\n", with: " ")
                            onAdd()
                        } else if new.count > CheckinItem.maxTextLength {
                            draft = String(new.prefix(CheckinItem.maxTextLength))
                        }
                    }
                HStack(spacing: 12) {
                    Button("Cancel", action: onCancel)
                        .buttonStyle(CheckinQuietButtonStyle())
                    Button("Add", action: onAdd)
                        .buttonStyle(ChunkyButtonStyle(fill: canAdd ? Theme.brand : Color(hex: 0x3A4E92),
                                                       edge: canAdd ? Theme.brandEdge : Color(hex: 0x23336E),
                                                       text: canAdd ? .white : .white.opacity(0.5)))
                        .disabled(!canAdd)
                        .animation(.easeInOut(duration: 0.2), value: canAdd)
                }
            }
            .padding(20)
            .background(shape.fill(LinearGradient(colors: [Color(hex: 0x2A4192), Color(hex: 0x1C2E73)],
                                                  startPoint: .top, endPoint: .bottom)))
            .overlay(shape.strokeBorder(.white.opacity(0.16), lineWidth: 1.5))
            .background(shape.fill(CheckinEvening.tileEdge).offset(y: 6))
            .overlay(alignment: .topTrailing) {
                LanviView(pose: .curious, size: 84)
                    .lanviMood(.listening)
                    .offset(x: -6, y: -52)
                    .allowsHitTesting(false)
            }
            .padding(.horizontal, 16)
            .padding(.top, topInset + 70)
        }
    }
}

/// Soft motes of light drifting up into the night on the goodnight step: the day's little
/// lights going up to join the aurora. They rise from the snow either side of Lanvi, never from the fox.
private struct RisingLights: View {
    var originY: CGFloat
    var ceiling: CGFloat   // motes fade out before they reach the top
    var width: CGFloat
    var count: Int

    private struct Seed { var x: CGFloat; var phase: Double; var size: CGFloat; var period: Double; var sway: CGFloat }
    private let seeds: [Seed] = [
        Seed(x: -0.36, phase: 0.00, size: 16, period: 6.2, sway: 10),
        Seed(x: 0.38, phase: 0.35, size: 13, period: 7.0, sway: 8),
        Seed(x: -0.42, phase: 0.62, size: 18, period: 6.6, sway: 12),
        Seed(x: 0.43, phase: 0.15, size: 11, period: 5.8, sway: 7),
        Seed(x: -0.30, phase: 0.80, size: 12, period: 7.4, sway: 8),
        Seed(x: 0.33, phase: 0.48, size: 10, period: 5.4, sway: 7),
        Seed(x: 0.40, phase: 0.70, size: 15, period: 6.9, sway: 10),
        Seed(x: -0.39, phase: 0.25, size: 9, period: 6.0, sway: 6),
    ]

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Canvas { ctx, _ in
                for i in 0..<min(count, seeds.count) {
                    let s = seeds[i]
                    let p = GameEase.fract(t / s.period + s.phase)
                    // Eased rise: lifts off gently, floats up, slows as it fades near the top.
                    let rise = CGFloat(GameEase.inOutSine(p)) * max(60, originY - ceiling)
                    let alpha = sin(p * .pi) * 0.95
                    let r = s.size * CGFloat(0.7 + 0.5 * sin(p * .pi))
                    let pt = CGPoint(x: width * (0.5 + s.x) + s.sway * CGFloat(sin(t * 0.9 + Double(i))), y: originY - rise)
                    let tint = i.isMultiple(of: 3) ? GameAurora.violet : (i.isMultiple(of: 2) ? GameAurora.mint : Theme.aurora)
                    CheckinLight.draw(ctx, at: pt, radius: r, color: tint, alpha: alpha)
                }
            }
        }
        .blendMode(.plusLighter)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Preview hook

extension CheckinView {
    /// `-screen checkin` opens the check-in with sample options; `-screen checkin-plan` also asks about yesterday's plan.
    static func preview(_ screen: String?) -> CheckinView {
        CheckinView(options: .sample, askAboutPlan: screen == "checkin-plan" ? .sample : nil) { _ in }
    }
}

// MARK: - Screenshot states (debug builds only)

extension CheckinView {
    /// `-checkinShot <name>` jumps to a state so headless screenshots can show every step.
    fileprivate func debugShot() async {
        #if DEBUG
        guard let shot = UserDefaults.standard.string(forKey: "checkinShot") else { return }
        print("checkin: shown")
        try? await Task.sleep(for: .milliseconds(300))
        switch shot {
        case "plan-yes": answerPlan(.yes)
        case "plan-no": answerPlan(.no)
        case "goods-picked":
            toggleGood(.catalog("walked")); toggleGood(.catalog("music"))
            goodThings.append(.text("Made pancakes with my sister")); react(.cheer)
        case "goods-typing":
            toggleGood(.catalog("outside"))
            try? await Task.sleep(for: .milliseconds(500))
            openTyping(.goodThing)
            try? await Task.sleep(for: .milliseconds(400))
            draft = "Made pancakes with my sister"
        case "tomorrow": go(to: .plan)
        case "tomorrow-picked": go(to: .plan); togglePlan(.catalog("coffee_outside"))
        case "tomorrow-typing":
            go(to: .plan)
            try? await Task.sleep(for: .milliseconds(500))
            openTyping(.plan)
            try? await Task.sleep(for: .milliseconds(400))
            draft = "Text Mia about Saturday"
        case "goodnight":
            goodThings = [.catalog("walked"), .catalog("music"), .text("Made pancakes with my sister")]
            plan = .catalog("coffee_outside")
            go(to: .goodnight)
        case "goodnight-empty": go(to: .goodnight)
        case "demo": await demo()
        default: break
        }
        #endif
    }

    #if DEBUG
    /// Walks the whole flow through the same actions the buttons call, types one item, and prints the result.
    fileprivate func demo() async {
        func wait(_ s: Double) async { try? await Task.sleep(for: .seconds(s)) }
        if askAboutPlan != nil { await wait(1); answerPlan(.no); await wait(1.2); go(to: .goodThings) }
        await wait(1); toggleGood(.catalog("laughed"))
        await wait(0.8); toggleGood(.catalog("rested"))
        await wait(0.8); openTyping(.goodThing)
        await wait(0.8); draft = "Soup with Mum"
        await wait(0.8); commitDraft()
        await wait(1); go(to: .plan)
        await wait(1); togglePlan(.catalog("walk"))
        await wait(0.8); openTyping(.plan)
        await wait(0.8); draft = String(repeating: "a long plan ", count: 14)
        await wait(0.8); commitDraft()
        await wait(1); go(to: .goodnight)
        await wait(1.5); finish()
    }
    #endif
}
