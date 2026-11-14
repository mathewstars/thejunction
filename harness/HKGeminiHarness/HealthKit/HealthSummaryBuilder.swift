import Foundation

/// Turns a bag of `HealthSample`s into a `HealthDataSummary`. Foundation only, so it works the same
/// for samples read from HealthKit and for samples imported from an Apple Health XML export.
///
/// Rules:
/// - Nothing is invented. A metric with no samples appears in `emptyTypes`, never as zeros.
/// - Sleep is attributed to the day the person woke up (end date), so "sleep → next day" questions
///   can pair the night ending on day d with day d's measurements.
/// - Cumulative metrics (steps, energy, distance) from several overlapping sources are not simply
///   summed. When HealthKit's own daily statistics are supplied they win; otherwise each day takes
///   the source with the largest total and the choice is written into `notes`.
public struct HealthSummaryBuilder {

    public var calendar: Calendar
    public var range: DateRange

    public init(range: DateRange, calendar: Calendar = .current) {
        self.range = range
        self.calendar = calendar
    }

    public func build(samples: [HealthSample], dailyStatistics: [HealthSample] = [],
                      unavailableTypes: [String] = [], emptyTypesHint: [String] = []) -> HealthDataSummary {
        var notes: [String] = []
        var metrics: [HealthMetricSummary] = []

        let inRange = samples.filter { range.overlaps(DateRange(start: $0.startDate, end: $0.endDate)) }
        var byType: [String: [HealthSample]] = [:]
        for s in inRange { byType[s.typeIdentifier, default: []].append(s) }
        var dailyStatsByType: [String: [HealthSample]] = [:]
        for s in dailyStatistics { dailyStatsByType[s.typeIdentifier, default: []].append(s) }

        let knownOrder = HealthTypeCatalog.all.map { $0.rawIdentifier }
        let unknownTypes = byType.keys.filter { !HealthTypeCatalog.byIdentifier.keys.contains($0) }.sorted()
        var emptyTypes: [String] = []

        for typeID in knownOrder + unknownTypes {
            guard let group = byType[typeID], !group.isEmpty else {
                if HealthTypeCatalog.byIdentifier[typeID] != nil, !unavailableTypes.contains(typeID) { emptyTypes.append(typeID) }
                continue
            }
            let d = HealthTypeCatalog.descriptor(for: typeID)
            if typeID == HealthTypeCatalog.workout.rawIdentifier {
                metrics.append(workoutMetric(group))
                continue
            }
            if typeID == "HKCategoryTypeIdentifierSleepAnalysis" {
                metrics.append(contentsOf: sleepMetrics(group, notes: &notes))
                continue
            }
            metrics.append(genericMetric(typeID: typeID, descriptor: d, samples: group,
                                         dailyStats: dailyStatsByType[typeID], notes: &notes))
        }

        let workouts = byType[HealthTypeCatalog.workout.rawIdentifier] ?? []
        var byActivity: [String: Int] = [:]
        for w in workouts { byActivity[w.workoutActivityType ?? "unknown", default: 0] += 1 }

        for t in emptyTypesHint where !emptyTypes.contains(t) && byType[t] == nil { emptyTypes.append(t) }
        notes.append("Daily values are formed in time zone \(calendar.timeZone.identifier).")
        notes.append("HRV and most watch metrics are sampled a few times a day; see samplingFrequency per metric before treating any series as continuous.")

        return HealthDataSummary(generatedAt: Date(), range: range, timeZoneIdentifier: calendar.timeZone.identifier,
                                 metrics: metrics, unavailableTypes: unavailableTypes.sorted(), emptyTypes: emptyTypes,
                                 workoutCount: workouts.count, workoutsByActivity: byActivity,
                                 totalSamples: inRange.count, notes: notes)
    }

    // MARK: Generic quantity / category metric

    private func genericMetric(typeID: String, descriptor d: HealthTypeDescriptor?, samples: [HealthSample],
                               dailyStats: [HealthSample]?, notes: inout [String]) -> HealthMetricSummary {
        let isCategory = samples.first?.kind == .category
        var aggregation = d?.aggregation ?? (isCategory ? .count : .mean)
        var unit = d?.unitString ?? samples.first?.unit
        var points: [(Date, Double, String)] = []

        if isCategory {
            if typeID == "HKCategoryTypeIdentifierMindfulSession" {
                aggregation = .sum; unit = "min"
                points = samples.map { ($0.endDate, $0.durationSeconds / 60, $0.sourceName ?? "?") }
            } else {
                aggregation = .count
                points = samples.map { ($0.startDate, 1, $0.sourceName ?? "?") }
            }
        } else {
            points = samples.compactMap { s in s.value.map { (s.startDate, $0, s.sourceName ?? "?") } }
        }

        var daily: [DailyAggregate]
        if aggregation == .sum, let stats = dailyStats, !stats.isEmpty {
            daily = stats.compactMap { s -> DailyAggregate? in
                guard let v = s.value else { return nil }
                var a = DailyAggregate(day: LocalStatistics.dayKey(s.startDate, calendar: calendar), count: 1)
                a.sum = v; a.mean = v; a.minimum = v; a.maximum = v
                return a
            }.sorted { $0.day < $1.day }
            notes.append("\(d?.displayName ?? typeID): daily totals come from HealthKit's statistics engine (sources merged by HealthKit).")
        } else if aggregation == .sum {
            daily = dailySumsTakingLargestSource(points)
            let sources = Set(points.map { $0.2 })
            if sources.count > 1 {
                notes.append("\(d?.displayName ?? typeID): \(sources.count) sources overlap; each day uses the source with the largest total to avoid double counting.")
            }
        } else {
            daily = LocalStatistics.dailyAggregates(points.map { ($0.0, $0.1) }, method: aggregation, calendar: calendar)
        }

        let values = points.map { $0.1 }
        var m = HealthMetricSummary(
            typeIdentifier: typeID, displayName: d?.displayName ?? typeID, category: d?.group.rawValue ?? "Unknown",
            unit: unit, aggregation: aggregation, sampleCount: samples.count,
            firstDate: samples.map { $0.startDate }.min(), lastDate: samples.map { $0.endDate }.max(),
            sources: Array(Set(samples.compactMap { $0.sourceName })).sorted(),
            statistics: isCategory ? nil : LocalStatistics.describe(values),
            dailyStatistics: LocalStatistics.describe(daily.compactMap { LocalStatistics.dailyValue($0) }),
            daily: daily, weekly: LocalStatistics.weeklyAggregates(daily, method: aggregation, calendar: calendar),
            samplingFrequency: LocalStatistics.samplingFrequency(samples.map { $0.startDate }),
            coverage: LocalStatistics.coverage(daily: daily, range: range, calendar: calendar),
            outliers: LocalStatistics.outliers(daily: daily),
            longitudinalChange: LocalStatistics.longitudinalChange(metric: typeID, unit: unit, daily: daily, calendar: calendar),
            categoryBreakdown: nil)
        if isCategory {
            var breakdown: [String: Int] = [:]
            for s in samples { breakdown[s.categoryLabel ?? "?", default: 0] += 1 }
            m.categoryBreakdown = breakdown
        }
        return m
    }

    /// Per day, per source sums; the day's value is the largest source total.
    private func dailySumsTakingLargestSource(_ points: [(Date, Double, String)]) -> [DailyAggregate] {
        var perDaySource: [String: [String: (sum: Double, n: Int)]] = [:]
        for (date, v, src) in points where v.isFinite {
            let k = LocalStatistics.dayKey(date, calendar: calendar)
            var e = perDaySource[k, default: [:]][src] ?? (0, 0)
            e.sum += v; e.n += 1
            perDaySource[k, default: [:]][src] = e
        }
        return perDaySource.keys.sorted().map { k in
            let best = perDaySource[k]!.max { $0.value.sum < $1.value.sum }!
            var a = DailyAggregate(day: k, count: best.value.n)
            a.sum = best.value.sum; a.mean = best.value.sum
            return a
        }
    }

    // MARK: Sleep

    private func sleepMetrics(_ samples: [HealthSample], notes: inout [String]) -> [HealthMetricSummary] {
        let typeID = "HKCategoryTypeIdentifierSleepAnalysis"
        let sources = Set(samples.compactMap { $0.sourceName })
        if sources.count > 1 {
            notes.append("Sleep: \(sources.count) sources; each night uses the source with the most recorded sleep.")
        }
        notes.append("Sleep is attributed to the wake-up day (end date of the interval).")

        func metric(label: String?, display: String) -> HealthMetricSummary? {
            let subset = samples.filter { s in
                guard let v = s.categoryValue else { return false }
                if let label { return s.categoryLabel == label }
                return HealthTypeCatalog.isAsleep(categoryValue: v)
            }
            guard !subset.isEmpty else { return nil }
            let pts = subset.map { ($0.endDate, $0.durationSeconds / 3600, $0.sourceName ?? "?") }
            let daily = dailySumsTakingLargestSource(pts)
            var breakdown: [String: Int] = [:]
            for s in samples { breakdown[s.categoryLabel ?? "?", default: 0] += 1 }
            let id = label.map { "\(typeID):\($0)" } ?? typeID
            return HealthMetricSummary(
                typeIdentifier: id, displayName: display, category: HealthTypeDescriptor.Group.sleepRecovery.rawValue,
                unit: "hr", aggregation: .durationHours, sampleCount: subset.count,
                firstDate: subset.map { $0.startDate }.min(), lastDate: subset.map { $0.endDate }.max(),
                sources: Array(sources).sorted(), statistics: LocalStatistics.describe(subset.map { $0.durationSeconds / 3600 }),
                dailyStatistics: LocalStatistics.describe(daily.compactMap { LocalStatistics.dailyValue($0) }),
                daily: daily, weekly: LocalStatistics.weeklyAggregates(daily, method: .durationHours, calendar: calendar),
                samplingFrequency: LocalStatistics.samplingFrequency(subset.map { $0.startDate }),
                coverage: LocalStatistics.coverage(daily: daily, range: range, calendar: calendar),
                outliers: LocalStatistics.outliers(daily: daily),
                longitudinalChange: LocalStatistics.longitudinalChange(metric: id, unit: "hr", daily: daily, calendar: calendar),
                categoryBreakdown: label == nil ? breakdown : nil)
        }

        var out: [HealthMetricSummary] = []
        if let m = metric(label: nil, display: "Sleep duration (asleep)") { out.append(m) }
        for (label, name) in [("asleepCore", "Sleep: core"), ("asleepDeep", "Sleep: deep"),
                              ("asleepREM", "Sleep: REM"), ("awake", "Sleep: awake in bed"), ("inBed", "Sleep: in bed")] {
            if let m = metric(label: label, display: name) { out.append(m) }
        }
        return out
    }

    // MARK: Workouts

    private func workoutMetric(_ workouts: [HealthSample]) -> HealthMetricSummary {
        let pts = workouts.map { ($0.startDate, $0.durationSeconds / 60) }
        let daily = LocalStatistics.dailyAggregates(pts, method: .sum, calendar: calendar)
        var byActivity: [String: Int] = [:]
        for w in workouts { byActivity[w.workoutActivityType ?? "unknown", default: 0] += 1 }
        return HealthMetricSummary(
            typeIdentifier: HealthTypeCatalog.workout.rawIdentifier, displayName: "Workout minutes",
            category: HealthTypeDescriptor.Group.other.rawValue, unit: "min", aggregation: .sum,
            sampleCount: workouts.count, firstDate: workouts.map { $0.startDate }.min(),
            lastDate: workouts.map { $0.endDate }.max(),
            sources: Array(Set(workouts.compactMap { $0.sourceName })).sorted(),
            statistics: LocalStatistics.describe(pts.map { $0.1 }),
            dailyStatistics: LocalStatistics.describe(daily.compactMap { LocalStatistics.dailyValue($0) }),
            daily: daily, weekly: LocalStatistics.weeklyAggregates(daily, method: .sum, calendar: calendar),
            samplingFrequency: LocalStatistics.samplingFrequency(workouts.map { $0.startDate }),
            coverage: LocalStatistics.coverage(daily: daily, range: range, calendar: calendar),
            outliers: nil, longitudinalChange: nil, categoryBreakdown: byActivity)
    }
}
