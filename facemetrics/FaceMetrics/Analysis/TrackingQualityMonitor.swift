import Foundation

/// Technical quality figures for the current tracking run. Values that come straight from ARKit
/// (camera tracking state, interruptions, anchor presence) are kept separate from the
/// application-derived score, whose formula is documented on `qualityScoreFormula`.
struct TrackingQualityReport {
    var frameCount: Int
    var trackedFrameCount: Int
    var frameInterval: Double?
    var meanFrameInterval: Double?
    var expectedFrameInterval: Double
    var measuredFPS: Double
    var averageFPS: Double
    var droppedFrameEstimate: Int
    var interruptionCount: Int
    var faceAnchorPresent: Bool
    var faceTracked: Bool
    var cameraTrackingState: CameraTrackingStateCode
    var cameraLimitedReason: String?
    var trackedFractionLastWindow: Double
    var droppedFractionLastWindow: Double
    /// Application-derived, 0...1. See `qualityScoreFormula`.
    var qualityScore: Float
    var sessionDuration: Double
    var windowSeconds: Double

    static let qualityScoreFormula =
        "score = 0.5 * trackedFraction(window) + 0.3 * (1 - droppedFraction(window)) + 0.2 * cameraStateWeight, " +
        "where cameraStateWeight is 1.0 for normal, 0.5 for limited, 0 for notAvailable. Application-derived; not an ARKit value."
}

final class TrackingQualityMonitor {

    var windowSeconds: Double = 2

    private(set) var frameCount: Int = 0
    private(set) var trackedFrameCount: Int = 0
    private(set) var droppedFrameEstimate: Int = 0
    /// Frame gaps of one second or more, excluded from FPS and dropped-frame figures.
    private(set) var longGapCount: Int = 0
    private(set) var interruptionCount: Int = 0
    private(set) var lifecycleEvents: [SessionLifecycleEvent] = []
    private(set) var firstTimestamp: Double?
    private(set) var lastTimestamp: Double?
    private var lastInterval: Double?
    private var intervalSum: Double = 0
    private var intervalCount: Int = 0
    private var recentIntervals = RingBuffer<Double>(capacity: 240)
    private var recentTracked = RingBuffer<(time: Double, tracked: Bool, dropped: Int)>(capacity: 600)
    private var fpsWindow = RingBuffer<Double>(capacity: 120)
    /// Tracking state history as (session time, tracked) transitions for the analytics view.
    private(set) var trackedTransitions: [(time: Double, tracked: Bool)] = []
    private var lastTrackedState: Bool?

    var expectedFrameInterval: Double = 1.0 / 60.0

    /// Records one frame. Returns (interval, droppedEstimate) for the sample.
    func noteFrame(timestamp: Double, faceTracked: Bool) -> (interval: Double?, dropped: Int) {
        frameCount += 1
        if faceTracked { trackedFrameCount += 1 }
        if firstTimestamp == nil { firstTimestamp = timestamp }
        var interval: Double? = nil
        var dropped = 0
        if let last = lastTimestamp {
            let dt = timestamp - last
            interval = dt
            // Gaps longer than a second are interruptions (app backgrounded, camera taken away),
            // not dropped frames; they are logged as lifecycle events and kept out of the rate statistics.
            if dt < 1.0 {
                intervalSum += dt
                intervalCount += 1
                recentIntervals.append(dt)
                fpsWindow.append(dt)
                if expectedFrameInterval > 0, dt > expectedFrameInterval * 1.5 {
                    dropped = max(0, Int((dt / expectedFrameInterval).rounded()) - 1)
                    droppedFrameEstimate += dropped
                }
            } else {
                longGapCount += 1
            }
        }
        lastInterval = interval
        lastTimestamp = timestamp
        recentTracked.append((timestamp, faceTracked, dropped))
        if lastTrackedState != faceTracked {
            trackedTransitions.append((timestamp - (firstTimestamp ?? timestamp), faceTracked))
            if trackedTransitions.count > 2000 { trackedTransitions.removeFirst(trackedTransitions.count - 2000) }
            lastTrackedState = faceTracked
        }
        return (interval, dropped)
    }

    func noteLifecycle(_ event: SessionLifecycleEvent) {
        lifecycleEvents.append(event)
        if lifecycleEvents.count > 500 { lifecycleEvents.removeFirst(lifecycleEvents.count - 500) }
        if event.kind == .interrupted { interruptionCount += 1 }
    }

    func report(faceAnchorPresent: Bool, faceTracked: Bool, cameraState: CameraTrackingStateCode, cameraReason: String?) -> TrackingQualityReport {
        let fpsIntervals = fpsWindow.toArray()
        let measuredFPS = fpsIntervals.isEmpty ? 0 : Double(fpsIntervals.count) / fpsIntervals.reduce(0, +)
        let averageFPS = intervalCount > 0 ? Double(intervalCount) / intervalSum : 0

        var trackedN = 0, totalN = 0, droppedN = 0
        if let newest = lastTimestamp {
            let cutoff = newest - windowSeconds
            recentTracked.forEach { entry in
                if entry.time >= cutoff {
                    totalN += 1
                    if entry.tracked { trackedN += 1 }
                    droppedN += entry.dropped
                }
            }
        }
        let trackedFraction = totalN > 0 ? Double(trackedN) / Double(totalN) : 0
        let droppedFraction = (totalN + droppedN) > 0 ? Double(droppedN) / Double(totalN + droppedN) : 0
        let cameraWeight: Double
        switch cameraState {
        case .normal: cameraWeight = 1
        case .limited: cameraWeight = 0.5
        case .notAvailable: cameraWeight = 0
        }
        let score = 0.5 * trackedFraction + 0.3 * (1 - droppedFraction) + 0.2 * cameraWeight

        return TrackingQualityReport(
            frameCount: frameCount,
            trackedFrameCount: trackedFrameCount,
            frameInterval: lastInterval,
            meanFrameInterval: intervalCount > 0 ? intervalSum / Double(intervalCount) : nil,
            expectedFrameInterval: expectedFrameInterval,
            measuredFPS: measuredFPS,
            averageFPS: averageFPS,
            droppedFrameEstimate: droppedFrameEstimate,
            interruptionCount: interruptionCount,
            faceAnchorPresent: faceAnchorPresent,
            faceTracked: faceTracked,
            cameraTrackingState: cameraState,
            cameraLimitedReason: cameraReason,
            trackedFractionLastWindow: trackedFraction,
            droppedFractionLastWindow: droppedFraction,
            qualityScore: Float(score),
            sessionDuration: (lastTimestamp ?? 0) - (firstTimestamp ?? lastTimestamp ?? 0),
            windowSeconds: windowSeconds
        )
    }

    func recentFrameIntervals(count: Int) -> [Float] {
        recentIntervals.suffix(count).map { Float($0) }
    }

    func reset() {
        frameCount = 0
        trackedFrameCount = 0
        droppedFrameEstimate = 0
        longGapCount = 0
        interruptionCount = 0
        lifecycleEvents.removeAll()
        firstTimestamp = nil
        lastTimestamp = nil
        lastInterval = nil
        intervalSum = 0
        intervalCount = 0
        recentIntervals.removeAll()
        recentTracked.removeAll()
        fpsWindow.removeAll()
        trackedTransitions.removeAll()
        lastTrackedState = nil
    }
}
