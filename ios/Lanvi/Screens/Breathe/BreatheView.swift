import SwiftUI

/// Breathe with Lanvi: about one minute of slow breathing with the fox.
///
/// Lanvi grows on the in-breath and settles on the out-breath; the ring of light behind
/// it and the aurora in the sky swell and fade with it. Everything follows one value,
/// `breath` (0 all the way out, 1 all the way in), moved by long eased animations, so the
/// motion never steps.
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
    @State private var breathsDone = 0
    @State private var result: BreatheResult?
    @State private var pose: LanviPose = .curious
    @State private var bounce = 0
    @State private var sparks = false

    private let demo = ProcessInfo.processInfo.arguments.contains("-demo")

    var body: some View {
        GeometryReader { geo in
            let safeTop = geo.safeAreaInsets.top
            let safeBottom = geo.safeAreaInsets.bottom
            let w = geo.size.width
            let h = geo.size.height + safeTop + safeBottom
            let hill = max(h * 0.60, h - safeBottom - 262).rounded()
            let fox = min(240, (h * 0.27).rounded())
            let foxY = hill + 16 - fox / 2
            let ring = fox * 1.3
            let ringY = foxY - fox * 0.08
            let skyTextY = (safeTop + ringY - ring * 0.54) / 2 + 10
            let snowTop = hill + 34
            let snowHeight = h - snowTop - safeBottom - 14

            ZStack(alignment: .topLeading) {
                SkyScene(top: Theme.nightTop, bottom: Theme.nightBottom, hillTop: hill)

                BreatheAurora(level: aurora)
                    .frame(width: w, height: hill * 0.62)

                GlowRing(breath: breath)
                    .frame(width: ring, height: ring)
                    .opacity(stage == .intro ? 0.6 : 1)
                    .position(x: w / 2, y: ringY)

                SparkBurst(fired: sparks)
                    .position(x: w / 2, y: foxY)

                LanviView(pose: pose, size: fox, bounceTrigger: bounce)
                    .scaleEffect(0.88 + 0.16 * breath, anchor: .bottom)
                    .position(x: w / 2, y: foxY)

                if stage == .session {
                    Text(phase.word)
                        .font(Theme.rounded(40, .heavy))
                        .foregroundStyle(.white)
                        .shadow(color: Theme.glow.opacity(0.9), radius: 14)
                        .id(phase)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.92)),
                            removal: .opacity))
                        .position(x: w / 2, y: skyTextY)
                        .accessibilityAddTraits(.updatesFrequently)
                }

                snowContent
                    .frame(width: w, height: snowHeight, alignment: .top)
                    .offset(y: snowTop)

                Button { onDone(nil) } label: { Image(systemName: "xmark") }
                    .buttonStyle(BreatheCornerButtonStyle())
                    .accessibilityLabel(stage == .finish ? "Close" : "Leave")
                    .position(x: w - 24 - 20, y: safeTop + 26)
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

    // MARK: - Snow area: words and the big button

    @ViewBuilder
    private var snowContent: some View {
        VStack(spacing: 0) {
            switch stage {
            case .intro:
                VStack(spacing: 8) {
                    Text("Breathe with Lanvi")
                        .font(Theme.rounded(30, .heavy))
                        .foregroundStyle(Theme.ink)
                    Text("One slow minute together.\nIn as I grow, out as I settle.")
                        .font(Theme.rounded(17, .semibold))
                        .foregroundStyle(Theme.inkSecondary)
                        .multilineTextAlignment(.center)
                }
                .transition(.opacity.combined(with: .offset(y: 12)))
                Spacer(minLength: 16)
                Button("Start", action: start)
                    .buttonStyle(ChunkyButtonStyle())
                    .padding(.horizontal, 24)
                    .transition(.opacity.combined(with: .offset(y: 30)))

            case .session:
                VStack(spacing: 14) {
                    BreathDots(total: BreathePace.breaths, done: breathsDone, breath: breath)
                    Text("Follow my glow")
                        .font(Theme.rounded(16, .semibold))
                        .foregroundStyle(Theme.inkSecondary)
                }
                .padding(.top, 6)
                .transition(.opacity.combined(with: .offset(y: 12)))
                Spacer()

            case .finish:
                VStack(spacing: 6) {
                    Text("Nice.")
                        .font(Theme.rounded(44, .black))
                        .foregroundStyle(Theme.brand)
                    Text("Thanks for breathing with me.")
                        .font(Theme.rounded(18, .semibold))
                        .foregroundStyle(Theme.inkSecondary)
                        .multilineTextAlignment(.center)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
                Spacer(minLength: 16)
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

        setPhase(.settle)
        withAnimation(.easeInOut(duration: BreathePace.settle)) {
            breath = 0
            aurora = 0.15
        }
        guard await wait(BreathePace.settle) else { return }

        for _ in 0..<BreathePace.breaths {
            setPhase(.inhale)
            withAnimation(.easeInOut(duration: BreathePace.inhale)) {
                breath = 0.95
                aurora = 0.8
            }
            guard await wait(BreathePace.inhale) else { return }

            setPhase(.hold)
            withAnimation(.easeInOut(duration: BreathePace.hold)) {
                breath = 1
                aurora = 0.85
            }
            guard await wait(BreathePace.hold) else { return }

            setPhase(.exhale)
            withAnimation(.easeInOut(duration: BreathePace.exhale)) {
                breath = 0
                aurora = 0.15
            }
            guard await wait(BreathePace.exhale) else { return }

            breathsDone += 1
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
        withAnimation(.easeInOut(duration: 1.6)) {
            breath = 0.55
            aurora = 1
        }
        bounce += 1
        sparks = true
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
