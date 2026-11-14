import Foundation

/// Joins HealthKit daily values with ARKit facial-feature windows on wall-clock time.
///
/// - ARKit windows are placed on the timeline only through `TimestampAlignment`; unaligned sessions
///   are listed in `notes` and left out of the join.
/// - Nothing is interpolated or filled in. A day without a value is simply absent from that row.
/// - Raw and derived stay apart: the health summary and the ARKit summaries travel unchanged inside
///   the dataset; `bins`, `dailyRows` and `correlations` are the derived layer.
public struct CombinedDatasetBuilder {

    public var calendar: Calendar
    /// Width of the fine-grained time bins. Health samples and facial windows are grouped by bin start.
    public var aggregationWindowSeconds: Double
    /// Facial windows of this length feed the join (the 60 s windows by default).
    public var facialWindowSeconds: Double
    public var minimumCorrelationPairs: Int

    public init(calendar: Calendar = .current, aggregationWindowSeconds: Double = 3600,
                facialWindowSeconds: Double = 60, minimumCorrelationPairs: Int = 7) {
        self.calendar = calendar
        self.aggregationWindowSeconds = aggregationWindowSeconds
        self.facialWindowSeconds = facialWindowSeconds
        self.minimumCorrelationPairs = minimumCorrelationPairs
    }

    /// Health metrics whose daily values are paired with facial features.
    public static let healthMetricsForJoin: [String] = [
        "HKQuantityTypeIdentifierHeartRateVariabilitySDNN", "HKQuantityTypeIdentifierRestingHeartRate",
        "HKQuantityTypeIdentifierHeartRate", "HKCategoryTypeIdentifierSleepAnalysis", "HKQuantityTypeIdentifierStepCount",
        "HKQuantityTypeIdentifierActiveEnergyBurned", "HKQuantityTypeIdentifierAppleExerciseTime",
        "HKQuantityTypeIdentifierRespiratoryRate", "HKQuantityTypeIdentifierWalkingSpeed", "HKCategoryTypeIdentifierMindfulSession"
    ]

    /// Facial feature keys taken from each window.
    public static let facialKeys: [String] = [
        "blinkRatePerMinute", "blinkMeanDurationS", "eyeOpennessMean", "headMeanAmplitudeRad", "headFrequencyHz",
        "headPoseVariabilityRad", "headMeanAngularSpeedRadPerS", "facialAmplitude", "facialVariability", "facialActivityPerSecond",
        "asymmetryOverall", "gazeChangeCount", "gazeMeanSpeedDegPerS", "trackedFraction"
    ]

    public static func metricKey(_ typeIdentifier: String) -> String {
        typeIdentifier
            .replacingOccurrences(of: "HKQuantityTypeIdentifier", with: "")
            .replacingOccurrences(of: "HKCategoryTypeIdentifier", with: "")
            .replacingOccurrences(of: "HKWorkoutTypeIdentifier", with: "Workout")
    }

    public static func facialValues(_ w: FacialFeatureWindow) -> [String: Double] {
        var v: [String: Double] = [:]
        if let b = w.blink { if let r = b.ratePerMinute { v["blinkRatePerMinute"] = r }; if let d = b.meanDurationSeconds { v["blinkMeanDurationS"] = d } }
        if let m = w.eyeOpenness?.mean { v["eyeOpennessMean"] = m }
        if let h = w.headMovement {
            if let a = h.meanAmplitudeRad { v["headMeanAmplitudeRad"] = a }
            if let f = h.frequencyHz { v["headFrequencyHz"] = f }
            if let p = h.poseVariabilityRad { v["headPoseVariabilityRad"] = p }
            if let s = h.meanAngularSpeedRadPerS { v["headMeanAngularSpeedRadPerS"] = s }
        }
        if let f = w.facialMovement {
            if let a = f.amplitude { v["facialAmplitude"] = a }
            if let s = f.variability { v["facialVariability"] = s }
            if let act = f.activityPerSecond { v["facialActivityPerSecond"] = act }
        }
        if let a = w.asymmetry?.overallMeanAbsoluteDifference { v["asymmetryOverall"] = a }
        if let g = w.gaze { v["gazeChangeCount"] = Double(g.directionChangeCount); if let s = g.meanAngularSpeedDegPerS { v["gazeMeanSpeedDegPerS"] = s } }
        v["trackedFraction"] = w.trackingQuality.trackedFraction
        return v
    }

    // MARK: Build

    /// - Parameters:
    ///   - healthData: the summary (daily values live in `metrics[].daily`).
    ///   - arKitData: per-session summaries including their windows.
    ///   - healthSamples: optional raw samples for the fine-grained bins; daily rows do not need them.
    public func buildCombinedDataset(healthData: HealthDataSummary, arKitData: [ARKitSessionSummary],
                                     healthSamples: [HealthSample] = [], baseline: BaselineProfile? = nil) -> CombinedDataset {
        var notes: [String] = []
        let aligned = arKitData.filter { $0.alignmentMethod != .unaligned && $0.recordedStart != nil }
        let unaligned = arKitData.filter { !($0.alignmentMethod != .unaligned && $0.recordedStart != nil) }
        if !unaligned.isEmpty {
            notes.append("\(unaligned.count) ARKit session(s) have no wall-clock anchor and were left out of the join: \(unaligned.map { $0.id }.joined(separator: ", ")).")
        }

        // Windows to join, with wall-clock time.
        var windows: [(FacialFeatureWindow, Date)] = []
        for s in aligned {
            let key = String(Int(facialWindowSeconds))
            let ws = s.windowsBySeconds[key] ?? (s.sessionLevelFeatures.map { [$0] } ?? [])
            for w in ws { if let d = w.startWallClock { windows.append((w, d)) } }
        }

        // Daily health values.
        var dailyHealth: [String: [String: Double]] = [:] // day -> metricKey -> value
        var healthKeys: [String: String] = [:]
        for m in healthData.metrics {
            let key = Self.metricKey(m.typeIdentifier)
            healthKeys[key] = m.unit ?? ""
            for d in m.daily { if let v = LocalStatistics.dailyValue(d) { dailyHealth[d.day, default: [:]][key] = v } }
        }

        // Daily facial values: mean over the day's windows (weighted equally).
        var dailyFacial: [String: [String: [Double]]] = [:]
        var dailySessions: [String: Set<String>] = [:]
        var dailyWindowCount: [String: Int] = [:]
        for (w, d) in windows {
            let day = LocalStatistics.dayKey(d, calendar: calendar)
            for (k, v) in Self.facialValues(w) { dailyFacial[day, default: [:]][k, default: []].append(v) }
            dailySessions[day, default: []].insert(w.sessionID)
            dailyWindowCount[day, default: 0] += 1
        }

        let allDays = Set(dailyHealth.keys).union(dailyFacial.keys)
        var rows: [CombinedDailyRow] = []
        for day in allDays.sorted() {
            guard let date = LocalStatistics.date(fromDayKey: day, calendar: calendar), healthData.range.contains(date) || dailyFacial[day] != nil else { continue }
            let prevKey = calendar.date(byAdding: .day, value: -1, to: date).map { LocalStatistics.dayKey($0, calendar: calendar) } ?? ""
            rows.append(CombinedDailyRow(
                day: day, health: dailyHealth[day] ?? [:], previousDayHealth: dailyHealth[prevKey] ?? [:],
                facial: (dailyFacial[day] ?? [:]).compactMapValues { LocalStatistics.mean($0) },
                arKitSessionIDs: Array(dailySessions[day] ?? []).sorted(), facialWindowCount: dailyWindowCount[day] ?? 0))
        }

        // Fine bins around facial windows.
        var bins: [AlignedBin] = []
        if aggregationWindowSeconds > 0, !windows.isEmpty {
            var byBin: [Date: ([FacialFeatureWindow], Set<String>)] = [:]
            for (w, d) in windows {
                let start = Date(timeIntervalSince1970: (d.timeIntervalSince1970 / aggregationWindowSeconds).rounded(.down) * aggregationWindowSeconds)
                byBin[start, default: ([], [])].0.append(w)
                byBin[start, default: ([], [])].1.insert(w.sessionID)
            }
            for (start, entry) in byBin.sorted(by: { $0.key < $1.key }) {
                let end = start.addingTimeInterval(aggregationWindowSeconds)
                var facial: [String: BinAggregate] = [:]
                var collected: [String: [Double]] = [:]
                for w in entry.0 { for (k, v) in Self.facialValues(w) { collected[k, default: []].append(v) } }
                for (k, vals) in collected {
                    facial[k] = BinAggregate(n: vals.count, mean: LocalStatistics.mean(vals), minimum: vals.min(), maximum: vals.max(), sum: nil, sources: Array(entry.1).sorted())
                }
                var health: [String: BinAggregate] = [:]
                if !healthSamples.isEmpty {
                    var hv: [String: ([Double], Set<String>)] = [:]
                    for s in healthSamples where s.kind == .quantity && s.startDate >= start && s.startDate < end {
                        guard let v = s.value else { continue }
                        let k = Self.metricKey(s.typeIdentifier)
                        hv[k, default: ([], [])].0.append(v)
                        if let src = s.sourceName { hv[k, default: ([], [])].1.insert(src) }
                    }
                    for (k, e) in hv {
                        let isSum = HealthTypeCatalog.descriptor(for: "HKQuantityTypeIdentifier" + k)?.isCumulative ?? false
                        health[k] = BinAggregate(n: e.0.count, mean: LocalStatistics.mean(e.0), minimum: e.0.min(), maximum: e.0.max(),
                                                 sum: isSum ? e.0.reduce(0, +) : nil, sources: Array(e.1).sorted())
                    }
                }
                bins.append(AlignedBin(start: start, end: end, health: health, facial: facial, arKitSessionIDs: Array(entry.1).sorted()))
            }
        }

        // Cross-metric correlations on daily rows.
        var correlations: [CorrelationResult] = []
        let healthForJoin = Self.healthMetricsForJoin.map(Self.metricKey).filter { k in rows.contains { $0.health[k] != nil } }
        let facialPresent = Self.facialKeys.filter { k in rows.contains { $0.facial[k] != nil } }
        for hk in healthForJoin {
            var hSeries: [String: Double] = [:]
            for r in rows { if let v = r.health[hk] { hSeries[r.day] = v } }
            for fk in facialPresent where fk != "trackedFraction" {
                var fSeries: [String: Double] = [:]
                for r in rows { if let v = r.facial[fk] { fSeries[r.day] = v } }
                // lag 0: same day (sleep is already attributed to the wake-up day).
                correlations.append(LocalStatistics.correlate(metricA: hk, a: hSeries, metricB: fk, b: fSeries, lagDays: 0,
                                                              calendar: calendar, minimumPairs: minimumCorrelationPairs))
                // lag 1: health on day d against the face on day d + 1.
                correlations.append(LocalStatistics.correlate(metricA: hk, a: hSeries, metricB: fk, b: fSeries, lagDays: 1,
                                                              calendar: calendar, minimumPairs: minimumCorrelationPairs))
            }
        }
        let computed = correlations.filter { $0.spearmanRho != nil }.count
        notes.append("\(computed) of \(correlations.count) health×facial pairs had at least \(minimumCorrelationPairs) paired days; the rest are listed with their pair count and no coefficient.")
        notes.append("Facial daily values are means over \(Int(facialWindowSeconds)) s windows of that day's recordings; recordings are short and sparse compared with health data.")
        notes.append("All correlations are descriptive. No causal claim is implied and no multiple-comparison correction is applied.")

        let start = min(healthData.range.start, windows.map { $0.1 }.min() ?? healthData.range.start)
        let end = max(healthData.range.end, windows.map { $0.1 }.max() ?? healthData.range.end)
        return CombinedDataset(
            id: UUID().uuidString, createdAt: Date(), range: DateRange(start: start, end: end),
            timeZoneIdentifier: calendar.timeZone.identifier, aggregationWindowSeconds: aggregationWindowSeconds,
            bins: bins, dailyRows: rows, healthSummary: healthData, arKitSummaries: arKitData,
            alignments: [], correlations: correlations, baseline: baseline, notes: notes)
    }
}

/// Personal reference ranges from the person's own history. Never a "healthy" norm.
public struct BaselineBuilder {
    public var calendar: Calendar
    public init(calendar: Calendar = .current) { self.calendar = calendar }

    public func build(health: HealthDataSummary, arKit: [ARKitSessionSummary], facialWindowSeconds: Double = 60) -> BaselineProfile {
        var healthRefs: [ReferenceRange] = []
        var changes: [LongitudinalChange] = []
        for m in health.metrics {
            if let r = LocalStatistics.referenceRange(metric: CombinedDatasetBuilder.metricKey(m.typeIdentifier), unit: m.unit,
                                                      daily: m.daily, coverage: m.coverage, calendar: calendar) {
                healthRefs.append(r)
            }
            if let c = m.longitudinalChange { changes.append(c) }
        }
        var facialRefs: [ReferenceRange] = []
        var perKey: [String: [Double]] = [:]
        var sessionsPerKey: [String: Set<String>] = [:]
        for s in arKit {
            let ws = s.windowsBySeconds[String(Int(facialWindowSeconds))] ?? (s.sessionLevelFeatures.map { [$0] } ?? [])
            for w in ws where w.trackingQuality.trackedFraction >= 0.5 {
                for (k, v) in CombinedDatasetBuilder.facialValues(w) { perKey[k, default: []].append(v); sessionsPerKey[k, default: []].insert(s.id) }
            }
        }
        for (k, vals) in perKey.sorted(by: { $0.key < $1.key }) {
            let d = LocalStatistics.describe(vals)
            var r = ReferenceRange(metric: k, unit: nil, sampleCount: vals.count, daysCovered: sessionsPerKey[k]?.count ?? 0,
                                   median: d.median, medianAbsoluteDeviation: d.medianAbsoluteDeviation, percentile5: d.percentile5,
                                   percentile25: d.percentile25, percentile75: d.percentile75, percentile95: d.percentile95, mean: d.mean,
                                   standardDeviation: d.standardDeviation, lowerUsual: nil, upperUsual: nil, coverageFraction: nil,
                                   firstDate: arKit.compactMap { $0.recordedStart }.min(), lastDate: arKit.compactMap { $0.recordedEnd }.max())
            if let m = d.median, let mad = d.medianAbsoluteDeviation, mad > 0 { r.lowerUsual = m - 2.5 * 1.4826 * mad; r.upperUsual = m + 2.5 * 1.4826 * mad }
            facialRefs.append(r)
        }
        return BaselineProfile(
            generatedAt: Date(), range: health.range, healthReferences: healthRefs, facialReferences: facialRefs,
            longitudinalChanges: changes,
            caveat: "Reference ranges describe this person's own recorded history (median ± 2.5 robust SD). They are not a healthy norm, and the history may itself contain unwell periods. Facial references count \(Int(facialWindowSeconds)) s windows with ≥ 50 % face tracking; 'daysCovered' is the number of recordings.")
    }
}
