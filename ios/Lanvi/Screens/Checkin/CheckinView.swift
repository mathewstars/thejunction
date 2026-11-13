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
    private var isChipStep: Bool { step == .goodThings || step == .plan }

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let small = h < 700
            let snowY = isChipStep ? h * (small ? 0.27 : 0.29) : h * (step == .goodnight ? 0.47 : 0.45)
            let fox: CGFloat = isChipStep ? (small ? 100 : 124) : (small ? 160 : 196)

            ZStack(alignment: .top) {
                EveningSky(hillTop: snowY + geo.safeAreaInsets.top)

                if step == .goodnight { RisingSparks(baseY: snowY).allowsHitTesting(false) }

                LanviView(pose: pose, size: fox, bounceTrigger: bounce)
                    .position(x: geo.size.width / 2, y: snowY + 18 - fox / 2)
                    .onTapGesture { react(pose) }
                    .accessibilityHidden(true)

                topBar

                stepContent(snowY: snowY, small: small)
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
        .task { await debugShot() }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 14) {
            SkyIconButton(icon: "xmark", label: "Leave the check-in") { onDone(nil) }
            StepProgress(progress: progress)
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
        .padding(.top, 6)
        .opacity(typing == nil ? 1 : 0)
    }

    // MARK: Steps

    @ViewBuilder
    private func stepContent(snowY: CGFloat, small: Bool) -> some View {
        switch step {
        case .planQuestion: planQuestion(snowY: snowY, small: small)
        case .goodThings: goodThingsStep(snowY: snowY, small: small)
        case .plan: planStep(snowY: snowY, small: small)
        case .goodnight: goodnight(snowY: snowY, small: small)
        }
    }

    private func planQuestion(snowY: CGFloat, small: Bool) -> some View {
        let label = askAboutPlan?.label ?? ""
        return VStack(spacing: 0) {
            Spacer().frame(height: snowY + (small ? 30 : 40))
            VStack(spacing: small ? 10 : 14) {
                switch planDone {
                case .notAsked:
                    Text("Yesterday you planned")
                        .font(Theme.rounded(17, .bold))
                        .foregroundStyle(Theme.inkSecondary)
                    PlanTicket(label: label)
                    Text("Did it happen?")
                        .font(Theme.rounded(small ? 26 : 28, .heavy))
                        .foregroundStyle(Theme.ink)
                case .yes:
                    replyText(title: "Yay, you did it!", body: "\(label) sounds like a kind thing to do for yourself.")
                case .no:
                    replyText(title: "That's okay.", body: "Some days go another way. You're here now, and that counts.")
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
            Spacer(minLength: 12)
            VStack(spacing: 14) {
                if planDone == .notAsked {
                    Button("Yes, it did") { answerPlan(.yes) }
                        .buttonStyle(ChunkyButtonStyle())
                    Button("Not this time") { answerPlan(.no) }
                        .buttonStyle(ChunkyQuietButtonStyle())
                } else {
                    Button("Continue") { go(to: .goodThings) }
                        .buttonStyle(ChunkyButtonStyle())
                        .transition(.scale(scale: 0.9).combined(with: .opacity))
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 14)
        }
    }

    private func replyText(title: String, body: String) -> some View {
        VStack(spacing: 10) {
            Text(title)
                .font(Theme.rounded(30, .heavy))
                .foregroundStyle(Theme.ink)
            Text(body)
                .font(Theme.rounded(18, .semibold))
                .foregroundStyle(Theme.inkSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .transition(.scale(scale: 0.92).combined(with: .opacity))
    }

    private func goodThingsStep(snowY: CGFloat, small: Bool) -> some View {
        let full = goodThings.count >= 3
        let subtitle: String = switch goodThings.count {
        case 0: "Small things count. Tap up to three."
        case 1: "Nice. That's one."
        case 2: "Lovely. One more, if you like."
        default: "Three little sparks for today."
        }
        return chipStep(
            snowY: snowY, small: small,
            title: "Three good things today",
            subtitle: subtitle,
            counter: AnyView(SparkCounter(count: goodThings.count)),
            chips: AnyView(FlowLayout(spacing: 10, lineSpacing: 12) {
                ForEach(options.goodThings) { option in
                    let on = goodThings.contains(.catalog(option.id))
                    Button { toggleGood(.catalog(option.id)) } label: { chipLabel(option.label, selected: on) }
                        .buttonStyle(CheckinChipStyle(selected: on, dimmed: full && !on))
                }
                ForEach(goodThings.compactMap(\.typedText), id: \.self) { text in
                    Button { toggleGood(.text(text)) } label: { chipLabel(text, selected: true, typed: true) }
                        .buttonStyle(CheckinChipStyle(selected: true))
                }
                Button { full ? fullNudge() : openTyping(.goodThing) } label: { somethingElseLabel }
                    .buttonStyle(CheckinChipStyle(selected: false, dimmed: full))
            }),
            button: goodThings.isEmpty
                ? AnyView(Button("Skip for tonight") { go(to: .plan) }.buttonStyle(ChunkyQuietButtonStyle()))
                : AnyView(Button("Continue") { go(to: .plan) }.buttonStyle(ChunkyButtonStyle())))
    }

    private func planStep(snowY: CGFloat, small: Bool) -> some View {
        let subtitle = plan == nil ? "Something nice and easy. I'll ask you tomorrow." : "Good one. I'll ask you how it went."
        return chipStep(
            snowY: snowY, small: small,
            title: "One small thing for tomorrow",
            subtitle: subtitle,
            counter: nil,
            chips: AnyView(FlowLayout(spacing: 10, lineSpacing: 12) {
                ForEach(options.plans) { option in
                    let on = plan == .catalog(option.id)
                    Button { togglePlan(.catalog(option.id)) } label: { chipLabel(option.label, selected: on) }
                        .buttonStyle(CheckinChipStyle(selected: on))
                }
                if let text = plan?.typedText {
                    Button { togglePlan(.text(text)) } label: { chipLabel(text, selected: true, typed: true) }
                        .buttonStyle(CheckinChipStyle(selected: true))
                }
                Button { openTyping(.plan) } label: { somethingElseLabel }
                    .buttonStyle(CheckinChipStyle(selected: false))
            }),
            button: plan == nil
                ? AnyView(Button("Skip for tonight") { go(to: .goodnight) }.buttonStyle(ChunkyQuietButtonStyle()))
                : AnyView(Button("Continue") { go(to: .goodnight) }.buttonStyle(ChunkyButtonStyle())))
    }

    private func chipStep(snowY: CGFloat, small: Bool, title: String, subtitle: String,
                          counter: AnyView?, chips: AnyView, button: AnyView) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer().frame(height: snowY + (small ? 26 : 34))
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(Theme.rounded(small ? 24 : 27, .heavy))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                HStack(alignment: .firstTextBaseline) {
                    Text(subtitle)
                        .font(Theme.rounded(16, .semibold))
                        .foregroundStyle(Theme.inkSecondary)
                        .contentTransition(.opacity)
                        .animation(.easeOut(duration: 0.2), value: subtitle)
                    Spacer(minLength: 8)
                    counter
                }
            }
            .padding(.horizontal, 24)

            ScrollView(.vertical, showsIndicators: false) {
                chips
                    .padding(.horizontal, 24)
                    .padding(.top, small ? 14 : 18)
                    .padding(.bottom, 26)
            }
            .scrollBounceBehavior(.basedOnSize)
            .mask {
                VStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: 10)
                    Color.black
                    LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 22)
                }
            }

            button
                .padding(.horizontal, 24)
                .padding(.top, 6)
                .padding(.bottom, 14)
                .animation(.spring(response: 0.3, dampingFraction: 0.75), value: goodThings.isEmpty)
                .animation(.spring(response: 0.3, dampingFraction: 0.75), value: plan == nil)
        }
    }

    private func goodnight(snowY: CGFloat, small: Bool) -> some View {
        let shared = !goodThings.isEmpty
        let body = shared
            ? "Thanks for telling me about your day. I'll keep those sparks safe."
            : "Thanks for stopping by tonight. Showing up is what counts."
        return VStack(spacing: 0) {
            Spacer().frame(height: snowY + (small ? 26 : 38))
            VStack(spacing: small ? 10 : 12) {
                Text("Goodnight")
                    .font(Theme.rounded(small ? 34 : 38, .black))
                    .foregroundStyle(Theme.brand)
                Text(body)
                    .font(Theme.rounded(small ? 17 : 18, .semibold))
                    .foregroundStyle(Theme.inkSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                if let plan {
                    TomorrowPill(label: label(for: plan))
                        .padding(.top, 4)
                }
            }
            .padding(.horizontal, 28)
            Spacer(minLength: 12)
            Button("Done", action: finish)
                .buttonStyle(ChunkyButtonStyle())
                .padding(.horizontal, 24)
                .padding(.bottom, 14)
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

    private var somethingElseLabel: some View {
        HStack(spacing: 7) {
            Image(systemName: "plus")
                .font(.system(size: 13, weight: .black))
            Text("Something else")
        }
        .foregroundStyle(Theme.brand)
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
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            if let i = goodThings.firstIndex(of: item) {
                goodThings.remove(at: i)
                pose = .curious
            } else if goodThings.count < 3 {
                goodThings.append(item)
            } else {
                fullNudge()
                return
            }
        }
        if goodThings.contains(item) { react(goodThings.count == 3 ? .cheer : .love) }
    }

    private func togglePlan(_ item: CheckinItem) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            plan = plan == item ? nil : item
        }
        if plan != nil { react(.cheer) } else { withAnimation { pose = .curious } }
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
        switch next {
        case .planQuestion: react(.curious)
        case .goodThings: react(goodThings.isEmpty ? .curious : .love)
        case .plan: react(plan == nil ? .peek : .cheer)
        case .goodnight: react(.love)
        }
    }

    private func react(_ newPose: LanviPose) {
        bounce &+= 1
        withAnimation(.spring(response: 0.42, dampingFraction: 0.62)) { pose = newPose }
    }

    private func finish() {
        finished = true
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

/// Yesterday's plan, shown as a little raised card.
private struct PlanTicket: View {
    var label: String

    var body: some View {
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
        .padding(.trailing, 20)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(.white))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Theme.line, lineWidth: 2))
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Theme.line).offset(y: 4))
    }
}

/// Tomorrow's plan on the goodnight step.
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
        .background(Capsule().fill(Theme.tint))
        .overlay(Capsule().stroke(Theme.line, lineWidth: 2))
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
            EveningTheme.top.opacity(0.55)
                .ignoresSafeArea()
                .onTapGesture(perform: onCancel)

            VStack(alignment: .leading, spacing: 14) {
                Text(prompt)
                    .font(Theme.rounded(22, .heavy))
                    .foregroundStyle(Theme.ink)
                    .padding(.trailing, 70)
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
                        .buttonStyle(ChunkyQuietButtonStyle())
                    Button("Add", action: onAdd)
                        .buttonStyle(ChunkyButtonStyle(fill: canAdd ? Theme.brand : Theme.glow,
                                                       edge: canAdd ? Theme.brandEdge : Theme.brand.opacity(0.45)))
                        .disabled(!canAdd)
                }
            }
            .padding(20)
            .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(.white))
            .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(Theme.line).offset(y: 6))
            .overlay(alignment: .topTrailing) {
                LanviView(pose: .curious, size: 84)
                    .offset(x: -8, y: -50)
                    .allowsHitTesting(false)
            }
            .padding(.horizontal, 16)
            .padding(.top, 70)
        }
    }
}

/// A few soft sparks drifting up from Lanvi on the goodnight step.
private struct RisingSparks: View {
    var baseY: CGFloat
    private let seeds: [(x: CGFloat, delay: Double, size: CGFloat)] = [
        (-0.30, 0.0, 11), (0.22, 0.9, 9), (-0.12, 1.7, 13), (0.34, 2.4, 8), (0.05, 3.1, 10), (-0.38, 3.8, 8),
    ]

    var body: some View {
        GeometryReader { geo in
            TimelineView(.animation) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                ZStack {
                    ForEach(seeds.indices, id: \.self) { i in
                        let s = seeds[i]
                        let p = ((t + s.delay) / 4.4).truncatingRemainder(dividingBy: 1)
                        Image(systemName: "sparkle")
                            .font(.system(size: s.size, weight: .black))
                            .foregroundStyle(i.isMultiple(of: 2) ? Theme.aurora : Theme.auroraViolet)
                            .shadow(color: Theme.glow, radius: 6)
                            .opacity(sin(p * .pi))
                            .position(x: geo.size.width * (0.5 + s.x) + 10 * sin(t + Double(i)),
                                      y: baseY - 40 - CGFloat(p) * baseY * 0.55)
                    }
                }
            }
        }
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
