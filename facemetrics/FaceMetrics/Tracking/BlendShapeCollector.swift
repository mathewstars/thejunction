import Foundation
import ARKit

/// Per-coefficient state the collector maintains for every identifier ARKit reports.
struct CoefficientState {
    let identifier: String          // ARKit raw identifier, e.g. "eyeBlink_L"
    let name: String                // Swift-style name, e.g. "eyeBlinkLeft"
    let category: BlendShapeCategory
    let side: BlendShapeSide
    var value: Float
    var timestamp: Double
    var previousValue: Float?
    var delta: Float?               // value - previousValue
    var velocity: Float?            // delta / dt, 1/s
    var sessionStats: RunningStatistics
    var firstSeen: Double

    var minimum: Float? { sessionStats.minOrNil }
    var maximum: Float? { sessionStats.maxOrNil }
    var mean: Float? { sessionStats.meanOrNil }
}

/// Enumerates the complete ARFaceAnchor.blendShapes dictionary on every frame and keeps raw
/// values plus session statistics for each identifier. Nothing is hardcoded: whatever keys the
/// running SDK returns are retained.
final class BlendShapeCollector {

    private(set) var states: [String: CoefficientState] = [:]
    private(set) var orderedIdentifiers: [String] = []
    private(set) var history: TimeAlignedHistory
    private(set) var lastTimestamp: Double?

    /// Number of history samples kept per coefficient for sparklines and windowed statistics.
    init(historyCapacity: Int = 900) {
        history = TimeAlignedHistory(capacity: historyCapacity)
    }

    /// Converts the ARKit dictionary into raw identifier -> Float.
    static func extract(from anchor: ARFaceAnchor) -> [String: Float] {
        var out = [String: Float](minimumCapacity: anchor.blendShapes.count)
        for (location, number) in anchor.blendShapes {
            out[location.rawValue] = number.floatValue
        }
        return out
    }

    /// Updates the per-coefficient states with one frame's values.
    func ingest(values: [String: Float], timestamp: Double) {
        let dt: Double? = lastTimestamp.map { timestamp - $0 }
        var newKeys = false
        for (id, value) in values {
            if var state = states[id] {
                state.previousValue = state.value
                let delta = value - state.value
                state.delta = delta
                if let dt, dt > 0 { state.velocity = Float(Double(delta) / dt) } else { state.velocity = nil }
                state.value = value
                state.timestamp = timestamp
                state.sessionStats.add(value)
                states[id] = state
            } else {
                var stats = RunningStatistics()
                stats.add(value)
                states[id] = CoefficientState(
                    identifier: id,
                    name: BlendShapeCatalog.friendlyName(for: id),
                    category: BlendShapeCategory.category(for: id),
                    side: BlendShapeCatalog.side(of: id),
                    value: value,
                    timestamp: timestamp,
                    previousValue: nil,
                    delta: nil,
                    velocity: nil,
                    sessionStats: stats,
                    firstSeen: timestamp
                )
                newKeys = true
            }
        }
        if newKeys {
            orderedIdentifiers = BlendShapeCatalog.sortedIdentifiers(states.keys)
        }
        history.append(time: timestamp, values: values)
        lastTimestamp = timestamp
    }

    /// Marks a frame without a face anchor so derivatives do not bridge the gap.
    func ingestMissingFrame(timestamp: Double) {
        for id in Array(states.keys) {
            states[id]?.previousValue = nil
            states[id]?.delta = nil
            states[id]?.velocity = nil
        }
        history.append(time: timestamp, values: [:])
        lastTimestamp = nil
    }

    func resetSessionStatistics() {
        for id in Array(states.keys) {
            states[id]?.sessionStats.reset()
        }
        history.removeAll()
    }

    func recentValues(for identifier: String, count: Int) -> [Float] {
        history.values(for: identifier, last: count)
    }
}
