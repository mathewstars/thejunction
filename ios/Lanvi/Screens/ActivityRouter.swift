import SwiftUI

/// The one place Home opens an activity: each case shows the real screen and
/// turns the screen's result into the record the server takes.
struct ActivityRouter: View {
    var kind: ActivityKind
    var checkinOptions: API.CheckinOptionsOut?
    var planToAsk: API.PlanToAsk?
    /// Opens the Help screen (the check-in shows a Help chip).
    var onHelp: (() -> Void)? = nil
    /// nil when the person closed it before anything happened.
    var onDone: (API.ActivityIn?) -> Void

    /// The game the `focus` activity opens: Revontulet. Set to false to bring back Sparks and snow.
    static let focusIsRevontulet = true

    var body: some View {
        switch kind {
        case .focus:
            FaceSenseHost {
                if Self.focusIsRevontulet {
                    RevontuletView { result in onDone(result.map { FaceSense.shared.attach(to: Self.record($0)) }) }
                } else {
                    FocusGameView { result in onDone(result.map { FaceSense.shared.attach(to: Self.record($0)) }) }
                }
            }
        case .breathing:
            FaceSenseHost {
                BreatheView { result in onDone(result.map { FaceSense.shared.attach(to: Self.record($0)) }) }
            }
        case .checkin:
            checkin
        }
    }

    private var checkin: some View {
        let options = checkinOptions.map {
            CheckinOptions(goodThings: $0.goodThings.map { CheckinOption(id: $0.id, label: $0.label) },
                           plans: $0.plans.map { CheckinOption(id: $0.id, label: $0.label) })
        } ?? .sample
        // A typed plan's words stay on the phone; without them the question is skipped.
        let question = planToAsk.flatMap {
            CheckinPlanQuestion(checkinId: $0.checkinId, planId: $0.planId, options: options)
        }
        var view = CheckinView(options: options, askAboutPlan: question) { result in
            onDone(result.map(Self.record))
        }
        view.onHelp = onHelp
        return view
    }

    static func record(_ r: CheckinResult) -> API.ActivityIn {
        func item(_ i: CheckinItem) -> API.CheckinItem { API.CheckinItem(catalogId: i.catalogId, text: i.typedText) }
        return API.ActivityIn(id: API.ActivityIn.newId(), type: .checkin,
                              startedAt: API.isoString(r.startedAt),
                              durationS: (r.durationSeconds * 10).rounded() / 10,
                              completed: true, endedBy: .finished,
                              goodThings: Array(r.goodThings.prefix(3)).map(item),
                              plan: r.plan.map(item),
                              planDone: API.PlanDone(rawValue: r.planDone.rawValue) ?? .notAsked)
    }

    // MARK: Screen results into server records

    static func record(_ r: FocusResult) -> API.ActivityIn {
        let duration = max(0, r.endedAt.timeIntervalSince(r.startedAt))
        let taps = r.correctTaps + r.wrongTaps
        return API.ActivityIn(id: API.ActivityIn.newId(), type: .focus,
                              startedAt: API.isoString(r.startedAt), durationS: (duration * 10).rounded() / 10,
                              completed: r.completed, endedBy: r.completed ? .finished : .userStopped,
                              correctTaps: r.correctTaps, wrongTaps: r.wrongTaps, misses: r.misses,
                              reactionMs: Array(r.reactionMs.prefix(min(200, taps))).map { min(max($0, 0), 10_000) })
    }

    /// Revontulet as a `focus` record, with exactly the fields `focus` has today (the server
    /// refuses unknown ones; everything else stays on the phone in the result):
    /// correct taps = launches + embers lit; wrong taps = 0 (there is nothing wrong to tap);
    /// misses = embers that flashed and passed; reactions = per launch, the half-circle
    /// appearing to the first touch on it, then per lit ember, its flash to the tap.
    static func record(_ r: RevontuletResult) -> API.ActivityIn {
        let duration = max(0, r.endedAt.timeIntervalSince(r.startedAt))
        let correct = r.launches + r.embersHit
        return API.ActivityIn(id: API.ActivityIn.newId(), type: .focus,
                              startedAt: API.isoString(r.startedAt), durationS: (duration * 10).rounded() / 10,
                              completed: r.completed, endedBy: r.completed ? .finished : r.interrupted ? .interrupted : .userStopped,
                              correctTaps: correct, wrongTaps: 0, misses: max(0, r.embersShown - r.embersHit),
                              reactionMs: Array(r.reactionMs.prefix(min(200, correct))).map { min(max($0, 0), 10_000) })
    }

    static func record(_ r: BreatheResult) -> API.ActivityIn {
        let duration = max(0, r.endedAt.timeIntervalSince(r.startedAt))
        return API.ActivityIn(id: API.ActivityIn.newId(), type: .breathing,
                              startedAt: API.isoString(r.startedAt), durationS: (duration * 10).rounded() / 10,
                              completed: r.completed, endedBy: r.completed ? .finished : .userStopped,
                              timePlayedS: min(r.timePlayedS, duration), breathsCompleted: r.breathsCompleted)
    }
}
