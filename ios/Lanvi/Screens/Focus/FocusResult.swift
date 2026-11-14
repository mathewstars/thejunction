import Foundation

/// What one round of Sparks and snow sends to the server as a `focus` activity
/// (see `docs/api/README.md`, "After an activity, send it").
struct FocusResult: Equatable {
    /// Sparks the person tapped.
    var correctTaps: Int
    /// Snowflakes the person tapped.
    var wrongTaps: Int
    /// Sparks that drifted all the way down without a tap.
    var misses: Int
    /// For each caught spark: time from the spark appearing to the tap, whole milliseconds. At most 200.
    var reactionMs: [Int]
    var startedAt: Date
    var endedAt: Date
    /// True when the round ran to its end.
    var completed: Bool
}
