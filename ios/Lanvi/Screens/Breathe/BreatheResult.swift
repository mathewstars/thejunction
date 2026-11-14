import SwiftUI

/// What one finished Breathe with Lanvi session hands back, ready for a `breathing`
/// activity record (`POST /v1/activities`, see docs/api/README.md).
///
/// - `startedAt`: when the person tapped Start.
/// - `endedAt`: when the last out-breath ended (not when they tapped Done).
/// - `timePlayedS`: real elapsed seconds between the two.
/// - `breathsCompleted`: only breaths that went all the way in, held and all the way out.
/// - `completed`: every planned breath was done.
struct BreatheResult: Equatable {
    var startedAt: Date
    var endedAt: Date
    var timePlayedS: Double
    var breathsCompleted: Int
    var completed: Bool

    init(startedAt: Date, endedAt: Date, breathsCompleted: Int, completed: Bool) {
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.timePlayedS = (max(0, endedAt.timeIntervalSince(startedAt)) * 10).rounded() / 10
        self.breathsCompleted = breathsCompleted
        self.completed = completed
    }
}

/// The rhythm: about six slow breaths a minute (docs/game-design.md), out-breath longer
/// than the in-breath, which is what makes slow breathing calming.
enum BreathePace {
    static let breaths = 6
    static let settle: Double = 2.0
    static let inhale: Double = 4.0
    static let hold: Double = 1.5
    static let exhale: Double = 5.5

    /// Shaped like real breath: the in-breath starts gently, flows, and rounds off full;
    /// the out-breath lets go a little quicker and then trails off slowly. Never linear.
    static let inhaleCurve = Animation.timingCurve(0.42, 0, 0.32, 1, duration: inhale)
    static let exhaleCurve = Animation.timingCurve(0.3, 0.05, 0.2, 1, duration: exhale)
    static let settleCurve = Animation.timingCurve(0.4, 0, 0.25, 1, duration: settle)
}

/// One step of a breath. `settle` is the short lead-in before the first breath.
enum BreathPhase: Equatable {
    case settle, inhale, hold, exhale

    var word: String {
        switch self {
        case .settle: "Get comfy"
        case .inhale: "Breathe in"
        case .hold: "Hold"
        case .exhale: "Breathe out"
        }
    }
}
