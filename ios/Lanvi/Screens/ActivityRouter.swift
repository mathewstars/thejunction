import SwiftUI

/// The one place Home opens an activity: each case shows the real screen and
/// turns the screen's result into the record the server takes.
///
/// Around every activity sits one `SensorSessionHost` (`ios/WATCH.md`): it gives the
/// activity its id before it starts, waits for the Apple Watch when there is one, hears
/// every `GameMoments` event, and at the end puts the watch's heart data and the moments
/// on the record (`sensors`) next to the face frames (`face_raw`, `FaceSenseHost`).
/// The games themselves are unchanged.
struct ActivityRouter: View {
    var kind: ActivityKind
    var checkinOptions: API.CheckinOptionsOut?
    var planToAsk: API.PlanToAsk?
    /// Opens the Help screen (the check-in shows a Help chip).
    var onHelp: (() -> Void)? = nil
    /// nil when the person closed it before anything happened.
    var onDone: (API.ActivityIn?) -> Void

    var body: some View {
        SensorSessionHost(kind: kind, onClose: { onDone(nil) }) { session in
            switch kind {
            case .focus:
                FaceSenseHost {
                    FocusGameView { result in finish(result.map(Self.record), session: session) }
                }
            case .breathing:
                FaceSenseHost {
                    BreatheView { result in finish(result.map(Self.record), session: session) }
                }
            case .checkin:
                checkin(session: session)
            }
        }
    }

    /// The face frames first (they stop the camera), then the watch's last samples
    /// (a short wait), then the record goes to Home with the session's id.
    private func finish(_ record: API.ActivityIn?, session: SensorSession) {
        guard let record else {
            session.cancel()
            onDone(nil)
            return
        }
        let withFace = FaceSense.shared.attach(to: record)
        Task { @MainActor in
            await session.end()
            onDone(session.attach(to: withFace, faceAnchorUptime: FaceSense.shared.lastFaceAnchorUptime))
        }
    }

    private func checkin(session: SensorSession) -> some View {
        let options = checkinOptions.map {
            CheckinOptions(goodThings: $0.goodThings.map { CheckinOption(id: $0.id, label: $0.label) },
                           plans: $0.plans.map { CheckinOption(id: $0.id, label: $0.label) })
        } ?? .sample
        // A typed plan's words stay on the phone; without them the question is skipped.
        let question = planToAsk.flatMap {
            CheckinPlanQuestion(checkinId: $0.checkinId, planId: $0.planId, options: options)
        }
        var view = CheckinView(options: options, askAboutPlan: question) { result in
            finish(result.map(Self.record), session: session)
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

    static func record(_ r: BreatheResult) -> API.ActivityIn {
        let duration = max(0, r.endedAt.timeIntervalSince(r.startedAt))
        return API.ActivityIn(id: API.ActivityIn.newId(), type: .breathing,
                              startedAt: API.isoString(r.startedAt), durationS: (duration * 10).rounded() / 10,
                              completed: r.completed, endedBy: r.completed ? .finished : .userStopped,
                              timePlayedS: min(r.timePlayedS, duration), breathsCompleted: r.breathsCompleted)
    }
}
