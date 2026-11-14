import SwiftUI

/// What Lanvi has learned about what suits the person (`GET /v1/mind`), in
/// plain words. Each lesson has a "Not true" button; open questions (at most
/// three) take yes / no / not sure. The person's word always wins.
struct HomeMindScreen: View {
    var onClose: () -> Void

    @Environment(AppStore.self) private var store
    @State private var pose: LanviPose = .curious
    @State private var bounce = 0
    @State private var say = "Here is what I've noticed so far. Tell me if I got something wrong."
    @State private var busy: String?

    var body: some View {
        GeometryReader { geo in
            let compact = geo.size.height < 700
            let hill = geo.size.height * (compact ? 0.34 : 0.36)
            let fox: CGFloat = compact ? 110 : 132
            ZStack(alignment: .top) {
                PaintedWorld(scene: store.worldScene)

                HStack(alignment: .bottom, spacing: 4) {
                    HomeSpeechBubble(text: say, pointAt: 0.92)
                        .frame(maxWidth: .infinity)
                        .padding(.bottom, fox * 0.55)
                    ZStack {
                        LanviView(pose: pose, size: fox, bounceTrigger: bounce)
                    }
                    .frame(width: fox, height: fox)
                }
                .padding(.horizontal, 16)
                .frame(height: hill + 14, alignment: .bottom)

                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        content
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 22)
                    .padding(.bottom, 30)
                }
                .scrollIndicators(.hidden)
                .padding(.top, hill + 14)

                HStack {
                    HomeCloseButton(action: onClose)
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.top, 6)
            }
        }
        .task { await store.loadMind() }
    }

    @ViewBuilder private var content: some View {
        if let mind = store.mind {
            if mind.lessons.isEmpty && mind.questions.isEmpty {
                emptyCard
            }
            if !mind.lessons.isEmpty {
                sectionTitle("What seems to suit you")
                ForEach(mind.lessons) { lesson in
                    lessonCard(lesson)
                        .transition(.asymmetric(insertion: .opacity, removal: .scale(scale: 0.8).combined(with: .opacity)))
                }
            }
            if !mind.questions.isEmpty {
                sectionTitle("Can I ask you something?")
                    .padding(.top, 6)
                ForEach(mind.questions.prefix(3)) { q in
                    questionCard(q)
                        .transition(.asymmetric(insertion: .opacity, removal: .scale(scale: 0.8).combined(with: .opacity)))
                }
            }
        } else if store.mindFailed {
            messageCard("I can't reach my notes right now. Let's look again a bit later.")
        } else {
            HStack { Spacer(); ProgressView().tint(Theme.brand).padding(30); Spacer() }
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(Theme.rounded(13, .black))
            .textCase(.uppercase)
            .tracking(0.8)
            .foregroundStyle(Theme.brand)
    }

    private var emptyCard: some View {
        messageCard("I'm still getting to know you. Play with me a few times, and I'll share what I notice.")
    }

    private func messageCard(_ text: String) -> some View {
        Text(text)
            .font(Theme.rounded(17, .bold))
            .foregroundStyle(Theme.ink)
            .fixedSize(horizontal: false, vertical: true)
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(MindCardBackground())
    }

    private func lessonCard(_ lesson: API.Lesson) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                MindGlowDot()
                Text(lesson.text)
                    .font(Theme.rounded(17, .heavy))
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if let n = lesson.evidenceCount, n > 0 {
                    Text(n == 1 ? "From one time we played" : "From \(n) times we played")
                        .font(Theme.rounded(13, .bold))
                        .foregroundStyle(Theme.inkSecondary)
                }
                Spacer()
                Button("Not true") { reject(lesson) }
                    .buttonStyle(MindSmallButtonStyle())
                    .disabled(busy != nil)
            }
        }
        .padding(16)
        .modifier(MindCardBackground())
    }

    private func questionCard(_ q: API.Question) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(q.text)
                .font(Theme.rounded(18, .heavy))
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                ForEach(q.answers, id: \.self) { a in
                    Button(Self.label(a)) { answer(q, a) }
                        .buttonStyle(MindSmallButtonStyle(filled: a == "yes"))
                        .disabled(busy != nil)
                }
            }
        }
        .padding(16)
        .modifier(MindCardBackground())
    }

    private static func label(_ answer: String) -> String {
        switch answer {
        case "yes": return "Yes"
        case "no": return "No"
        default: return "Not sure"
        }
    }

    private func reject(_ lesson: API.Lesson) {
        busy = lesson.id
        Task {
            let ok = await store.rejectLesson(lesson.id)
            busy = nil
            react(ok ? "Thanks for telling me. I'll forget that one." : "I couldn't save that just now. Can we try again in a bit?",
                  ok ? .love : .curious)
        }
    }

    private func answer(_ q: API.Question, _ a: String) {
        busy = q.id
        Task {
            let ok = await store.answerQuestion(q.id, answer: a)
            busy = nil
            react(ok ? "Thank you. That helps me a lot." : "I couldn't save that just now. Can we try again in a bit?",
                  ok ? .cheer : .curious)
        }
    }

    private func react(_ text: String, _ newPose: LanviPose) {
        say = text
        pose = newPose
    }
}

/// White card with the same 3D edge as the rest of the app.
private struct MindCardBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(.white))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Theme.line, lineWidth: 2))
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Theme.line).offset(y: 4))
    }
}

/// A small soft light, like a mote from Lanvi's tail.
private struct MindGlowDot: View {
    var body: some View {
        ZStack {
            Circle().fill(RadialGradient(colors: [Color(hex: 0x3EE6A8).opacity(0.55), .clear],
                                         center: .center, startRadius: 0, endRadius: 14))
            Circle().fill(RadialGradient(colors: [.white, Color(hex: 0x5CCBFF)],
                                         center: .center, startRadius: 0, endRadius: 5))
                .frame(width: 9, height: 9)
                .shadow(color: Color(hex: 0x5CCBFF), radius: 4)
        }
        .frame(width: 26, height: 26)
    }
}

private struct MindSmallButtonStyle: ButtonStyle {
    var filled = false
    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        configuration.label
            .font(Theme.rounded(14, .heavy))
            .foregroundStyle(filled ? .white : Theme.brand)
            .padding(.horizontal, 14)
            .frame(height: 38)
            .background(shape.fill(filled ? Theme.brand : .white))
            .overlay(shape.stroke(filled ? .clear : Theme.line, lineWidth: 2))
            .offset(y: pressed ? 3 : 0)
            .background(shape.fill(filled ? Theme.brandEdge : Theme.line).offset(y: 3))
            .animation(LanviTiming.press, value: pressed)
            .sensoryFeedback(.impact(weight: .light), trigger: pressed)
    }
}
