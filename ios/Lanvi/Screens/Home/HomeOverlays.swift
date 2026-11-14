import SwiftUI

// MARK: - Help

/// The help text from the server, with its phone numbers as big call buttons.
/// One tap from Home, always.
struct HomeHelpScreen: View {
    var crisis: API.CrisisBlock
    var onClose: () -> Void

    @Environment(AppStore.self) private var store

    @State private var bounce = 0
    @State private var confirmDisconnect = false

    var body: some View {
        GeometryReader { geo in
            let compact = geo.size.height < 700
            let hill = geo.size.height * (compact ? 0.55 : 0.62)
            let fox: CGFloat = compact ? 160 : 220
            ZStack(alignment: .top) {
                PaintedWorld(scene: store.worldScene)

                LanviView(pose: .love, size: fox, bounceTrigger: bounce)
                    .position(x: geo.size.width / 2, y: hill - fox / 2 + 12)

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("Help is here")
                                .font(Theme.rounded(28, .black))
                                .foregroundStyle(Theme.ink)
                            Spacer()
                            if !crisis.reviewedByClinician {
                                Text("Draft wording")
                                    .font(Theme.rounded(12, .heavy))
                                    .foregroundStyle(Theme.inkSecondary)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(Capsule().fill(Theme.tint))
                            }
                        }
                        Text(crisis.text)
                            .font(Theme.rounded(18, .semibold))
                            .foregroundStyle(Theme.ink)
                            .fixedSize(horizontal: false, vertical: true)

                        ForEach(crisis.contacts, id: \.phone) { c in
                            if let url = URL(string: "tel:\(c.phone.filter { $0.isNumber || $0 == "+" })") {
                                Link(destination: url) {
                                    HStack(spacing: 10) {
                                        Image(systemName: "phone.fill")
                                        Text("Call \(c.phone)")
                                    }
                                }
                                .buttonStyle(ChunkyButtonStyle())
                                Text(c.label)
                                    .font(Theme.rounded(14, .bold))
                                    .foregroundStyle(Theme.inkSecondary)
                                    .frame(maxWidth: .infinity)
                                    .padding(.top, -6)
                            }
                        }
                        FaceSenseSwitch()

                        if store.isConnected {
                            // For testers: forget this phone so it can pair again with a new code.
                            Button("Disconnect this phone") { confirmDisconnect = true }
                                .font(Theme.rounded(15, .bold))
                                .foregroundStyle(Theme.inkSecondary)
                                .frame(maxWidth: .infinity)
                                .padding(.top, 12)
                                .confirmationDialog("Disconnect this phone from your clinic?",
                                                    isPresented: $confirmDisconnect, titleVisibility: .visible) {
                                    Button("Disconnect", role: .destructive) {
                                        Task {
                                            await store.disconnect()
                                            onClose()
                                        }
                                    }
                                    Button("Keep connected", role: .cancel) {}
                                } message: {
                                    Text("You'll need a new code from your clinic to connect again.")
                                }
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, hill + 22)
                    .padding(.bottom, 24)
                }
                .scrollBounceBehavior(.basedOnSize)

                HStack {
                    HomeCloseButton(action: onClose)
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.top, 6)
            }
        }
        .task {
            try? await Task.sleep(for: .milliseconds(350))
            bounce += 1
        }
    }
}

// MARK: - Story from a wandering

/// Lanvi came back from Lapland with a tiny story and a question.
struct HomeStoryScreen: View {
    var story: API.StoryOut
    /// Demo only: answer by itself after a moment.
    var autoAnswer: String? = nil
    var onAnswer: (String) async -> Bool
    var onClose: () -> Void

    @Environment(AppStore.self) private var store

    @State private var pose: LanviPose = .run
    @State private var runX: CGFloat = -500
    @State private var arrived = false
    @State private var bounce = 0
    @State private var chosen: String?
    @State private var thanks = false
    @State private var sending = false

    var body: some View {
        GeometryReader { geo in
            let compact = geo.size.height < 700
            let hill = geo.size.height * (compact ? 0.53 : 0.60)
            let fox: CGFloat = compact ? 150 : 210
            ZStack(alignment: .top) {
                PaintedWorld(scene: store.worldScene)

                ZStack {
                    LanviView(pose: pose, size: fox, bounceTrigger: bounce)
                }
                .frame(width: fox * 2, height: fox * 2)
                .position(x: geo.size.width / 2 + runX, y: hill - fox / 2 + 12)

                // Lanvi tells the story in its speech bubble; the thank-you replaces
                // it without the two texts ever showing at once.
                HomeSpeechBubble(text: thanks ? "Thank you. I'll remember that on my next trip." : story.text,
                                 pointAt: 0.5)
                    .frame(maxWidth: .infinity)
                .opacity(arrived ? 1 : 0)
                .scaleEffect(arrived ? 1 : 0.8, anchor: .bottom)
                .padding(.horizontal, 24)
                .padding(.top, compact ? 62 : 74)

                VStack(alignment: .leading, spacing: 14) {
                    Text("Lanvi's story")
                        .font(Theme.rounded(13, .black))
                        .textCase(.uppercase)
                        .tracking(0.8)
                        .foregroundStyle(Theme.brand)
                    Text(story.question)
                        .font(Theme.rounded(24, .black))
                        .foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(Array(story.answers.enumerated()), id: \.element.id) { i, a in
                        Button(a.text) { answer(a.id) }
                            .buttonStyle(i == 0 ? ChunkyButtonStyle()
                                                : ChunkyButtonStyle(fill: .white, edge: Theme.line, text: Theme.brand))
                            .overlay {
                                if i != 0 {
                                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                                        .stroke(Theme.line, lineWidth: 2).allowsHitTesting(false)
                                }
                            }
                            .opacity(chosen == nil || chosen == a.id ? 1 : 0.45)
                            .disabled(sending || thanks)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, hill + 24)
                .opacity(arrived ? 1 : 0)
                .offset(y: arrived ? 0 : 40)

                HStack {
                    HomeCloseButton(action: onClose)
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.top, 6)
            }
        }
        .task {
            // Lanvi runs in from the side, stops, cheers; then the story appears.
            try? await Task.sleep(for: .milliseconds(250))
            withAnimation(.easeOut(duration: 1.0)) { runX = 0 }
            try? await Task.sleep(for: .milliseconds(1000))
            pose = .cheer
            try? await Task.sleep(for: .milliseconds(350))
            withAnimation(LanviTiming.screen) { arrived = true }
            // The -demo walk-through answers by itself.
            let auto = autoAnswer ?? (ProcessInfo.processInfo.arguments.contains("-demo") ? story.answers.first?.id : nil)
            if let auto {
                try? await Task.sleep(for: .seconds(4.5))
                answer(auto)
            }
        }
    }

    private func answer(_ id: String) {
        guard !sending else { return }
        sending = true
        withAnimation(LanviTiming.pop) { chosen = id }
        Task {
            let ok = await onAnswer(id)
            sending = false
            guard ok else {
                withAnimation(LanviTiming.pop) { chosen = nil }
                pose = .meh
                return
            }
            pose = .love
            thanks = true
            try? await Task.sleep(for: .seconds(2.2))
            onClose()
        }
    }
}
