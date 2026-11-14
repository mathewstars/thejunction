import Foundation

/// Computes windowed facial-behaviour features from imported ARKit frames.
///
/// Everything here is arithmetic on the raw ARKit columns (blend shapes, head transform, lookAtPoint,
/// tracking flags). The results describe movement; they are not emotions, moods or clinical signs,
/// and the field names deliberately avoid such words. Every window lists the columns it used in
/// `supportingMeasurements`, and the recorder's own derived columns are reported separately in
/// `exportedDerivedMeans` so the two never get mixed up.
public struct FacialFeatureAnalyzer {

    public static let standardWindows: [Double] = [5, 15, 30, 60]

    public struct Configuration {
        public var blinkOnsetThreshold: Double = 0.5
        public var blinkOffsetThreshold: Double = 0.3
        public var blinkMinimumDurationS: Double = 0.03
        public var blinkMaximumDurationS: Double = 0.5
        public var gazeChangeThresholdDeg: Double = 5
        public var activeCoefficientThreshold: Double = 0.25
        /// Windows with fewer tracked frames than this fraction of the expected count are still reported,
        /// with the low tracking fraction visible in `trackingQuality`.
        public var minimumTrackedFrames: Int = 3
        public init() {}
    }

    public var configuration = Configuration()

    public init(configuration: Configuration = Configuration()) { self.configuration = configuration }

    // MARK: Windows

    /// Tiles the recording into consecutive windows of `windowSeconds` on the uptime clock.
    public func windows(session: ARKitSession, windowSeconds: Double) -> [FacialFeatureWindow] {
        guard let first = session.frames.first, let last = session.frames.last, windowSeconds > 0 else { return [] }
        var out: [FacialFeatureWindow] = []
        var start = first.timestampUptime
        var lo = 0
        let frames = session.frames
        while start <= last.timestampUptime {
            let end = start + windowSeconds
            var hi = lo
            while hi < frames.count, frames[hi].timestampUptime < end { hi += 1 }
            let slice = Array(frames[lo..<hi])
            if !slice.isEmpty {
                out.append(features(frames: slice, session: session, windowSeconds: windowSeconds, startUptime: start, endUptime: end))
            }
            lo = hi
            start = end
        }
        return out
    }

    /// The whole recording as one window.
    public func sessionLevelWindow(session: ARKitSession) -> FacialFeatureWindow? {
        guard let first = session.frames.first, let last = session.frames.last else { return nil }
        let dur = max(last.timestampUptime - first.timestampUptime, 1e-3)
        return features(frames: session.frames, session: session, windowSeconds: dur, startUptime: first.timestampUptime, endUptime: last.timestampUptime)
    }

    // MARK: Feature computation

    public func features(frames: [ARKitFrame], session: ARKitSession, windowSeconds: Double,
                         startUptime: Double, endUptime: Double) -> FacialFeatureWindow {
        let c = configuration
        let tracked = frames.filter { $0.faceTracked == true && !$0.blendShapes.isEmpty }
        let bsIDs = session.blendShapeIdentifiers
        var supporting: Set<String> = ["timestamp_s", "face_tracked", "camera_tracking_state"]

        // Missing blend shapes among tracked frames.
        var missingCells = 0
        for f in tracked { missingCells += max(0, bsIDs.count - f.blendShapes.count) }
        let missingFraction = tracked.isEmpty || bsIDs.isEmpty ? (frames.isEmpty ? 0 : 1) : Double(missingCells) / Double(tracked.count * bsIDs.count)

        // Tracking quality (all frames, not only tracked).
        var camStates: [String: Int] = [:]
        for f in frames { camStates[f.cameraTrackingState ?? "unknown", default: 0] += 1 }
        let intervals = frames.compactMap { $0.frameInterval }
        let quality = TrackingQualityFeatures(
            trackedFraction: frames.isEmpty ? 0 : Double(tracked.count) / Double(frames.count),
            cameraStateDistribution: camStates.mapValues { Double($0) / Double(max(1, frames.count)) },
            meanFrameIntervalSeconds: LocalStatistics.mean(intervals),
            droppedFramesEstimate: frames.reduce(0) { $0 + ($1.droppedFramesEstimate ?? 0) },
            meanAmbientIntensity: LocalStatistics.mean(frames.compactMap { $0.ambientIntensity }),
            meanColorTemperatureK: LocalStatistics.mean(frames.compactMap { $0.ambientColorTemperature }),
            meanExposureDurationS: LocalStatistics.mean(frames.compactMap { $0.exposureDuration }))
        if !intervals.isEmpty { supporting.insert("frame_interval_s") }
        if frames.contains(where: { $0.ambientIntensity != nil }) { supporting.insert("light_ambient_intensity"); supporting.insert("light_color_temperature_k") }

        let (s, e) = TimestampAligner.wallClockRange(session.alignment, startUptime: startUptime, endUptime: endUptime)
        var window = FacialFeatureWindow(
            id: "\(session.id)-\(Int(windowSeconds))s-\(String(format: "%.3f", startUptime))", sessionID: session.id,
            windowSeconds: windowSeconds, startUptime: startUptime, endUptime: endUptime, startWallClock: s, endWallClock: e,
            frameCount: frames.count, trackedFrameCount: tracked.count, missingBlendShapeFraction: missingFraction,
            markers: Array(Set(frames.compactMap { $0.activeMarker })).sorted(), blink: nil, eyeOpenness: nil, headMovement: nil,
            facialMovement: nil, blendShapeDynamics: [:], asymmetry: nil, gaze: nil, trackingQuality: quality,
            supportingMeasurements: [], exportedDerivedMeans: exportedDerivedMeans(frames: frames, session: session))

        guard tracked.count >= c.minimumTrackedFrames else {
            window.supportingMeasurements = supporting.sorted()
            return window
        }

        let times = tracked.map { $0.timestampUptime }
        let span = max((times.last! - times.first!), 1e-3)

        // Blink and eye openness from eyeBlink_L / eyeBlink_R.
        let left = tracked.map { $0.blendShapes["eyeBlink_L"] }
        let right = tracked.map { $0.blendShapes["eyeBlink_R"] }
        if left.contains(where: { $0 != nil }) || right.contains(where: { $0 != nil }) {
            supporting.insert("bs_eyeBlink_L"); supporting.insert("bs_eyeBlink_R")
            window.blink = detectBlinks(times: times, left: left, right: right, span: span)
            let openness: [Double] = zip(left, right).compactMap { l, r in
                let vals = [l, r].compactMap { $0 }
                guard !vals.isEmpty else { return nil }
                return 1 - vals.reduce(0, +) / Double(vals.count)
            }
            window.eyeOpenness = LocalStatistics.featureStat(openness)
        }

        // Head movement from the raw world transform.
        let headPairs: [(Double, [Double])] = tracked.compactMap { f in f.headWorldTransform.map { (f.timestampUptime, $0) } }
        if headPairs.count >= 3 {
            for r in 0..<4 { for col in 0..<4 { supporting.insert("head_world_m\(r)\(col)") } }
            var pitch: [Double] = [], yaw: [Double] = [], roll: [Double] = []
            var pos: [[Double]] = []
            for (_, m) in headPairs {
                let eu = Self.eulerAngles(rowMajor: m)
                pitch.append(eu.pitch); yaw.append(eu.yaw); roll.append(eu.roll)
                pos.append([m[3], m[7], m[11]])
            }
            pitch = Self.unwrap(pitch); yaw = Self.unwrap(yaw); roll = Self.unwrap(roll)
            func range(_ x: [Double]) -> Double { (x.max() ?? 0) - (x.min() ?? 0) }
            var speeds: [Double] = []
            for i in 1..<headPairs.count {
                let dt = headPairs[i].0 - headPairs[i - 1].0
                guard dt > 0 else { continue }
                let dp = pitch[i] - pitch[i - 1], dy = yaw[i] - yaw[i - 1], dr = roll[i] - roll[i - 1]
                speeds.append((dp * dp + dy * dy + dr * dr).squareRoot() / dt)
            }
            let headSpan = max(headPairs.last!.0 - headPairs.first!.0, 1e-3)
            let combined = zip(yaw, pitch).map { $0 + $1 }
            let stds = [pitch, yaw, roll].compactMap { LocalStatistics.standardDeviation($0) }
            let xs = pos.map { $0[0] }, ys = pos.map { $0[1] }, zs = pos.map { $0[2] }
            window.headMovement = HeadMovementFeatures(
                amplitudeRad: ["pitch": range(pitch), "yaw": range(yaw), "roll": range(roll)],
                meanAmplitudeRad: (range(pitch) + range(yaw) + range(roll)) / 3,
                frequencyHz: LocalStatistics.zeroCrossingRate(combined, durationSeconds: headSpan),
                poseVariabilityRad: LocalStatistics.mean(stds), meanAngularSpeedRadPerS: LocalStatistics.mean(speeds),
                positionRangeM: ["x": range(xs), "y": range(ys), "z": range(zs)],
                meanDistanceToOriginM: LocalStatistics.mean(pos.map { ($0[0] * $0[0] + $0[1] * $0[1] + $0[2] * $0[2]).squareRoot() }))
        }

        // Facial movement and per-coefficient dynamics.
        var dynamics: [String: FeatureStat] = [:]
        var ranges: [Double] = [], stds: [Double] = [], absDeltaRates: [Double] = [], means: [Double] = []
        var activeCount = 0
        var stdByID: [(String, Double)] = []
        for id in bsIDs {
            let series = tracked.compactMap { $0.blendShapes[id] }
            guard series.count >= 2 else { continue }
            supporting.insert("bs_\(id)")
            var st = LocalStatistics.featureStat(series)
            var absDelta = 0.0
            for i in 1..<series.count { absDelta += abs(series[i] - series[i - 1]) }
            let rate = absDelta / span
            absDeltaRates.append(rate)
            ranges.append((st.maximum ?? 0) - (st.minimum ?? 0))
            if let sd = st.standardDeviation { stds.append(sd); stdByID.append((id, sd)) }
            if let m = st.mean { means.append(m) }
            if (st.maximum ?? 0) > c.activeCoefficientThreshold { activeCount += 1 }
            st.n = series.count
            dynamics[id] = st
        }
        if !ranges.isEmpty {
            window.facialMovement = FacialMovementFeatures(
                amplitude: LocalStatistics.mean(ranges), variability: LocalStatistics.mean(stds),
                activityPerSecond: LocalStatistics.mean(absDeltaRates), meanActivation: LocalStatistics.mean(means),
                activeCoefficientFraction: bsIDs.isEmpty ? nil : Double(activeCount) / Double(bsIDs.count),
                mostActiveCoefficients: stdByID.sorted { $0.1 > $1.1 }.prefix(5).map { $0.0 })
        }
        window.blendShapeDynamics = dynamics

        // Left/right asymmetry over every _L/_R pair.
        window.asymmetry = asymmetry(tracked: tracked, ids: bsIDs)

        // Gaze from lookAtPoint.
        let lookAts = tracked.compactMap { f in f.lookAtPoint.map { (f.timestampUptime, $0) } }
        if lookAts.count >= 3 {
            supporting.insert("look_at_x"); supporting.insert("look_at_y"); supporting.insert("look_at_z")
            window.gaze = gaze(points: lookAts)
        }

        window.supportingMeasurements = supporting.sorted()
        return window
    }

    // MARK: Blink detection

    func detectBlinks(times: [Double], left: [Double?], right: [Double?], span: Double) -> BlinkFeatures {
        let c = configuration
        var events: [(start: Double, end: Double, leftCrossed: Bool, rightCrossed: Bool)] = []
        var open = false
        var start = 0.0
        var lCrossed = false, rCrossed = false
        for i in 0..<times.count {
            let l = left[i] ?? 0, r = right[i] ?? 0
            let m = max(l, r)
            if !open {
                if m >= c.blinkOnsetThreshold {
                    open = true; start = times[i]; lCrossed = l >= c.blinkOnsetThreshold; rCrossed = r >= c.blinkOnsetThreshold
                }
            } else {
                lCrossed = lCrossed || l >= c.blinkOnsetThreshold
                rCrossed = rCrossed || r >= c.blinkOnsetThreshold
                if l <= c.blinkOffsetThreshold && r <= c.blinkOffsetThreshold {
                    open = false
                    events.append((start, times[i], lCrossed, rCrossed))
                }
            }
        }
        let blinks = events.filter { ($0.end - $0.start) >= c.blinkMinimumDurationS && ($0.end - $0.start) <= c.blinkMaximumDurationS }
        let durations = blinks.map { $0.end - $0.start }
        var ibis: [Double] = []
        for i in 1..<max(1, blinks.count) { ibis.append(blinks[i].start - blinks[i - 1].start) }
        return BlinkFeatures(
            count: blinks.count, ratePerMinute: span > 0 ? Double(blinks.count) / span * 60 : nil,
            meanDurationSeconds: LocalStatistics.mean(durations), durationStdSeconds: LocalStatistics.standardDeviation(durations),
            meanInterBlinkIntervalSeconds: LocalStatistics.mean(ibis),
            leftOnlyCount: blinks.filter { $0.leftCrossed && !$0.rightCrossed }.count,
            rightOnlyCount: blinks.filter { $0.rightCrossed && !$0.leftCrossed }.count,
            method: "hysteresis on max(eyeBlink_L, eyeBlink_R): onset ≥ \(c.blinkOnsetThreshold), offset ≤ \(c.blinkOffsetThreshold), duration \(c.blinkMinimumDurationS)–\(c.blinkMaximumDurationS) s; longer closures excluded")
    }

    // MARK: Asymmetry

    func asymmetry(tracked: [ARKitFrame], ids: [String]) -> AsymmetryFeatures? {
        let bases = Set(ids.filter { $0.hasSuffix("_L") }.map { String($0.dropLast(2)) })
            .filter { ids.contains($0 + "_R") }
        guard !bases.isEmpty else { return nil }
        var byPair: [String: Double] = [:]
        var byGroupAbs: [String: [Double]] = [:]
        var allAbs: [Double] = []
        for base in bases.sorted() {
            var diffs: [Double] = []
            for f in tracked {
                if let l = f.blendShapes[base + "_L"], let r = f.blendShapes[base + "_R"] { diffs.append(l - r) }
            }
            guard let meanSigned = LocalStatistics.mean(diffs) else { continue }
            byPair[base] = meanSigned
            let meanAbs = LocalStatistics.mean(diffs.map { abs($0) }) ?? 0
            allAbs.append(meanAbs)
            byGroupAbs[Self.group(for: base), default: []].append(meanAbs)
        }
        return AsymmetryFeatures(pairCount: byPair.count, overallMeanAbsoluteDifference: LocalStatistics.mean(allAbs),
                                 byGroup: byGroupAbs.compactMapValues { LocalStatistics.mean($0) }, byPairSigned: byPair)
    }

    static func group(for base: String) -> String {
        let b = base.lowercased()
        if b.hasPrefix("mouthsmile") { return "smile" }
        if b.hasPrefix("brow") { return "brow" }
        if b.hasPrefix("eye") { return "eye" }
        if b.hasPrefix("cheek") { return "cheek" }
        if b.hasPrefix("mouth") || b.hasPrefix("jaw") { return "mouth" }
        if b.hasPrefix("nose") { return "nose" }
        return "other"
    }

    // MARK: Gaze

    func gaze(points: [(Double, [Double])]) -> GazeFeatures {
        let c = configuration
        var yaws: [Double] = [], pitches: [Double] = [], dists: [Double] = []
        var dirs: [[Double]] = []
        for (_, p) in points {
            let n = (p[0] * p[0] + p[1] * p[1] + p[2] * p[2]).squareRoot()
            dists.append(n)
            guard n > 0 else { dirs.append([0, 0, 1]); yaws.append(0); pitches.append(0); continue }
            let d = [p[0] / n, p[1] / n, p[2] / n]
            dirs.append(d)
            yaws.append(atan2(d[0], d[2]) * 180 / .pi)
            pitches.append(atan2(d[1], (d[0] * d[0] + d[2] * d[2]).squareRoot()) * 180 / .pi)
        }
        var changes = 0
        var speeds: [Double] = []
        var inChange = false
        for i in 1..<dirs.count {
            let dot = max(-1, min(1, dirs[i][0] * dirs[i - 1][0] + dirs[i][1] * dirs[i - 1][1] + dirs[i][2] * dirs[i - 1][2]))
            let angle = acos(dot) * 180 / .pi
            let dt = points[i].0 - points[i - 1].0
            if dt > 0 { speeds.append(angle / dt) }
            if angle >= c.gazeChangeThresholdDeg {
                if !inChange { changes += 1; inChange = true }
            } else { inChange = false }
        }
        return GazeFeatures(directionChangeCount: changes, changeThresholdDegrees: c.gazeChangeThresholdDeg,
                            meanAngularSpeedDegPerS: LocalStatistics.mean(speeds), yawStdDeg: LocalStatistics.standardDeviation(yaws),
                            pitchStdDeg: LocalStatistics.standardDeviation(pitches), meanLookAtDistanceM: LocalStatistics.mean(dists))
    }

    // MARK: Exported derived columns (reported, not recomputed)

    func exportedDerivedMeans(frames: [ARKitFrame], session: ARKitSession) -> [String: Double] {
        var out: [String: Double] = [:]
        for c in session.columns where ARKitDatasetImporter.exportedDerivedColumns.contains(c.name) {
            if let m = LocalStatistics.mean(frames.compactMap { $0.values[c.index] }) { out[c.name] = m }
        }
        return out
    }

    // MARK: Math

    /// Intrinsic Z-Y-X Tait–Bryan decomposition of the rotation part of a row-major 4×4 transform:
    /// pitch about X, yaw about Y, roll about Z, radians. Amplitude/variability metrics change little
    /// with the convention for the head angles seen in front-camera recordings (well under 90°).
    public static func eulerAngles(rowMajor m: [Double]) -> (pitch: Double, yaw: Double, roll: Double) {
        guard m.count >= 12 else { return (0, 0, 0) }
        let m00 = m[0], m10 = m[4], m20 = m[8], m21 = m[9], m22 = m[10]
        let yaw = atan2(-m20, (m21 * m21 + m22 * m22).squareRoot())
        let pitch = atan2(m21, m22)
        let roll = atan2(m10, m00)
        return (pitch, yaw, roll)
    }

    /// Removes 2π jumps so ranges and standard deviations are not inflated at the ±π seam.
    static func unwrap(_ x: [Double]) -> [Double] {
        guard x.count > 1 else { return x }
        var out = [x[0]]
        var offset = 0.0
        for i in 1..<x.count {
            var d = x[i] - x[i - 1]
            if d > .pi { offset -= 2 * .pi; d -= 2 * .pi } else if d < -.pi { offset += 2 * .pi; d += 2 * .pi }
            out.append(x[i] + offset)
        }
        return out
    }
}
