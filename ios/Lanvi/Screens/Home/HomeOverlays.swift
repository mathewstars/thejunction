import SwiftUI

// MARK: - Help

/// The help text from the server, with its phone numbers as big call buttons.
/// One tap from Home, always.
struct HomeHelpScreen: View {
    var crisis: API.CrisisBlock
    var onClose: () -> Void

    @State private var bounce = 0

    var body: some View {
        GeometryReader { geo in
            let hill = geo.size.height * 0.40
            ZStack(alignment: .top) {
                SkyScene(top: Theme.nightTop, bottom: Theme.nightBottom, hillTop: hill)

                LanviView(pose: .love, size: 150, bounceTrigger: bounce)
                    .position(x: geo.size.width / 2, y: hill - 75 + 12)

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
    var onAnswer: (String) async -> Bool
    var onClose: () -> Void

    @State private var pose: LanviPose = .cheer
    @State private var bounce = 0
    @State private var chosen: String?
    @State private var thanks = false
    @State private var sending = false

    var body: some View {
        GeometryReader { geo in
            let hill = geo.size.height * 0.46
            ZStack(alignment: .top) {
                SkyScene(top: Theme.nightTop, bottom: Theme.nightBottom, hillTop: hill)

                HomeTailGlow(pose: pose, glow: 0.8, foxSize: 170)
                    .position(x: geo.size.width / 2, y: hill - 85 + 12)
                LanviView(pose: pose, size: 170, bounceTrigger: bounce)
                    .position(x: geo.size.width / 2, y: hill - 85 + 12)

                VStack(spacing: 0) {
                    Text(thanks ? "Thank you. I'll remember that on my next trip." : story.text)
                        .font(Theme.rounded(19, .heavy))
                        .foregroundStyle(Theme.ink)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(18)
                        .frame(maxWidth: .infinity)
                        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(.white))
                        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Theme.line).offset(y: 4))
                        .shadow(color: Theme.nightTop.opacity(0.3), radius: 16, y: 8)
                        .id(thanks)
                        .transition(.scale(scale: 0.85).combined(with: .opacity))
                }
                .padding(.horizontal, 24)
                .padding(.top, 70)

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

                HStack {
                    HomeCloseButton(action: onClose)
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.top, 6)
            }
        }
        .task {
            try? await Task.sleep(for: .milliseconds(300))
            bounce += 1
        }
    }

    private func answer(_ id: String) {
        guard !sending else { return }
        sending = true
        withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { chosen = id }
        Task {
            let ok = await onAnswer(id)
            sending = false
            guard ok else {
                withAnimation { chosen = nil; pose = .meh }
                return
            }
            withAnimation(.spring(response: 0.45, dampingFraction: 0.65)) {
                pose = .love
                thanks = true
            }
            try? await Task.sleep(for: .seconds(2.2))
            onClose()
        }
    }
}
