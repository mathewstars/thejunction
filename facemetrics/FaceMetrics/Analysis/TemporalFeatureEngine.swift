import Foundation
import Accelerate

/// One hysteresis-detected activation of a single coefficient.
struct ActivationEvent: Identifiable {
    let id = UUID()
    let identifier: String
    let onsetTime: Double
    var offsetTime: Double?
    var peak: Float
    var duration: Double? { offsetTime.map { $0 - onsetTime } }
}

/// A span during which overall facial activity stayed below the low-activity threshold.
struct LowActivityPeriod: Identifiable {
    let id = UUID()
    let start: Double
    var end: Double?
    var duration: Double { (end ?? start) - start }
}

/// Per-coefficient temporal state exposed to the UI and export.
struct CoefficientDynamics {
    var firstDerivative: Float?
    var secondDerivative: Float?
    var isActive: Bool
    var currentOnsetTime: Double?
    var activationCount: Int
    var windowMin: Float
    var windowMax: Float
    var windowMean: Float
    var windowStd: Float
}

struct TemporalConfiguration {
    var windowSeconds: Double = 5
    /// A coefficient becomes "active" above this value...
    var activationOnset: Float = 0.25
    /// ...and inactive again below this (hysteresis).
    var activationOffset: Float = 0.15
    /// Minimum activation duration to count as an event, seconds.
    var minimumActivationDuration: Double = 0.05
    /// Facial activity (mean |d/dt|) below this for `lowActivityMinimumDuration` marks a low-activity period.
    var lowActivityThreshold: Float = 0.08
    var lowActivityMinimumDuration: Double = 2.0
}

/// Examines how blend-shape coefficients change over time: derivatives, activation events with
/// hysteresis, windowed statistics and overall facial activity.
///
/// All outputs are application-derived; none of them is an emotion or clinical measure.
final class TemporalFeatureEngine {

    var configuration = TemporalConfiguration()
    var windowStatsEveryNthFrame: Int = 4
    private var frameCounter: Int = 0

    private var previousValues: [String: Float] = [:]
    private var previousDerivatives: [String: Float] = [:]
    private var previousTime: Double?
    private(set) var dynamics: [String: CoefficientDynamics] = [:]
    private var openEvents: [String: ActivationEvent] = [:]
    private(set) var completedEvents: [ActivationEvent] = []
    private(set) var totalActivationCount: Int = 0
    private var onsetTimes = RingBuffer<Double>(capacity: 2000)

    /// Global per-frame signals kept for windowed statistics and charts.
    private(set) var history = TimeAlignedHistory(capacity: 1800)
    private var lowActivityCandidateStart: Double?
    private(set) var currentLowActivity: LowActivityPeriod?
    private(set) var lowActivityPeriods: [LowActivityPeriod] = []

    /// Processes one frame of coefficients and returns the frame's temporal metrics.
    /// `valueHistory` provides per-coefficient history for windowed statistics.
    func process(values: [String: Float], timestamp: Double, valueHistory: TimeAlignedHistory) -> TemporalMetrics {
        let dt: Double? = previousTime.map { timestamp - $0 }
        var sumAbsVelocity: Float = 0
        var sumAbsDelta: Float = 0
        var sumValue: Float = 0
        var velocityCount = 0
        var activeCount = 0

        // Per-coefficient windowed statistics are refreshed every few frames; the UI reads them at
        // 15 Hz at most, so recomputing 50+ windows on every 60 Hz frame would be wasted work.
        frameCounter &+= 1
        let refreshWindows = windowStatsEveryNthFrame <= 1 || frameCounter % windowStatsEveryNthFrame == 0
        let windowSamples = refreshWindows ? valueHistory.sampleCount(withinLast: configuration.windowSeconds) : 0

        for (id, value) in values {
            sumValue += value
            var dyn = dynamics[id] ?? CoefficientDynamics(
                firstDerivative: nil, secondDerivative: nil, isActive: false, currentOnsetTime: nil,
                activationCount: 0, windowMin: value, windowMax: value, windowMean: value, windowStd: 0
            )

            // Derivatives
            if let prev = previousValues[id], let dt, dt > 0 {
                let delta = value - prev
                let d1 = Float(Double(delta) / dt)
                sumAbsDelta += abs(delta)
                sumAbsVelocity += abs(d1)
                velocityCount += 1
                if let prevD1 = previousDerivatives[id] {
                    dyn.secondDerivative = Float(Double(d1 - prevD1) / dt)
                } else {
                    dyn.secondDerivative = nil
                }
                dyn.firstDerivative = d1
                previousDerivatives[id] = d1
            } else {
                dyn.firstDerivative = nil
                dyn.secondDerivative = nil
                previousDerivatives[id] = nil
            }

            // Hysteresis activation events
            if !dyn.isActive, value >= configuration.activationOnset {
                dyn.isActive = true
                dyn.currentOnsetTime = timestamp
                openEvents[id] = ActivationEvent(identifier: id, onsetTime: timestamp, offsetTime: nil, peak: value)
            } else if dyn.isActive {
                if var ev = openEvents[id] {
                    ev.peak = max(ev.peak, value)
                    openEvents[id] = ev
                }
                if value <= configuration.activationOffset {
                    dyn.isActive = false
                    if var ev = openEvents.removeValue(forKey: id) {
                        ev.offsetTime = timestamp
                        if let d = ev.duration, d >= configuration.minimumActivationDuration {
                            dyn.activationCount += 1
                            totalActivationCount += 1
                            onsetTimes.append(ev.onsetTime)
                            completedEvents.append(ev)
                            if completedEvents.count > 500 { completedEvents.removeFirst(completedEvents.count - 500) }
                        }
                    }
                    dyn.currentOnsetTime = nil
                }
            }
            if dyn.isActive { activeCount += 1 }

            // Windowed statistics
            if windowSamples >= 2 {
                let w = valueHistory.values(for: id, last: windowSamples)
                if !w.isEmpty {
                    dyn.windowMin = vDSP.minimum(w)
                    dyn.windowMax = vDSP.maximum(w)
                    dyn.windowMean = vDSP.mean(w)
                    dyn.windowStd = MathSupport.standardDeviation(w)
                }
            }
            dynamics[id] = dyn
            previousValues[id] = value
        }

        let n = max(values.count, 1)
        let meanActivation = sumValue / Float(n)
        let activity = velocityCount > 0 ? sumAbsVelocity / Float(velocityCount) : 0

        history.append(time: timestamp, values: [
            "activity": activity,
            "meanActivation": meanActivation,
            "totalVariation": sumAbsDelta
        ])

        // Windowed global statistics
        let gn = history.sampleCount(withinLast: configuration.windowSeconds)
        let meanSeries = history.values(for: "meanActivation", last: gn)
        let activitySeries = history.values(for: "activity", last: gn)
        var amplitude: Float = 0
        for id in values.keys {
            if let dyn = dynamics[id] { amplitude += dyn.windowMax - dyn.windowMin }
        }
        amplitude /= Float(n)
        let std = MathSupport.standardDeviation(meanSeries)
        let variance = std * std
        let frequency = TemporalFeatureEngine.zeroCrossingRate(meanSeries, seconds: configuration.windowSeconds)

        // Transition rate: onsets inside the window per second
        let cutoff = timestamp - configuration.windowSeconds
        var onsetsInWindow = 0
        onsetTimes.forEach { if $0 >= cutoff { onsetsInWindow += 1 } }
        let transitionRate = Float(Double(onsetsInWindow) / configuration.windowSeconds)

        // Low-activity periods based on windowed mean activity
        let windowedActivity = activitySeries.isEmpty ? activity : MathSupport.mean(activitySeries)
        var lowDuration: Float = 0
        if windowedActivity < configuration.lowActivityThreshold {
            if lowActivityCandidateStart == nil { lowActivityCandidateStart = timestamp }
            if let start = lowActivityCandidateStart, timestamp - start >= configuration.lowActivityMinimumDuration {
                if currentLowActivity == nil { currentLowActivity = LowActivityPeriod(start: start, end: nil) }
                currentLowActivity?.end = timestamp
                lowDuration = Float(timestamp - start)
            }
        } else {
            lowActivityCandidateStart = nil
            if var period = currentLowActivity {
                period.end = timestamp
                lowActivityPeriods.append(period)
                if lowActivityPeriods.count > 500 { lowActivityPeriods.removeFirst() }
                currentLowActivity = nil
            }
        }

        previousTime = timestamp

        return TemporalMetrics(
            facialActivity: activity,
            totalVariation: sumAbsDelta,
            movementAmplitude: amplitude,
            movementFrequencyHz: frequency,
            meanActivation: meanActivation,
            activationStd: std,
            activationVariance: variance,
            transitionRate: transitionRate,
            activeCoefficientCount: activeCount,
            lowActivity: currentLowActivity != nil,
            lowActivityDuration: lowDuration
        )
    }

    func noteMissingFrame(timestamp: Double) {
        previousValues.removeAll()
        previousDerivatives.removeAll()
        previousTime = nil
        history.append(time: timestamp, values: [:])
    }

    func recent(_ key: String, count: Int) -> [Float] { history.values(for: key, last: count) }

    static func zeroCrossingRate(_ series: [Float], seconds: Double) -> Float {
        guard series.count > 2, seconds > 0 else { return 0 }
        let m = vDSP.mean(series)
        var crossings = 0
        for i in 1..<series.count where (series[i - 1] - m) * (series[i] - m) < 0 { crossings += 1 }
        return Float(crossings) / 2 / Float(seconds)
    }

    func reset() {
        previousValues.removeAll()
        previousDerivatives.removeAll()
        previousTime = nil
        dynamics.removeAll()
        openEvents.removeAll()
        completedEvents.removeAll()
        totalActivationCount = 0
        onsetTimes.removeAll()
        history.removeAll()
        lowActivityCandidateStart = nil
        currentLowActivity = nil
        lowActivityPeriods.removeAll()
    }
}
