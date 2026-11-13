import Foundation

/// One detected blink (or longer eye closure). Times are ARFrame timestamps.
struct BlinkEvent: Identifiable, Codable {
    var id = UUID()
    var startTime: Double
    var endTime: Double
    var duration: Double { endTime - startTime }
    var peakLeft: Float
    var peakRight: Float
    /// peakLeft - peakRight: positive when the left eye closed further.
    var peakAsymmetry: Float { peakLeft - peakRight }
    /// Seconds the left eye led (positive) or lagged (negative) the right eye at onset. nil if one eye never crossed.
    var onsetLag: Double?
    /// true when both eyes crossed the onset threshold during the event.
    var bilateral: Bool
    /// "blink" when shorter than the long-closure limit, otherwise "closure".
    var kind: String
    /// Interval since the previous event's start, seconds.
    var interBlinkInterval: Double?
}

struct BlinkConfiguration {
    /// eyeBlink coefficient at or above this starts an event...
    var onsetThreshold: Float = 0.5
    /// ...and at or below this ends it (hysteresis).
    var offsetThreshold: Float = 0.3
    /// Events shorter than this are ignored as noise, seconds.
    var minimumDuration: Double = 0.03
    /// Events longer than this are labelled "closure" rather than "blink", seconds.
    var longClosureDuration: Double = 0.5
    /// Blinks whose inter-blink interval is below this are counted as clustered, seconds.
    var clusterInterval: Double = 1.0
    /// Rate window, seconds.
    var rateWindowSeconds: Double = 60
}

struct BlinkStatistics {
    var totalBlinks: Int
    var totalClosures: Int
    var blinkInProgress: Bool
    var currentClosureDuration: Double
    /// Blinks per minute over the rate window (nil until the window holds at least one blink).
    var ratePerMinute: Float?
    var meanDuration: Double?
    var meanInterBlinkInterval: Double?
    var interBlinkIntervalStd: Double?
    /// std / mean of the inter-blink intervals (coefficient of variation).
    var interBlinkIntervalCV: Double?
    var clusteredBlinkCount: Int
    var meanPeakAsymmetry: Float?
    var leftOnlyCount: Int
    var rightOnlyCount: Int
    /// Standard deviation of (1 - eyeBlink) averaged over both eyes within the rate window.
    var opennessVariability: Float?
    var windowSeconds: Double
}

/// Hysteresis blink detector running on the eyeBlink_L / eyeBlink_R coefficients.
/// A bilateral event opens when either eye crosses the onset threshold and closes when both
/// eyes are back below the offset threshold.
final class BlinkDetectionEngine {

    var configuration = BlinkConfiguration()

    private(set) var events: [BlinkEvent] = []
    private(set) var blinkInProgress = false
    private var eventStart: Double = 0
    private var peakLeft: Float = 0
    private var peakRight: Float = 0
    private var leftCrossed = false
    private var rightCrossed = false
    private var leftOnsetTime: Double?
    private var rightOnsetTime: Double?
    private var lastEventStart: Double?
    private var openness = RingBuffer<(time: Double, value: Float)>(capacity: 3600)
    private var currentTime: Double = 0

    var maximumStoredEvents = 2000

    /// Feeds one frame. Returns a completed event when one ends on this frame.
    @discardableResult
    func process(left: Float?, right: Float?, timestamp: Double) -> BlinkEvent? {
        currentTime = timestamp
        guard left != nil || right != nil else {
            // No measurement: abandon any open event rather than inventing a duration.
            blinkInProgress = false
            leftCrossed = false; rightCrossed = false
            leftOnsetTime = nil; rightOnsetTime = nil
            return nil
        }
        let l = left ?? 0
        let r = right ?? 0
        let availableEyes = (left != nil ? 1 : 0) + (right != nil ? 1 : 0)
        let meanOpenness = ((left.map { 1 - $0 } ?? 0) + (right.map { 1 - $0 } ?? 0)) / Float(availableEyes)
        openness.append((timestamp, meanOpenness))

        let onset = configuration.onsetThreshold
        let offset = configuration.offsetThreshold

        if !blinkInProgress {
            if l >= onset || r >= onset {
                blinkInProgress = true
                eventStart = timestamp
                peakLeft = l; peakRight = r
                leftCrossed = l >= onset
                rightCrossed = r >= onset
                leftOnsetTime = leftCrossed ? timestamp : nil
                rightOnsetTime = rightCrossed ? timestamp : nil
            }
            return nil
        }

        peakLeft = max(peakLeft, l)
        peakRight = max(peakRight, r)
        if !leftCrossed, l >= onset { leftCrossed = true; leftOnsetTime = timestamp }
        if !rightCrossed, r >= onset { rightCrossed = true; rightOnsetTime = timestamp }

        if l <= offset, r <= offset {
            blinkInProgress = false
            let duration = timestamp - eventStart
            guard duration >= configuration.minimumDuration else { return nil }
            var lag: Double? = nil
            if let lt = leftOnsetTime, let rt = rightOnsetTime { lag = rt - lt }
            let event = BlinkEvent(
                startTime: eventStart,
                endTime: timestamp,
                peakLeft: peakLeft,
                peakRight: peakRight,
                onsetLag: lag,
                bilateral: leftCrossed && rightCrossed,
                kind: duration > configuration.longClosureDuration ? "closure" : "blink",
                interBlinkInterval: lastEventStart.map { eventStart - $0 }
            )
            lastEventStart = eventStart
            events.append(event)
            if events.count > maximumStoredEvents { events.removeFirst(events.count - maximumStoredEvents) }
            return event
        }
        return nil
    }

    func statistics() -> BlinkStatistics {
        let window = configuration.rateWindowSeconds
        let cutoff = currentTime - window
        let recent = events.filter { $0.startTime >= cutoff }
        let blinks = events.filter { $0.kind == "blink" }
        let recentBlinks = recent.filter { $0.kind == "blink" }
        let intervals = recentBlinks.compactMap { $0.interBlinkInterval }

        var rate: Float? = nil
        if let first = events.first {
            // Rate over the shorter of the window and the time since the first event.
            let span = min(window, max(currentTime - first.startTime, 1))
            if !recentBlinks.isEmpty { rate = Float(Double(recentBlinks.count) / span * 60) }
        }
        let meanDuration = recentBlinks.isEmpty ? nil : recentBlinks.map { $0.duration }.reduce(0, +) / Double(recentBlinks.count)
        var meanIBI: Double? = nil
        var stdIBI: Double? = nil
        var cv: Double? = nil
        if !intervals.isEmpty {
            let m = intervals.reduce(0, +) / Double(intervals.count)
            meanIBI = m
            if intervals.count > 1 {
                let v = intervals.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(intervals.count - 1)
                stdIBI = sqrt(v)
                cv = m > 0 ? sqrt(v) / m : nil
            }
        }
        let clustered = recentBlinks.filter { ($0.interBlinkInterval ?? .infinity) < configuration.clusterInterval }.count
        let asym = recentBlinks.isEmpty ? nil : recentBlinks.map { $0.peakAsymmetry }.reduce(0, +) / Float(recentBlinks.count)

        var opennessValues: [Float] = []
        openness.forEach { if $0.time >= cutoff { opennessValues.append($0.value) } }

        return BlinkStatistics(
            totalBlinks: blinks.count,
            totalClosures: events.count - blinks.count,
            blinkInProgress: blinkInProgress,
            currentClosureDuration: blinkInProgress ? currentTime - eventStart : 0,
            ratePerMinute: rate,
            meanDuration: meanDuration,
            meanInterBlinkInterval: meanIBI,
            interBlinkIntervalStd: stdIBI,
            interBlinkIntervalCV: cv,
            clusteredBlinkCount: clustered,
            meanPeakAsymmetry: asym,
            leftOnlyCount: events.filter { !$0.bilateral && $0.peakLeft >= $0.peakRight }.count,
            rightOnlyCount: events.filter { !$0.bilateral && $0.peakRight > $0.peakLeft }.count,
            opennessVariability: opennessValues.count > 1 ? MathSupport.standardDeviation(opennessValues) : nil,
            windowSeconds: window
        )
    }

    func reset() {
        events.removeAll()
        blinkInProgress = false
        leftCrossed = false; rightCrossed = false
        leftOnsetTime = nil; rightOnsetTime = nil
        lastEventStart = nil
        openness.removeAll()
    }
}
