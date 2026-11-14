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
    @State private var bounce = 0

    private let limit = 280

    var body: some View {
        ZStack(alignment: .top) {
            SkyScene(top: Theme.nightTop, bottom: Theme.nightBottom, hillTop: 2000)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                header
                thread
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { composer }
        .onAppear { store.openChat() }
        .onChange(of: draft.isEmpty) { _, empty in
            withAnimation(.spring(response: 0.42, dampingFraction: 0.62)) { pose = empty ? .curious : .peek }
        }
        .onChange(of: store.chat.messages.count) { old, new in
            guard new > old, store.chat.messages.last?.from == .lanvi else { return }
            withAnimation(.spring(response: 0.42, dampingFraction: 0.62)) { pose = .love }
            bounce += 1
            Task {
                try? await Task.sleep(for: .seconds(2))
                withAnimation(.spring(response: 0.42, dampingFraction: 0.62)) { pose = draft.isEmpty ? .curious : .peek }
            }
        }
        .task { await runDemo() }
    }

    // MARK: Header: Lanvi small at the top, listening

    private var header: some View {
        HStack(alignment: .center) {
            HomeCloseButton(action: onClose)
            Spacer()
            VStack(spacing: 2) {
                ZStack {
                    HomeTailGlow(pose: pose, glow: 0.45, foxSize: 74)
                    LanviView(pose: pose, size: 74, bounceTrigger: bounce)
                }
                .frame(width: 96, height: 80)
                Text("Lanvi")
                    .font(Theme.rounded(17, .black))
                    .foregroundStyle(.white)
                Text("A little fox who listens")
                    .font(Theme.rounded(12, .bold))
                    .foregroundStyle(.white.opacity(0.7))
            }
            Spacer()
            Button(action: onHelp) { Image(systemName: "lifepreserver.fill") }
                .buttonStyle(HomeSkyRoundStyle())
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
                        .transition(.scale(scale: 0.8, anchor: .bottomLeading).combined(with: .opacity))
                    }
                    Color.clear.frame(height: 4).id("bottom")
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: store.chat.messages.count) { _, _ in scrollDown(proxy) }
            .onChange(of: store.chatWaiting) { _, _ in scrollDown(proxy) }
            .onChange(of: focused) { _, _ in
                Task {
                    try? await Task.sleep(for: .milliseconds(350))
                    scrollDown(proxy)
                }
            }
            .onAppear { scrollDown(proxy, animated: false) }
        }
    }

    private func scrollDown(_ proxy: ScrollViewProxy, animated: Bool = true) {
        if animated {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.9)) { proxy.scrollTo("bottom", anchor: .bottom) }
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
                    Text(m.text)
                        .font(Theme.rounded(17, .semibold))
                        .foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                        .background(ChatBubbleShape(mine: false).fill(.white))
                        .background(ChatBubbleShape(mine: false).fill(Theme.line).offset(y: 3))
                    Spacer(minLength: 44)
                }
                if let s = m.suggestion, let kind = ActivityKind.allCases.first(where: { $0.suggestionAction == s.action }) {
                    suggestionCard(kind)
                        .padding(.leading, 44)
                }
            }
            .transition(.asymmetric(insertion: .scale(scale: 0.85, anchor: .bottomLeading).combined(with: .opacity),
                                    removal: .opacity))
        case .me:
            VStack(alignment: .trailing, spacing: 4) {
                HStack {
                    Spacer(minLength: 56)
                    Text(m.text)
                        .font(Theme.rounded(17, .semibold))
                        .foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                        .background(ChatBubbleShape(mine: true).fill(
                            LinearGradient(colors: [Color(hex: 0x5A7CF0), Theme.brand], startPoint: .top, endPoint: .bottom)))
                        .background(ChatBubbleShape(mine: true).fill(Theme.brandEdge).offset(y: 3))
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
                        .foregroundStyle(.white.opacity(0.85))
                    }
                    .buttonStyle(.plain)
                }
            }
            .transition(.asymmetric(insertion: .scale(scale: 0.85, anchor: .bottomTrailing).combined(with: .opacity),
                                    removal: .opacity))
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
                    .foregroundStyle(.white.opacity(0.75))
                    .padding(.trailing, 70)
                    .transition(.opacity)
            }
            HStack(alignment: .bottom, spacing: 10) {
                TextField("Write to Lanvi", text: $draft, axis: .vertical)
                    .font(Theme.rounded(17, .semibold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1...4)
                    .focused($focused)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(.white))
                    .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Theme.line).offset(y: 3))
                    .onChange(of: draft) { _, v in
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
        .background(
            LinearGradient(colors: [Theme.nightBottom.opacity(0), Theme.nightBottom.opacity(0.9)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        )
        .animation(.easeOut(duration: 0.2), value: left <= 40)
    }

    private func send() {
        let text = draft
        draft = ""
        Task { await store.sendChat(text) }
    }

    // MARK: Demo and screenshots

    /// `-chatDemo <name>`: type a draft (`typing`), or play a short conversation (`talk`).
    private func runDemo() async {
        if let demoMessage {
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
        case "typing":
            focused = true
            try? await Task.sleep(for: .milliseconds(400))
            draft = "Slept badly, but the coffee outside was nice"
        case "long":
            focused = true
            draft = String(repeating: "Quiet day today, nothing much happened. ", count: 7)
        case "talk", "help":
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

/// A rounded bubble with a small tail at the bottom corner.
private struct ChatBubbleShape: Shape {
    var mine: Bool
    func path(in rect: CGRect) -> Path {
        var p = Path(roundedRect: rect, cornerRadius: 20, style: .continuous)
        let x = mine ? rect.maxX - 14 : rect.minX + 14
        let dir: CGFloat = mine ? 1 : -1
        p.move(to: CGPoint(x: x - 8 * dir, y: rect.maxY - 1))
        p.addQuadCurve(to: CGPoint(x: x + 14 * dir, y: rect.maxY + 6), control: CGPoint(x: x + 4 * dir, y: rect.maxY + 2))
        p.addQuadCurve(to: CGPoint(x: x + 4 * dir, y: rect.maxY - 10), control: CGPoint(x: x + 8 * dir, y: rect.maxY - 2))
        p.closeSubpath()
        return p
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
            .background(ChatBubbleShape(mine: false).fill(.white))
            .background(ChatBubbleShape(mine: false).fill(Theme.line).offset(y: 3))
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
            .animation(.spring(response: 0.16, dampingFraction: 0.7), value: pressed)
            .sensoryFeedback(.impact(weight: .light), trigger: pressed)
    }
}
