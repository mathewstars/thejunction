import Foundation

/// Turns the health summary into the engine's `/v1/daily` records.
///
/// The engine wants one record per calendar day with `steps` (required), and optional walking speed,
/// HRV and hours asleep. Days without a step total are skipped and listed, never sent as zero.
public enum DailyRecordBuilder {

    public struct Result {
        public var days: [EngineDayRecord]
        public var skippedDays: [String: String]
        public var note: String
    }

    public static func build(from summary: HealthDataSummary, maxDays: Int = 400) -> Result {
        func daily(_ id: String) -> [String: Double] {
            guard let m = summary.metrics.first(where: { $0.typeIdentifier == id }) else { return [:] }
            var out: [String: Double] = [:]
            for d in m.daily { if let v = LocalStatistics.dailyValue(d) { out[d.day] = v } }
            return out
        }
        let steps = daily("HKQuantityTypeIdentifierStepCount")
        let speed = daily("HKQuantityTypeIdentifierWalkingSpeed")
        let hrv = daily("HKQuantityTypeIdentifierHeartRateVariabilitySDNN")
        let sleep = daily("HKCategoryTypeIdentifierSleepAnalysis")

        var days: [EngineDayRecord] = []
        var skipped: [String: String] = [:]
        let allDays = Set(steps.keys).union(speed.keys).union(hrv.keys).union(sleep.keys)
        for day in allDays.sorted() {
            guard let s = steps[day] else { skipped[day] = "no step total (engine requires steps)"; continue }
            guard s >= 0, s < 200_000 else { skipped[day] = "implausible step total"; continue }
            days.append(EngineDayRecord(date: day, steps: Int(s.rounded()),
                                        walkingSpeedMS: speed[day].map { ($0 * 100).rounded() / 100 },
                                        hrvMs: hrv[day].map { ($0 * 10).rounded() / 10 },
                                        sleepH: sleep[day].map { ($0 * 100).rounded() / 100 }))
        }
        if days.count > maxDays { days = Array(days.suffix(maxDays)) }
        return Result(days: days, skippedDays: skipped,
                      note: "steps from HealthKit daily statistics (sources merged) or largest single source; HRV = daily mean; sleep = hours asleep attributed to the wake-up day; walking speed = daily mean.")
    }
}

/// Turns an imported FaceMetrics recording into the engine's `face_raw`.
///
/// What changes and what does not:
/// - Channel names: FaceMetrics writes ARKit's `BlendShapeLocation.rawValue` (`eyeBlink_L`); the
///   engine wants the Swift constant spelling (`eyeBlinkLeft`). Values are untouched (3 decimals).
/// - Head angles: the engine wants degrees relative to the camera. The recording's `head_view_*_rad`
///   columns are exactly that; when they are absent, the world transform is used and the report says so.
/// - Time: the engine needs a steady frame rate. Frames are resampled onto a fixed grid by nearest
///   neighbour; grid points without a tracked frame nearby (gaps, pauses, lost tracking) become
///   `tracked = 0` with zero values, which is how the engine wants untracked frames marked.
/// - Nothing is computed from the face. No smile, blink or movement numbers leave this function.
public struct FaceRawBuilder {

    public var rateHz: Double = 30
    /// Flip the sign of pitch if the recording's convention is "chin down = negative".
    public var flipPitchSign = false
    /// Marker labels whose start times become `moments_ms` (pleasant moments). Empty = none.
    public var momentMarkerLabels: [String] = []

    public init() {}

    public enum BuildError: LocalizedError {
        case noFrames
        case missingRequiredChannels([String])
        public var errorDescription: String? {
            switch self {
            case .noFrames: return "The recording has no frames."
            case .missingRequiredChannels(let m): return "Recording lacks channels the engine requires: \(m.joined(separator: ", "))"
            }
        }
    }

    /// "eyeBlink_L" → "eyeBlinkLeft". Names already in Swift spelling pass through.
    public static func engineChannelName(_ arkitIdentifier: String) -> String {
        if arkitIdentifier.hasSuffix("_L") { return String(arkitIdentifier.dropLast(2)) + "Left" }
        if arkitIdentifier.hasSuffix("_R") { return String(arkitIdentifier.dropLast(2)) + "Right" }
        return arkitIdentifier
    }

    public func build(session: ARKitSession) throws -> (EngineFaceRaw, FaceRawBuildReport) {
        let frames = session.frames
        guard let first = frames.first, let last = frames.last else { throw BuildError.noFrames }
        var warnings: [String] = []

        // Channels.
        var blendIDs: [(engine: String, arkit: String)] = []
        var dropped: [String] = []
        for id in session.blendShapeIdentifiers {
            let name = Self.engineChannelName(id)
            if EngineFaceRaw.allowedBlendShapes.contains(name) { blendIDs.append((name, id)) } else { dropped.append(id) }
        }
        let present = Set(blendIDs.map { $0.engine })
        let missing = EngineFaceRaw.requiredChannels.filter { !present.contains($0) }
        if !missing.isEmpty { throw BuildError.missingRequiredChannels(missing) }
        if blendIDs.count + 3 > EngineFaceRaw.maxChannels { blendIDs = Array(blendIDs.prefix(EngineFaceRaw.maxChannels - 3)); warnings.append("Channel list cut to the engine's maximum of \(EngineFaceRaw.maxChannels).") }
        let channels = blendIDs.map { $0.engine } + EngineFaceRaw.headChannels

        // Head angle source.
        let cols = Dictionary(session.columns.map { ($0.name, $0.index) }, uniquingKeysWith: { a, _ in a })
        let viewEuler = (cols["head_view_pitch_rad"], cols["head_view_yaw_rad"], cols["head_view_roll_rad"])
        let useView = viewEuler.0 != nil && viewEuler.1 != nil && viewEuler.2 != nil
        let headSource = useView ? "head_view_pitch/yaw/roll_rad (camera-relative, from the recorder)"
                                 : "Euler angles decomposed from head_world_m00..m33 (world-relative; camera-relative columns absent)"
        if !useView { warnings.append("No head_view_*_rad columns: head angles are relative to the ARKit world, not the camera.") }

        // Rate: fit the engine's sample limit.
        let span = last.timestampUptime - first.timestampUptime
        var rate = min(max(rateHz, EngineFaceRaw.rateRange.lowerBound), EngineFaceRaw.rateRange.upperBound)
        var n = Int((span * rate).rounded()) + 1
        if n > EngineFaceRaw.maxSamples {
            rate = max(EngineFaceRaw.rateRange.lowerBound, Double(EngineFaceRaw.maxSamples - 1) / span)
            rate = (rate * 10).rounded(.down) / 10
            n = Int((span * rate).rounded()) + 1
            warnings.append("Frame rate lowered to \(rate) Hz so the recording fits the engine's \(EngineFaceRaw.maxSamples)-sample limit.")
        }
        var truncated = 0.0
        if n > EngineFaceRaw.maxSamples {
            truncated = span - Double(EngineFaceRaw.maxSamples - 1) / rate
            n = EngineFaceRaw.maxSamples
            warnings.append(String(format: "Recording truncated by %.1f s to fit the sample limit.", truncated))
        }

        // Resample: nearest tracked frame within ¾ of a grid step.
        let tolerance = 0.75 / rate
        var samples: [[Double]] = []
        samples.reserveCapacity(n)
        var tracked: [Int] = []
        tracked.reserveCapacity(n)
        var cursor = 0
        var trackedCount = 0
        func round3(_ x: Double) -> Double { (x * 1000).rounded() / 1000 }
        func round2(_ x: Double) -> Double { (x * 100).rounded() / 100 }
        for k in 0..<n {
            let t = first.timestampUptime + Double(k) / rate
            while cursor + 1 < frames.count, abs(frames[cursor + 1].timestampUptime - t) <= abs(frames[cursor].timestampUptime - t) { cursor += 1 }
            let f = frames[cursor]
            let ok = abs(f.timestampUptime - t) <= tolerance && f.faceTracked == true && !f.blendShapes.isEmpty
            guard ok else { samples.append([Double](repeating: 0, count: channels.count)); tracked.append(0); continue }
            var row = [Double](repeating: 0, count: channels.count)
            var complete = true
            for (i, c) in blendIDs.enumerated() {
                if let v = f.blendShapes[c.arkit] { row[i] = round3(min(1, max(0, v))) } else { complete = false }
            }
            guard complete else { samples.append([Double](repeating: 0, count: channels.count)); tracked.append(0); continue }
            var pitch = 0.0, yaw = 0.0, roll = 0.0
            if useView, let p = f.values[viewEuler.0!], let y = f.values[viewEuler.1!], let r = f.values[viewEuler.2!] {
                pitch = p; yaw = y; roll = r
            } else if let m = f.headWorldTransform {
                let e = FacialFeatureAnalyzer.eulerAngles(rowMajor: m)
                pitch = e.pitch; yaw = e.yaw; roll = e.roll
            }
            if flipPitchSign { pitch = -pitch }
            let base = blendIDs.count
            row[base] = round2(Self.clampDeg(pitch * 180 / .pi))
            row[base + 1] = round2(Self.clampDeg(yaw * 180 / .pi))
            row[base + 2] = round2(Self.clampDeg(roll * 180 / .pi))
            samples.append(row)
            tracked.append(1)
            trackedCount += 1
        }

        // Moments from markers, if asked.
        var moments: [Int]? = nil
        if !momentMarkerLabels.isEmpty, let marks = session.manifest?.markers {
            let wanted = Set(momentMarkerLabels)
            let ms = marks.filter { wanted.contains($0.label) }
                .map { Int(((($0.startTimestamp - first.timestampUptime) * 1000).rounded())) }
                .filter { $0 >= 0 && $0 <= Int(span * 1000) }
                .sorted()
            moments = Array(ms.prefix(EngineFaceRaw.maxMoments))
            if ms.count > EngineFaceRaw.maxMoments { warnings.append("Only the first \(EngineFaceRaw.maxMoments) marker moments are sent.") }
        }

        let allTracked = trackedCount == n
        let raw = EngineFaceRaw(rateHz: rate, channels: channels, samples: samples, tracked: allTracked ? nil : tracked, momentsMs: moments)
        let bytes = n * (channels.count * 6 + 4)
        if Double(trackedCount) / rate < 5 { warnings.append("Under 5 s of tracked frames: the engine will compute only tracking_quality.") }
        let report = FaceRawBuildReport(
            sessionID: session.id, rateHz: rate, requestedRateHz: rateHz, channelCount: channels.count, blendShapeChannels: blendIDs.count,
            droppedBlendShapes: dropped, sampleCount: n, trackedFraction: n > 0 ? Double(trackedCount) / Double(n) : 0, spanSeconds: span,
            truncatedSeconds: truncated, headAngleSource: headSource, momentCount: moments?.count ?? 0, approximateBytes: bytes, warnings: warnings)
        return (raw, report)
    }

    static func clampDeg(_ d: Double) -> Double {
        var x = d
        while x > 180 { x -= 360 }
        while x < -180 { x += 360 }
        return x
    }
}

/// Wraps a recording as an activity record the engine accepts.
public enum EngineActivityBuilder {

    public enum ActivityKind: String, CaseIterable, Identifiable {
        case breathing, focus
        public var id: String { rawValue }
    }

    public enum BuildError: LocalizedError {
        case unaligned
        public var errorDescription: String? { "The recording has no wall-clock anchor (session.json missing); the engine needs started_at." }
    }

    /// A FaceMetrics recording is not a game, so `breathing` is the honest wrapper: `time_played_s`
    /// is the tracked recording time. `focus` is offered for testing the other path and sends zero taps.
    public static func activity(for session: ARKitSession, faceRaw: EngineFaceRaw, kind: ActivityKind,
                                idPrefix: String = "fm-") throws -> EngineActivity {
        guard let start = session.alignment?.recordingStartWallClock, let first = session.frames.first, let last = session.frames.last else {
            throw BuildError.unaligned
        }
        let span = last.timestampUptime - first.timestampUptime
        let duration = min(1800, span)
        let played = min(duration, session.validation?.recordingDurationSeconds ?? duration)
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        var a = EngineActivity(id: EngineActivity.clientID(from: idPrefix + session.id), type: kind.rawValue,
                               startedAt: f.string(from: start), durationS: (duration * 10).rounded() / 10, completed: true,
                               endedBy: "finished", suggestionId: nil, timePlayedS: nil, breathsCompleted: nil, correctTaps: nil,
                               wrongTaps: nil, misses: nil, reactionMs: nil, faceRaw: faceRaw)
        switch kind {
        case .breathing:
            a.timePlayedS = (played * 10).rounded() / 10
        case .focus:
            a.correctTaps = 0; a.wrongTaps = 0; a.misses = 0; a.reactionMs = []
        }
        return a
    }
}
