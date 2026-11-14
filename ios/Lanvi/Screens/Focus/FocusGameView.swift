import SwiftUI

/// Sparks and snow: tap the warm sparks, let the snowflakes fall. About 45 seconds.
///
/// Every spark you catch bursts, then rises into the night and becomes part of the aurora
/// ("fox fires": the legend says the fox's sparks make the northern lights), so the sky
/// overhead grows fuller and brighter catch by catch, and the finish shows the aurora you made.
/// Lanvi sits in the snow and watches each light go up. No light ever touches the fox.
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
    @State private var reactTick = 0
    @State private var look: UnitPoint?
    @State private var lookToken = 0
    @State private var caughtTick = 0
    @State private var meltTick = 0
    @State private var touching = false
    @State private var appeared = false
    /// What Lanvi says under its feet during the round. Changes now and then, never about doing badly.
    @State private var line = "Tap the sparks"
    @State private var lineAt = Date.distantPast
    /// Sparks caught since the last one that drifted by.
    @State private var streak = 0

    private let demo = ProcessInfo.processInfo.arguments.contains("-demo")

    /// Where everything sits for one screen size.
    private struct Layout {
        var fox: CGFloat
        var feet: CGFloat
        var field: CGRect
        var captionY: CGFloat
        /// Where the finish words sit: in the clear sky between the aurora and the far hills.
        var finishY: CGFloat

        init(_ s: GameStage) {
            fox = s.compact ? 150 : 196
            feet = s.feet(fox: fox * 1.1, reserve: 96)
            let playTop = feet - fox * 0.84
            field = CGRect(x: 26, y: s.belowBar + 8, width: s.width - 52, height: max(160, playTop - 8 - s.belowBar - 8))
            finishY = min(s.world.point(0.5, 0.43).y, feet - fox * 1.1 - 70)
            captionY = (feet + s.buttonY - 27) / 2 + 2
        }

        func scale(_ phase: Phase, compact: Bool) -> CGFloat {
            switch phase {
            case .intro: 1
            case .playing: 0.84
            case .finished: compact ? 1.0 : 1.1
            }
        }
    }

    var body: some View {
        GeometryReader { geo in
            let s = GameStage(geo)
            let L = Layout(s)
            let scale = L.scale(phase, compact: s.compact)

            ZStack(alignment: .topLeading) {
                GameBackdrop(scene: .night, stage: s)

                FocusSky(engine: engine, field: L.field, screen: s.size)

                if phase == .playing {
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(touchGesture)
                        .accessibilityLabel("The sky. Tap the sparks.")
                }

                LanviView(pose: pose, size: L.fox, bounceTrigger: bounce)
                    .lanviReaction(.happy, trigger: reactTick)
                    .lanviLookAt(look)
                    .scaleEffect(scale, anchor: .bottom)
                    .frame(width: L.fox, height: L.fox)
                    .position(x: s.width / 2, y: L.feet - L.fox / 2)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)

                content(s, L, scale: scale)
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 14)
            }
            .frame(width: s.width, height: s.height)
            .ignoresSafeArea()
            .onAppear { lastStage = s }
            .onChange(of: geo.size) { lastStage = GameStage(geo) }
        }
        .sensoryFeedback(.impact(weight: .light, intensity: 0.8), trigger: caughtTick)
        .sensoryFeedback(.impact(flexibility: .soft, intensity: 0.35), trigger: meltTick)
        .sensoryFeedback(.success, trigger: phase == .finished)
        .onAppear {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.86).delay(0.1)) { appeared = true }
            look = UnitPoint(x: 0.5, y: -0.5)
        }
        .task(id: phase) { await run(phase) }
    }

    // MARK: Words and buttons

    @ViewBuilder
    private func content(_ s: GameStage, _ L: Layout, scale: CGFloat) -> some View {
        let sky = GameInk.sky(.night)
        let foxTop = L.feet - L.fox * scale
        ZStack(alignment: .topLeading) {
            switch phase {
            case .intro:
                VStack(spacing: s.compact ? 6 : 8) {
                    Text("Sparks and snow")
                        .font(Theme.rounded(s.compact ? 30 : 34, .heavy))
                        .foregroundStyle(sky.title)
                    Text("Catch the sparks. Each one\nlights up the sky.")
                        .font(Theme.rounded(s.compact ? 16 : 18, .semibold))
                        .foregroundStyle(sky.body)
                        .multilineTextAlignment(.center)
                    HStack(spacing: s.compact ? 36 : 56) {
                        howTo(spark: true, text: "Tap the sparks", ink: sky, compact: s.compact)
                        howTo(spark: false, text: "Let snow fall", ink: sky, compact: s.compact)
                    }
                    .padding(.top, s.compact ? 8 : 18)
                }
                .gameLegible(sky)
                .frame(width: s.width - 40)
                .position(x: s.width / 2, y: (s.belowBar + foxTop) / 2 + (s.compact ? 6 : 18))
                .transition(.opacity.combined(with: .offset(y: -10)))

                Text("About 45 seconds. Stop any time.")
                    .font(Theme.rounded(15, .bold))
                    .foregroundStyle(GameInk.snow.body)
                    .position(x: s.width / 2, y: L.captionY)
                    .transition(.opacity)

                Button("Start") { start() }
                    .buttonStyle(ChunkyButtonStyle())
                    .padding(.horizontal, 24)
                    .frame(width: s.width)
                    .position(x: s.width / 2, y: s.buttonY)
                    .transition(.opacity.combined(with: .offset(y: 24)))

            case .playing:
                if let engine {
                    TimeBar(start: engine.start, length: FocusEngine.roundLength)
                        .frame(width: s.width - 24 - 44 - 16 - 28)
                        .position(x: 24 + 44 + 16 + (s.width - 24 - 44 - 16 - 28) / 2, y: s.barY)
                        .transition(.opacity)
                }
                GameLine(text: line, font: Theme.rounded(18, .heavy), color: GameInk.snow.body)
                    .frame(width: s.width - 48)
                    .position(x: s.width / 2, y: (L.feet + s.bottom) / 2)
                    .allowsHitTesting(false)
                    .transition(.opacity)

            case .finished:
                let caught = result?.correctTaps ?? 0
                VStack(spacing: s.compact ? 8 : 12) {
                    Text(caught > 0 ? "You lit up the sky!" : "What a snowy night.")
                        .font(Theme.rounded(s.compact ? 30 : 34, .heavy))
                        .foregroundStyle(sky.title)
                        .multilineTextAlignment(.center)
                    if caught > 0 {
                        HStack(spacing: 2) {
                            FocusArtPreview(spark: true, size: 40)
                            Text(caught == 1 ? "1 spark became northern lights" : "\(caught) sparks became northern lights")
                                .font(Theme.rounded(17, .heavy))
                                .foregroundStyle(sky.title)
                        }
                        .padding(.trailing, 14)
                    }
                    Text("Thanks for playing with me.")
                        .font(Theme.rounded(s.compact ? 16 : 18, .semibold))
                        .foregroundStyle(sky.body)
                }
                .gameLegible(sky)
                .background(GameShade())
                .frame(width: s.width - 40)
                .position(x: s.width / 2, y: L.finishY)
                .transition(.opacity.combined(with: .scale(scale: 0.94)))

                Button("Done") { onDone(result) }
                    .buttonStyle(ChunkyButtonStyle())
                    .padding(.horizontal, 24)
                    .frame(width: s.width)
                    .position(x: s.width / 2, y: s.buttonY)
                    .transition(.opacity.combined(with: .offset(y: 24)))
            }

            if phase != .finished {
                GameCloseButton {
                    if phase == .playing { GameMoments.emit(.focusEnded(finished: false)) }
                    onDone(nil)
                }
                    .position(x: 24 + 22, y: s.barY)
                    .transition(.opacity)
            }
        }
        .frame(width: s.width, height: s.height)
    }

    private func howTo(spark: Bool, text: String, ink: GameInk, compact: Bool) -> some View {
        VStack(spacing: -6) {
            FocusArtPreview(spark: spark, size: compact ? 70 : 84)
            Text(text)
                .font(Theme.rounded(15, .heavy))
                .foregroundStyle(ink.title)
        }
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
        case .caught(let ms, let toward):
            GameMoments.emit(.sparkCaught(reactionMs: ms))
            caughtTick += 1
            streak += 1
            if engine.correctTaps == 1 {
                say("Ooh, look up!", always: true)
            } else if streak.isMultiple(of: 4) {
                say(["Look at the sky!", "The lights are growing", "More fox fires!", "So pretty", "That one went so high"]
                    .randomElement()!)
            }
            watch(toward)
            if demo { print("focus: caught after \(ms) ms") }
        case .melted:
            GameMoments.emit(.snowTapped)
            meltTick += 1
            say(["Brr, chilly!", "Snow likes to fall"].randomElement()!)
            if demo { print("focus: snowflake melted") }
        case .nothing:
            break
        }
    }

    /// Lanvi's eyes and head follow the light up into the sky, then come back.
    private func watch(_ point: CGPoint) {
        guard let stage = lastStage else { return }
        let L = Layout(stage)
        let side = L.fox * L.scale(.playing, compact: stage.compact)
        let minX = stage.width / 2 - side / 2
        let minY = L.feet - side
        let target = UnitPoint(x: (point.x - minX) / side, y: max(-1.2, (point.y - minY) / side))
        lookToken += 1
        let token = lookToken
        withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) { look = target }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.3))
            guard token == lookToken, phase == .playing else { return }
            withAnimation(.spring(response: 0.7, dampingFraction: 0.85)) { look = nil }
        }
    }

    /// Lanvi says something new under its feet; the old line fades out before the new one fades in.
    /// Not more often than every few seconds, so it stays calm.
    private func say(_ text: String, always: Bool = false) {
        guard text != line, always || Date().timeIntervalSince(lineAt) > 3.5 else { return }
        lineAt = Date()
        if demo { print("focus: lanvi says \(text)") }
        line = text
    }

    private func start() {
        guard phase == .intro else { return }
        engine = FocusEngine()
        GameMoments.emit(.focusStarted)
        withAnimation(.spring(response: 0.6, dampingFraction: 0.86)) {
            phase = .playing
            look = nil
        }
    }

    private func finish() {
        guard phase == .playing, let engine else { return }
        let end = Date()
        engine.end(now: end)
        result = engine.result(completed: true, endedAt: end)
        GameMoments.emit(.focusEnded(finished: true))
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.7))
            withAnimation(.spring(response: 0.65, dampingFraction: 0.82)) {
                phase = .finished
                pose = .cheer
                look = UnitPoint(x: 0.5, y: -0.7)
            }
        }
    }

    // MARK: Timing

    /// The stage from the last layout, so a tap can work out where Lanvi is.
    @State private var lastStage: GameStage?

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
            var seenMisses = 0, seenSnow = 0, seenFed = 0, saidLastBit = false
            // Watch the round a few times a second so Lanvi can react to what happens in the sky.
            while Date() < end {
                try? await Task.sleep(for: .seconds(min(0.25, max(0, end.timeIntervalSinceNow))))
                guard !Task.isCancelled else { return }
                if engine.fed > seenFed {
                    // Every fifth light that lands in the aurora, a happy little hop.
                    if engine.fed / 5 > seenFed / 5 { reactTick += 1 }
                    seenFed = engine.fed
                }
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
            // A small celebration: two happy hops while the aurora ripples.
            for delay in [0.5, 1.1] {
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                reactTick += 1
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
                    if age > 0.9 + Double(d.id % 5) * 0.22 {
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
                    Capsule().fill(Color(hex: 0x07103A).opacity(0.45))
                        .overlay(Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 1.5))
                    Capsule()
                        .fill(LinearGradient(colors: [GameAurora.mint, Theme.aurora, .white], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(16, geo.size.width * p))
                        .overlay(alignment: .top) {
                            Capsule().fill(.white.opacity(0.55)).frame(height: 3).padding(.horizontal, 6).padding(.top, 3)
                        }
                        .shadow(color: GameAurora.mint.opacity(0.5), radius: 6)
                }
            }
            .frame(height: 16)
        }
        .accessibilityLabel("Time")
    }
}
