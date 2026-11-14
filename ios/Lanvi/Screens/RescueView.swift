import SwiftUI

/// The opening: the rescue (the captain, Saturday). A small fox kit lies curled
/// in the snow, alone, snow on his fur. The person holds a finger on him for
/// about three seconds to warm him: a warm ring of light grows under the finger
/// and soft haptics tick like a slow heartbeat. Letting go early eases back and
/// waits; there is no failure. When the hold completes he wakes, the snow falls
/// off, he sits up: "…you stayed." then "I'm Lanvi.", and first run continues.
///
/// He is rescued once. After this he is safe for good.
struct RescueView: View {
    var auto: Bool = false          // -demo and -flow: the hold plays by itself
    var onDone: () -> Void

    private static let holdSeconds = 3.0

    @State private var showLine = false
    @State private var showHint = false
    @State private var holding = false
    @State private var touch: CGPoint?
    @State private var warmth: Double = 0          // 0...1, how far the hold has come
    @State private var awake = false
    @State private var say: String?
    @State private var mouth: MouthShape?
    @State private var heartbeat = 0
    @State private var wakeTick = 0
    @State private var shakeOff: Date?
    @State private var holdTask: Task<Void, Never>?
    @State private var kitCenter: CGPoint = .zero

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            // The same place, size and ground line as Home (the shared fox layout).
            let stage = FoxStage(size: geo.size, insets: geo.safeAreaInsets)
            let feetY = stage.feetY
            let kitW = min(stage.fox * 0.80, w * 0.62)
            let kitH = kitW * 794 / 900
            let kit = CGPoint(x: w / 2, y: feetY - kitH / 2 + stage.fox * 0.02)
            let fox = stage.fox

            ZStack(alignment: .top) {
                PaintedWorld(scene: .night)

                // A soft warmth spreading on the snow around him as he is held.
                Ellipse()
                    .fill(RadialGradient(colors: [Color(hex: 0xFFC59A).opacity(0.45 * warmth), .clear],
                                         center: .center, startRadius: 0, endRadius: kitW * 0.8))
                    .frame(width: kitW * 1.8, height: kitW * 0.7)
                    .position(x: kit.x, y: feetY - 6)
                    .allowsHitTesting(false)

                // The kit, curled asleep, breathing slowly.
                if !awake {
                    SleepingKit(width: kitW, warmth: warmth)
                        .position(kit)
                        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottom)))
                        .accessibilityElement()
                        .accessibilityLabel("A small fox, curled up in the snow")
                        .accessibilityHint("Touch and hold to warm him")
                        .accessibilityAction(named: "Warm him") { completeHold() }
                }

                // Awake: Lanvi sits up where the kit lay.
                if awake {
                    GroundedFox(stage: stage, scene: .night) {
                        LanviView(pose: .curious, size: fox)
                            .lanviReaction(.surprised, trigger: wakeTick)
                            .lanviMouth(mouth)
                            .lanviHops(false)
                    }
                    .transition(.opacity)
                    .accessibilityHidden(true)
                    SnowShakeOff(start: shakeOff, center: CGPoint(x: w / 2, y: feetY - fox * 0.55), size: fox)
                        .allowsHitTesting(false)
                }

                // The warm ring of light under the finger.
                if let touch, !awake {
                    WarmRing(progress: warmth)
                        .frame(width: 220, height: 220)
                        .position(touch)
                        .allowsHitTesting(false)
                }

                // Awake: his words in the same bubble, in the same place, as on Home.
                if let say {
                    HomeSpeech(text: say, target: stage.speechTarget, width: w, mouth: $mouth, hint: nil) {}
                }

                // Asleep: the narrator's words, white on the dark night sky.
                VStack(spacing: 10) {
                    if say == nil {
                        if showLine {
                            Text("Someone has been left out here.")
                                .font(Theme.rounded(24, .heavy))
                                .foregroundStyle(.white)
                                .multilineTextAlignment(.center)
                                .transition(LanviTiming.arrive)
                        }
                        if showHint {
                            Text("Hold him to warm him.")
                                .font(Theme.rounded(17, .semibold))
                                .foregroundStyle(.white.opacity(0.75))
                                .transition(LanviTiming.arrive)
                        }
                    }
                }
                .padding(.horizontal, 24)
                .frame(maxWidth: .infinity)
                .padding(.top, awake ? max(feetY - fox - 110, 40) : h * 0.24)
                .animation(LanviTiming.screen, value: awake)
            }
            .contentShape(Rectangle())
            .gesture(holdGesture(kit: kit, kitW: kitW))
            .onAppear { kitCenter = kit }
            .onChange(of: geo.size) { _, _ in kitCenter = kit }
        }
        .sensoryFeedback(.impact(weight: .light, intensity: 0.6), trigger: heartbeat)
        .sensoryFeedback(.success, trigger: wakeTick)
        .task {
            try? await Task.sleep(for: .milliseconds(700))
            withAnimation(LanviTiming.screen) { showLine = true }
            try? await Task.sleep(for: .milliseconds(1500))
            withAnimation(LanviTiming.screen) { showHint = true }
            if auto {
                try? await Task.sleep(for: .milliseconds(1200))
                beginHold(at: kitCenter)
            }
        }
    }

    // MARK: The hold

    private func holdGesture(kit: CGPoint, kitW: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { v in
                guard !awake else { return }
                touch = v.location
                if !holding {
                    // Only a touch on (or right around) the kit starts the warming.
                    let d = hypot(v.startLocation.x - kit.x, v.startLocation.y - kit.y)
                    if d < kitW * 0.75 { beginHold(at: v.location) }
                }
            }
            .onEnded { _ in releaseHold() }
    }

    private func beginHold(at point: CGPoint?) {
        guard !holding, !awake else { return }
        holding = true
        if let point { touch = point }
        holdTask?.cancel()
        holdTask = Task { @MainActor in
            var last = Date()
            var nextBeat = 0.0
            while holding, !Task.isCancelled {
                let now = Date()
                let dt = now.timeIntervalSince(last)
                last = now
                warmth = min(1, warmth + dt / Self.holdSeconds)
                // A slow heartbeat: two soft ticks, a pause.
                nextBeat -= dt
                if nextBeat <= 0 {
                    heartbeat += 1
                    try? await Task.sleep(for: .milliseconds(140))
                    heartbeat += 1
                    nextBeat = 0.9
                }
                if warmth >= 1 { completeHold(); return }
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    /// Let go early: the warmth eases back gently, and he waits.
    private func releaseHold() {
        guard holding, !awake else { touch = nil; return }
        holding = false
        holdTask?.cancel()
        withAnimation(.easeOut(duration: 0.7)) {
            warmth = 0
            touch = nil
        }
    }

    private func completeHold() {
        guard !awake else { return }
        holding = false
        holdTask?.cancel()
        withAnimation(LanviTiming.screen) {
            awake = true
            touch = nil
            showHint = false
        }
        // The warm glow on the snow goes once he is awake: nothing stays under him.
        withAnimation(.easeOut(duration: 0.9)) { warmth = 0 }
        shakeOff = Date()
        wakeTick += 1
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(900))
            withAnimation(LanviTiming.pop) { say = "…you stayed." }
            try? await Task.sleep(for: .milliseconds(2200))
            say = "I'm Lanvi."
            try? await Task.sleep(for: .milliseconds(1800))
            onDone()
        }
    }
}

/// The curled kit, asleep: a slow, eased breath, and a touch warmer as he is held.
private struct SleepingKit: View {
    var width: CGFloat
    var warmth: Double

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            // One breath every 3.6 s, eased (in a little faster than out).
            let p = (t.truncatingRemainder(dividingBy: 3.6)) / 3.6
            let breath = p < 0.42 ? sin(p / 0.42 * .pi / 2) : cos((p - 0.42) / 0.58 * .pi / 2)
            Image("lanvi-rescue-curled")
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: width)
                .scaleEffect(x: 1 + 0.006 * breath, y: 1 + 0.016 * breath, anchor: .bottom)
                .colorMultiply(Color(red: 1, green: 1 - 0.05 * warmth, blue: 1 - 0.12 * warmth))
        }
    }
}

/// A soft ring of warm light that grows under the finger while holding.
private struct WarmRing: View {
    var progress: Double

    var body: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [Color(hex: 0xFFE2C4).opacity(0.55 * progress),
                                              Color(hex: 0xFFB27A).opacity(0.25 * progress), .clear],
                                     center: .center, startRadius: 0, endRadius: 110))
                .scaleEffect(0.35 + 0.65 * progress)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(Color(hex: 0xFFE9D2).opacity(0.85), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .frame(width: 92, height: 92)
                .opacity(progress > 0.02 ? 1 : 0)
        }
        .blendMode(.plusLighter)
    }
}

/// When he wakes, the snow falls off his fur: a few soft flakes drop away.
private struct SnowShakeOff: View {
    var start: Date?
    var center: CGPoint
    var size: CGFloat

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60)) { context in
            Canvas { ctx, _ in
                guard let start else { return }
                let age = context.date.timeIntervalSince(start)
                guard age >= 0, age < 1.4 else { return }
                for i in 0..<22 {
                    let seed = Double(i) * 2.399
                    let a = seed.truncatingRemainder(dividingBy: 2 * .pi)
                    let spread = size * (0.18 + 0.22 * abs(sin(seed * 3.1)))
                    let x = center.x + cos(a) * spread * min(age * 2.2, 1)
                    let y = center.y + sin(a) * spread * 0.6 + 260 * age * age
                    let r = 2.0 + 2.0 * abs(sin(seed * 5.7))
                    let alpha = max(0, 1 - age / 1.4)
                    ctx.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                             with: .color(.white.opacity(0.9 * alpha)))
                }
            }
        }
    }
}
