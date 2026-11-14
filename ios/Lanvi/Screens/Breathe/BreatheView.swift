import SwiftUI

/// Breathe with Lanvi: about one minute of slow breathing with the fox.
///
/// A soft light of aurora floats in the sky above Lanvi. On the in-breath it swells and its
/// motes drift in, the aurora overhead brightens, the night lifts a little and Lanvi's chest
/// rises as it looks up at the light; on the out-breath everything settles together.
/// One value, `breath` (0 all the way out, 1 all the way in), drives all of it, moved by long
/// curves shaped like real breathing, so nothing is linear and nothing steps.
///
/// `onDone` gets the result after the person taps Done, or `nil` when they leave early.
/// Launch with `-demo` and the session starts by itself (for recording the pitch video).
struct BreatheView: View {
    private let onDone: (BreatheResult?) -> Void

    init(onDone: @escaping (BreatheResult?) -> Void) {
        self.onDone = onDone
    }

    private enum Stage { case intro, session, finish }

    @Environment(AppStore.self) private var store: AppStore?

    @State private var stage: Stage = .intro
    @State private var phase: BreathPhase = .settle
    @State private var breath: CGFloat = 0.35
    @State private var aurora: Double = 0.2
    @State private var flare: CGFloat = 0
    /// 0 while breathing; 1 once the light has risen into the aurora at the finish.
    @State private var lift: CGFloat = 0
    @State private var breathsDone = 0
    @State private var progress: CGFloat = 0
    @State private var result: BreatheResult?
    @State private var pose: LanviPose = .curious
    @State private var bounce = 0
    @State private var reactTick = 0
    @State private var look: UnitPoint?
    @State private var appeared = false

    private let demo = ProcessInfo.processInfo.arguments.contains("-demo")

    var body: some View {
        GeometryReader { geo in
            let s = GameStage(geo)
            let fox: CGFloat = s.compact ? 158 : 208
            let feet = s.feet(fox: fox * 1.04, reserve: s.compact ? 92 : 100)
            let foxTop = feet - fox
            let skyMid = (s.belowBar + foxTop) / 2
            let bloomH = (foxTop - s.belowBar) * 1.08
            let scene: WorldScene = stage == .intro ? GameBackdrop.current(store) : .night
            let ink = GameInk.sky(scene)

            ZStack(alignment: .topLeading) {
                GameBackdrop(scene: scene, stage: s)

                // The night breathes too: a soft veil over the sky lifts on the in-breath.
                LinearGradient(colors: [Color(hex: 0x060D33).opacity(stage == .intro ? 0 : 0.34 * Double(1 - breath)), .clear],
                               startPoint: .top, endPoint: .bottom)
                    .frame(width: s.width, height: s.horizon + 60)
                    .allowsHitTesting(false)

                GameAuroraView(level: aurora)
                    .frame(width: s.width, height: s.height)
                    .opacity(stage == .intro && scene != .night ? 0 : 1)

                BreathBloom(breath: breath, flare: flare)
                    .frame(width: s.width, height: bloomH)
                    .scaleEffect(1 - 0.45 * lift)
                    .opacity(Double(1 - 0.92 * lift) * (stage == .intro ? 0 : 1))
                    .position(x: s.width / 2, y: skyMid - (skyMid - s.top - 40) * lift)

                LanviView(pose: pose, size: fox, bounceTrigger: bounce)
                    .lanviReaction(.happy, trigger: reactTick)
                    .lanviLookAt(look)
                    .scaleEffect(x: 1 + 0.016 * breath, y: 1 + 0.036 * breath, anchor: .bottom)
                    .frame(width: fox, height: fox)
                    .position(x: s.width / 2, y: feet - fox / 2)
                    .accessibilityHidden(true)

                Group {
                    words(s, feet: feet, skyMid: skyMid, ink: ink)
                    GameCloseButton {
                        if stage == .session { GameMoments.emit(.breatheEnded(finished: false)) }
                        onDone(nil)
                    }
                        .position(x: 24 + 22, y: s.barY)
                        .opacity(stage == .finish ? 0 : 1)
                        .disabled(stage == .finish)
                }
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 14)
            }
            .frame(width: s.width, height: s.height)
            .ignoresSafeArea()
        }
        .sensoryFeedback(.impact(flexibility: .soft, intensity: 0.5), trigger: phase)
        .sensoryFeedback(.success, trigger: stage == .finish)
        .onAppear {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.86).delay(0.1)) { appeared = true }
        }
        .task(id: stage) {
            if demo { print("breathe: stage \(stage)") }
            switch stage {
            case .intro:
                guard demo else { return }
                try? await Task.sleep(for: .seconds(2))
                if !Task.isCancelled { start() }
            case .session:
                await runSession()
            case .finish:
                try? await Task.sleep(for: .seconds(0.9))
                if !Task.isCancelled { reactTick += 1 }
            }
        }
    }

    // MARK: - Words and the button

    @ViewBuilder
    private func words(_ s: GameStage, feet: CGFloat, skyMid: CGFloat, ink: GameInk) -> some View {
        let below = s.bottom - feet
        ZStack(alignment: .topLeading) {
            switch stage {
            case .intro:
                VStack(spacing: 8) {
                    Text("Breathe with Lanvi")
                        .font(Theme.rounded(s.compact ? 30 : 34, .heavy))
                        .foregroundStyle(ink.title)
                    Text("One slow minute together.\nIn as the light grows, out as it settles.")
                        .font(Theme.rounded(s.compact ? 16 : 18, .semibold))
                        .foregroundStyle(ink.body)
                        .multilineTextAlignment(.center)
                }
                .gameLegible(ink)
                .frame(width: s.width - 40)
                .position(x: s.width / 2, y: skyMid)
                .transition(.opacity.combined(with: .offset(y: -10)))

                Button("Start", action: start)
                    .buttonStyle(ChunkyButtonStyle())
                    .padding(.horizontal, 24)
                    .frame(width: s.width)
                    .position(x: s.width / 2, y: s.buttonY)
                    .transition(.opacity.combined(with: .offset(y: 24)))

            case .session:
                GameLine(text: phase.word, font: Theme.rounded(s.compact ? 28 : 32, .heavy), color: GameInk.snow.title,
                         out: 0.22, into: 0.42)
                    .frame(width: s.width - 48)
                    .position(x: s.width / 2, y: feet + below * 0.36)
                    .accessibilityAddTraits(.updatesFrequently)
                    .transition(.opacity)
                BreathDots(total: BreathePace.breaths, done: breathsDone, progress: progress, breath: breath)
                    .position(x: s.width / 2, y: feet + below * 0.76)
                    .transition(.opacity.combined(with: .offset(y: 12)))

            case .finish:
                VStack(spacing: 8) {
                    Text("That was lovely.")
                        .font(Theme.rounded(s.compact ? 32 : 36, .black))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text("Thanks for breathing with me.")
                        .font(Theme.rounded(s.compact ? 17 : 19, .semibold))
                        .foregroundStyle(GameInk.sky(.night).body)
                        .multilineTextAlignment(.center)
                }
                .gameLegible(GameInk.sky(.night))
                .background(GameShade())
                .frame(width: s.width - 40)
                .position(x: s.width / 2, y: skyMid + (s.compact ? 10 : 30))
                .transition(.opacity.combined(with: .scale(scale: 0.94)))

                Button("Done") { onDone(result) }
                    .buttonStyle(ChunkyButtonStyle())
                    .padding(.horizontal, 24)
                    .frame(width: s.width)
                    .position(x: s.width / 2, y: s.buttonY)
                    .transition(.opacity.combined(with: .offset(y: 24)))
            }
        }
        .frame(width: s.width, height: s.height)
    }

    // MARK: - The session

    private func start() {
        guard stage == .intro else { return }
        withAnimation(.spring(response: 0.6, dampingFraction: 0.88)) {
            stage = .session
            pose = .love
        }
    }

    /// Runs the breaths one after the other. Cancelled (and nothing is returned) when the
    /// person leaves, because the view goes away and takes this task with it.
    private func runSession() async {
        let startedAt = Date()
        GameMoments.emit(.breatheStarted)
        breathsDone = 0
        progress = 0
        let total = BreathePace.inhale + BreathePace.hold + BreathePace.exhale

        phase = .settle
        withAnimation(BreathePace.settleCurve) {
            breath = 0
            aurora = 0.12
            look = UnitPoint(x: 0.5, y: -0.25)
        }
        guard await wait(BreathePace.settle) else { return }

        for number in 1...BreathePace.breaths {
            phase = .inhale
            GameMoments.emit(.breathIn(number: number))
            withAnimation(BreathePace.inhaleCurve) {
                breath = 0.95
                aurora = 0.8
                progress = BreathePace.inhale / total
                look = UnitPoint(x: 0.5, y: -0.7)
            }
            guard await wait(BreathePace.inhale) else { return }

            phase = .hold
            GameMoments.emit(.breathHold(number: number))
            withAnimation(.easeInOut(duration: BreathePace.hold)) {
                breath = 1
                aurora = 0.85
                progress = (BreathePace.inhale + BreathePace.hold) / total
            }
            guard await wait(BreathePace.hold) else { return }

            phase = .exhale
            GameMoments.emit(.breathOut(number: number))
            withAnimation(BreathePace.exhaleCurve) {
                breath = 0
                aurora = 0.12
                progress = 1
                look = UnitPoint(x: 0.5, y: -0.2)
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
        GameMoments.emit(.breatheEnded(finished: true))
        finish()
    }

    /// The light rises into the sky and the aurora opens out fully; Lanvi cheers.
    private func finish() {
        withAnimation(.spring(response: 0.7, dampingFraction: 0.82)) {
            stage = .finish
            pose = .cheer
        }
        withAnimation(.timingCurve(0.45, 0, 0.2, 1, duration: 2.4)) {
            breath = 0.7
            lift = 1
            look = UnitPoint(x: 0.5, y: -0.8)
        }
        withAnimation(.easeInOut(duration: 2.8).delay(0.4)) { aurora = 1 }
        withAnimation(.easeOut(duration: 2.6)) { flare = 1 }
        FaceSense.mark()   // a pleasant moment for the face sensor
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
