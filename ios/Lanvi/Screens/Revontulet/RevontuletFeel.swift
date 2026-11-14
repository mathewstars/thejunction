import CoreHaptics
import QuartzCore

// MARK: - The tuning table
//
// Every number the hand feels, grouped by moment. Intensity (I) and sharpness (S) run 0...1,
// times are seconds. 1.0 is kept for the burst alone; small events stay under about 0.4.
// Retune here after feeling it on a phone; nothing else needs to change.
enum RevontuletTune {
    // Picking a fault line: one soft knock; the vein adds a second, brighter one.
    static let chooseI = 0.34, chooseS = 0.42
    static let chooseHardI = 0.26, chooseHardS = 0.7, chooseHardGap = 0.07

    // Tracing: a crisp light bead every twelfth of the half-circle (by distance, not time).
    static let beadI = 0.14, beadRise = 0.012, beadS = 0.78
    // Full: a short swell and a fuller last bead.
    static let chargeSwellT = 0.24, chargeSwellI = 0.3, chargeSwellS = 0.3, chargeClickI = 0.4, chargeClickS = 0.85

    // The pull: tension that climbs on a curve (little at first, a lot near the end).
    static let pullI = (from: 0.03, to: 0.55), pullS = (from: 0.08, to: 0.6), pullCurve = 1.9
    // Ratchet clicks, closer together as it tightens.
    static let clickAt: [Double] = [0.28, 0.5, 0.66, 0.78, 0.87, 0.93, 0.97]
    static let clickI = (from: 0.14, to: 0.36), clickS = 0.95
    // At full pull a small steady tremble says "let go".
    static let trembleFrom = 0.93, trembleRate = 16.0, trembleI = 0.16, trembleS = 0.55
    // Release: a hard crack and a short dying buzz whose length follows the pull.
    static let snapI = 0.78, snapS = 1.0
    static let snapBuzz = (short: 0.06, long: 0.2), snapBuzzI = 0.4, snapBuzzS = 0.7

    // The flight: a faint whoosh rising with the spark's speed, then silence, then the hit.
    static let whooshI = (from: 0.03, to: 0.26), whooshS = (from: 0.12, to: 0.5), silenceBeforeHit = 0.04
    // Embers: a bright tick when one flashes, a crisp double tick when lit.
    static let emberShownI = 0.28, emberShownS = 1.0
    static let emberHitI = 0.4, emberHitS = 0.95, emberHitEchoI = 0.24, emberHitGap = 0.055

    // Impacts: easy is one warm round thud; hard is deeper and longer with crackle;
    // the full combo adds a rising three-beat flourish.
    static let easyThud = (i: 0.58, s: 0.22, t: 0.12)
    static let hardThud = (i: 0.76, s: 0.08, t: 0.26)
    static let comboThud = (i: 0.86, s: 0.06, t: 0.32)
    static let crackleI = 0.3, crackleS = 0.9, crackles = (easy: 2, hard: 7, combo: 10)
    static let flourish: [(t: Double, i: Double, s: Double)] = [(0.36, 0.24, 0.5), (0.47, 0.3, 0.62), (0.58, 0.38, 0.75)]
    // The surprise ribbon: one soft wave.
    static let ribbonWave = (delay: 0.7, t: 1.1, i: 0.26, s: 0.1)

    // The burst: the crack at full, a deep rumble dying for as long as the slow motion
    // lasts, light ticks as shards land, one slow wide swell as the aurora sweeps.
    static let burstCrackI = 1.0, burstCrackS = 0.9
    static let burstRumble = (t: 2.2, i: 0.62, s: 0.05)
    static let shardTicks: [Double] = [0.55, 0.8, 0.98, 1.2, 1.36, 1.55, 1.72, 1.9, 2.1, 2.35, 2.6]
    static let shardTickI = 0.22, shardTickS = 0.92
    static let sweepSwell = (delay: 1.0, t: 2.2, i: 0.32, s: 0.0)
    // The fox's celebration: three soft happy bumps.
    static let celebrate: [(t: Double, i: Double)] = [(0, 0.34), (0.17, 0.28), (0.34, 0.22)], celebrateS = 0.32

    // The purr: a soft flutter about 25 times a second, breathing; fullest on slow strokes.
    static let purrRate = 25.0, purrBreath = 2.0, purrI = 0.5, purrS = 0.06
    static let purrSlow = 140.0, purrFast = 700.0          // points per second
    static let purrFull = (i: 0.95, s: -0.12), purrThin = (i: 0.42, s: 0.15)
    static let purrFadeIn = 0.2, purrFadeOut = 0.3
    // Snow leaving the fur: a few grainy ticks.
    static let snowTicks: [Double] = [0, 0.035, 0.08, 0.11], snowTickI = 0.18, snowTickS = 1.0

    // Fur under a stroke: faint soft ticks by distance (one per furStep points).
    static let furI = 0.1, furS = 0.2, furStep = 18.0

    // A first-time coach appearing: a soft double tick.
    static let coachI = 0.22, coachS = 0.45, coachGap = 0.09

    // Falling asleep: one slow pulse that fades away.
    static let sleepSwell = (t: 0.5, i: 0.36), sleepFade = 1.4, sleepS = 0.04

    // Sending parameters while a finger moves: at most this often, easing toward the target.
    static let updateEvery = 1.0 / 60, ease = 0.45
}

/// Everything the game makes you feel, in one place. Haptics only, never sound: the engine
/// plays haptics only and no audio framework is used. If sound is ever added, it goes here.
///
/// - The engine starts when the game opens and runs until it closes (no auto shutdown, so
///   nothing answers late); every pattern is built once and its player made once.
/// - Hits whose time is known (embers flashing, the impact, the burst) are scheduled on the
///   engine's own clock the moment they are certain; only finger-driven feel plays on the spot.
/// - Safe where haptics are missing (the simulator): every call does nothing.
@MainActor
final class RevontuletFeel {
    private typealias T = RevontuletTune
    private enum Key: Hashable {
        case choose(Bool), bead, charged, click, snap(Int), emberShown(Int), emberHit
        case whoosh(Int), thud(Int), crackle(Int), ribbon, burstCrack, burstTicks, burstSwell, celebrate, snow, sleep, coach, fur
    }

    private let supported = CHHapticEngine.capabilitiesForHardware().supportsHaptics
    private var engine: CHHapticEngine?
    private var players: [Key: CHHapticPatternPlayer] = [:]
    private var clicks: [CHHapticPatternPlayer] = []
    private var tension: CHHapticAdvancedPatternPlayer?
    private var tremble: CHHapticAdvancedPatternPlayer?
    private var purr: CHHapticAdvancedPatternPlayer?
    private var running = false
    private var tensionOn = false, trembleOn = false, purrOn = false
    private var nextClick = 0
    private var sentPull = (i: 0.0, s: 0.0, at: 0.0)
    private var sentPurr = (i: 0.0, s: 0.0, at: 0.0)

    nonisolated init() {}

    // MARK: Start and stop

    /// Call when the game opens and when the app comes back to the foreground.
    func start() {
        guard supported, engine == nil else { return }
        guard let e = try? CHHapticEngine() else { return }
        e.playsHapticsOnly = true
        e.isAutoShutdownEnabled = false
        e.resetHandler = { [weak self] in
            Task { @MainActor in self?.rebuild() }
        }
        e.stoppedHandler = { [weak self] _ in
            Task { @MainActor in self?.running = false }
        }
        engine = e
        e.start { [weak self] error in
            guard error == nil else { return }
            Task { @MainActor in
                self?.running = true
                self?.buildPlayers()
            }
        }
    }

    /// Call when the game closes and when the app leaves the foreground. Cancels anything scheduled.
    func stop() {
        engine?.stop(completionHandler: nil)
        engine = nil
        running = false
        players = [:]
        clicks = []
        tension = nil; tremble = nil; purr = nil
        tensionOn = false; trembleOn = false; purrOn = false
    }

    private func rebuild() {
        guard let e = engine else { return }
        players = [:]; clicks = []
        tension = nil; tremble = nil; purr = nil
        tensionOn = false; trembleOn = false; purrOn = false
        do {
            try e.start()
            running = true
            buildPlayers()
        } catch {
            running = false
        }
    }

    // MARK: Finger-driven, played on the spot

    func choose(hard: Bool) { fire(.choose(hard)) }

    /// The light passed another twelfth of the half-circle (step 1...12).
    func traceStep(_ step: Int) {
        if step >= 12 { fire(.charged) } else { fire(.bead) }
    }

    func charged() { fire(.charged) }

    /// The pull, 0...1. Eased and sent at most 60 times a second.
    func pull(_ level: Double) {
        guard running, let tension else { return }
        if !tensionOn {
            try? tension.start(atTime: CHHapticTimeImmediate)
            tensionOn = true
            nextClick = 0
            sentPull = (0, 0, 0)
        }
        let now = CACurrentMediaTime()
        let shaped = pow(level, T.pullCurve)
        let wantI = T.pullI.from + (T.pullI.to - T.pullI.from) * shaped
        let wantS = T.pullS.from + (T.pullS.to - T.pullS.from) * shaped
        if now - sentPull.at >= T.updateEvery {
            let i = sentPull.i + (wantI - sentPull.i) * T.ease
            let s = sentPull.s + (wantS - sentPull.s) * T.ease
            sentPull = (i, s, now)
            try? tension.sendParameters([dyn(.hapticIntensityControl, i), dyn(.hapticSharpnessControl, s - 0.3)], atTime: CHHapticTimeImmediate)
        }
        while !clicks.isEmpty, nextClick < T.clickAt.count, level >= T.clickAt[nextClick] {
            let k = Double(nextClick) / Double(T.clickAt.count - 1)
            let player = clicks[min(clicks.count - 1, Int(k * Double(clicks.count - 1) + 0.5))]
            try? player.start(atTime: CHHapticTimeImmediate)
            nextClick += 1
        }
        if nextClick > 0, level < T.clickAt[nextClick - 1] - 0.08 { nextClick -= 1 }
        if level >= T.trembleFrom, !trembleOn {
            try? tremble?.start(atTime: CHHapticTimeImmediate)
            trembleOn = true
        } else if level < T.trembleFrom - 0.04, trembleOn {
            try? tremble?.stop(atTime: CHHapticTimeImmediate)
            trembleOn = false
        }
    }

    func pullEnded() {
        if tensionOn { try? tension?.stop(atTime: CHHapticTimeImmediate) }
        if trembleOn { try? tremble?.stop(atTime: CHHapticTimeImmediate) }
        tensionOn = false
        trembleOn = false
        nextClick = 0
    }

    /// Let go: the crack, and a buzz as long as the pull was far.
    func snap(_ level: Double) {
        pullEnded()
        fire(.snap(level < 0.45 ? 0 : level < 0.8 ? 1 : 2))
    }

    func emberHit() { fire(.emberHit) }

    /// The purr while a stroke moves. Fades in, then follows the speed (fullest when slow).
    func purr(speed: Double) {
        guard running, let purr else { return }
        let now = CACurrentMediaTime()
        let slow = max(0, min(1, 1 - (speed - T.purrSlow) / (T.purrFast - T.purrSlow)))
        let wantI = T.purrThin.i + (T.purrFull.i - T.purrThin.i) * slow
        let wantS = T.purrThin.s + (T.purrFull.s - T.purrThin.s) * slow
        if !purrOn {
            purrOn = true
            try? purr.sendParameters([dyn(.hapticIntensityControl, 0)], atTime: CHHapticTimeImmediate)
            try? purr.start(atTime: CHHapticTimeImmediate)
            try? purr.scheduleParameterCurve(curve(.hapticIntensityControl, from: 0, to: wantI, over: T.purrFadeIn), atTime: CHHapticTimeImmediate)
            sentPurr = (wantI, wantS, now + T.purrFadeIn)
            return
        }
        guard now - sentPurr.at >= T.updateEvery else { return }
        let i = sentPurr.i + (wantI - sentPurr.i) * T.ease
        let s = sentPurr.s + (wantS - sentPurr.s) * T.ease
        sentPurr = (i, s, now)
        try? purr.sendParameters([dyn(.hapticIntensityControl, i), dyn(.hapticSharpnessControl, s)], atTime: CHHapticTimeImmediate)
    }

    func purrEnded() {
        guard purrOn, let purr, let engine else { purrOn = false; return }
        purrOn = false
        try? purr.scheduleParameterCurve(curve(.hapticIntensityControl, from: sentPurr.i, to: 0, over: T.purrFadeOut), atTime: CHHapticTimeImmediate)
        try? purr.stop(atTime: engine.currentTime + T.purrFadeOut + 0.02)
    }

    /// Snow leaving the fur.
    func snowOff() { fire(.snow) }

    /// Fur under the finger: a faint soft tick every few points stroked.
    func furTick() { fire(.fur) }

    /// A first-time coach appears: one soft double tick.
    func coachTick() { fire(.coach) }

    /// An ember flashing now (when a coach holds time, its tick cannot be scheduled ahead).
    func emberShown(_ i: Int) { fire(.emberShown(min(i, 1))) }

    // MARK: Scheduled on the engine's clock

    /// The spark left the sling (or the fox launched it): the whoosh now, each ember's tick
    /// at the instant it flashes. `kind` 0 easy, 1 hard, 2 the fox's own.
    func flight(kind: Int, launch: Double, emberShows: [Double]) {
        fire(.whoosh(kind), at: launch)
        for (i, t) in emberShows.enumerated() { fire(.emberShown(i), at: t) }
    }

    /// The landing is certain: the hit lands on the frame it is drawn; then the burst.
    func landing(at time: Double, hard: Bool, embersHit: Int, ribbon: Bool, burstAt: Double?) {
        let kind = !hard ? 0 : embersHit >= 2 ? 2 : 1
        fire(.thud(kind), at: time)
        fire(.crackle(kind), at: time)
        if ribbon { fire(.ribbon, at: time) }
        if let b = burstAt {
            fire(.burstCrack, at: b)
            fire(.burstTicks, at: b)
            fire(.burstSwell, at: b)
        }
    }

    func celebrate() { fire(.celebrate) }

    /// Falling asleep: the purr falls asleep too (slower, softer, one last long out-breath),
    /// then one slow fading pulse.
    func sleep() {
        if purrOn, let purr, let engine {
            purrOn = false
            try? purr.scheduleParameterCurve(curve(.hapticIntensityControl, from: sentPurr.i, to: 0, over: 1.2), atTime: CHHapticTimeImmediate)
            try? purr.stop(atTime: engine.currentTime + 1.25)
        }
        pullEnded()
        fire(.sleep)
    }

    // MARK: Playing

    private func fire(_ key: Key, at uptime: Double? = nil) {
        guard running, let engine, let player = players[key] else { return }
        var when = CHHapticTimeImmediate
        if let u = uptime {
            let delay = u - CACurrentMediaTime()
            if delay > 0.004 { when = engine.currentTime + delay }
        }
        try? player.start(atTime: when)
    }

    // MARK: Building every pattern once

    private func buildPlayers() {
        guard let engine else { return }
        func make(_ events: [CHHapticEvent], _ curves: [CHHapticParameterCurve] = []) -> CHHapticPatternPlayer? {
            guard let p = try? CHHapticPattern(events: events, parameterCurves: curves) else { return nil }
            return try? engine.makePlayer(with: p)
        }
        var built: [Key: CHHapticPatternPlayer] = [:]
        built[.choose(false)] = make([tap(0, T.chooseI, T.chooseS)])
        built[.choose(true)] = make([tap(0, T.chooseI, T.chooseS), tap(T.chooseHardGap, T.chooseHardI, T.chooseHardS)])
        built[.bead] = make([tap(0, T.beadI + T.beadRise * 6, T.beadS)])
        built[.charged] = make([hum(0, T.chargeSwellT, T.chargeSwellI, T.chargeSwellS),
                                tap(T.chargeSwellT, T.chargeClickI, T.chargeClickS)],
                               [curve(.hapticIntensityControl, from: 0.1, to: 1, over: T.chargeSwellT)])
        for (k, buzz) in [T.snapBuzz.short, (T.snapBuzz.short + T.snapBuzz.long) / 2, T.snapBuzz.long].enumerated() {
            built[.snap(k)] = make([tap(0, T.snapI, T.snapS), hum(0.008, buzz, T.snapBuzzI, T.snapBuzzS)],
                                   [curve(.hapticIntensityControl, from: 1, to: 0, over: buzz, start: 0.008)])
        }
        for i in 0..<2 { built[.emberShown(i)] = make([tap(0, T.emberShownI, T.emberShownS)]) }
        built[.emberHit] = make([tap(0, T.emberHitI, T.emberHitS), tap(T.emberHitGap, T.emberHitEchoI, T.emberHitS)])
        for kind in 0..<3 { built[.whoosh(kind)] = make(whoosh(kind: kind).events, whoosh(kind: kind).curves) }
        for kind in 0..<3 {
            let thud = [T.easyThud, T.hardThud, T.comboThud][kind]
            built[.thud(kind)] = make([tap(0, thud.i, thud.s + 0.15), hum(0, thud.t, thud.i, thud.s)],
                                      [curve(.hapticIntensityControl, from: 1, to: 0, over: thud.t)])
            built[.crackle(kind)] = make(crackle(kind: kind))
        }
        built[.ribbon] = make([hum(T.ribbonWave.delay, T.ribbonWave.t, T.ribbonWave.i, T.ribbonWave.s)],
                              [bell(.hapticIntensityControl, start: T.ribbonWave.delay, length: T.ribbonWave.t)])
        // The burst in three parts, so each keeps its own envelope.
        built[.burstCrack] = make([tap(0, T.burstCrackI, T.burstCrackS), hum(0, T.burstRumble.t, T.burstRumble.i, T.burstRumble.s)],
                                  [CHHapticParameterCurve(parameterID: .hapticIntensityControl, controlPoints: [
                                    .init(relativeTime: 0, value: 1), .init(relativeTime: 0.4, value: 0.7),
                                    .init(relativeTime: 1.2, value: 0.35), .init(relativeTime: T.burstRumble.t, value: 0)], relativeTime: 0)])
        built[.burstTicks] = make(T.shardTicks.enumerated().map { tap($0.element, T.shardTickI * (1 - 0.05 * Double($0.offset)), T.shardTickS) })
        built[.burstSwell] = make([hum(T.sweepSwell.delay, T.sweepSwell.t, T.sweepSwell.i, T.sweepSwell.s)],
                                  [bell(.hapticIntensityControl, start: T.sweepSwell.delay, length: T.sweepSwell.t)])
        built[.celebrate] = make(T.celebrate.map { tap($0.t, $0.i, T.celebrateS) })
        built[.coach] = make([tap(0, T.coachI, T.coachS), tap(T.coachGap, T.coachI * 0.7, T.coachS)])
        built[.fur] = make([tap(0, T.furI, T.furS)])
        built[.snow] = make(T.snowTicks.enumerated().map { tap($0.element, T.snowTickI * (1 - 0.15 * Double($0.offset)), T.snowTickS) })
        built[.sleep] = make([hum(0, T.sleepSwell.t + T.sleepFade, T.sleepSwell.i, T.sleepS)],
                             [CHHapticParameterCurve(parameterID: .hapticIntensityControl, controlPoints: [
                                .init(relativeTime: 0, value: 0), .init(relativeTime: T.sleepSwell.t, value: 1),
                                .init(relativeTime: T.sleepSwell.t + T.sleepFade * 0.5, value: 0.35),
                                .init(relativeTime: T.sleepSwell.t + T.sleepFade, value: 0)], relativeTime: 0)])
        players = built
        clicks = (0..<4).compactMap { k in
            let i = T.clickI.from + (T.clickI.to - T.clickI.from) * Double(k) / 3
            return make([tap(0, i, T.clickS)])
        }
        if let p = try? CHHapticPattern(events: [hum(0, 60, 1, 0.5)], parameters: []) {
            tension = try? engine.makeAdvancedPlayer(with: p)
        }
        if let p = try? CHHapticPattern(events: (0..<Int(T.trembleRate)).map { tap(Double($0) / T.trembleRate, T.trembleI, T.trembleS) }, parameters: []) {
            tremble = try? engine.makeAdvancedPlayer(with: p)
            tremble?.loopEnabled = true
        }
        if let p = try? Self.purrPattern() {
            purr = try? engine.makeAdvancedPlayer(with: p)
            purr?.loopEnabled = true
        }
    }

    /// The faint whoosh: follows the spark's speed (it slows at the embers), rising overall,
    /// and stops a breath before the hit so the thud lands on silence.
    private func whoosh(kind: Int) -> (events: [CHHapticEvent], curves: [CHHapticParameterCurve]) {
        let f = RevontuletFlight.template(kind: kind)
        let length = f.duration - T.silenceBeforeHit
        var iPoints: [CHHapticParameterCurve.ControlPoint] = []
        var sPoints: [CHHapticParameterCurve.ControlPoint] = []
        let n = 14
        for k in 0...n {
            let t = length * Double(k) / Double(n)
            let speed = min(1, f.speed(at: t) / 2.2)
            let rise = 0.4 + 0.6 * t / length
            let i = T.whooshI.from + (T.whooshI.to - T.whooshI.from) * pow(speed, 0.7) * rise
            let s = T.whooshS.from + (T.whooshS.to - T.whooshS.from) * t / length
            iPoints.append(.init(relativeTime: t, value: Float(i / T.whooshI.to)))
            sPoints.append(.init(relativeTime: t, value: Float(s - 0.3)))
        }
        return ([hum(0, length, T.whooshI.to, 0.3)],
                [CHHapticParameterCurve(parameterID: .hapticIntensityControl, controlPoints: iPoints, relativeTime: 0),
                 CHHapticParameterCurve(parameterID: .hapticSharpnessControl, controlPoints: sPoints, relativeTime: 0)])
    }

    /// The crackle after a thud (easy: a couple; hard: more; the combo adds a rising
    /// three-beat flourish). Kept apart from the thud so the thud's decay does not mute it.
    private func crackle(kind: Int) -> [CHHapticEvent] {
        let n = [T.crackles.easy, T.crackles.hard, T.crackles.combo][kind]
        var events: [CHHapticEvent] = []
        var t = 0.05
        for k in 0..<n {
            let fall = 1 - Double(k) / Double(max(n, 1)) * 0.6
            events.append(tap(t, T.crackleI * fall, T.crackleS - 0.05 * Double(k % 3)))
            t += 0.03 + 0.017 * Double(k % 3) + 0.006 * Double(k)
        }
        if kind == 2 { events += T.flourish.map { tap($0.t, $0.i, $0.s) } }
        return events
    }

    /// Two seconds of purr, looped: soft pulses about 25 a second with small irregularities,
    /// breathing (the in-breath a little brighter and shorter, the out-breath softer, longer).
    private static func purrPattern() throws -> CHHapticPattern {
        var events: [CHHapticEvent] = []
        var t = 0.0, k = 0
        let inBreath = T.purrBreath * 0.42
        while t < T.purrBreath {
            let breathIn = t < inBreath
            let phase = breathIn ? t / inBreath : (t - inBreath) / (T.purrBreath - inBreath)
            let level = breathIn ? 0.75 + 0.25 * sin(phase * .pi) : 0.55 + 0.25 * cos(phase * .pi / 2)
            let jitter = 0.92 + 0.08 * sin(Double(k) * 2.39)
            events.append(CHHapticEvent(eventType: .hapticContinuous, parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: Float(T.purrI * level * jitter)),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: Float(T.purrS + (breathIn ? 0.06 : 0))),
            ], relativeTime: t, duration: 0.55 / T.purrRate))
            t += (1 / T.purrRate) * (0.94 + 0.12 * Double((k * 7) % 5) / 5)
            k += 1
        }
        return try CHHapticPattern(events: events, parameters: [])
    }

    // MARK: Building blocks

    private func tap(_ t: Double, _ i: Double, _ s: Double) -> CHHapticEvent {
        CHHapticEvent(eventType: .hapticTransient, parameters: [
            CHHapticEventParameter(parameterID: .hapticIntensity, value: Float(max(0.02, min(1, i)))),
            CHHapticEventParameter(parameterID: .hapticSharpness, value: Float(max(0, min(1, s)))),
        ], relativeTime: t)
    }

    private func hum(_ t: Double, _ duration: Double, _ i: Double, _ s: Double) -> CHHapticEvent {
        CHHapticEvent(eventType: .hapticContinuous, parameters: [
            CHHapticEventParameter(parameterID: .hapticIntensity, value: Float(max(0.02, min(1, i)))),
            CHHapticEventParameter(parameterID: .hapticSharpness, value: Float(max(0, min(1, s)))),
        ], relativeTime: t, duration: duration)
    }

    private func curve(_ id: CHHapticDynamicParameter.ID, from a: Double, to b: Double, over t: Double, start: Double = 0) -> CHHapticParameterCurve {
        CHHapticParameterCurve(parameterID: id, controlPoints: [
            .init(relativeTime: 0, value: Float(a)), .init(relativeTime: t * 0.35, value: Float(a + (b - a) * 0.6)),
            .init(relativeTime: t, value: Float(b))], relativeTime: start)
    }

    private func bell(_ id: CHHapticDynamicParameter.ID, start: Double, length: Double) -> CHHapticParameterCurve {
        CHHapticParameterCurve(parameterID: id, controlPoints: [
            .init(relativeTime: 0, value: 0), .init(relativeTime: length * 0.4, value: 1),
            .init(relativeTime: length, value: 0)], relativeTime: start)
    }

    private func dyn(_ id: CHHapticDynamicParameter.ID, _ v: Double) -> CHHapticDynamicParameter {
        CHHapticDynamicParameter(parameterID: id, value: Float(v), relativeTime: 0)
    }
}

extension RevontuletFlight {
    /// A stand-in flight with the real timing, for shaping the whoosh (0 easy, 1 hard, 2 fox).
    static func template(kind: Int) -> RevontuletFlight {
        var f = RevontuletFlight(launch: 0, from: .zero, control: CGPoint(x: 0.5, y: 0.5), to: CGPoint(x: 1, y: 1),
                                 duration: [RevontuletEngine.easyFlight, RevontuletEngine.hardFlight, RevontuletEngine.foxFlight][kind],
                                 hard: kind == 1, foxOwn: kind == 2)
        if kind == 1 {
            f.emberU = RevontuletEngine.emberU
            f.emberT = RevontuletEngine.emberT
        }
        return f
    }

    /// How fast the spark moves along its path at `t` (path lengths per second).
    func speed(at t: Double) -> Double {
        let h = 0.01
        return abs(progress(t + h) - progress(max(0, t - h))) / (t + h - max(0, t - h))
    }
}
