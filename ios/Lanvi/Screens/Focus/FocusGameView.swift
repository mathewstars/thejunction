import SwiftUI

/// Sparks and snow: tap the warm sparks, let the snowflakes fall. About 45 seconds.
///
/// Intro, then the round, then a warm finish. `onDone` gets the round's numbers from the
/// Done button, or `nil` when the person leaves early with the close button.
/// Launch with `-demo` and the round plays itself (for the pitch video and screenshots).
struct FocusGameView: View {
    private let onDone: (FocusResult?) -> Void

    init(onDone: @escaping (FocusResult?) -> Void) {
        self.onDone = onDone
    }

    private enum Phase { case intro, playing, finished }

    @State private var phase: Phase = .intro
    @State private var engine: FocusEngine?
    @State private var result: FocusResult?
    @State private var pose: LanviPose = .curious
    @State private var bounce = 0
    /// Sparks whose light has reached Lanvi's tail. Only ever goes up.
    @State private var glow = 0
    @State private var caughtTick = 0
    @State private var meltTick = 0
    @State private var touching = false
    @State private var poseToken = 0
    /// What Lanvi says under its feet during the round. Changes now and then, never about doing badly.
    @State private var line = "Tap the sparks"
    @State private var lineAt = Date.distantPast
    /// Sparks caught since the last one that drifted by.
    @State private var streak = 0

    private let demo = ProcessInfo.processInfo.arguments.contains("-demo")

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let small = h < 700
            let hill = h * (phase == .playing ? 0.80 : phase == .finished && !small ? 0.57 : 0.50)
            let size: CGFloat = switch phase {
            case .intro: small ? 150 : 185
            case .playing: small ? 100 : 118
            case .finished: small ? 160 : 235
            }
            let feet = hill + 14
            let tail = CGPoint(x: w / 2 + size * 0.25, y: feet - size * 0.28)
            let field = CGRect(x: 34, y: 78, width: w - 68, height: hill - 14 - 78)

            ZStack(alignment: .topLeading) {
                SkyScene(top: Theme.nightTop, bottom: Theme.nightBottom, hillTop: hill + geo.safeAreaInsets.top)

                switch phase {
                case .intro:
                    FocusDecor()
                        .frame(width: w, height: hill - 20)
                        .transition(.opacity)
                case .finished:
                    FocusDecor(rising: true)
                        .frame(width: w, height: hill)
                        .transition(.opacity)
                case .playing:
                    EmptyView()
                }

                tailGlow(size: size)
                    .position(phase == .playing ? tail : CGPoint(x: w / 2, y: feet - size * 0.45))

                if phase == .playing, let engine {
                    FocusSky(engine: engine, field: field, tail: tail)
                        .contentShape(Rectangle())
                        .gesture(touchGesture)
                        .transition(.opacity)
                }

                LanviView(pose: pose, size: size, bounceTrigger: bounce)
                    .position(x: w / 2, y: feet - size / 2)
                    .allowsHitTesting(false)

                if phase == .playing {
                    tailFlare(size: size).position(tail)
                }

                content(width: w, height: h, hill: hill, feet: feet)
            }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: caughtTick)
        .sensoryFeedback(.impact(flexibility: .soft, intensity: 0.35), trigger: meltTick)
        .sensoryFeedback(.success, trigger: phase == .finished)
        .task(id: phase) { await run(phase) }
    }

    // MARK: Layers

    /// Lanvi's tail glows warmer with every spark caught, and pulses when one arrives.
    private func tailGlow(size: CGFloat) -> some View {
        let base: CGFloat = phase == .finished ? size * 1.5 : size * 0.7 + CGFloat(min(glow, 30)) * 3
        return Circle()
            .fill(RadialGradient(
                colors: [FocusArt.gold.opacity(phase == .intro ? 0.18 : 0.5), FocusArt.ember.opacity(0)],
                center: .center, startRadius: 0, endRadius: base / 2))
            .frame(width: base, height: base)
            .keyframeAnimator(initialValue: CGFloat(1), trigger: glow) { view, s in
                view.scaleEffect(s)
            } keyframes: { _ in
                SpringKeyframe(1.35, duration: 0.15, spring: .snappy)
                SpringKeyframe(1, duration: 0.5, spring: .bouncy)
            }
            .blendMode(.plusLighter)
            .allowsHitTesting(false)
    }

    /// The moment a spark's light lands, the tail flares bright and settles again.
    private func tailFlare(size: CGFloat) -> some View {
        Circle()
            .fill(RadialGradient(colors: [FocusArt.core, FocusArt.gold.opacity(0.7), FocusArt.gold.opacity(0)],
                                 center: .center, startRadius: 0, endRadius: size * 0.22))
            .frame(width: size * 0.44, height: size * 0.44)
            .keyframeAnimator(initialValue: FlareState(), trigger: glow) { view, f in
                view.scaleEffect(f.scale).opacity(f.opacity)
            } keyframes: { _ in
                KeyframeTrack(\.opacity) {
                    LinearKeyframe(0.95, duration: 0.06)
                    CubicKeyframe(0, duration: 0.45)
                }
                KeyframeTrack(\.scale) {
                    SpringKeyframe(1.3, duration: 0.12, spring: .snappy)
                    CubicKeyframe(0.8, duration: 0.4)
                }
            }
            .blendMode(.plusLighter)
            .allowsHitTesting(false)
    }

    @ViewBuilder
    private func content(width w: CGFloat, height h: CGFloat, hill: CGFloat, feet: CGFloat) -> some View {
        switch phase {
        case .intro:
            VStack(spacing: 0) {
                topBar(showTime: false)
                Spacer().frame(height: max(0, feet + 22 - 50))
                Text("Sparks and snow")
                    .font(Theme.rounded(30, .heavy))
                    .foregroundStyle(Theme.ink)
                Text("Tap the sparks, let the snow fall.")
                    .font(Theme.rounded(18, .semibold))
                    .foregroundStyle(Theme.inkSecondary)
                    .padding(.top, 4)
                HStack(spacing: 12) {
                    howTo(spark: true, text: "Tap the sparks")
                    howTo(spark: false, text: "Let snow fall")
                }
                .padding(.top, h < 700 ? 14 : 22)
                Spacer(minLength: 12)
                Text("About 45 seconds. Stop any time.")
                    .font(Theme.rounded(15, .semibold))
                    .foregroundStyle(Theme.inkSecondary)
                    .padding(.bottom, 14)
                Button("Start") { start() }
                    .buttonStyle(ChunkyButtonStyle())
                    .padding(.bottom, 12)
            }
            .padding(.horizontal, 24)
            .frame(width: w, height: h)
            .transition(.opacity)

        case .playing:
            ZStack(alignment: .top) {
                topBar(showTime: true)
                    .padding(.horizontal, 24)
                Text(line)
                    .font(Theme.rounded(17, .heavy))
                    .foregroundStyle(Theme.inkSecondary)
                    .id(line)
                    .transition(.opacity.combined(with: .offset(y: 4)))
                    .position(x: w / 2, y: feet + max(22, (h - feet) / 2))
                    .allowsHitTesting(false)
            }
            .frame(width: w, height: h)
            .transition(.opacity)

        case .finished:
            VStack(spacing: 0) {
                // The words sit centred in the snow between Lanvi and the button.
                Spacer().frame(height: max(0, feet + 10))
                Spacer(minLength: 12)
                Text("Lanvi's tail is glowing!")
                    .font(Theme.rounded(28, .heavy))
                    .foregroundStyle(Theme.ink)
                    .multilineTextAlignment(.center)
                if let caught = result?.correctTaps, caught > 0 {
                    HStack(spacing: 8) {
                        Image(systemName: "sparkles")
                        Text(caught == 1 ? "1 spark caught" : "\(caught) sparks caught")
                    }
                    .font(Theme.rounded(17, .heavy))
                    .foregroundStyle(Theme.brand)
                    .padding(.vertical, 10)
                    .padding(.horizontal, 16)
                    .background(Capsule().fill(Theme.tint))
                    .overlay(Capsule().stroke(Theme.line, lineWidth: 2))
                    .padding(.top, 14)
                }
                Text("Thanks for playing with me.")
                    .font(Theme.rounded(18, .semibold))
                    .foregroundStyle(Theme.inkSecondary)
                    .padding(.top, 14)
                Spacer(minLength: 12)
                Button("Done") { onDone(result) }
                    .buttonStyle(ChunkyButtonStyle())
                    .padding(.bottom, 12)
            }
            .padding(.horizontal, 24)
            .frame(width: w, height: h)
            .transition(.opacity)
        }
    }

    private func topBar(showTime: Bool) -> some View {
        HStack(spacing: 16) {
            Button { onDone(nil) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 17, weight: .heavy))
                    .foregroundStyle(.white)
            }
            .buttonStyle(RoundChunkyStyle())
            .accessibilityLabel("Close")

            if showTime, let engine {
                TimeBar(start: engine.start, length: FocusEngine.roundLength)
                    .padding(.trailing, 4)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 6)
        .frame(height: 50)
    }

    private func howTo(spark: Bool, text: String) -> some View {
        VStack(spacing: 8) {
            FocusArtIcon(spark: spark)
            Text(text)
                .font(Theme.rounded(15, .heavy))
                .foregroundStyle(Theme.ink)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(.white))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Theme.line, lineWidth: 2))
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Theme.line).offset(y: 4))
    }

    // MARK: Playing

    /// Reacts on touch down, so the reaction time is the moment the finger lands.
    private var touchGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard !touching else { return }
                touching = true
                handleTap(at: value.startLocation)
            }
            .onEnded { _ in touching = false }
    }

    private func handleTap(at point: CGPoint) {
        guard phase == .playing, let engine else { return }
        switch engine.tap(at: point, now: Date()) {
        case .caught(let ms):
            caughtTick += 1
            streak += 1
            if engine.correctTaps == 1 {
                say("Ooh, warm!", always: true)
            } else if streak.isMultiple(of: 4) {
                say(["My tail feels warm", "Look at them glow", "So pretty", "More fox fires!", "That one sparkled"]
                    .randomElement()!)
            }
            if demo { print("focus: caught after \(ms) ms") }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(FocusEngine.flightTime))
                lightArrived()
            }
        case .melted:
            meltTick += 1
            say(["Brr, chilly!", "Snow likes to fall"].randomElement()!)
            if demo { print("focus: snowflake melted") }
        case .nothing:
            break
        }
    }

    /// Lanvi says something new under its feet; the old line fades out as the new one fades in.
    /// Not more often than every few seconds, so it stays calm.
    private func say(_ text: String, always: Bool = false) {
        guard text != line, always || Date().timeIntervalSince(lineAt) > 3.5 else { return }
        lineAt = Date()
        if demo { print("focus: lanvi says \(text)") }
        withAnimation(.easeInOut(duration: 0.45)) { line = text }
    }

    /// A spark's light reached the tail: the tail glows, Lanvi hops, and now and then shows some love.
    private func lightArrived() {
        guard phase == .playing else { return }
        glow += 1
        bounce &+= 1
        guard glow.isMultiple(of: 5) else { return }
        poseToken += 1
        let token = poseToken
        withAnimation(.spring(response: 0.42, dampingFraction: 0.62)) { pose = glow.isMultiple(of: 10) ? .cheer : .love }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            guard phase == .playing, token == poseToken else { return }
            withAnimation(.spring(response: 0.42, dampingFraction: 0.62)) { pose = .curious }
        }
    }

    private func start() {
        guard phase == .intro else { return }
        engine = FocusEngine()
        withAnimation(.spring(response: 0.6, dampingFraction: 0.86)) { phase = .playing }
    }

    private func finish() {
        guard phase == .playing, let engine else { return }
        let end = Date()
        engine.end(now: end)
        result = engine.result(completed: true, endedAt: end)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.7))
            withAnimation(.spring(response: 0.6, dampingFraction: 0.82)) {
                phase = .finished
                pose = .cheer
            }
        }
    }

    // MARK: Timing

    private func run(_ phase: Phase) async {
        if demo { print("focus: phase \(phase)") }
        switch phase {
        case .intro:
            guard demo else { return }
            try? await Task.sleep(for: .seconds(3.5))
            guard !Task.isCancelled else { return }
            start()

        case .playing:
            guard let engine else { return }
            if demo { Task { await autoplay(engine) } }
            let end = engine.start.addingTimeInterval(FocusEngine.roundLength)
            var seenMisses = 0, seenSnow = 0, saidLastBit = false
            // Watch the round a few times a second so Lanvi can comment on what drifts by.
            while Date() < end {
                try? await Task.sleep(for: .seconds(min(0.25, max(0, end.timeIntervalSinceNow))))
                guard !Task.isCancelled else { return }
                if engine.misses > seenMisses {
                    seenMisses = engine.misses
                    streak = 0
                    if Int.random(in: 0..<3) == 0 { say(["Plenty more coming", "More are on the way"].randomElement()!) }
                }
                if engine.snowPassed > seenSnow {
                    seenSnow = engine.snowPassed
                    if Bool.random() { say(["Let it drift", "Bye, little snowflake", "Snow can fall"].randomElement()!) }
                }
                if !saidLastBit && end.timeIntervalSinceNow < 9 {
                    saidLastBit = true
                    say("A few more sparks", always: true)
                }
            }
            guard !Task.isCancelled else { return }
            finish()

        case .finished:
            for delay in [0.35, 0.8, 0.8] {
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                bounce &+= 1
            }
            if demo, let result {
                print("focus: result \(result)")
            }
        }
    }

    /// Demo only: plays the round through the same tap path as a finger would,
    /// catching most sparks, letting a few go and melting a couple of snowflakes.
    private func autoplay(_ engine: FocusEngine) async {
        var melted = 0
        while phase == .playing && engine.endedAt == nil {
            try? await Task.sleep(for: .seconds(0.1))
            let t = engine.clock(Date())
            for d in engine.drops {
                let age = t - d.born
                switch d.kind {
                case .spark:
                    guard d.id % 6 != 4 else { continue }           // let a few drift by
                    if age > 0.7 + Double(d.id % 5) * 0.18 {
                        handleTap(at: engine.position(of: d, at: t))
                    }
                case .snow:
                    let due = (melted == 0 && t > 14) || (melted == 1 && t > 30)
                    if due && age > 1.5 {
                        melted += 1
                        handleTap(at: engine.position(of: d, at: t))
                    }
                }
            }
        }
    }
}

/// The quiet round timer: a soft bar that fills as the round goes.
private struct TimeBar: View {
    let start: Date
    let length: TimeInterval

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { timeline in
            let p = min(1, max(0, timeline.date.timeIntervalSince(start) / length))
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.2))
                    Capsule()
                        .fill(LinearGradient(colors: [Theme.aurora, .white], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(16, geo.size.width * p))
                        .overlay(alignment: .top) {
                            Capsule().fill(.white.opacity(0.55)).frame(height: 3).padding(.horizontal, 6).padding(.top, 3)
                        }
                }
            }
            .frame(height: 16)
        }
        .accessibilityLabel("Time")
    }
}

/// A round, see-through 3D button for the close button on the sky.
private struct RoundChunkyStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        configuration.label
            .frame(width: 44, height: 44)
            .background(Circle().fill(Color(hex: 0x3A5BC7)))
            .overlay(Circle().stroke(.white.opacity(0.22), lineWidth: 1.5))
            .offset(y: pressed ? 4 : 0)
            .background(Circle().fill(Theme.nightTop).offset(y: 4))
            .contentShape(Circle())
            .animation(.spring(response: 0.16, dampingFraction: 0.7), value: pressed)
            .sensoryFeedback(.impact(weight: .light), trigger: pressed)
    }
}

/// Brightness and size of the tail flare.
private struct FlareState {
    var opacity: Double = 0
    var scale: CGFloat = 0.8
}
