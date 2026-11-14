import SwiftUI

/// The one place Home opens an activity. Each case shows the real screen when
/// it exists on main, or a small stand-in until then, and turns the screen's
/// result into the record the server takes. Swapping in a real screen is the
/// few lines inside one case.
struct ActivityRouter: View {
    var kind: ActivityKind
    var checkinOptions: API.CheckinOptionsOut?
    var planToAsk: API.PlanToAsk?
    /// nil when the person closed it before anything happened.
    var onDone: (API.ActivityIn?) -> Void

    var body: some View {
        switch kind {
        case .focus:
            FocusGameView { result in onDone(result.map(Self.record)) }
        case .breathing:
            BreatheView { result in onDone(result.map(Self.record)) }
        case .checkin:
            StandInActivity(kind: .checkin, onDone: onDone)
        }
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

// MARK: - Stand-ins until the real screens land

/// A simple stand-in so Home, the send and the XP moment can be tested end to
/// end. "Finish" reports a believable record of the activity's usual length.
private struct StandInActivity: View {
    var kind: ActivityKind
    var onDone: (API.ActivityIn?) -> Void
    @State private var bounce = 0

    var body: some View {
        GeometryReader { geo in
            let hill = geo.size.height * 0.62
            ZStack(alignment: .top) {
                SkyScene(top: Theme.nightTop, bottom: Theme.nightBottom, hillTop: hill)
                LanviView(pose: pose, size: 200, bounceTrigger: bounce)
                    .position(x: geo.size.width / 2, y: hill - 100 + 14)
                    .onTapGesture { bounce += 1 }

                VStack(spacing: 10) {
                    Text(title)
                        .font(Theme.rounded(30, .black))
                        .foregroundStyle(.white)
                    Text("Stand-in until the real screen lands")
                        .font(Theme.rounded(15, .semibold))
                        .foregroundStyle(.white.opacity(0.75))
                }
                .padding(.top, 90)

                VStack(spacing: 14) {
                    Spacer()
                    Button("Finish") { onDone(record(completed: true)) }
                        .buttonStyle(ChunkyButtonStyle())
                    Button("Stop early") { onDone(record(completed: false)) }
                        .buttonStyle(ChunkyButtonStyle(fill: .white, edge: Theme.line, text: Theme.brand))
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 16)

                HStack {
                    HomeCloseButton { onDone(nil) }
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.top, 6)
            }
        }
    }

    private var title: String {
        switch kind {
        case .focus: return "Sparks and snow"
        case .breathing: return "Breathe with Lanvi"
        case .checkin: return "Evening check-in"
        }
    }

    private var pose: LanviPose {
        switch kind {
        case .focus: return .run
        case .breathing: return .love
        case .checkin: return .curious
        }
    }

    private func record(completed: Bool) -> API.ActivityIn {
        let seconds: Double = kind == .checkin ? 50 : (completed ? (kind == .focus ? 45 : 60) : 20)
        let started = API.isoString(Date().addingTimeInterval(-seconds))
        let ended: API.EndedBy = completed ? .finished : .userStopped
        switch kind {
        case .focus:
            let correct = completed ? 18 : 8
            return API.ActivityIn(id: API.ActivityIn.newId(), type: .focus, startedAt: started,
                                  durationS: seconds, completed: completed, endedBy: ended,
                                  correctTaps: correct, wrongTaps: 1, misses: 3,
                                  reactionMs: (0..<correct).map { 480 + ($0 * 37) % 160 })
        case .breathing:
            return API.ActivityIn(id: API.ActivityIn.newId(), type: .breathing, startedAt: started,
                                  durationS: seconds, completed: completed, endedBy: ended,
                                  timePlayedS: seconds, breathsCompleted: Int(seconds / 10))
        case .checkin:
            return API.ActivityIn(id: API.ActivityIn.newId(), type: .checkin, startedAt: started,
                                  durationS: seconds, completed: completed, endedBy: ended,
                                  goodThings: completed ? [.init(catalogId: "walked"), .init(catalogId: "laughed")] : [],
                                  plan: completed ? .init(catalogId: "coffee_outside") : nil,
                                  planDone: .notAsked)
        }
    }
}
