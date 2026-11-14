import Foundation

// The face summary maths: a few numbers from a game's worth of ARKit frames.
//
// Thresholds and formulas follow Peter's FaceMetrics instrument (`facemetrics/`):
// - smiles, brows: the hysteresis activation of `TemporalFeatureEngine`
//   (on at 0.25, off at 0.15, at least 0.05 s),
// - blinks: `BlinkDetectionEngine` (on at 0.5, off at 0.3, at least 0.03 s,
//   longer than 0.5 s is a closure, not a blink),
// - facial activity: `TemporalFeatureEngine`'s mean |d/dt| over all coefficients,
// - head movement: `HeadPoseProcessor`'s variability (mean std of pitch, yaw and
//   roll in 5 s windows) scaled by its 0.05 rad stability reference,
// - smile asymmetry: `AsymmetryAnalyzer`'s normalised index for mouthSmile,
// - tracking quality: `TrackingQualityMonitor`'s score
//   (0.5 * tracked share + 0.3 * (1 - dropped share) + 0.2 * camera state weight),
//   taken over the whole game instead of the last 2 s.
// Everything here is plain numbers. No frame, image or landmark is ever kept.

/// What one camera frame gives the summary. Only coefficients and head angles.
struct FaceFrame: Sendable {
    /// Frame time in seconds (ARFrame.timestamp or any steady clock).
    var time: Double
    /// True when ARKit tracked a face on this frame.
    var tracked: Bool
    /// ARKit blend-shape coefficients by their identifier (e.g. "mouthSmile_L"), 0...1.
    var shapes: [String: Float] = [:]
    /// Head angles in the portrait camera view, radians (Peter's MathSupport.eulerAngles):
    /// pitch about X (looking down is positive), yaw about Y, roll about Z.
    var pitch: Float = 0
    var yaw: Float = 0
    var roll: Float = 0
    /// 1 normal, 0.5 limited, 0 not available (as in TrackingQualityMonitor).
    var cameraWeight: Float = 1
}

/// Builds the `face` object of `POST /v1/activities` from frames, one at a time.
/// Keeps only running totals and short lists of event times; never a frame.
struct FaceSummaryBuilder {

    struct Thresholds {
        var activationOn: Float = 0.25      // TemporalConfiguration.activationOnset
        var activationOff: Float = 0.15     // TemporalConfiguration.activationOffset
        var activationMinS: Double = 0.05   // TemporalConfiguration.minimumActivationDuration
        var blinkOn: Float = 0.5            // BlinkConfiguration.onsetThreshold
        var blinkOff: Float = 0.3           // BlinkConfiguration.offsetThreshold
        var blinkMinS: Double = 0.03        // BlinkConfiguration.minimumDuration
        var closureS: Double = 0.5          // BlinkConfiguration.longClosureDuration
        /// A smile "reaches the eyes" when the cheek raise peaks at least this high during it.
        var eyeSmileCheek: Float = 0.2
        /// Looking down: head pitch at least this many degrees, or eyes looking down at least `lookDownEyes`.
        var lookDownPitchDeg: Float = 15
        var lookDownEyes: Float = 0.6
        /// Head movement reaches 1 at this variability (HeadPoseProcessor.stabilityReferenceRadians).
        var headReferenceRad: Float = 0.05
        var headWindowS: Double = 5         // HeadPoseProcessor.windowSeconds
        /// A smile starting this soon after a marked pleasant moment answers it.
        var responseWindowS: Double = 3
        /// Expected camera frame interval, for the dropped-frame estimate.
        var expectedInterval: Double = 1.0 / 60.0
        /// Less tracked time than this and there is no summary at all.
        var minimumTrackedS: Double = 5
    }

    var thresholds = Thresholds()

    // Frames and time
    private(set) var frameCount = 0
    private(set) var trackedFrameCount = 0
    private(set) var droppedEstimate = 0
    private var cameraWeightSum: Double = 0
    private(set) var trackedSeconds: Double = 0
    private var firstTime: Double?
    private var lastTime: Double?
    private var previousTracked = false

    // Facial activity: mean |d/dt| across coefficients
    private var previousShapes: [String: Float]?
    private var activitySum: Double = 0
    private var activityCount = 0

    // Smiles
    private var smile = Hysteresis()
    private var smileCheekPeak: Float = 0
    private var smileAsymmetrySum: Double = 0
    private var smileAsymmetryCount = 0
    private(set) var smileOnsets: [Double] = []
    private var smilePeaks: [Float] = []
    private var smileReachedEyes: [Bool] = []
    private var smileSeconds: Double = 0

    // Brows
    private var browDown = Hysteresis()
    private var innerBrowUp = Hysteresis()
    private var browDownSeconds: Double = 0
    private var innerBrowUpSeconds: Double = 0

    // Blinks
    private var blinkOpen = false
    private var blinkStart: Double = 0
    private(set) var blinkDurations: [Double] = []
    private(set) var closures = 0

    // Head
    private var pitchSum: Double = 0
    private var rollSum: Double = 0
    private var headCount = 0
    private var lookDownSeconds: Double = 0
    private var window: (start: Double, pitch: [Float], yaw: [Float], roll: [Float])?
    private var windowVariabilities: [Float] = []

    // Pleasant moments marked by the game
    private(set) var marks: [Double] = []
    private var smilingAtMark: [Bool] = []

    init(thresholds: Thresholds = Thresholds()) {
        self.thresholds = thresholds
    }

    // MARK: Feeding

    /// A pleasant moment in the game (Lanvi cheers). Used for the smile response.
    mutating func mark(at time: Double) {
        marks.append(time)
        smilingAtMark.append(smile.active)
    }

    mutating func add(_ f: FaceFrame) {
        let t = thresholds
        frameCount += 1
        cameraWeightSum += Double(f.cameraWeight)
        if firstTime == nil { firstTime = f.time }

        // Time between frames. Gaps of a second or more are interruptions, not dropped frames.
        var dt: Double = 0
        if let last = lastTime {
            let gap = f.time - last
            if gap > 0, gap < 1 {
                dt = gap
                if gap > t.expectedInterval * 1.5 {
                    droppedEstimate += max(0, Int((gap / t.expectedInterval).rounded()) - 1)
                }
            }
        }
        lastTime = f.time

        guard f.tracked else {
            // No face: nothing bridges the gap (Peter's noteMissingFrame), open events are dropped.
            previousTracked = false
            previousShapes = nil
            blinkOpen = false
            closeSmile(at: f.time, keep: false)
            browDown.reset()
            innerBrowUp.reset()
            window = nil
            return
        }
        trackedFrameCount += 1
        let countable = previousTracked && dt > 0
        if countable { trackedSeconds += dt }
        previousTracked = true

        let s = f.shapes
        func v(_ k: String) -> Float { s[k] ?? 0 }
        func pair(_ base: String) -> Float { (v(base + "_L") + v(base + "_R")) / 2 }

        // Facial activity
        if let prev = previousShapes, countable {
            var sum: Float = 0
            var n = 0
            for (k, value) in s {
                if let p = prev[k] {
                    sum += abs(value - p) / Float(dt)
                    n += 1
                }
            }
            if n > 0 {
                activitySum += Double(sum / Float(n))
                activityCount += 1
            }
        }
        previousShapes = s

        // Smiles
        let smileValue = pair("mouthSmile")
        let wasSmiling = smile.active
        if smile.active, countable { smileSeconds += dt }
        if !wasSmiling, smileValue >= t.activationOn {
            smile.open(at: f.time, value: smileValue)
            smileCheekPeak = pair("cheekSquint")
        } else if wasSmiling {
            smile.peak = max(smile.peak, smileValue)
            smileCheekPeak = max(smileCheekPeak, pair("cheekSquint"))
            if smileValue <= t.activationOff { closeSmile(at: f.time, keep: true) }
        }
        if smile.active {
            let l = v("mouthSmile_L"), r = v("mouthSmile_R")
            let m = max(l, r)
            if m > 0.02 {   // AsymmetryPair.normalisedIndex
                smileAsymmetrySum += Double(abs(l - r) / m)
                smileAsymmetryCount += 1
            }
        }

        // Brows
        if browDown.active, countable { browDownSeconds += dt }
        browDown.step(pair("browDown"), at: f.time, on: t.activationOn, off: t.activationOff)
        if innerBrowUp.active, countable { innerBrowUpSeconds += dt }
        innerBrowUp.step(v("browInnerUp"), at: f.time, on: t.activationOn, off: t.activationOff)

        // Blinks: opens when either eye crosses on, closes when both are back below off.
        let bl = v("eyeBlink_L"), br = v("eyeBlink_R")
        if !blinkOpen {
            if bl >= t.blinkOn || br >= t.blinkOn {
                blinkOpen = true
                blinkStart = f.time
            }
        } else if bl <= t.blinkOff, br <= t.blinkOff {
            blinkOpen = false
            let d = f.time - blinkStart
            if d >= t.blinkMinS {
                if d > t.closureS { closures += 1 } else { blinkDurations.append(d) }
            }
        }

        // Head
        let pitchDeg = f.pitch * 180 / .pi
        pitchSum += Double(pitchDeg)
        rollSum += Double(f.roll * 180 / .pi)
        headCount += 1
        if countable, pitchDeg >= t.lookDownPitchDeg || pair("eyeLookDown") >= t.lookDownEyes {
            lookDownSeconds += dt
        }
        if window == nil { window = (f.time, [], [], []) }
        window!.pitch.append(f.pitch)
        window!.yaw.append(f.yaw)
        window!.roll.append(f.roll)
        if f.time - window!.start >= t.headWindowS {
            closeWindow()
        }
    }

    // MARK: The summary

    /// The `face` object, or nil when there was too little tracked face to say anything.
    func summary() -> API.FaceSummary? {
        guard trackedFrameCount > 0, trackedSeconds >= thresholds.minimumTrackedS else { return nil }
        let t = thresholds
        let minutes = trackedSeconds / 60

        // Tracking quality (TrackingQualityMonitor's formula over the whole game).
        let trackedShare = Double(trackedFrameCount) / Double(max(frameCount, 1))
        let droppedShare = Double(droppedEstimate) / Double(max(frameCount + droppedEstimate, 1))
        let cameraWeight = cameraWeightSum / Double(max(frameCount, 1))
        let quality = 0.5 * trackedShare + 0.3 * (1 - droppedShare) + 0.2 * cameraWeight

        // A smile still open at the end counts as a smile (it lasted long enough already).
        var onsets = smileOnsets
        var peaks = smilePeaks
        var eyes = smileReachedEyes
        if smile.active, let last = lastTime, last - smile.start >= t.activationMinS {
            onsets.append(smile.start)
            peaks.append(smile.peak)
            eyes.append(smileCheekPeak >= t.eyeSmileCheek)
        }

        // Smile response to the marked moments.
        var responses = 0
        var counted = 0
        var latencies: [Double] = []
        for (i, m) in marks.enumerated() {
            if smilingAtMark[i] {
                counted += 1; responses += 1; latencies.append(0)
                continue
            }
            if let onset = onsets.first(where: { $0 > m && $0 - m <= t.responseWindowS }) {
                counted += 1; responses += 1; latencies.append(onset - m)
            } else if let last = lastTime, last - m >= t.responseWindowS {
                counted += 1
            }
        }

        // Head movement: complete 5 s windows, or the whole game when shorter.
        var variabilities = windowVariabilities
        if variabilities.isEmpty, let w = window, w.pitch.count >= 4 {
            variabilities.append(Self.variability(w.pitch, w.yaw, w.roll))
        }
        let headMovement: Double? = variabilities.isEmpty ? nil
            : Double(Self.clamp01(Self.mean(variabilities) / t.headReferenceRad))

        var f = API.FaceSummary(trackingQuality: Self.clamp(quality, 0, 1))
        f.smileRatePerMin = Self.clamp(Double(onsets.count) / minutes, 0, 120)
        f.smileIntensity = peaks.isEmpty ? nil : Self.clamp(Double(Self.mean(peaks)), 0, 1)
        f.smileTimeShare = Self.clamp(smileSeconds / trackedSeconds, 0, 1)
        f.eyeSmileShare = eyes.isEmpty ? nil : Double(eyes.filter { $0 }.count) / Double(eyes.count)
        f.smileAsymmetry = smileAsymmetryCount == 0 ? nil
            : Self.clamp(smileAsymmetrySum / Double(smileAsymmetryCount), 0, 1)
        f.smileResponseShare = counted == 0 ? nil : Double(responses) / Double(counted)
        f.smileResponseLatencyS = latencies.isEmpty ? nil : Self.clamp(Self.median(latencies), 0, 30)
        f.facialActivity = activityCount == 0 ? nil : Self.clamp(activitySum / Double(activityCount), 0, 1)
        f.blinkRatePerMin = Self.clamp(Double(blinkDurations.count) / minutes, 0, 120)
        f.blinkDurationMs = blinkDurations.isEmpty ? nil : Self.clamp(Self.median(blinkDurations) * 1000, 0, 2000)
        f.browDownShare = Self.clamp(browDownSeconds / trackedSeconds, 0, 1)
        f.innerBrowUpShare = Self.clamp(innerBrowUpSeconds / trackedSeconds, 0, 1)
        f.lookDownShare = Self.clamp(lookDownSeconds / trackedSeconds, 0, 1)
        f.headPitchDeg = headCount == 0 ? nil : Self.clamp(pitchSum / Double(headCount), -90, 90)
        f.headTiltDeg = headCount == 0 ? nil : Self.clamp(rollSum / Double(headCount), -90, 90)
        f.headMovement = headMovement
        return f.rounded()
    }

    // MARK: Helpers

    private mutating func closeSmile(at time: Double, keep: Bool) {
        guard smile.active else { return }
        if keep, time - smile.start >= thresholds.activationMinS {
            smileOnsets.append(smile.start)
            smilePeaks.append(smile.peak)
            smileReachedEyes.append(smileCheekPeak >= thresholds.eyeSmileCheek)
        }
        smile.reset()
        smileCheekPeak = 0
    }

    private mutating func closeWindow() {
        guard let w = window else { return }
        if w.pitch.count >= 4 {
            windowVariabilities.append(Self.variability(w.pitch, w.yaw, w.roll))
        }
        window = nil
    }

    /// Mean standard deviation of pitch, yaw and roll (HeadPoseProcessor.windowedMetrics).
    static func variability(_ p: [Float], _ y: [Float], _ r: [Float]) -> Float {
        (std(p) + std(y) + std(r)) / 3
    }

    static func mean(_ a: [Float]) -> Float { a.isEmpty ? 0 : a.reduce(0, +) / Float(a.count) }

    static func std(_ a: [Float]) -> Float {
        guard a.count > 1 else { return 0 }
        let m = mean(a)
        return sqrt(a.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Float(a.count - 1))
    }

    static func median(_ a: [Double]) -> Double {
        let s = a.sorted()
        guard !s.isEmpty else { return 0 }
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    static func clamp(_ x: Double, _ lo: Double, _ hi: Double) -> Double {
        x.isFinite ? min(max(x, lo), hi) : lo
    }

    static func clamp01(_ x: Float) -> Float { x.isFinite ? min(max(x, 0), 1) : 0 }
}

/// On/off with two thresholds, as in Peter's activation events.
private struct Hysteresis {
    var active = false
    var start: Double = 0
    var peak: Float = 0

    mutating func open(at time: Double, value: Float) {
        active = true
        start = time
        peak = value
    }

    mutating func step(_ value: Float, at time: Double, on: Float, off: Float) {
        if !active, value >= on { open(at: time, value: value) }
        else if active, value <= off { reset() }
    }

    mutating func reset() {
        active = false
        peak = 0
    }
}

extension API.FaceSummary {
    /// Three decimals is plenty; keeps the record small and stable.
    func rounded() -> API.FaceSummary {
        func r(_ x: Double?) -> Double? { x.map { ($0 * 1000).rounded() / 1000 } }
        var f = self
        f.smileRatePerMin = r(smileRatePerMin)
        f.smileIntensity = r(smileIntensity)
        f.facialActivity = r(facialActivity)
        f.blinkRatePerMin = r(blinkRatePerMin)
        f.lookDownShare = r(lookDownShare)
        f.headTiltDeg = r(headTiltDeg)
        f.smileTimeShare = r(smileTimeShare)
        f.eyeSmileShare = r(eyeSmileShare)
        f.smileResponseShare = r(smileResponseShare)
        f.smileResponseLatencyS = r(smileResponseLatencyS)
        f.browDownShare = r(browDownShare)
        f.innerBrowUpShare = r(innerBrowUpShare)
        f.blinkDurationMs = r(blinkDurationMs)
        f.headPitchDeg = r(headPitchDeg)
        f.headMovement = r(headMovement)
        f.smileAsymmetry = r(smileAsymmetry)
        f.trackingQuality = r(trackingQuality) ?? 0
        return f
    }
}
