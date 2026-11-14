import Foundation
import QuartzCore

// MARK: - Game moments (read this first, Peter)
//
// The three activities announce what is happening in them, the instant it happens, so the
// sensors can line their data up with the game without touching game code.
//
// What fires, and when:
//
//   Sparks and snow (activity .focus)
//     focusStarted              the round starts (Start tapped, sparks begin to fall)
//     sparkCaught(reactionMs:)  a spark was tapped; reactionMs = spark appearing -> finger down
//     snowTapped                a snowflake was tapped (a wrong tap)
//     sparkMissed               a spark drifted all the way down without a tap
//     focusEnded(finished:)     the round ran to its end (true) or the person closed it (false)
//
//   Revontulet (activity .focus; it replaces Sparks and snow, see ios/REVONTULET.md)
//     revontuletStarted                 Start tapped; the 90-second clock begins
//     effortChosen(round:effort:)       a fault line picked; round counts from 1, effort .easy or .hard
//     traceStarted(round:)              the first touch on the half-circle
//     traceEnded(round:)                the light reached the end of the half-circle
//     slingReleased(round:)             the spark was let go
//     emberHit(reactionMs:)             an ember lit; reactionMs = its flash -> finger down
//     emberMissed                       an ember passed without a tap (it costs nothing)
//     iceImpact(round:)                 the spark hit the ice
//     iceShattered                      the wall burst (also a pleasant moment, FaceSense.mark())
//     foxCelebrates                     the fox's celebration starts (also a pleasant moment)
//     foxStroked(number:)               a stroke on the fox's fur ended; number counts from 1
//     revontuletEnded(finished:)        the fox fell asleep (true) or the person closed it (false)
//
//   Breathe with Lanvi (activity .breathing)
//     breatheStarted            the session starts (Start tapped)
//     breathIn(number:)         an in-breath begins; number counts from 1
//     breathHold(number:)       the short hold at the top of that breath begins
//     breathOut(number:)        the out-breath begins
//     breatheEnded(finished:)   every breath done (true) or the person closed it (false)
//
//   Evening check-in (activity .checkin)
//     checkinStarted            the check-in opens
//     checkinStep(_:)           a step is shown: plan question, good things, plan, goodnight
//     checkinEnded(finished:)   Done on goodnight (true) or closed early (false)
//     Moments never carry typed words or the labels the person picked.
//
// Each event carries `date` (wall clock) and `uptime` (CACurrentMediaTime(), seconds since
// boot). `uptime` is the same clock as ARFrame.timestamp, so it lines up with face frames.
//
// Listening: `GameMoments.shared.listen { event in ... }` returns a token; keep it, and
// listening stops when the token is released or you call `cancel()`. Or iterate
// `GameMoments.shared.stream()`. Handlers are called on the main thread, a moment after the
// event (its times are taken at the instant it happened). With no listener, emitting is one
// cheap check and nothing else.
//
// Example:
//
//   let token = GameMoments.shared.listen { event in
//       guard event.activity == .breathing else { return }
//       if case .breathIn(let n) = event.moment { print("breath \(n) in at", event.uptime) }
//   }
//   // ... later: token.cancel()  (or let it go out of scope)
//
// Separate from `FaceSense.mark()` (pleasant moments): both can be used side by side.

/// Which activity a moment belongs to. Raw values match the server's activity types.
enum GameActivity: String, Sendable {
    case focus, breathing, checkin
}

/// Which fault line was picked in Revontulet.
enum GameEffort: String, Sendable {
    case easy, hard
}

/// A step of the evening check-in, by name only.
enum GameCheckinStep: String, Sendable {
    case planQuestion = "plan_question"
    case goodThings = "good_things"
    case plan
    case goodnight
}

/// Something that just happened in a game. See the note at the top of this file.
enum GameMoment: Equatable, Sendable {
    // Sparks and snow
    case focusStarted
    case sparkCaught(reactionMs: Int)
    case snowTapped
    case sparkMissed
    case focusEnded(finished: Bool)
    // Revontulet
    case revontuletStarted
    case effortChosen(round: Int, effort: GameEffort)
    case traceStarted(round: Int)
    case traceEnded(round: Int)
    case slingReleased(round: Int)
    case emberHit(reactionMs: Int)
    case emberMissed
    case iceImpact(round: Int)
    case iceShattered
    case foxCelebrates
    case foxStroked(number: Int)
    case revontuletEnded(finished: Bool)
    // Breathe with Lanvi
    case breatheStarted
    case breathIn(number: Int)
    case breathHold(number: Int)
    case breathOut(number: Int)
    case breatheEnded(finished: Bool)
    // Evening check-in
    case checkinStarted
    case checkinStep(GameCheckinStep)
    case checkinEnded(finished: Bool)

    var activity: GameActivity {
        switch self {
        case .focusStarted, .sparkCaught, .snowTapped, .sparkMissed, .focusEnded: .focus
        case .revontuletStarted, .effortChosen, .traceStarted, .traceEnded, .slingReleased, .emberHit,
             .emberMissed, .iceImpact, .iceShattered, .foxCelebrates, .foxStroked, .revontuletEnded: .focus
        case .breatheStarted, .breathIn, .breathHold, .breathOut, .breatheEnded: .breathing
        case .checkinStarted, .checkinStep, .checkinEnded: .checkin
        }
    }

    /// A short stable name for logs and files, e.g. "spark_caught", "breath_in".
    var name: String {
        switch self {
        case .focusStarted: "focus_started"
        case .sparkCaught: "spark_caught"
        case .snowTapped: "snow_tapped"
        case .sparkMissed: "spark_missed"
        case .focusEnded: "focus_ended"
        case .revontuletStarted: "revontulet_started"
        case .effortChosen: "effort_chosen"
        case .traceStarted: "trace_started"
        case .traceEnded: "trace_ended"
        case .slingReleased: "sling_released"
        case .emberHit: "ember_hit"
        case .emberMissed: "ember_missed"
        case .iceImpact: "ice_impact"
        case .iceShattered: "ice_shattered"
        case .foxCelebrates: "fox_celebrates"
        case .foxStroked: "fox_stroked"
        case .revontuletEnded: "revontulet_ended"
        case .breatheStarted: "breathe_started"
        case .breathIn: "breath_in"
        case .breathHold: "breath_hold"
        case .breathOut: "breath_out"
        case .breatheEnded: "breathe_ended"
        case .checkinStarted: "checkin_started"
        case .checkinStep: "checkin_step"
        case .checkinEnded: "checkin_ended"
        }
    }
}

/// One moment with when it happened.
struct GameMomentEvent: Sendable {
    let moment: GameMoment
    let activity: GameActivity
    /// Wall-clock time.
    let date: Date
    /// `CACurrentMediaTime()` at the instant it happened: the same clock as `ARFrame.timestamp`.
    let uptime: TimeInterval
}

/// The emitter. Games call `GameMoments.emit(_:)`; sensors listen.
final class GameMoments: @unchecked Sendable {
    static let shared = GameMoments()

    private let lock = NSLock()
    private var handlers: [UUID: (GameMomentEvent) -> Void] = [:]

    /// Stops listening when released or cancelled.
    final class Token {
        private var stop: (() -> Void)?
        fileprivate init(_ stop: @escaping () -> Void) { self.stop = stop }
        func cancel() { stop?(); stop = nil }
        deinit { cancel() }
    }

    /// Announce a moment from a game. Safe from any thread; nearly free with no listener.
    static func emit(_ moment: GameMoment) { shared.emit(moment) }

    func emit(_ moment: GameMoment) {
        lock.lock()
        let listeners = Array(handlers.values)
        lock.unlock()
        guard !listeners.isEmpty else { return }
        let event = GameMomentEvent(moment: moment, activity: moment.activity, date: Date(), uptime: CACurrentMediaTime())
        // Delivered on the main thread on the next turn, so a listener can never disturb a
        // screen that is in the middle of drawing.
        DispatchQueue.main.async {
            for handler in listeners { handler(event) }
        }
    }

    /// Call `handler` on the main thread for every moment from now on, until the token goes.
    func listen(_ handler: @escaping (GameMomentEvent) -> Void) -> Token {
        let id = UUID()
        lock.lock()
        handlers[id] = handler
        lock.unlock()
        return Token { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.handlers[id] = nil
            self.lock.unlock()
        }
    }

    /// Every moment from now on, as an async sequence. Ends when the loop that reads it stops.
    func stream() -> AsyncStream<GameMomentEvent> {
        AsyncStream { continuation in
            let token = listen { continuation.yield($0) }
            continuation.onTermination = { _ in token.cancel() }
        }
    }
}
