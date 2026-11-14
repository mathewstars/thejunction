import SwiftUI

/// Breathe with Lanvi: about one minute of slow breathing with the fox.
///
/// Lanvi grows on the in-breath and settles on the out-breath; the aurora bloom behind it,
/// its motes of light and the aurora in the sky swell and fade with it. Everything follows
/// one value, `breath` (0 all the way out, 1 all the way in), moved by long eased
/// animations, so the motion never steps.
///
/// `onDone` gets the result after the person taps Done, or `nil` when they leave early.
/// Launch with `-demo` and the session starts by itself (for recording the pitch video).
struct BreatheView: View {
    private let onDone: (BreatheResult?) -> Void

    init(onDone: @escaping (BreatheResult?) -> Void) {
        self.onDone = onDone
    }

    private enum Stage { case intro, session, finish }

    @State private var stage: Stage = .intro
    @State private var phase: BreathPhase = .settle
    @State private var breath: CGFloat = 0.35
    @State private var aurora: CGFloat = 0.3
    @State private var flare: CGFloat = 0
    @State private var breathsDone = 0
    @State private var progress: CGFloat = 0
    @State private var result: BreatheResult?
    @State private var pose: LanviPose = .love
    @State private var bounce = 0

    private let demo = ProcessInfo.processInfo.arguments.contains("-demo")

    var body: some View {
        GeometryReader { geo in
            let safeTop = geo.safeAreaInsets.top
            let safeBottom = geo.safeAreaInsets.bottom
            let w = geo.size.width
            let h = geo.size.height + safeTop + safeBottom
            // The horizon sits low so the night sky and Lanvi own the screen; the snow keeps
            // just enough room for the words and the button.
            let hill = max(h * 0.58, h - safeBottom - 215).rounded()
            let fox = min(236, (h * 0.27).rounded())
            let foxY = hill + 16 - fox / 2
            let bloom = fox * 3.55
            let snowTop = hill + 30
            let snowHeight = h - snowTop - safeBottom - 14

            ZStack(alignment: .topLeading) {
                SkyScene(top: Theme.nightTop, bottom: Theme.nightBottom, hillTop: hill)

                BreatheAurora(level: aurora)
                    .frame(width: w, height: hill * 0.62)

                BreathBloom(breath: breath, flare: flare)
                    .frame(width: w, height: bloom)
                    .position(x: w / 2, y: foxY - fox * 0.04)

                LanviView(pose: pose, size: fox, bounceTrigger: bounce)
                    .scaleEffect(0.88 + 0.16 * breath, anchor: .bottom)
                    .position(x: w / 2, y: foxY)

                snowContent
                    .frame(width: w, height: snowHeight)
                    .offset(y: snowTop)

                Button { onDone(nil) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 17, weight: .heavy))
                        .foregroundStyle(.white)
                }
                .buttonStyle(BreatheRoundButtonStyle())
                .accessibilityLabel("Close")
                .position(x: 24 + 22, y: safeTop + 6 + 22)
                .opacity(stage == .finish ? 0 : 1)
                .disabled(stage == .finish)
            }
            .ignoresSafeArea()
        }
        .sensoryFeedback(.impact(flexibility: .soft, intensity: 0.55), trigger: phase)
        .sensoryFeedback(.success, trigger: stage == .finish)
        .task(id: stage) {
            switch stage {
            case .intro:
                guard demo else { return }
                try? await Task.sleep(for: .seconds(1.5))
                if !Task.isCancelled { start() }
            case .session:
                await runSession()
            case .finish:
                return
            }
        }
    }

    // MARK: - Snow area: words, dots and the big button

    @ViewBuilder
    private var snowContent: some View {
        VStack(spacing: 0) {
            switch stage {
            case .intro:
                VStack(spacing: 6) {
                    Text("Breathe with Lanvi")
                        .font(Theme.rounded(30, .heavy))
                        .foregroundStyle(Theme.ink)
                    Text("One slow minute together.\nIn as I grow, out as I settle.")
                        .font(Theme.rounded(17, .semibold))
                        .foregroundStyle(Theme.inkSecondary)
                        .multilineTextAlignment(.center)
                }
                .transition(.opacity.combined(with: .offset(y: 12)))
                Spacer(minLength: 14)
                Button("Start", action: start)
                    .buttonStyle(ChunkyButtonStyle())
                    .padding(.horizontal, 24)
                    .transition(.opacity.combined(with: .offset(y: 30)))

            case .session:
                Spacer(minLength: 0)
                VStack(spacing: 16) {
                    Text(phase.word)
                        .font(Theme.rounded(32, .heavy))
                        .foregroundStyle(Theme.ink)
                        .id(phase)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.92)),
                            removal: .opacity))
                        .accessibilityAddTraits(.updatesFrequently)
                    BreathDots(total: BreathePace.breaths, done: breathsDone,
                               progress: progress, breath: breath)
                }
                .transition(.opacity.combined(with: .offset(y: 16)))

            case .finish:
                VStack(spacing: 6) {
                    Text("That was lovely.")
                        .font(Theme.rounded(34, .black))
                        .foregroundStyle(Theme.brand)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text("Thanks for breathing with me.")
                        .font(Theme.rounded(18, .semibold))
                        .foregroundStyle(Theme.inkSecondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 24)
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
                Spacer(minLength: 14)
                Button("Done") { onDone(result) }
                    .buttonStyle(ChunkyButtonStyle())
                    .padding(.horizontal, 24)
                    .transition(.opacity.combined(with: .offset(y: 30)))
            }
        }
        .padding(.bottom, 5)
    }

    // MARK: - The session

    private func start() {
        guard stage == .intro else { return }
        withAnimation(.spring(response: 0.5, dampingFraction: 0.88)) {
            stage = .session
        }
    }

    /// Runs the breaths one after the other. Cancelled (and nothing is returned) when the
    /// person leaves, because the view goes away and takes this task with it.
    private func runSession() async {
        let startedAt = Date()
        breathsDone = 0
        progress = 0
        let breathLength = BreathePace.inhale + BreathePace.hold + BreathePace.exhale

        setPhase(.settle)
        withAnimation(.easeInOut(duration: BreathePace.settle)) {
            breath = 0
            aurora = 0.1
        }
        guard await wait(BreathePace.settle) else { return }

        for _ in 0..<BreathePace.breaths {
            withAnimation(.linear(duration: breathLength)) { progress = 1 }

            setPhase(.inhale)
            withAnimation(.easeInOut(duration: BreathePace.inhale)) {
                breath = 0.95
                aurora = 0.85
            }
            guard await wait(BreathePace.inhale) else { return }

            setPhase(.hold)
            withAnimation(.easeInOut(duration: BreathePace.hold)) {
                breath = 1
                aurora = 0.9
            }
            guard await wait(BreathePace.hold) else { return }

            setPhase(.exhale)
            withAnimation(.easeInOut(duration: BreathePace.exhale)) {
                breath = 0
                aurora = 0.1
            }
            guard await wait(BreathePace.exhale) else { return }

            // The dot is full: count it and get the next dot ready, without animating the
            // reset, then let a frame pass before the next breath starts filling it.
            withTransaction(\.animation, nil) {
                breathsDone += 1
                progress = 0
            }
            guard await wait(0.05) else { return }
        }

        let endedAt = Date()
        result = BreatheResult(startedAt: startedAt, endedAt: endedAt,
                               breathsCompleted: breathsDone,
                               completed: breathsDone == BreathePace.breaths)
        finish()
    }

    private func finish() {
        withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) {
            stage = .finish
            pose = .cheer
        }
        withAnimation(.easeInOut(duration: 1.8)) {
            breath = 0.75
            aurora = 1
        }
        withAnimation(.easeOut(duration: 2.6)) { flare = 1 }
        bounce += 1
    }

    private func setPhase(_ next: BreathPhase) {
        withAnimation(.easeInOut(duration: 0.45)) { phase = next }
    }

    /// Sleeps for `seconds`; false when the session was cancelled meanwhile.
    private func wait(_ seconds: Double) async -> Bool {
        try? await Task.sleep(for: .seconds(seconds))
        return !Task.isCancelled
    }
}

#Preview {
    BreatheView { _ in }
}
