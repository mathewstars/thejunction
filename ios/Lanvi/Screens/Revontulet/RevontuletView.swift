import SwiftUI
import QuartzCore

/// Revontulet ("fox fires"): 90 seconds with no way to lose. Three times: pick a fault line
/// in a pane of dark ice, trace a half-circle to charge the fox's spark, sling it into the
/// ice. The third impact bursts the wall and the aurora fills the sky; the fox celebrates,
/// you brush the snow off its fur, it falls asleep, and the game hands back its result.
///
/// `onDone` gets the result when the fox is asleep, or when the person closes it early
/// (`completed == false`); nil only when closed before Start. See `ios/REVONTULET.md`.
///
/// Launch arguments (read here only): `-revontuletAuto [mixed|hard|easy|idle]` plays itself;
/// `-revontuletFreeze <beat>` opens frozen on one beat for stills.
struct RevontuletView: View {

    private let onDone: (RevontuletResult?) -> Void

    init(onDone: @escaping (RevontuletResult?) -> Void) {
        self.onDone = onDone
    }

    @State private var engine: RevontuletEngine?
    @State private var art: RevontuletArt?
    @State private var box = Box()
    @State private var feel = RevontuletFeel()
    @State private var frozenAt: Double?
    @State private var quiet = false
    @State private var handedBack = false
    // The fox's direction.
    @State private var reaction: LanviMood = .curious
    @State private var reactionTick = 0
    @State private var look: UnitPoint?
    @State private var yawnTick = 0
    @State private var petTick = 0
    // The screen.
    @State private var line = ""
    @State private var finger: CGPoint?
    @State private var coach: RevontuletCoachState?
    /// This flight's embers are being coached (the first hard shot this player has made).
    @State private var coachingEmbers = false
    /// The goodnight's Continue button is showing.
    @State private var continueShown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.displayScale) private var displayScale

    /// Not drawn from: the pretend finger and a frame counter, kept out of SwiftUI's sight.
    private final class Box {
        var auto: RevontuletAutoPlay?
        var frame = 0
    }

    private static let freezeBeat: RevontuletBeat? = {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-revontuletFreeze"), i + 1 < args.count else { return nil }
        return RevontuletBeat(rawValue: args[i + 1])
    }()

    var body: some View {
        GeometryReader { outer in
            let insets = outer.safeAreaInsets
            GeometryReader { geo in
                let L = RevontuletLayout(size: geo.size, safeTop: insets.top, safeBottom: insets.bottom)
                ZStack {
                    if let engine, let art {
                        scene(engine, art)
                        RevontuletTouchSurface { input, time in feed(input, at: time) }
                        overlay(engine)
                    } else {
                        PaintedWorld(scene: .night)
                    }
                }
                .onAppear { setUp(L) }
                .onChange(of: geo.size) { _, _ in setUp(L) }
            }
            .ignoresSafeArea()
        }
        .task { await run() }
        .onAppear { feel.start() }
        .onDisappear { feel.stop() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { feel.start() } else { feel.stop() }
            // Leaving the app mid-game (home, a call, the lock button) ends it cleanly as
            // interrupted, with a valid record; a pull-down or a banner only pauses the haptics.
            if phase == .background { interrupt() }
        }
    }

    // MARK: Layers

    private func scene(_ e: RevontuletEngine, _ art: RevontuletArt) -> some View {
        let L = e.layout
        return ZStack {
            PaintedWorld(scene: .night)
            TimelineView(.animation(minimumInterval: 1.0 / 60, paused: frozenAt != nil)) { _ in
                let painter = RevontuletPainter(e: e, art: art, now: frozenAt ?? CACurrentMediaTime(), coach: coach, reduceMotion: reduceMotion)
                ZStack {
                    Canvas { ctx, size in
                        painter.sky(&ctx, size: size)
                        painter.ice(&ctx, size: size)
                    }
                    // Lower-left and smaller while playing; at the burst it springs to the centre.
                    RevontuletFox(act: act(e), size: L.foxSize, reaction: reaction, reactionTick: reactionTick,
                                  look: look, yawnTick: yawnTick, petTick: petTick)
                        .equatable()
                        .frame(width: L.foxSize, height: L.foxSize)
                        .scaleEffect(Self.foxScale(e))
                        .position(Self.foxPoint(e))
                        .animation(.spring(response: 0.5, dampingFraction: 0.72), value: Self.foxPlace(e))
                        .animation(.spring(response: 1.1, dampingFraction: 0.9), value: e.beat == .warmth)
                    Canvas { ctx, size in
                        painter.front(&ctx, size: size)
                        painter.coachLayer(&ctx, size: size)
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func overlay(_ e: RevontuletEngine) -> some View {
        let L = e.layout
        let lineY: CGFloat = switch e.beat {
        case .intro: L.startY - 27 - 30
        case .sleep, .done: L.restLineY
        default: L.lineY
        }
        return ZStack {
            if e.beat == .intro {
                // On the dark glass, where white reads clearly, with room around it.
                VStack(spacing: 6) {
                    Text("Revontulet")
                        .font(Theme.rounded(42, .black))
                        .foregroundStyle(.white)
                    Text("Help me light up the sky")
                        .font(Theme.rounded(18, .heavy))
                        .foregroundStyle(.white.opacity(0.82))
                }
                .shadow(color: Color(red: 0.02, green: 0.05, blue: 0.16).opacity(0.7), radius: 14)
                .position(x: L.size.width / 2, y: L.wall.minY + L.wall.height * 0.5)
                .allowsHitTesting(false)
                .transition(.opacity.animation(.easeOut(duration: 0.35)))
            }

            if let c = coach, c.endedAt == nil {
                RevontuletCoachBubble(text: c.kind.words)
                    .position(bubblePoint(c, e))
                    .allowsHitTesting(false)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.94)).animation(.easeOut(duration: 0.3).delay(0.12)),
                                            removal: .opacity.animation(.easeOut(duration: 0.18))))
                    .id(c.kind.rawValue + "\(c.ember)")
            }

            if !line.isEmpty {
                Text(line)
                    .font(Theme.rounded(20, .heavy))
                    .foregroundStyle(Theme.ink)
                    .shadow(color: .white.opacity(0.8), radius: 8)
                    .multilineTextAlignment(.center)
                    .id(line)
                    // One line at a time: the old one leaves before the new one arrives.
                    .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 6)).animation(.easeOut(duration: 0.22).delay(0.16)),
                                            removal: .opacity.animation(.easeOut(duration: 0.14))))
                    .position(x: L.size.width / 2, y: lineY)
                    .allowsHitTesting(false)
            }

            if let finger {
                Circle()
                    .fill(.white.opacity(0.28))
                    .overlay(Circle().stroke(.white.opacity(0.75), lineWidth: 2))
                    .frame(width: 36, height: 36)
                    .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
                    .position(finger)
                    .allowsHitTesting(false)
            }

            // The end beat stays until the player continues: the app's own chunky button.
            if continueShown, !handedBack {
                Button("Continue") { continueTapped() }
                    .buttonStyle(ChunkyButtonStyle())
                    .padding(.horizontal, 24)
                    .position(x: L.size.width / 2, y: L.startY)
                    .transition(.opacity.combined(with: .offset(y: 14)).animation(.easeOut(duration: 0.4)))
                    .accessibilityLabel("Continue")
            }

            Button { close() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 17, weight: .heavy))
                    .foregroundStyle(.white)
            }
            .buttonStyle(RevontuletCloseStyle())
            .accessibilityLabel("Close")
            .position(x: 20 + 22, y: L.safeTop + 6 + 22)
        }
        .animation(.easeOut(duration: 0.25), value: e.beat == .intro)
    }

    private static func foxPlace(_ e: RevontuletEngine) -> RevontuletLayout.FoxPlace {
        switch e.beat {
        case .burst, .celebrate: return .full
        case .warmth: return .warm
        case .sleep, .done: return .rest
        default: return .play
        }
    }

    private static func foxScale(_ e: RevontuletEngine) -> CGFloat {
        switch foxPlace(e) {
        case .play: return e.layout.playFoxScale
        case .full: return 1
        case .warm, .rest: return e.layout.warmFoxScale
        }
    }

    private static func foxPoint(_ e: RevontuletEngine) -> CGPoint {
        switch foxPlace(e) {
        case .play: return e.layout.playFoxCenter
        case .full: return e.layout.foxCenter
        case .warm: return e.layout.warmFoxCenter
        case .rest: return e.layout.restFoxCenter
        }
    }

    /// Beside the spotlight, never over it, the fox or the words.
    private func bubblePoint(_ c: RevontuletCoachState, _ e: RevontuletEngine) -> CGPoint {
        let L = e.layout
        let width = CGFloat(c.kind.words.count) * 9 + 40
        var p: CGPoint
        switch c.kind {
        case .start: p = CGPoint(x: L.anchor.x, y: L.anchor.y - 92)
        case .choice: p = CGPoint(x: L.size.width / 2, y: L.wall.minY + L.wall.height * 0.55)
        case .trace: p = CGPoint(x: L.anchor.x, y: L.anchor.y - L.arcRadius - 62)
        case .sling: p = CGPoint(x: L.anchor.x, y: L.anchor.y - 84)
        case .embers:
            let q = e.flight.flatMap { f in f.emberU.indices.contains(c.ember) ? f.emberPoint(c.ember) : nil } ?? L.anchor
            p = CGPoint(x: q.x, y: q.y + 74)
        case .stroke:
            let sq = L.foxSquare(.warm)
            p = CGPoint(x: sq.midX, y: sq.minY - 34)
        }
        p.x = min(max(p.x, width / 2 + 14), L.size.width - width / 2 - 14)
        p.y = max(p.y, L.safeTop + 74)
        return p
    }

    private func act(_ e: RevontuletEngine) -> RevontuletFox.Act {
        switch e.beat {
        case .celebrate: return .celebrating
        case .sleep, .done: return .sleeping
        default: return .playing
        }
    }

    // MARK: Setting up

    private func setUp(_ L: RevontuletLayout) {
        guard engine == nil, L.size.width > 10, L.size.height > 10 else { return }
        let began = CACurrentMediaTime()
        defer { print("revontulet: set up in \(Int((CACurrentMediaTime() - began) * 1000)) ms") }
        if ProcessInfo.processInfo.arguments.contains("-revontuletSelfTest") {
            let report = RevontuletSelfTest.run(layout: L)
            for f in report.failures.prefix(40) { print("revontulet selftest FAIL \(f)") }
            print(report.summary)
            line = report.failures.isEmpty ? "Self-test passed" : "Self-test: \(report.failures.count) failures"
        }
        if let beat = Self.freezeBeat {
            freeze(L, at: beat)
            return
        }
        engine = RevontuletEngine(layout: L)
        art = RevontuletArt(layout: L)
        box.auto = RevontuletAutoPlay.fromArguments().map {
            RevontuletAutoPlay(style: $0, coachPause: RevontuletCoachMemory.forced ? 2.2 : 0)
        }
        showCoach(.start, at: CACurrentMediaTime() + 0.6)
    }

    /// `-revontuletFreeze <beat>`: play the game on a made-up clock with the pretend finger
    /// until that beat, then hold the picture there.
    private func freeze(_ L: RevontuletLayout, at beat: RevontuletBeat) {
        var e = RevontuletEngine(layout: L, seed: 42)
        let a = RevontuletArt(layout: L)
        var auto = RevontuletAutoPlay(style: beat == .flight ? .hard : .mixed)
        var now = 1000.0
        var all: [RevontuletEvent] = []
        while now < 1100 {
            for input in auto.step(e, now: now) { all += e.handle(input, at: now) }
            all += e.tick(now)
            a.sync(e)
            if Self.reached(beat, e, now) { break }
            now += 1.0 / 60
        }
        quiet = true
        engine = e
        art = a
        frozenAt = now
        finger = auto.finger
        react(all, e, now: now)
        continueShown = e.beat == .sleep && e.completed
        if RevontuletCoachMemory.forced, let k = Self.coachFor(beat) {
            coach = RevontuletCoachState(kind: k, since: now - 1.2)
        }
        steerFox(e, now: now, force: true)
    }

    /// For coach stills (`-revontuletCoach -revontuletFreeze <beat>`).
    private static func coachFor(_ b: RevontuletBeat) -> RevontuletCoachKind? {
        switch b {
        case .intro: return .start
        case .choice: return .choice
        case .trace: return .trace
        case .sling: return .sling
        case .flight: return .embers
        case .warmth: return .stroke
        default: return nil
        }
    }

    private static func reached(_ b: RevontuletBeat, _ e: RevontuletEngine, _ now: Double) -> Bool {
        let into = now - e.beatStart
        switch b {
        case .intro: return true
        case .choice: return e.beat == .choice && into > 1.3
        case .trace: return e.beat == .trace && (RevontuletCoachMemory.forced ? into > 0.6 : e.progress > 0.6)
        case .sling: return e.beat == .sling && (RevontuletCoachMemory.forced ? into > 0.4 : hypot(e.pull.dx, e.pull.dy) > e.layout.maxPull * 0.8)
        case .flight: return e.beat == .flight && (e.flight.map { now - $0.launch > 1.05 } ?? false)
        case .impact: return e.beat == .impact && into > 0.28
        case .burst: return e.beat == .burst && into > 0.7
        case .celebrate: return e.beat == .celebrate && into > 1.0
        case .warmth: return e.beat == .warmth && e.stroking && e.strokesCounted >= 1
        case .sleep: return e.beat == .sleep && into > 1.5
        case .done: return e.beat == .done
        }
    }

    // MARK: Running

    private func run() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(16))
            step(CACurrentMediaTime())
        }
    }

    private func step(_ now: Double) {
        guard var e = engine, frozenAt == nil, !handedBack else { return }
        box.frame &+= 1
        var events: [RevontuletEvent] = []
        if box.auto != nil {
            for input in box.auto!.step(e, now: now) {
                // The pretend finger presses the real close button.
                if input == .close {
                    engine = e
                    close()
                    return
                }
                events += e.handle(input, at: now)
                if case .down = input { touchedDuringCoach(&e, at: now) }
            }
            if box.auto!.finger != finger { finger = box.auto!.finger }
        }
        events += e.tick(now)
        if e != engine { engine = e }
        if !events.isEmpty { react(events, e, now: now) }
        tendCoach(now: now)
        steerFox(e, now: now)
        // Snow right under a stroking finger comes off at once.
        if e.beat == .warmth, e.stroking, let f = e.finger, let art {
            let before = art.speckGone.count
            art.brush(near: f, at: now)
            if art.speckGone.count > before { feel.snowOff() }
        }
    }

    /// A real finger (from the touch surface) or the Start button.
    private func feed(_ input: RevontuletInput, at time: Double) {
        guard var e = engine, frozenAt == nil, !handedBack else { return }
        if box.auto != nil, input != .start { return }
        let events = e.handle(input, at: time)
        if case .down = input { touchedDuringCoach(&e, at: time) }
        if e != engine { engine = e }
        if !events.isEmpty { react(events, e, now: time) }
    }

    // MARK: Reacting: haptics, moments, the fox, the words

    private func react(_ events: [RevontuletEvent], _ e: RevontuletEngine, now: Double) {
        for event in events {
            switch event {
            case .started:
                emit(.revontuletStarted)
                RevontuletCoachMemory.learned(.start)
                endCoach(at: now)
            case let .choiceShown(r):
                say(nil)
                if r > 0 { foxReact(.curious) }
                if r == 0 { showCoach(.choice, at: now + 0.35) }
            case let .chose(r, effort):
                if !quiet { feel.choose(hard: effort == .hard) }
                emit(.effortChosen(round: r + 1, effort: effort == .hard ? .hard : .easy))
                RevontuletCoachMemory.learned(.choice)
                endCoach(at: now)
                if r == 0, showCoach(.trace, at: e.beatStart + 0.12) { engine?.markCoached() }
            case .arcShown:
                break
            case let .traceStarted(r):
                emit(.traceStarted(round: r + 1))
            case let .traceStep(s):
                if !quiet { feel.traceStep(s) }
            case let .traceEnded(r):
                emit(.traceEnded(round: r + 1))
                RevontuletCoachMemory.learned(.trace)
                endCoach(at: now)
                foxReact(.happy)
                if r == 0 { showCoach(.sling, at: now + 0.2) }
            case .pullStarted:
                if !quiet { feel.pull(0) }
                foxReact(.listening)
            case let .pull(level):
                if !quiet { feel.pull(level) }
            case .pullLetGo:
                if !quiet { feel.pullEnded() }
            case let .released(r, level):
                emit(.slingReleased(round: r + 1))
                RevontuletCoachMemory.learned(.sling)
                endCoach(at: now)
                coachingEmbers = e.flight?.hard == true && RevontuletCoachMemory.needs(.embers)
                if let f = e.flight, !quiet {
                    feel.snap(level)
                    // Coached embers hold time still, so their ticks play when they flash.
                    feel.flight(kind: f.hard ? 1 : 0, launch: f.launch,
                                emberShows: f.hard && !coachingEmbers ? f.emberT.map { f.launch + $0 - RevontuletFlight.emberLead } : [])
                }
                say(nil)
            case .foxLaunched:
                if !quiet { feel.flight(kind: 2, launch: now, emberShows: []) }
                say("Let me help!")
                foxReact(.proud)
            case let .emberShown(i):
                if coachingEmbers {
                    if !quiet { feel.emberShown(i) }
                    engine?.slowFlight(at: now)
                    showCoach(.embers, at: now, ember: i)
                }
            case let .emberHit(i, ms):
                if !quiet { feel.emberHit() }
                emit(.emberHit(reactionMs: ms))
                if coachingEmbers, coach?.kind == .embers, coach?.ember == i {
                    engine?.resumeFlight(at: now)
                    endCoach(at: now)
                }
            case .emberMissed:
                emit(.emberMissed)
            case let .landing(at, _, hard, hits, _, ribbon, burstAt):
                if !quiet { feel.landing(at: at, hard: hard, embersHit: hits, ribbon: ribbon, burstAt: burstAt) }
            case let .impact(r, _, breaking):
                art?.sync(e)
                say(nil)
                if coachingEmbers {
                    RevontuletCoachMemory.learned(.embers)
                    coachingEmbers = false
                }
                emit(.iceImpact(round: r + 1))
                foxReact(.surprised)
                if !breaking, !quiet {
                    let pleased: LanviMood = e.impacts.last?.hard == true ? .proud : .happy
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(0.95))
                        guard let b = engine?.beat, b == .impact || b == .choice else { return }
                        foxReact(pleased)
                    }
                }
            case .shattered:
                art?.sync(e)
                emit(.iceShattered)
                if !quiet { FaceSense.mark() }
                say(nil)
                foxReact(.surprised)
            case .celebrate:
                emit(.foxCelebrates)
                if !quiet {
                    FaceSense.mark()
                    feel.celebrate()
                }
                foxReact(.happy)
                say("We did it!")
                if !quiet {
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(2.4))
                        guard engine?.beat == .celebrate else { return }
                        foxReact(.happy)
                    }
                }
            case .warmthBegan:
                say(nil)
                showCoach(.stroke, at: now + RevontuletEngine.strokesFrom)
            case let .strokeBegan(n):
                petTick += 1
                if n >= 2 { foxReact(n == 2 ? .proud : .happy) }
            case let .strokeMoved(speed):
                if !quiet { feel.purr(speed: speed) }
            case let .strokeEnded(n, counted):
                if !quiet { feel.purrEnded() }
                if counted {
                    RevontuletCoachMemory.learned(.stroke)
                    art?.sync(e)
                    emit(.foxStroked(number: n))
                    if !quiet { feel.snowOff() }
                    if n == 1 { say(nil) }
                }
            case .sleep:
                if !quiet { feel.sleep() }
                yawnTick += 1
                say("Thank you. Goodnight.")
            case .asleep:
                withAnimation(.easeOut(duration: 0.4)) { continueShown = true }
            case let .ended(completed):
                emit(.revontuletEnded(finished: completed))
                // Continue, or the safety net: hand back at once (closing hands back itself).
                if completed, !quiet, let e = engine { handBack(e) }
            }
        }
    }

    // MARK: The first-time coach

    /// Shows the coach for a move the player has not done yet. True when it is showing.
    @discardableResult
    private func showCoach(_ k: RevontuletCoachKind, at time: Double, ember: Int = 0) -> Bool {
        guard frozenAt == nil, RevontuletCoachMemory.needs(k) else { return false }
        coach = RevontuletCoachState(kind: k, since: time, ember: ember)
        if !quiet {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(max(0, time - CACurrentMediaTime())))
                if coach?.kind == k, coach?.endedAt == nil { feel.coachTick() }
            }
        }
        return true
    }

    private func endCoach(at time: Double) {
        guard var c = coach, c.endedAt == nil else { return }
        c.endedAt = max(time, c.since)
        coach = c
    }

    /// A finger landed: the coach melts away (and time runs again for a held ember).
    private func touchedDuringCoach(_ e: inout RevontuletEngine, at time: Double) {
        guard let c = coach, c.endedAt == nil, time >= c.since else { return }
        if c.kind == .embers { e.resumeFlight(at: time) }
        endCoach(at: time)
    }

    /// Lets go of a coach whose beat has passed, and of a held ember after a while.
    private func tendCoach(now: Double) {
        guard let c = coach, let e = engine else { return }
        if let end = c.endedAt, now - end > 0.3 { coach = nil; return }
        guard c.endedAt == nil else { return }
        let beat: RevontuletBeat? = switch c.kind {
        case .start: .intro
        case .choice: .choice
        case .trace: .trace
        case .sling: .sling
        case .embers: .flight
        case .stroke: .warmth
        }
        if let b = beat, e.beat != b, !(c.kind == .trace && e.beat == .choice) { endCoach(at: now); return }
        if c.kind == .embers, now - c.since > (c.ember == 0 ? 2.5 : 1.5) {
            engine?.resumeFlight(at: now)
            endCoach(at: now)
        }
    }

    private func emit(_ m: GameMoment) {
        guard !quiet else { return }
        GameMoments.emit(m)
    }

    private func say(_ text: String?) {
        let t = text ?? ""
        guard t != line else { return }
        line = t
    }

    private func foxReact(_ mood: LanviMood) {
        reaction = mood
        reactionTick += 1
    }

    /// Where the fox looks: at the fault lines while choosing, the light while tracing, the
    /// spark in the sling and in the air, the hit, then straight at you.
    private func steerFox(_ e: RevontuletEngine, now: Double, force: Bool = false) {
        guard force || box.frame % 3 == 0 else { return }
        let L = e.layout
        let into = now - e.beatStart
        var target: CGPoint?
        switch e.beat {
        case .choice:
            let f = L.faults(round: e.round)
            let cycle = into < 5 ? into : 5 + (into - 5).truncatingRemainder(dividingBy: 6)
            if cycle < 1.1 { target = f.easy[f.easy.count / 2] }
            else if cycle < 2.3 { target = f.hard[f.hard.count / 2] }
            else if cycle >= 7 && cycle < 8.2 { target = f.easy[f.easy.count / 2] }
            else if cycle >= 8.2 && cycle < 9.4 { target = f.hard[f.hard.count / 2] }
        case .trace:
            target = e.tracing ? e.finger : e.arc.point(e.progress, reversed: e.reversed)
        case .sling, .flight:
            target = e.sparkPoint(now)
        case .impact:
            if into < 0.7 { target = e.impacts.last?.point }
        case .warmth:
            if e.stroking { target = e.finger }
        default:
            target = nil
        }
        let sq = L.foxSquare(Self.foxPlace(e))
        let u = target.map { UnitPoint(x: ($0.x - sq.minX) / sq.width, y: ($0.y - sq.minY) / sq.height) }
        let moved: Bool
        switch (u, look) {
        case (nil, nil): moved = false
        case let (a?, b?): moved = abs(a.x - b.x) > 0.02 || abs(a.y - b.y) > 0.02
        default: moved = true
        }
        if moved { look = u }
    }

    // MARK: Ending

    private func close() {
        guard !handedBack else { return }
        guard var e = engine, e.startUptime != nil else {
            handedBack = true
            feel.stop()
            onDone(nil)
            return
        }
        if e.beat != .done {
            let events = e.handle(.close, at: CACurrentMediaTime())
            engine = e
            react(events, e, now: CACurrentMediaTime())
        }
        handBack(e)
    }

    /// Continue on the goodnight: the finished game goes back, once.
    private func continueTapped() {
        guard !handedBack, var e = engine else { return }
        let events = e.handle(.finish, at: CACurrentMediaTime())
        engine = e
        react(events, e, now: CACurrentMediaTime())
    }

    private func interrupt() {
        guard !handedBack, frozenAt == nil, var e = engine, e.startUptime != nil, e.beat != .done else { return }
        let events = e.handle(.interrupt, at: CACurrentMediaTime())
        engine = e
        react(events, e, now: CACurrentMediaTime())
        handBack(e)
    }

    private func handBack(_ e: RevontuletEngine) {
        guard !handedBack else { return }
        handedBack = true
        feel.stop()
        var result = e.result()
        result?.ptPerCm = API.Revontulet.pointsPerCentimetre(displayScale: displayScale)
        print("revontulet: handed back \(result == nil ? "nothing" : result!.completed ? "a finished game" : "a stopped game")")
        if box.auto != nil, let r = result {
            // For the connection check: the measures exactly as the record carries them.
            if let m = ActivityRouter.record(r).revontulet, let json = try? API.encoder.encode(m) {
                print("revontulet: measures \(String(decoding: json, as: UTF8.self))")
            }
            print("revontulet: result completed=\(r.completed) interrupted=\(r.interrupted) seconds=\(String(format: "%.1f", r.endUptime - r.startUptime)) launches=\(r.launches) embers=\(r.embersHit)/\(r.embersShown) reactions=\(r.reactionMs) strokes=\(r.strokes.count) foxFinished=\(r.foxFinishedWall)")
        }
        onDone(result)
    }
}

/// The one close button every game has: chunky, round, blue, top-left.
private struct RevontuletCloseStyle: ButtonStyle {
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
