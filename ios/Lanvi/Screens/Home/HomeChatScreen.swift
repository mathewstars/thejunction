import SwiftUI

/// Talk to Lanvi: a thread under the night sky. The person's messages on the
/// right in chunky blue bubbles, Lanvi's on the left in soft white ones with a
/// small fox face. Each message goes to the server; Lanvi's words always come
/// back from it. Today's thread stays on the phone until tomorrow.
struct HomeChatScreen: View {
    var onClose: () -> Void
    var onHelp: () -> Void
    var onActivity: (ActivityKind) -> Void
    /// Demo walk-through only: send this by itself, then close.
    var demoMessage: String? = nil

    @Environment(AppStore.self) private var store
    @State private var draft = ""
    @FocusState private var focused: Bool
    @State private var pose: LanviPose = .curious

    private let limit = 280

    /// Type on the sky: navy on dawn and day, white at night.
    private var onSky: Color { store.worldScene == .night ? .white : Theme.ink }

    var body: some View {
        ZStack(alignment: .top) {
            PaintedWorld(scene: store.worldScene)

            VStack(spacing: 0) {
                header
                // The composer is the list's own bottom inset, so the newest
                // message always scrolls fully into view above it.
                thread
                    .safeAreaInset(edge: .bottom, spacing: 0) { composer }
            }
        }
        .onAppear { store.openChat() }
        .onChange(of: draft.isEmpty) { _, empty in
            pose = .curious   // typing: the listening mood carries it (peek is not a puppet pose)
        }
        .onChange(of: store.chat.messages.count) { old, new in
            guard new > old, store.chat.messages.last?.from == .lanvi else { return }
            pose = .love
            Task {
                try? await Task.sleep(for: .seconds(2))
                pose = .curious
            }
        }
        .task { await runDemo() }
    }

    // MARK: Header: Lanvi small at the top, listening

    private var header: some View {
        HStack(alignment: .center) {
            HomeCloseButton(action: close)
            Spacer()
            VStack(spacing: 2) {
                ZStack {
                    LanviView(pose: pose, size: 74)
                        .lanviHops(false)
                        .lanviMood(draft.isEmpty ? nil : .listening)
                }
                .frame(width: 96, height: 80)
                Text("Lanvi")
                    .font(Theme.rounded(17, .black))
                    .foregroundStyle(onSky)
                Text("A little fox who listens")
                    .font(Theme.rounded(12, .bold))
                    .foregroundStyle(onSky.opacity(0.75))
            }
            Spacer()
            Button(action: onHelp) { Image(systemName: "lifepreserver.fill") }
                .buttonStyle(HomeCornerRoundStyle())
                .accessibilityLabel("Help")
        }
        .padding(.horizontal, 20)
        .padding(.top, 6)
        .padding(.bottom, 8)
    }

    // MARK: The thread

    private var thread: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(store.chat.messages) { m in
                        row(m).id(m.id)
                    }
                    if store.chatWaiting {
                        HStack(alignment: .bottom, spacing: 8) {
                            foxFace
                            ChatDots()
                            Spacer(minLength: 60)
                        }
                        .id("dots")
                        .padding(.bottom, LanviBubbleShape.tailHeight)
                        .transition(LanviTiming.arrive)
                    }
                    Color.clear.frame(height: 4).id("bottom")
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: store.chat.messages.count) { _, _ in settleDown(proxy) }
            .onChange(of: store.chatWaiting) { _, _ in settleDown(proxy) }
            .onChange(of: focused) { _, _ in settleDown(proxy, first: 0.35) }
            .onAppear { scrollDown(proxy, animated: false) }
        }
    }

    /// Scroll once the new row has its size, and again after it has finished
    /// arriving, so the latest message ends fully in view.
    private func settleDown(_ proxy: ScrollViewProxy, first: Double = 0.06) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(first))
            scrollDown(proxy)
            try? await Task.sleep(for: .milliseconds(380))
            scrollDown(proxy)
        }
    }

    /// Close: put the keyboard away first, so it never shrinks along with the screen.
    private func close() {
        guard focused else { onClose(); return }
        focused = false
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(280))
            onClose()
        }
    }

    private func scrollDown(_ proxy: ScrollViewProxy, animated: Bool = true) {
        if animated {
            withAnimation(LanviTiming.screen) { proxy.scrollTo("bottom", anchor: .bottom) }
        } else {
            proxy.scrollTo("bottom", anchor: .bottom)
        }
    }

    @ViewBuilder private func row(_ m: ChatMessage) -> some View {
        switch m.from {
        case .lanvi:
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .bottom, spacing: 8) {
                    foxFace
                    ChatBubble(text: m.text, mine: false)
                    Spacer(minLength: 44)
                }
                if let s = m.suggestion, let kind = ActivityKind.allCases.first(where: { $0.suggestionAction == s.action }) {
                    suggestionCard(kind)
                        .padding(.leading, 44)
                }
            }
            .padding(.bottom, LanviBubbleShape.tailHeight)
            .transition(LanviTiming.arrive)
        case .me:
            VStack(alignment: .trailing, spacing: 4) {
                HStack {
                    Spacer(minLength: 56)
                    ChatBubble(text: m.text, mine: true)
                        .opacity(m.status == .failed ? 0.6 : 1)
                }
                if m.status == .failed {
                    Button {
                        Task { await store.retryChat(m.id) }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.clockwise")
                            Text("Lanvi couldn't hear this yet. Tap to try again.")
                        }
                        .font(Theme.rounded(13, .bold))
                        .foregroundStyle(onSky.opacity(0.85))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.bottom, LanviBubbleShape.tailHeight)
            .transition(LanviTiming.arrive)
        }
    }

    private var foxFace: some View {
        ZStack {
            Circle().fill(LinearGradient(colors: [.white, Theme.tint], startPoint: .top, endPoint: .bottom))
            Circle().stroke(.white, lineWidth: 2)
            Image(LanviPose.curious.imageName)
                .resizable()
                .scaledToFill()
                .frame(width: 44, height: 44)
                .offset(y: 7)
                .clipShape(Circle())
        }
        .frame(width: 36, height: 36)
        .shadow(color: Theme.nightTop.opacity(0.3), radius: 4, y: 2)
    }

    private func suggestionCard(_ kind: ActivityKind) -> some View {
        Button { onActivity(kind) } label: {
            HStack(spacing: 10) {
                Image(systemName: TodayCopy.icon(kind))
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(LinearGradient(colors: [Color(hex: 0x7C9BFF), Theme.brand],
                                                             startPoint: .top, endPoint: .bottom)))
                VStack(alignment: .leading, spacing: 1) {
                    Text(TodayCopy.title(kind))
                        .font(Theme.rounded(16, .heavy))
                        .foregroundStyle(Theme.ink)
                    Text(TodayCopy.duration(kind))
                        .font(Theme.rounded(12, .bold))
                        .foregroundStyle(Theme.inkSecondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(Theme.brand)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: 260)
        }
        .buttonStyle(ChatCardPressStyle())
    }

    // MARK: Composer

    private var composer: some View {
        let left = limit - draft.count
        return VStack(alignment: .trailing, spacing: 4) {
            if left <= 40 {
                Text("\(max(left, 0)) left")
                    .font(Theme.rounded(12, .bold))
                    .foregroundStyle(Theme.inkSecondary)
                    .padding(.trailing, 70)
                    .transition(.opacity)
            }
            HStack(alignment: .bottom, spacing: 10) {
                TextField("Write to Lanvi", text: $draft, axis: .vertical)
                    .font(Theme.rounded(17, .semibold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1...4)
                    .focused($focused)
                    .submitLabel(.send)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(.white))
                    .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Theme.line).offset(y: 3))
                    .onChange(of: draft) { _, v in
                        // Return sends (a multi-line field turns it into a newline).
                        if v.contains("\n") {
                            draft = v.replacingOccurrences(of: "\n", with: "")
                            send()
                            return
                        }
                        if v.count > limit { draft = String(v.prefix(limit)) }
                    }
                Button(action: send) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 19, weight: .black))
                }
                .buttonStyle(HomeRoundButtonStyle(diameter: 48))
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.chatWaiting)
                .opacity(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.55 : 1)
                .accessibilityLabel("Send")
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
        // A solid snow-white strip under the field that runs to the very bottom,
        // behind the keyboard too: nothing of the scene shows through there.
        .background(alignment: .top) {
            VStack(spacing: 0) {
                LinearGradient(colors: [Color(hex: 0xF4F8FF).opacity(0), Color(hex: 0xF4F8FF)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 24)
                Color(hex: 0xF4F8FF)
            }
            .padding(.top, -24)
            .ignoresSafeArea(edges: .bottom)
        }
        .animation(LanviTiming.swap, value: left <= 40)
    }

    /// Sends, and keeps the keyboard up for the next message. Empty does nothing.
    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !store.chatWaiting else { return }
        draft = ""
        Task { await store.sendChat(text) }
    }

    // MARK: Demo and screenshots

    /// `-chatDemo <name>`: type a draft (`typing`), or play a short conversation (`talk`).
    private func runDemo() async {
        // The -demo walk-through sends one message by itself, then closes.
        let walkthrough = ProcessInfo.processInfo.arguments.contains("-demo")
        if let demoMessage = demoMessage ?? (walkthrough ? "The coffee outside was nice today" : nil) {
            try? await Task.sleep(for: .milliseconds(900))
            for ch in demoMessage {
                draft.append(ch)
                try? await Task.sleep(for: .milliseconds(45))
            }
            try? await Task.sleep(for: .milliseconds(300))
            send()
            while store.chatWaiting { try? await Task.sleep(for: .milliseconds(100)) }
            try? await Task.sleep(for: .seconds(2.6))
            onClose()
            return
        }
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-chatDemo"), i + 1 < args.count else { return }
        try? await Task.sleep(for: .milliseconds(700))
        switch args[i + 1] {
        case "feelclose":
            // Keyboard up, then the X: for every-frame checks of the close.
            focused = true
            try? await Task.sleep(for: .milliseconds(1500))
            print(String(format: "FEEL chat.closekb %.3f", Date().timeIntervalSince1970))
            close()
        case "typing":
            focused = true
            try? await Task.sleep(for: .milliseconds(400))
            draft = "Slept badly, but the coffee outside was nice"
        case "long":
            focused = true
            draft = String(repeating: "Quiet day today, nothing much happened. ", count: 7)
        case "talk", "help", "kbtalk":
            if args[i + 1] == "kbtalk" { focused = true; try? await Task.sleep(for: .milliseconds(900)) }
            let lines = args[i + 1] == "help"
                ? ["I need help"]
                : ["Slept badly last night", "The coffee outside was nice though", "Thanks Lanvi"]
            for l in lines {
                draft = l
                try? await Task.sleep(for: .milliseconds(500))
                send()
                while store.chatWaiting { try? await Task.sleep(for: .milliseconds(100)) }
                try? await Task.sleep(for: .milliseconds(700))
            }
        default: break
        }
    }
}

/// One chat message: the same single-shape bubble as Lanvi's speech, with a
/// smooth tail toward the speaker. Lanvi's are white with the soft outline;
/// the person's are brand blue with white text.
private struct ChatBubble: View {
    var text: String
    var mine: Bool

    var body: some View {
        Text(text)
            .font(Theme.rounded(17, .semibold))
            .foregroundStyle(mine ? .white : Theme.ink)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(GeometryReader { g in
                if mine {
                    let shape = LanviBubbleShape(tailX: g.size.width - 22, lean: 1, radius: 20)
                    ZStack {
                        shape.fill(Theme.brandEdge).offset(y: 3)
                        shape.fill(LinearGradient(colors: [Color(hex: 0x5A7CF0), Theme.brand],
                                                  startPoint: .top, endPoint: .bottom))
                    }
                } else {
                    LanviBubbleBackground(tailX: 22, lean: -1)
                }
            })
    }
}

/// Three soft dots, only while Lanvi's answer is on its way.
private struct ChatDots: View {
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 6) {
                ForEach(0..<3) { i in
                    let phase = sin(t * 5 - Double(i) * 0.7)
                    Circle()
                        .fill(Theme.brand.opacity(0.35 + 0.35 * (phase + 1) / 2))
                        .frame(width: 9, height: 9)
                        .offset(y: -3 * CGFloat(max(phase, 0)))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 15)
            .background(GeometryReader { _ in LanviBubbleBackground(tailX: 22, lean: -1) })
        }
        .accessibilityLabel("Lanvi is answering")
    }
}

private struct ChatCardPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        configuration.label
            .background(shape.fill(.white))
            .overlay(shape.stroke(Theme.line, lineWidth: 2))
            .offset(y: pressed ? 4 : 0)
            .background(shape.fill(Theme.line).offset(y: 4))
            .animation(LanviTiming.press, value: pressed)
            .sensoryFeedback(.impact(weight: .light), trigger: pressed)
    }
}
