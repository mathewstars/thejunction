import Foundation

/// Builds the numeric payload for each experiment from the local models, trimming what would only
/// cost tokens (long daily series, per-window blend-shape tables) and dropping anything personal
/// (participant labels, notes, device names beyond the model, source bundle identifiers).
public struct GeminiPayloadBuilder {

    public struct Options {
        /// Most recent daily points kept per metric.
        public var maxDailyPoints = 120
        /// Facial window lengths included per session (seconds). Session-level features are always included.
        public var windowLengths: [Int] = [60]
        public var maxWindowsPerLength = 120
        /// Per-window per-coefficient tables are dropped; per-session blend-shape statistics are kept.
        public var includeWindowBlendShapeDynamics = false
        public var includeBins = false
        public var maxDailyRows = 180
        public init() {}
    }

    public var options = Options()
    public init(options: Options = Options()) { self.options = options }

    // MARK: Public builders

    public func healthPayload(_ summary: HealthDataSummary, baseline: BaselineProfile?) throws -> (JSONValue, [String], DateRange) {
        var metrics: [JSONValue] = []
        var categories = Set<String>()
        for m in summary.metrics {
            categories.insert(m.category)
            metrics.append(try metricJSON(m))
        }
        var obj: [String: JSONValue] = [
            "source": .string("Apple Health via HealthKit / Apple Health XML export; statistics computed on device"),
            "date_range": .object(["start": .string(ISO8601.string(from: summary.range.start)), "end": .string(ISO8601.string(from: summary.range.end))]),
            "time_zone": .string(summary.timeZoneIdentifier),
            "metrics": .array(metrics),
            "unavailable_types": .array(summary.unavailableTypes.map { .string(CombinedDatasetBuilder.metricKey($0)) }),
            "empty_types": .array(summary.emptyTypes.map { .string(CombinedDatasetBuilder.metricKey($0)) }),
            "workouts": .object(["count": .number(Double(summary.workoutCount)), "by_activity": .object(summary.workoutsByActivity.mapValues { .number(Double($0)) })]),
            "processing_notes": .array(summary.notes.map { .string($0) })
        ]
        if let b = baseline { obj["baseline_profile"] = try baselineJSON(b) }
        return (.object(obj), categories.sorted(), summary.range)
    }

    public func arKitPayload(_ sessions: [ARKitSessionSummary]) throws -> (JSONValue, [String], DateRange?) {
        var arr: [JSONValue] = []
        for s in sessions { arr.append(try sessionJSON(s)) }
        let starts = sessions.compactMap { $0.recordedStart }, ends = sessions.compactMap { $0.recordedEnd }
        let range = (starts.min() != nil && ends.max() != nil) ? DateRange(start: starts.min()!, end: ends.max()!) : nil
        let obj: [String: JSONValue] = [
            "source": .string("FaceMetrics ARKit recorder exports (samples.csv, session.json); features computed on device"),
            "feature_definitions": featureDefinitions,
            "sessions": .array(arr)
        ]
        return (.object(obj), ["Facial behaviour features (numbers only)"], range)
    }

    public func combinedPayload(_ ds: CombinedDataset) throws -> (JSONValue, [String], DateRange) {
        let (health, healthCats, _) = try healthPayload(ds.healthSummary, baseline: nil)
        let (arkit, _, _) = try arKitPayload(ds.arKitSummaries)
        let rows = Array(ds.dailyRows.suffix(options.maxDailyRows))
        var obj: [String: JSONValue] = [
            "date_range": .object(["start": .string(ISO8601.string(from: ds.range.start)), "end": .string(ISO8601.string(from: ds.range.end))]),
            "time_zone": .string(ds.timeZoneIdentifier),
            "health": health,
            "arkit": arkit,
            "daily_rows": try JSONValue.from(rows),
            "correlations": try JSONValue.from(ds.correlations),
            "processing_notes": .array(ds.notes.map { .string($0) })
        ]
        if let b = ds.baseline { obj["baseline_profile"] = try baselineJSON(b) }
        if options.includeBins { obj["bins"] = try JSONValue.from(ds.bins) }
        return (.object(obj), healthCats + ["Facial behaviour features (numbers only)", "Daily joined rows", "Correlations"], ds.range)
    }

    public func baselinePayload(_ b: BaselineProfile) throws -> (JSONValue, [String], DateRange) {
        (try baselineJSON(b), ["Personal reference ranges"], b.range)
    }

    public func geometryPayload(_ session: ARKitSessionSummary) throws -> (JSONValue, [String], DateRange?) {
        var s = try sessionJSON(session)
        if var o = s.objectValue {
            o["geometry_features"] = try JSONValue.from(session.geometryFeatures)
            s = .object(o)
        }
        let range = session.recordedStart.flatMap { st in session.recordedEnd.map { DateRange(start: st, end: $0) } }
        return (.object(["session": s]), ["Geometry-derived aggregate features", "Facial behaviour features (numbers only)"], range)
    }

    public func comparisonPayload(_ a: StructuredAnalysis, _ b: StructuredAnalysis) throws -> JSONValue {
        .object(["first": try JSONValue.from(a), "second": try JSONValue.from(b)])
    }

    // MARK: Pieces

    func metricJSON(_ m: HealthMetricSummary) throws -> JSONValue {
        var o: [String: JSONValue] = [
            "metric": .string(CombinedDatasetBuilder.metricKey(m.typeIdentifier)),
            "display_name": .string(m.displayName),
            "category": .string(m.category),
            "unit": m.unit.map { .string($0) } ?? .null,
            "daily_aggregation": .string(m.aggregation.rawValue),
            "sample_count": .number(Double(m.sampleCount)),
            "first_date": m.firstDate.map { .string(ISO8601.string(from: $0)) } ?? .null,
            "last_date": m.lastDate.map { .string(ISO8601.string(from: $0)) } ?? .null,
            "source_count": .number(Double(m.sources.count)),
            "statistics_per_sample": try JSONValue.from(m.statistics),
            "statistics_per_day": try JSONValue.from(m.dailyStatistics),
            "daily": try JSONValue.from(Array(m.daily.suffix(options.maxDailyPoints)).map { DailyPoint(day: $0.day, value: LocalStatistics.dailyValue($0), n: $0.count) }),
            "daily_points_omitted": .number(Double(max(0, m.daily.count - options.maxDailyPoints))),
            "weekly": try JSONValue.from(m.weekly),
            "sampling_frequency": try JSONValue.from(m.samplingFrequency),
            "coverage": try JSONValue.from(m.coverage.map { CoverageBrief(daysInRange: $0.daysInRange, daysWithData: $0.daysWithData, coverageFraction: $0.coverageFraction, missingDaysCount: $0.missingDays.count) }),
            "outliers": try JSONValue.from(m.outliers),
            "longitudinal_change": try JSONValue.from(m.longitudinalChange)
        ]
        if let b = m.categoryBreakdown { o["category_breakdown"] = .object(b.mapValues { .number(Double($0)) }) }
        return .object(o)
    }

    struct DailyPoint: Encodable { var day: String; var value: Double?; var n: Int }
    struct CoverageBrief: Encodable { var daysInRange: Int; var daysWithData: Int; var coverageFraction: Double; var missingDaysCount: Int }

    func sessionJSON(_ s: ARKitSessionSummary) throws -> JSONValue {
        var windows: [String: JSONValue] = [:]
        for len in options.windowLengths {
            guard let ws = s.windowsBySeconds[String(len)] else { continue }
            let trimmed = Array(ws.prefix(options.maxWindowsPerLength)).map { strip($0) }
            windows["\(len)s"] = try JSONValue.from(trimmed)
        }
        var validation = try JSONValue.from(s.validation)
        if var v = validation.objectValue { v.removeValue(forKey: "unknownColumns"); validation = .object(v) }
        return .object([
            "session_id": .string(s.id),
            "recorded_start": s.recordedStart.map { .string(ISO8601.string(from: $0)) } ?? .null,
            "recorded_end": s.recordedEnd.map { .string(ISO8601.string(from: $0)) } ?? .null,
            "time_alignment": .string(s.alignmentMethod.rawValue),
            "duration_s": .number(s.durationSeconds),
            "frame_count": .number(Double(s.frameCount)),
            "tracked_fraction": .number(s.trackedFraction),
            "effective_fps": s.effectiveFrameRate.map { .number($0) } ?? .null,
            "video_format": s.videoFormat.map { .string($0) } ?? .null,
            "markers": .array(s.markers.map { .string($0) }),
            "validation": validation,
            "session_level_features": try JSONValue.from(s.sessionLevelFeatures.map { strip($0, keepDynamics: true) }),
            "windows": .object(windows),
            "blend_shape_statistics": try JSONValue.from(s.blendShapeStatistics),
            "recorder_exported_derived_means": try JSONValue.from(s.exportedDerivedColumnMeans)
        ])
    }

    func strip(_ w: FacialFeatureWindow, keepDynamics: Bool = false) -> FacialFeatureWindow {
        var c = w
        if !(keepDynamics || options.includeWindowBlendShapeDynamics) { c.blendShapeDynamics = [:] }
        c.supportingMeasurements = []  // column list is in feature_definitions once, not per window
        return c
    }

    func baselineJSON(_ b: BaselineProfile) throws -> JSONValue { try JSONValue.from(b) }

    var featureDefinitions: JSONValue {
        .object([
            "blink": .string("Hysteresis events on bs_eyeBlink_L/R (onset ≥ 0.5, offset ≤ 0.3, 0.03–0.5 s). ratePerMinute = count / tracked span."),
            "eyeOpenness": .string("1 − mean(eyeBlink_L, eyeBlink_R) per frame; statistics over the window."),
            "headMovement": .string("Euler angles (rad) from head_world_m00..m33; amplitude = range, poseVariability = mean std, frequency = zero-crossing rate of yaw+pitch."),
            "facialMovement": .string("Over all bs_* coefficients on tracked frames: amplitude = mean range, variability = mean std, activityPerSecond = mean Σ|Δ| / span."),
            "asymmetry": .string("Per _L/_R pair mean(L − R) (signed) and mean |L − R| (overall and by group)."),
            "gaze": .string("look_at_x/y/z direction; a change is counted when consecutive frames differ by ≥ 5°."),
            "trackingQuality": .string("face_tracked fraction, camera_tracking_state distribution, dropped frame estimate, light estimate means."),
            "exportedDerivedMeans": .string("Means of the recorder's own derived columns (its blink detector, quality score…). Independent of the features above."),
            "windows": .string("Consecutive fixed-length windows on the recording clock; startWallClock/endWallClock come from the session.json time anchor.")
        ])
    }
}
