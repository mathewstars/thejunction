import SwiftUI

/// The evening check-in: (yesterday's plan, if any) → three good things → one small thing for tomorrow → goodnight.
/// Calls `onDone(result)` from the goodnight step, or `onDone(nil)` when the person leaves early.
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
    @State private var nudge = 0
    @State private var startedAt = Date()
    @State private var finished = false
    @FocusState private var fieldFocused: Bool

    private var steps: [Step] { askAboutPlan == nil ? [.goodThings, .plan, .goodnight] : [.planQuestion, .goodThings, .plan, .goodnight] }
    private var progress: CGFloat {
        let i = steps.firstIndex(of: step) ?? 0
        return CGFloat(i + 1) / CGFloat(steps.count)
    }

    /// Where things sit for the current step, in points from the top of the safe area.
    private struct Frame {
        var snowY: CGFloat      // the horizon: snow starts here, low on the screen
        var fox: CGFloat        // Lanvi's size
        var foxTop: CGFloat     // the sky content must end above this
        var small: Bool
    }

    private func frame(height h: CGFloat) -> Frame {
        let small = h < 700
        let snowY: CGFloat
        let fox: CGFloat
        switch step {
        case .planQuestion: snowY = h - 182; fox = small ? 150 : 212
        case .goodThings, .plan: snowY = h - 116; fox = small ? 84 : 108
        case .goodnight: snowY = h - 116; fox = small ? 160 : 210
        }
        return Frame(snowY: snowY, fox: fox, foxTop: snowY + 18 - fox, small: small)
    }

    private let skyTop: CGFloat = 62

    var body: some View {
        GeometryReader { geo in
            let f = frame(height: geo.size.height)

            ZStack(alignment: .top) {
                CheckinEveningSky(hillTop: f.snowY + geo.safeAreaInsets.top, showMoon: !f.small && (step == .planQuestion || step == .goodnight))

                if step == .goodnight {
                    RisingLights(originY: f.foxTop + f.fox * 0.45, ceiling: (skyTop + f.foxTop) / 2 + 125, width: geo.size.width)
                }

                LanviView(pose: pose, size: f.fox, bounceTrigger: bounce)
                    .position(x: geo.size.width / 2, y: f.snowY + 18 - f.fox / 2)
                    .onTapGesture { react(pose) }
                    .accessibilityHidden(true)

                topBar

                stepContent(f)
                    .id(step)
                    .transition(.asymmetric(
                        insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                        removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity)))

                if let typing {
                    TypingCard(
                        prompt: typing == .goodThing ? "A good thing from today" : "A small thing for tomorrow",
                        placeholder: typing == .goodThing ? "A few words" : "Something nice and easy",
                        draft: $draft,
                        focused: $fieldFocused,
                        onAdd: commitDraft,
                        onCancel: closeTyping)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(2)
                }
            }
        }
        .ignoresSafeArea(.keyboard)
        .sensoryFeedback(.selection, trigger: goodThings)
        .sensoryFeedback(.selection, trigger: plan)
        .sensoryFeedback(.warning, trigger: nudge)
        .sensoryFeedback(.success, trigger: finished)
        .task {
            GameMoments.emit(.checkinStarted)
            GameMoments.emit(.checkinStep(step.moment))
            await debugShot()
        }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 14) {
            CheckinCloseButton {
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
                    .font(Theme.rounded(16, .heavy))
                    .foregroundStyle(.white)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)
                    .background(Capsule().fill(.white.opacity(0.18)))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
        .opacity(typing == nil ? 1 : 0)
    }

    // MARK: Steps

    @ViewBuilder
    private func stepContent(_ f: Frame) -> some View {
        switch step {
        case .planQuestion: planQuestion(f)
        case .goodThings: goodThingsStep(f)
        case .plan: planStep(f)
        case .goodnight: goodnight(f)
        }
    }

    /// Sky content (centred above Lanvi) plus the buttons on the snow.
    private func skyAndSnow<Sky: View, Buttons: View>(_ f: Frame, @ViewBuilder sky: () -> Sky,
                                                      @ViewBuilder buttons: () -> Buttons) -> some View {
        VStack(spacing: 0) {
            sky()
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
                .frame(height: max(0, f.foxTop - 6 - skyTop))
                .padding(.top, skyTop)
            Spacer(minLength: 0)
            VStack(spacing: 14) { buttons() }
                .padding(.horizontal, 24)
                .padding(.bottom, 14)
        }
    }

    private func planQuestion(_ f: Frame) -> some View {
        let label = askAboutPlan?.label ?? ""
        return skyAndSnow(f) {
            VStack(spacing: f.small ? 12 : 16) {
                switch planDone {
                case .notAsked:
                    Text("Yesterday you planned")
                        .font(Theme.rounded(17, .bold))
                        .foregroundStyle(CheckinEvening.skyText)
                    PlanTicket(label: label)
                    Text("Did it happen?")
                        .font(Theme.rounded(f.small ? 28 : 32, .heavy))
                        .foregroundStyle(.white)
                case .yes:
                    replyText(title: "Yay, you did it!", body: "\(label). That was a kind thing to do for yourself.", f)
                case .no:
                    replyText(title: "That's okay.", body: "Some days go another way. You're here now, and that counts.", f)
                }
            }
        } buttons: {
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

    private func replyText(title: String, body: String, _ f: Frame) -> some View {
        VStack(spacing: 10) {
            Text(title)
                .font(Theme.rounded(f.small ? 30 : 34, .heavy))
                .foregroundStyle(.white)
            Text(body)
                .font(Theme.rounded(18, .semibold))
                .foregroundStyle(CheckinEvening.skyText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .transition(.scale(scale: 0.92).combined(with: .opacity))
    }

    private func goodThingsStep(_ f: Frame) -> some View {
        let full = goodThings.count >= 3
        let subtitle: String = switch goodThings.count {
        case 0: "Small things count. Tap up to three."
        case 1: "Nice. That's one."
        case 2: "Lovely. One more, if you like."
        default: "Three little lights for today."
        }
        return chipStep(f, title: "Three good things today", subtitle: subtitle, showTray: true) {
            // "Write my own" leads, so it is visible even on the smallest phone.
            Button { full ? fullNudge() : openTyping(.goodThing) } label: { writeOwnLabel }
                .buttonStyle(CheckinAddChipStyle(dimmed: full))
            ForEach(goodThings.compactMap(\.typedText), id: \.self) { text in
                Button { toggleGood(.text(text)) } label: { chipLabel(text, selected: true, typed: true) }
                    .buttonStyle(CheckinChipStyle(selected: true))
            }
            ForEach(options.goodThings) { option in
                let on = goodThings.contains(.catalog(option.id))
                Button { toggleGood(.catalog(option.id)) } label: { chipLabel(option.label, selected: on) }
                    .buttonStyle(CheckinChipStyle(selected: on, dimmed: full && !on))
            }
        } button: {
            if goodThings.isEmpty {
                Button("Skip for tonight") { go(to: .plan) }.buttonStyle(CheckinQuietButtonStyle())
            } else {
                Button("Continue") { go(to: .plan) }.buttonStyle(ChunkyButtonStyle())
            }
        }
    }

    private func planStep(_ f: Frame) -> some View {
        let subtitle = plan == nil ? "Something nice and easy. I'll ask you tomorrow." : "Good one. I'll ask how it went."
        return chipStep(f, title: "One small thing for tomorrow", subtitle: subtitle, showTray: false) {
            Button { openTyping(.plan) } label: { writeOwnLabel }
                .buttonStyle(CheckinAddChipStyle())
            if let text = plan?.typedText {
                Button { togglePlan(.text(text)) } label: { chipLabel(text, selected: true, typed: true) }
                    .buttonStyle(CheckinChipStyle(selected: true))
            }
            ForEach(options.plans) { option in
                let on = plan == .catalog(option.id)
                Button { togglePlan(.catalog(option.id)) } label: { chipLabel(option.label, selected: on) }
                    .buttonStyle(CheckinChipStyle(selected: on))
            }
        } button: {
            if plan == nil {
                Button("Skip for tonight") { go(to: .goodnight) }.buttonStyle(CheckinQuietButtonStyle())
            } else {
                Button("Continue") { go(to: .goodnight) }.buttonStyle(ChunkyButtonStyle())
            }
        }
    }

    private func chipStep<Chips: View, Bottom: View>(_ f: Frame, title: String, subtitle: String, showTray: Bool,
                                                     @ViewBuilder chips: () -> Chips,
                                                     @ViewBuilder button: () -> Bottom) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(Theme.rounded(f.small ? 25 : 28, .heavy))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                HStack(alignment: .center) {
                    Text(subtitle)
                        .font(Theme.rounded(16, .semibold))
                        .foregroundStyle(CheckinEvening.skyText)
                        .lineLimit(2)
                        .contentTransition(.opacity)
                        .animation(.easeOut(duration: 0.2), value: subtitle)
                    Spacer(minLength: 8)
                    if showTray { CheckinSparkTray(count: goodThings.count) }
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, skyTop + 2)

            ScrollView(.vertical, showsIndicators: false) {
                CheckinFlowLayout(spacing: 10, lineSpacing: 12) { chips() }
                    .padding(.horizontal, 24)
                    .padding(.top, f.small ? 14 : 20)
                    .padding(.bottom, 22)
            }
            .scrollBounceBehavior(.basedOnSize)
            .mask {
                VStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: 10)
                    Color.black
                    LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 22)
                }
            }
            .frame(height: max(0, f.foxTop - 2 - (skyTop + 2) - (f.small ? 66 : 70)))

            Spacer(minLength: 0)

            button()
                .padding(.horizontal, 24)
                .padding(.bottom, 14)
                .animation(.spring(response: 0.3, dampingFraction: 0.75), value: goodThings.isEmpty)
                .animation(.spring(response: 0.3, dampingFraction: 0.75), value: plan == nil)
        }
    }

    private func goodnight(_ f: Frame) -> some View {
        let body = goodThings.isEmpty
            ? "Thanks for stopping by tonight. Showing up is what counts."
            : "Thanks for telling me about your day. I'll keep those lights safe."
        return skyAndSnow(f) {
            VStack(spacing: f.small ? 10 : 14) {
                Text("Goodnight")
                    .font(Theme.rounded(f.small ? 40 : 46, .black))
                    .foregroundStyle(.white)
                    .shadow(color: Theme.aurora.opacity(0.6), radius: 14)
                Text(body)
                    .font(Theme.rounded(f.small ? 17 : 18, .semibold))
                    .foregroundStyle(CheckinEvening.skyText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                if let plan {
                    TomorrowPill(label: label(for: plan))
                        .padding(.top, 6)
                }
            }
        } buttons: {
            Button("Done", action: finish)
                .buttonStyle(ChunkyButtonStyle())
        }
    }

    // MARK: Chip labels

    private func chipLabel(_ text: String, selected: Bool, typed: Bool = false) -> some View {
        HStack(spacing: 7) {
            if selected {
                Image(systemName: typed ? "pencil" : "checkmark")
                    .font(.system(size: 13, weight: .black))
                    .transition(.scale.combined(with: .opacity))
            }
            Text(text)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
    }

    private var writeOwnLabel: some View {
        HStack(spacing: 7) {
            Image(systemName: "plus")
                .font(.system(size: 13, weight: .black))
            Text("Write my own")
        }
    }

    private func label(for item: CheckinItem) -> String {
        switch item {
        case .catalog(let id): options.planLabel(id) ?? options.goodThingLabel(id) ?? id
        case .text(let t): t
        }
    }

    // MARK: Actions

    private func answerPlan(_ answer: CheckinPlanDone) {
        withAnimation(.spring(response: 0.42, dampingFraction: 0.7)) { planDone = answer }
        react(answer == .yes ? .cheer : .love)
    }

    private func toggleGood(_ item: CheckinItem) {
        if goodThings.contains(item) {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { goodThings.removeAll { $0 == item } }
            calm()
        } else if goodThings.count < 3 {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { goodThings.append(item) }
            react(goodThings.count == 3 ? .cheer : .love)
        } else {
            fullNudge()
        }
    }

    private func togglePlan(_ item: CheckinItem) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { plan = plan == item ? nil : item }
        if plan != nil { react(.cheer) } else { calm() }
    }

    /// Back to the curious idle pose, no jump.
    private func calm() {
        withAnimation(.spring(response: 0.42, dampingFraction: 0.75)) { pose = .curious }
    }

    private func fullNudge() {
        nudge += 1
        react(.surprised)
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
            react(goodThings.count == 3 ? .cheer : .love)
        case .plan:
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { plan = item }
            react(.cheer)
        }
    }

    private func go(to next: Step) {
        forward = next > step
        withAnimation(.spring(response: 0.5, dampingFraction: 0.86)) { step = next }
        GameMoments.emit(.checkinStep(next.moment))
        switch next {
        case .planQuestion: react(.curious)
        case .goodThings: react(goodThings.isEmpty ? .curious : .love)
        case .plan: react(plan == nil ? .curious : .cheer)
        case .goodnight: react(.love)
        }
    }

    private func react(_ newPose: LanviPose) {
        bounce &+= 1
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

/// Yesterday's plan, shown as a raised white card on the night sky.
private struct PlanTicket: View {
    var label: String

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(Theme.tint)
                Image(systemName: "sun.max.fill")
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(Theme.brand)
            }
            .frame(width: 42, height: 42)
            Text(label)
                .font(Theme.rounded(21, .heavy))
                .foregroundStyle(Theme.ink)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 12)
        .padding(.leading, 12)
        .padding(.trailing, 22)
        .background(shape.fill(.white))
        .background(shape.fill(CheckinEvening.chipEdge).offset(y: 5))
        .shadow(color: Theme.glow.opacity(0.35), radius: 16)
    }
}

/// Tomorrow's plan on the goodnight step: a small raised pill.
private struct TomorrowPill: View {
    var label: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "sun.horizon.fill")
                .foregroundStyle(Theme.brand)
            Text("Tomorrow: ").foregroundStyle(Theme.inkSecondary) + Text(label).foregroundStyle(Theme.ink)
        }
        .font(Theme.rounded(16, .heavy))
        .lineLimit(2)
        .padding(.vertical, 10)
        .padding(.horizontal, 16)
        .background(Capsule().fill(.white))
        .background(Capsule().fill(CheckinEvening.chipEdge).offset(y: 4))
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

    private var canAdd: Bool { CheckinItem.typed(draft) != nil }
    private var left: Int { CheckinItem.maxTextLength - draft.count }

    var body: some View {
        ZStack(alignment: .top) {
            CheckinEvening.top.opacity(0.6)
                .ignoresSafeArea()
                .onTapGesture(perform: onCancel)

            VStack(alignment: .leading, spacing: 14) {
                Text(prompt)
                    .font(Theme.rounded(22, .heavy))
                    .foregroundStyle(Theme.ink)
                    .padding(.trailing, 76)
                TextField(placeholder, text: $draft, axis: .vertical)
                    .font(Theme.rounded(18, .semibold))
                    .foregroundStyle(Theme.ink)
                    .tint(Theme.brand)
                    .lineLimit(1...3)
                    .submitLabel(.done)
                    .focused(focused)
                    .padding(.vertical, 14)
                    .padding(.horizontal, 16)
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.snow))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Theme.brand, lineWidth: 2))
                    .overlay(alignment: .bottomTrailing) {
                        if left <= 20 {
                            Text("\(left)")
                                .font(Theme.rounded(13, .heavy))
                                .foregroundStyle(Theme.inkSecondary)
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
                        .buttonStyle(ChunkyButtonStyle(fill: canAdd ? Theme.brand : Theme.glow,
                                                       edge: canAdd ? Theme.brandEdge : Theme.brand.opacity(0.45)))
                        .disabled(!canAdd)
                }
            }
            .padding(20)
            .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(.white))
            .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(CheckinEvening.chipEdge).offset(y: 6))
            .overlay(alignment: .topTrailing) {
                LanviView(pose: .curious, size: 84)
                    .offset(x: -6, y: -52)
                    .allowsHitTesting(false)
            }
            .padding(.horizontal, 16)
            .padding(.top, 74)
        }
    }
}

/// Soft motes of light drifting up from Lanvi into the night on the goodnight step: fox fires.
private struct RisingLights: View {
    var originY: CGFloat
    var ceiling: CGFloat   // motes fade out before they reach the words above
    var width: CGFloat

    private struct Seed { var x: CGFloat; var phase: Double; var size: CGFloat; var period: Double; var sway: CGFloat }
    private let seeds: [Seed] = [
        Seed(x: -0.30, phase: 0.00, size: 16, period: 5.2, sway: 10),
        Seed(x: 0.27, phase: 0.35, size: 12, period: 6.0, sway: 8),
        Seed(x: -0.21, phase: 0.62, size: 19, period: 5.6, sway: 12),
        Seed(x: 0.36, phase: 0.15, size: 10, period: 4.8, sway: 7),
        Seed(x: -0.40, phase: 0.80, size: 11, period: 6.4, sway: 8),
        Seed(x: 0.20, phase: 0.48, size: 9, period: 4.4, sway: 7),
        Seed(x: 0.42, phase: 0.70, size: 14, period: 5.9, sway: 10),
        Seed(x: -0.34, phase: 0.25, size: 8, period: 5.0, sway: 6),
    ]

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            ZStack(alignment: .topLeading) {
                ForEach(seeds.indices, id: \.self) { i in
                    let s = seeds[i]
                    let p = (t / s.period + s.phase).truncatingRemainder(dividingBy: 1)
                    let rise = CGFloat(p) * max(60, originY - ceiling)
                    CheckinMote(size: s.size, color: i.isMultiple(of: 3) ? Theme.auroraViolet : Theme.aurora)
                        .opacity(sin(p * .pi) * 0.95)
                        .scaleEffect(0.7 + 0.5 * sin(p * .pi))
                        .position(x: width * (0.5 + s.x) + s.sway * CGFloat(sin(t * 0.9 + Double(i))),
                                  y: originY - rise)
                }
            }
            .frame(width: width, height: originY + 40, alignment: .topLeading)
        }
        .allowsHitTesting(false)
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
