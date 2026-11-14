import Foundation
import CoreGraphics

/// The whole game as a plain value: feed it inputs and the clock, read its state.
///
/// Times are `CACurrentMediaTime()` seconds (the caller passes `now`, so the auto-play and
/// the frozen stills can run it on a made-up clock). Nothing here can fail: there is no
/// wrong answer, no reset, no lost progress, and the clock only ever helps.
struct RevontuletEngine: Equatable {
    /// The hard cap: the fox is asleep and the game has handed back by 1:30.
    static let cap: Double = 90
    /// From 1:05 the next impact breaks the wall, whatever round it is.
    static let breakOnImpactAfter: Double = 65
    /// At 1:12 a still-standing wall is broken by the fox's own spark.
    static let foxFinishesAt: Double = 72
    /// The latest the fox starts to fall asleep (it glides into sleep in 2 seconds).
    static let sleepLatest: Double = 88

    static let rounds = 3
    static let easyFlight = 0.7
    static let hardFlight = 1.8
    static let foxFlight = 1.0
    /// Where the two embers sit along a hard path, and when the spark reaches each.
    static let emberU = [0.36, 0.7]
    static let emberT = [0.85, 1.45]
    static let impactHold = 0.95        // the next lines light while the debris still falls
    static let breakDelay = 0.55        // the breaking impact's cracks race before the burst
    static let celebrateDelay = 0.8     // the burst, then the fox's celebration
    static let warmthDelay = 4.2        // three calm seconds for the smile, then the warmth
    static let strokesFrom = 0.6        // after the warmth begins, strokes count
    static let strokesWanted = 3
    static let sleepAfterStrokes = 1.0
    /// The goodnight: the fox glides into sleep, then the game waits for Continue. If nothing
    /// is touched for this long it hands back by itself, so nobody is ever stuck.
    static let asleepAfter = 1.0
    static let continueSafety = 30.0
    /// Lead-ins: the half-circle after a choice, the sling after the trace.
    static let arcLead = 0.22
    static let slingLead = 0.08

    let layout: RevontuletLayout
    let seed: UInt64

    private(set) var beat: RevontuletBeat = .intro
    /// When the current beat begins. It can be a moment in the future (a short lead-in);
    /// touches before it are ignored.
    private(set) var beatStart: Double = 0
    private(set) var startUptime: Double?
    private(set) var startDate: Date?
    private(set) var round = 0
    private(set) var records: [RevontuletResult.Round] = []

    // Trace
    private(set) var progress: Double = 0
    private(set) var reversed = false
    private(set) var tracing = false
    private var traceStart: Double?
    private var traceDown: Double?          // when the current tracing touch went down
    private var traceTouchTime: Double = 0
    private var traceRadii: [Double] = []
    private var lastStep = 0

    // Sling
    private(set) var pull: CGVector = .zero
    private(set) var pulling = false
    private var pullOrigin: CGPoint = .zero
    private var pullStart: Double = 0
    private var pullMax: CGFloat = 0
    private var lastPullLevel: Double = 0
    /// A touch that began in an earlier beat must lift before it can do something new.
    private var staleTouch = false

    // Flight and the wall
    private(set) var flight: RevontuletFlight?
    /// While a first-time coach shows the first embers, the flight's own time slows almost
    /// to a stop (`slowRate`); `flightDebt` is the time it has fallen behind the real clock.
    private(set) var slowSince: Double?
    private(set) var flightDebt: Double = 0
    static let slowRate = 0.05
    private(set) var impacts: [RevontuletImpact] = []
    private(set) var skyLight: Double = 0
    private(set) var burstAt: Double?
    private(set) var celebrateAt: Double?
    private(set) var warmthAt: Double?
    private(set) var foxFinished = false

    // Warmth and sleep
    private(set) var strokes: [RevontuletResult.Stroke] = []
    private(set) var stroking = false
    private var stroke: StrokeTrack?
    private(set) var sleepAt: Double?
    private(set) var endAt: Double?
    private(set) var completed = false
    /// The app left the foreground mid-game: ended, recorded as interrupted.
    private(set) var interrupted = false
    /// The last finger down (for the touch's answering flash) and the last input of any kind
    /// (for the gentle hint after a few seconds of nothing).
    private(set) var lastDown: CGPoint?
    private(set) var lastDownAt: Double = 0
    private(set) var lastInputAt: Double = 0

    // The finger
    private(set) var finger: CGPoint?
    private var last: Sample?
    private var speed: Double = 0

    private var rng: Rng
    /// Every touch radius of the game, for its mean and variance.
    private var radiusSum = 0.0, radiusSquares = 0.0, radiusCount = 0

    init(layout: RevontuletLayout, seed: UInt64 = UInt64.random(in: 1...UInt64.max)) {
        self.layout = layout
        self.seed = seed
        rng = Rng(seed: seed)
    }

    /// Seconds since Start (0 before it).
    func clock(_ now: Double) -> Double { startUptime.map { now - $0 } ?? 0 }

    func date(_ uptime: Double) -> Date {
        guard let d = startDate, let u = startUptime else { return Date() }
        return d.addingTimeInterval(uptime - u)
    }

    var arc: RevontuletArc { layout.arc(round: round) }
    var choice: RevontuletEffort? { records.indices.contains(round) ? records[round].effort : nil }
    var broken: Bool { burstAt != nil }
    var strokesCounted: Int { strokes.count }

    /// The flight's own clock: the real clock, less the time spent slowed.
    func flightClock(_ now: Double) -> Double {
        now - flightDebt - (slowSince.map { max(0, now - $0) * (1 - Self.slowRate) } ?? 0)
    }

    /// Time slows almost to a stop (a coach is showing an ember); `resumeFlight` lets it run.
    mutating func slowFlight(at now: Double) {
        guard beat == .flight, slowSince == nil else { return }
        slowSince = now
    }

    mutating func resumeFlight(at now: Double) {
        guard let s = slowSince else { return }
        flightDebt += max(0, now - s) * (1 - Self.slowRate)
        slowSince = nil
    }

    /// Where the spark is right now (resting, pulled, or in the air).
    func sparkPoint(_ now: Double) -> CGPoint {
        if let f = flight, beat == .flight { return f.point(at: flightClock(now)) }
        return CGPoint(x: layout.anchor.x + pull.dx, y: layout.anchor.y + pull.dy)
    }

    // MARK: Inputs

    mutating func handle(_ input: RevontuletInput, at now: Double) -> [RevontuletEvent] {
        var ev = tick(now)
        switch input {
        case .start:
            guard beat == .intro else { return ev }
            startUptime = now
            lastInputAt = now
            startDate = Date().addingTimeInterval(now - Self.uptimeNow())
            ev.append(.started)
            records = [RevontuletResult.Round(number: 1)]
            setBeat(.choice, at: now)
            ev.append(.choiceShown(round: 0))
        case .interrupt:
            guard beat != .done, startUptime != nil else { return ev }
            if stroking { ev += endStroke(at: now) }
            // Once the wall has burst the game is finished, however the person leaves; before
            // that, leaving the app is an interruption.
            let finished = burstAt != nil
            beat = .done
            beatStart = now
            if !(completed && endAt != nil) { endAt = now }
            completed = finished
            interrupted = !finished
            ev.append(.ended(completed: finished))
        case .finish:
            // Continue, once the fox is asleep.
            guard beat == .sleep, completed else { return ev }
            beat = .done
            beatStart = now
            ev.append(.ended(completed: true))
        case .close:
            resumeFlight(at: now)
            guard beat != .done else { return ev }
            if stroking { ev += endStroke(at: now) }
            // Once the wall has burst the game is finished, however the person leaves
            // (celebration, warmth, goodnight); closing before that is stopped by the person.
            let finished = burstAt != nil
            beat = .done
            beatStart = now
            if !(completed && endAt != nil) { endAt = now }
            completed = finished
            ev.append(.ended(completed: finished))
        case let .down(p, r):
            noteRadius(r)
            // One finger plays. A second finger landing while one is down is ignored (unless
            // the first went quiet long ago: then its lift was lost, so lift it now).
            if let f = finger {
                if let l = last, now - l.t < 2 { return ev }
                ev += up(f, at: now)
            }
            finger = p
            last = Sample(p: p, t: now)
            speed = 0
            staleTouch = false
            lastDown = p
            lastDownAt = now
            lastInputAt = now
            if beat == .intro {
                // The game starts on the first touch.
                ev += handle(.start, at: now)
                staleTouch = true
                return ev
            }
            ev += down(p, radius: r, at: now)
        case let .move(p, r):
            guard finger != nil else { return ev }
            noteRadius(r)
            ev += move(p, radius: r, at: now)
            finger = p
            lastInputAt = now
        case let .up(p):
            guard finger != nil else { return ev }
            ev += move(p, radius: nil, at: now)
            ev += up(p, at: now)
            finger = nil
            last = nil
            staleTouch = false
        }
        return ev
    }

    private mutating func down(_ p: CGPoint, radius: CGFloat?, at now: Double) -> [RevontuletEvent] {
        guard startUptime != nil, now >= beatStart else { return [] }
        switch beat {
        case .choice:
            return choose(at: p, now: now)
        case .trace:
            return traceTouch(p, radius: radius, at: now, isDown: true)
        case .sling:
            pulling = true
            pullOrigin = p
            pullStart = now
            pullMax = 0
            pull = .zero
            lastPullLevel = 0
            return [.pullStarted]
        case .flight:
            return tapEmber(p, at: now)
        case .warmth:
            guard let w = warmthAt, now >= w + Self.strokesFrom, strokes.count < Self.strokesWanted else { return [] }
            stroking = true
            stroke = StrokeTrack(start: now, from: p, radii: radius.map { [Double($0)] } ?? [])
            return [.strokeBegan(number: strokes.count + 1)]
        default:
            return []
        }
    }

    private mutating func move(_ p: CGPoint, radius: CGFloat?, at now: Double) -> [RevontuletEvent] {
        var ev: [RevontuletEvent] = []
        let step: CGFloat = last.map { hypot(p.x - $0.p.x, p.y - $0.p.y) } ?? 0
        if let l = last, now - l.t > 0.004 {
            let inst = Double(step) / (now - l.t)
            speed = speed == 0 ? inst : speed * 0.55 + inst * 0.45
        }
        if let l = last { last = Sample(p: p, t: max(now, l.t)) }
        guard startUptime != nil, !staleTouch, now >= beatStart else { return ev }
        switch beat {
        case .trace:
            if tracing {
                records[round].traceLength += Double(step)
                records[round].tracePeakSpeed = max(records[round].tracePeakSpeed ?? 0, speed)
                if let r = radius { traceRadii.append(Double(r)) }
            }
            ev += traceTouch(p, radius: radius, at: now, isDown: false)
        case .sling where pulling:
            let raw = CGVector(dx: p.x - pullOrigin.x, dy: p.y - pullOrigin.y)
            let len = hypot(raw.dx, raw.dy)
            pullMax = max(pullMax, len)
            let soft = layout.maxPull * CGFloat(tanh(Double(len / layout.maxPull)))
            pull = len > 0.01 ? CGVector(dx: raw.dx * soft / len, dy: raw.dy * soft / len) : .zero
            let level = Double(soft / layout.maxPull)
            if abs(level - lastPullLevel) > 0.01 {
                lastPullLevel = level
                ev.append(.pull(level))
            }
        case .warmth where stroking:
            stroke?.add(p, step: step, speed: speed, radius: radius, at: now)
            ev.append(.strokeMoved(speed: speed))
        default:
            break
        }
        return ev
    }

    private mutating func up(_ p: CGPoint, at now: Double) -> [RevontuletEvent] {
        var ev: [RevontuletEvent] = []
        switch beat {
        case .trace where tracing:
            if let d = traceDown { traceTouchTime += now - d }
            traceDown = nil
            tracing = false
            records[round].traceLifts += 1
        case .sling where pulling:
            pulling = false
            let level = Double(hypot(pull.dx, pull.dy) / layout.maxPull)
            if level < 0.16 {
                pull = .zero
                ev.append(.pullLetGo)
            } else {
                ev += launch(at: now, level: level)
            }
        case .warmth where stroking:
            ev += endStroke(at: now)
        default:
            break
        }
        return ev
    }

    // MARK: The choice

    private mutating func choose(at p: CGPoint, now: Double) -> [RevontuletEvent] {
        let f = layout.faults(round: round)
        let de = Self.distance(p, to: f.easy), dh = Self.distance(p, to: f.hard)
        let reach = layout.size.width * 0.2
        guard min(de, dh) < reach else { return [] }
        let effort: RevontuletEffort = de < dh ? .easy : .hard
        records[round].effort = effort
        records[round].decisionMs = Self.ms(now - beatStart)
        records[round].chosenUptime = now
        setBeat(.trace, at: now + Self.arcLead)
        records[round].arcShownUptime = beatStart
        progress = 0
        reversed = false
        tracing = false
        traceStart = nil
        traceDown = nil
        traceTouchTime = 0
        traceRadii = []
        lastStep = 0
        staleTouch = true
        return [.chose(round: round, effort: effort), .arcShown(round: round)]
    }

    // MARK: The trace

    private mutating func traceTouch(_ p: CGPoint, radius: CGFloat?, at now: Double, isDown: Bool) -> [RevontuletEvent] {
        var ev: [RevontuletEvent] = []
        let arc = self.arc
        var spot = arc.locate(p, reversed: reversed)
        let near = spot.off < arc.radius * 0.7 && spot.s > -0.18 && spot.s < 1.18
        if !tracing {
            guard near || (isDown && spot.off < arc.radius * 0.95) else { return ev }
            // Starting at the far end is fine: the light then runs the other way.
            if progress == 0, spot.s > 0.72 {
                reversed = true
                spot = arc.locate(p, reversed: true)
            }
            tracing = true
            traceDown = now
            if traceStart == nil {
                traceStart = now
                records[round].firstTouchMs = Self.ms(now - beatStart)
                ev.append(.traceStarted(round: round))
            }
            if let r = radius { traceRadii.append(Double(r)) }
        }
        guard near else { return ev }
        // The light follows the finger forwards; it never skips ahead and never goes back.
        if spot.s >= progress - 0.1, spot.s <= progress + 0.24 {
            progress = min(1, max(progress, spot.s))
        }
        let stepNow = Int(progress * 12)
        if stepNow > lastStep {
            lastStep = stepNow
            ev.append(.traceStep(stepNow))
        }
        if progress >= 0.975 {
            progress = 1
            if let d = traceDown { traceTouchTime += now - d }
            traceDown = nil
            tracing = false
            let start = traceStart ?? now
            records[round].traceDurationMs = Self.ms(now - start)
            if traceTouchTime > 0.05 {
                records[round].traceMeanSpeed = records[round].traceLength / traceTouchTime
            }
            if !traceRadii.isEmpty {
                records[round].traceTouchRadius = traceRadii.reduce(0, +) / Double(traceRadii.count)
            }
            ev.append(.traceEnded(round: round))
            setBeat(.sling, at: now + Self.slingLead)
            pull = .zero
            staleTouch = true
        }
        return ev
    }

    // MARK: The sling and the flight

    private mutating func launch(at now: Double, level: Double) -> [RevontuletEvent] {
        guard let effort = choice else { return [] }
        records[round].pullDistance = Double(hypot(pull.dx, pull.dy))
        records[round].pullMaxFinger = Double(pullMax)
        records[round].holdMs = Self.ms(now - pullStart)
        records[round].launchUptime = now
        records[round].launchDate = date(now)
        let from = CGPoint(x: layout.anchor.x + pull.dx, y: layout.anchor.y + pull.dy)
        let to = layout.target(round: round, effort: effort)
        let control = RevontuletLayout.flightControl(from: from, to: to, pull: pull)
        var f = RevontuletFlight(launch: now, from: from, control: control, to: to,
                                 duration: effort == .hard ? Self.hardFlight : Self.easyFlight, hard: effort == .hard, foxOwn: false)
        if effort == .hard {
            f.emberU = Self.emberU
            f.emberT = Self.emberT
            f.emberShownAt = [nil, nil]
            f.emberShownReal = [nil, nil]
            f.emberHitAt = [nil, nil]
            f.emberMissed = [false, false]
        }
        flight = f
        flightDebt = 0
        slowSince = nil
        pull = .zero
        setBeat(.flight, at: now)
        var ev: [RevontuletEvent] = [.released(round: round, level: level)]
        ev += settle(now)
        return ev
    }

    private mutating func foxLaunch(at now: Double) -> [RevontuletEvent] {
        var ev: [RevontuletEvent] = []
        if pulling { pulling = false; ev.append(.pullLetGo) }
        tracing = false
        foxFinished = true
        let from = layout.anchor
        let to = layout.foxTarget
        let control = CGPoint(x: from.x + layout.size.width * 0.12, y: (from.y + to.y) / 2 - 30)
        flight = RevontuletFlight(launch: now, from: from, control: control, to: to,
                                  duration: Self.foxFlight, hard: false, foxOwn: true)
        flightDebt = 0
        slowSince = nil
        pull = .zero
        staleTouch = true
        setBeat(.flight, at: now)
        ev.append(.foxLaunched)
        ev += settle(now)
        return ev
    }

    private mutating func tapEmber(_ p: CGPoint, at now: Double) -> [RevontuletEvent] {
        guard var f = flight, f.hard else { return [] }
        let fc = flightClock(now)
        let t = fc - f.launch
        var best: (i: Int, d: CGFloat)?
        for i in f.emberU.indices where f.emberHitAt[i] == nil && !f.emberMissed[i] {
            guard t >= f.emberT[i] - RevontuletFlight.emberLead - RevontuletFlight.emberEarly,
                  t <= f.emberT[i] + RevontuletFlight.emberGrace else { continue }
            let d = hypot(p.x - f.emberPoint(i).x, p.y - f.emberPoint(i).y)
            if d < max(76, layout.size.width * 0.22), d < (best?.d ?? .infinity) { best = (i, d) }
        }
        guard let hit = best else { return [] }
        let shown = f.launch + f.emberT[hit.i] - RevontuletFlight.emberLead
        // On the real clock, from the flash the person saw to the finger (a tap a moment
        // before the flash counts, as 0).
        let ms = Self.ms(now - (f.emberShownReal[hit.i] ?? now))
        f.emberHitAt[hit.i] = now
        if f.emberShownAt[hit.i] == nil {
            f.emberShownAt[hit.i] = shown
            records[round].embersShown += 1
        }
        flight = f
        records[round].emberHits.append(.init(index: hit.i, reactionMs: ms, uptime: now, coached: slowSince != nil))
        return [.emberHit(index: hit.i, reactionMs: ms)]
    }

    private mutating func land(at time: Double) -> [RevontuletEvent] {
        guard let f = flight else { return [] }
        let t = time - (startUptime ?? time)
        let outcome = f.planned ?? plan(for: f, landing: t)
        let hits = outcome.embersHit, breaking = outcome.breaking, pieces = outcome.pieces, ribbon = outcome.ribbon
        impacts.append(RevontuletImpact(time: time, point: f.to, round: round, pieces: pieces, hard: f.hard,
                                        embersHit: hits, breaking: breaking, ribbon: ribbon, foxOwn: f.foxOwn))
        if !f.foxOwn {
            records[round].impactUptime = time
            records[round].bonus = ribbon
        }
        skyLight = min(0.85, skyLight + (f.hard ? 0.24 + 0.08 * Double(hits) : 0.1))
        setBeat(.impact, at: time)
        return [.impact(round: round, pieces: pieces, breaking: breaking)]
    }

    /// Once nothing can change the landing, fix it and say so (for scheduled haptics).
    private mutating func settle(_ now: Double) -> [RevontuletEvent] {
        guard slowSince == nil, var f = flight, f.planned == nil, flightClock(now) >= f.settledAt,
              let t0 = startUptime else { return [] }
        let at = f.launch + f.duration + flightDebt
        let p = plan(for: f, landing: at - t0)
        f.planned = p
        flight = f
        return [.landing(at: at, pieces: p.pieces, hard: f.hard, embersHit: p.embersHit, breaking: p.breaking,
                         ribbon: p.ribbon, burstAt: p.breaking ? at + Self.breakDelay : nil)]
    }

    private mutating func plan(for f: RevontuletFlight, landing t: Double) -> RevontuletFlight.Planned {
        let hits = f.emberHitAt.compactMap { $0 }.count
        let breaking = f.foxOwn || round >= Self.rounds - 1 || t >= Self.breakOnImpactAfter
        // Round one is thin ice: a quick, generous first win. Later rounds build to the burst.
        // Easy: one piece. Hard: a much wider hole, wider still with each ember lit.
        let pieces = f.foxOwn ? 2 : (f.hard ? 3 + hits : 1) + (round == 0 ? 1 : 0)
        let ribbon = f.hard && hits == 2 && rng.next() < 0.6
        return .init(pieces: pieces, embersHit: hits, breaking: breaking, ribbon: ribbon)
    }

    // MARK: Strokes

    private mutating func endStroke(at now: Double) -> [RevontuletEvent] {
        guard let s = stroke else { stroking = false; return [] }
        stroke = nil
        stroking = false
        let duration = max(now - s.start, 0.001)
        let counted = s.length >= layout.strokeLength && strokes.count < Self.strokesWanted
        let number = strokes.count + 1
        if counted {
            let dy = Double(s.lastPoint.y - s.from.y)
            strokes.append(.init(number: number, startUptime: s.start, durationMs: Self.ms(duration),
                                 length: Double(s.length), meanSpeed: Double(s.length) / duration,
                                 peakSpeed: s.peak, downness: s.length > 0 ? max(-1, min(1, dy / Double(s.length))) : 0,
                                 touchRadius: s.radii.isEmpty ? nil : s.radii.reduce(0, +) / Double(s.radii.count)))
            if strokes.count == Self.strokesWanted, sleepAt == nil {
                sleepAt = min(now + Self.sleepAfterStrokes, (startUptime ?? now) + Self.sleepLatest)
            }
        }
        return [.strokeEnded(number: number, counted: counted)]
    }

    // MARK: The clock

    mutating func tick(_ now: Double) -> [RevontuletEvent] {
        guard let t0 = startUptime, beat != .intro, beat != .done else { return [] }
        var ev: [RevontuletEvent] = []
        let t = now - t0

        if beat == .flight, var f = flight {
            let fc = flightClock(now)
            for i in f.emberU.indices {
                let shown = f.launch + f.emberT[i] - RevontuletFlight.emberLead
                if f.emberShownAt[i] == nil, fc >= shown {
                    f.emberShownAt[i] = shown
                    f.emberShownReal[i] = now
                    records[round].embersShown += 1
                    ev.append(.emberShown(index: i))
                }
                if f.emberHitAt[i] == nil, !f.emberMissed[i], fc > f.launch + f.emberT[i] + RevontuletFlight.emberGrace {
                    f.emberMissed[i] = true
                    ev.append(.emberMissed(index: i))
                }
            }
            flight = f
            ev += settle(now)
            if slowSince == nil, fc >= f.launch + f.duration { ev += land(at: f.launch + f.duration + flightDebt) }
        }

        if beat == .impact, let last = impacts.last {
            if last.breaking {
                if now >= last.time + Self.breakDelay {
                    burstAt = last.time + Self.breakDelay
                    celebrateAt = burstAt! + Self.celebrateDelay
                    warmthAt = min(burstAt! + Self.warmthDelay, t0 + 80)
                    skyLight = 1
                    flight = nil
                    setBeat(.burst, at: burstAt!)
                    ev.append(.shattered)
                }
            } else if now >= last.time + Self.impactHold {
                round += 1
                records.append(RevontuletResult.Round(number: round + 1))
                flight = nil
                setBeat(.choice, at: now)
                staleTouch = finger != nil
                ev.append(.choiceShown(round: round))
            }
        }

        // Nobody is left behind: at 1:12 the fox's own spark finishes a wall still standing.
        if burstAt == nil, t >= Self.foxFinishesAt {
            let breakingImpact = beat == .impact && impacts.last?.breaking == true
            if [RevontuletBeat.choice, .trace, .sling].contains(beat) || (beat == .impact && !breakingImpact) {
                ev += foxLaunch(at: now)
            }
        }

        if beat == .burst, let c = celebrateAt, now >= c {
            setBeat(.celebrate, at: c)
            ev.append(.celebrate)
        }
        if beat == .celebrate, let w = warmthAt, now >= w {
            setBeat(.warmth, at: w)
            ev.append(.warmthBegan)
        }

        // The hard cap: glide into sleep from wherever the person is.
        if sleepAt == nil, t >= Self.sleepLatest {
            if stroking { ev += endStroke(at: now) }
            sleepAt = now
        }
        if let s = sleepAt, now >= s, beat != .sleep {
            if stroking { ev += endStroke(at: now) }
            pulling = false
            tracing = false
            setBeat(.sleep, at: s)
            endAt = min(s + Self.asleepAfter, t0 + Self.cap)
            ev.append(.sleep)
        }
        // Asleep: the game is complete (its record ends here), and it waits for Continue.
        if beat == .sleep, let e = endAt, now >= e, !completed {
            completed = true
            ev.append(.asleep)
        }
        if beat == .sleep, completed, let e = endAt, now >= e + Self.continueSafety {
            beat = .done
            beatStart = now
            ev.append(.ended(completed: true))
        }
        return ev
    }

    // MARK: The result

    /// The measurements so far (nil before Start).
    func result() -> RevontuletResult? {
        guard let u0 = startUptime, let d0 = startDate else { return nil }
        let end = endAt ?? u0
        return RevontuletResult(startedAt: d0, endedAt: date(end), startUptime: u0, endUptime: end,
                                completed: completed, rounds: records.filter { $0.effort != nil || $0.number == 1 },
                                strokes: strokes, burstUptime: burstAt, celebrateUptime: celebrateAt,
                                foxFinishedWall: foxFinished, surpriseRibbons: impacts.filter(\.ribbon).count,
                                interrupted: interrupted, touchRadiusMean: radiusCount > 0 ? radiusSum / Double(radiusCount) : nil,
                                touchRadiusVar: radiusCount > 1 ? max(0, radiusSquares / Double(radiusCount) - pow(radiusSum / Double(radiusCount), 2)) : nil)
    }

    // MARK: Helpers

    private mutating func noteRadius(_ r: CGFloat?) {
        guard let r, r.isFinite, r > 0 else { return }
        radiusSum += Double(r)
        radiusSquares += Double(r * r)
        radiusCount += 1
    }

    /// Marks the current round's move as shown by a first-time coach.
    mutating func markCoached() {
        if records.indices.contains(round) { records[round].coached = true }
    }

    private mutating func setBeat(_ b: RevontuletBeat, at time: Double) {
        beat = b
        beatStart = time
    }

    static func ms(_ seconds: Double) -> Int { Int((max(0, seconds) * 1000).rounded()) }

    static func uptimeNow() -> Double { ProcessInfo.processInfo.systemUptime }

    static func distance(_ p: CGPoint, to line: [CGPoint]) -> CGFloat {
        var best = CGFloat.infinity
        for i in 0..<(line.count - 1) {
            let a = line[i], b = line[i + 1]
            let abx = b.x - a.x, aby = b.y - a.y
            let len2 = max(abx * abx + aby * aby, 0.0001)
            let u = max(0, min(1, ((p.x - a.x) * abx + (p.y - a.y) * aby) / len2))
            best = min(best, hypot(p.x - (a.x + u * abx), p.y - (a.y + u * aby)))
        }
        return best
    }
}

/// The finger's last position and time.
private struct Sample: Equatable {
    var p: CGPoint
    var t: Double
}

/// One stroke on the fox while the finger is down.
private struct StrokeTrack: Equatable {
    var start: Double
    var from: CGPoint
    var lastPoint: CGPoint = .zero
    var length: CGFloat = 0
    var peak: Double = 0
    var radii: [Double]

    init(start: Double, from: CGPoint, radii: [Double]) {
        self.start = start
        self.from = from
        self.lastPoint = from
        self.radii = radii
    }

    mutating func add(_ p: CGPoint, step: CGFloat, speed: Double, radius: CGFloat?, at now: Double) {
        length += step
        lastPoint = p
        peak = max(peak, speed)
        if let r = radius { radii.append(Double(r)) }
    }
}

/// A tiny repeatable random source (so a session's surprises and the stills are stable).
struct Rng: Equatable {
    private var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 0x9E3779B97F4A7C15 : seed }
    mutating func next() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double((state >> 11) & ((1 << 53) - 1)) / Double(1 << 53)
    }
}
