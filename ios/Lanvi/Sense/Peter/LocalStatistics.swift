// From Peter's HKGeminiHarness: harness/HKGeminiHarness/Analysis/LocalStatistics.swift on branch finalish-testing-app.
// Copied as he wrote it (only this header added). Built as the Harness framework so its names never clash with the app's.

import Foundation

/// Deterministic statistics computed on-device before anything reaches Gemini.
/// Pure functions over `[Double]` and `(Date, Double)` pairs. No HealthKit or ARKit types here.
public enum LocalStatistics {

    // MARK: Descriptive

    public static func mean(_ x: [Double]) -> Double? {
        guard !x.isEmpty else { return nil }
        return x.reduce(0, +) / Double(x.count)
    }

    public static func median(_ x: [Double]) -> Double? {
        guard !x.isEmpty else { return nil }
        let s = x.sorted()
        let n = s.count
        return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
    }

    /// Sample standard deviation (n − 1). nil for fewer than two values.
    public static func standardDeviation(_ x: [Double]) -> Double? {
        guard x.count >= 2, let m = mean(x) else { return nil }
        let ss = x.reduce(0) { $0 + ($1 - m) * ($1 - m) }
        return (ss / Double(x.count - 1)).squareRoot()
    }

    /// Linear-interpolated percentile, p in 0...100, on an already sorted array.
    public static func percentile(sorted s: [Double], _ p: Double) -> Double? {
        guard !s.isEmpty else { return nil }
        if s.count == 1 { return s[0] }
        let rank = (p / 100) * Double(s.count - 1)
        let lo = Int(rank.rounded(.down))
        let hi = min(lo + 1, s.count - 1)
        let frac = rank - Double(lo)
        return s[lo] + (s[hi] - s[lo]) * frac
    }

    public static func interquartileRange(_ x: [Double]) -> Double? {
        let s = x.sorted()
        guard let q1 = percentile(sorted: s, 25), let q3 = percentile(sorted: s, 75) else { return nil }
        return q3 - q1
    }

    public static func medianAbsoluteDeviation(_ x: [Double]) -> Double? {
        guard let m = median(x) else { return nil }
        return median(x.map { abs($0 - m) })
    }

    public static func describe(_ x: [Double]) -> DescriptiveStatistics {
        let clean = x.filter { $0.isFinite }
        var d = DescriptiveStatistics(count: clean.count)
        guard !clean.isEmpty else { return d }
        let s = clean.sorted()
        d.mean = mean(clean)
        d.median = median(clean)
        d.standardDeviation = standardDeviation(clean)
        d.minimum = s.first
        d.maximum = s.last
        d.percentile5 = percentile(sorted: s, 5)
        d.percentile25 = percentile(sorted: s, 25)
        d.percentile75 = percentile(sorted: s, 75)
        d.percentile95 = percentile(sorted: s, 95)
        if let q1 = d.percentile25, let q3 = d.percentile75 { d.interquartileRange = q3 - q1 }
        d.medianAbsoluteDeviation = medianAbsoluteDeviation(clean)
        d.sum = clean.reduce(0, +)
        return d
    }

    public static func featureStat(_ x: [Double]) -> FeatureStat {
        let clean = x.filter { $0.isFinite }
        return FeatureStat(n: clean.count, mean: mean(clean), standardDeviation: standardDeviation(clean),
                           minimum: clean.min(), maximum: clean.max(), median: median(clean))
    }

    // MARK: Rolling

    /// Trailing rolling mean over `window` points. Output has the same length; the first
    /// `window − 1` entries use the shorter available history.
    public static func rollingMean(_ x: [Double], window: Int) -> [Double] {
        guard window > 0, !x.isEmpty else { return [] }
        var out: [Double] = []
        out.reserveCapacity(x.count)
        var sum = 0.0
        for i in 0..<x.count {
            sum += x[i]
            if i >= window { sum -= x[i - window] }
            out.append(sum / Double(min(i + 1, window)))
        }
        return out
    }

    // MARK: Calendar aggregation

    public static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    public static func weekKey(_ date: Date, calendar: Calendar) -> String {
        var cal = calendar
        cal.firstWeekday = 2 // Monday
        let comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        guard let start = cal.date(from: comps) else { return dayKey(date, calendar: calendar) }
        return dayKey(start, calendar: calendar)
    }

    public static func date(fromDayKey key: String, calendar: Calendar) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    /// Groups timestamped values by calendar day and summarises each day with `method`.
    /// For `.durationHours` the value of each point must already be a duration in seconds.
    public static func dailyAggregates(_ points: [(Date, Double)], method: AggregationMethod,
                                       calendar: Calendar) -> [DailyAggregate] {
        var groups: [String: [Double]] = [:]
        var latest: [String: (Date, Double)] = [:]
        for (d, v) in points where v.isFinite {
            let k = dayKey(d, calendar: calendar)
            groups[k, default: []].append(v)
            if let l = latest[k] { if d > l.0 { latest[k] = (d, v) } } else { latest[k] = (d, v) }
        }
        return groups.keys.sorted().map { k in
            let vals = groups[k]!
            var a = DailyAggregate(day: k, count: vals.count)
            a.minimum = vals.min(); a.maximum = vals.max()
            a.standardDeviation = standardDeviation(vals)
            a.median = median(vals)
            switch method {
            case .sum: a.sum = vals.reduce(0, +); a.mean = a.sum
            case .mean: a.mean = mean(vals)
            case .durationHours: a.sum = vals.reduce(0, +) / 3600; a.mean = a.sum
            case .latest: a.mean = latest[k]?.1
            case .count: a.sum = Double(vals.count); a.mean = a.sum
            }
            return a
        }
    }

    /// Daily value used for cross-metric work: the aggregate's `mean` field (which holds the sum for
    /// summed metrics, the mean for averaged ones, hours for sleep).
    public static func dailyValue(_ a: DailyAggregate) -> Double? { a.mean }

    public static func weeklyAggregates(_ daily: [DailyAggregate], method: AggregationMethod,
                                        calendar: Calendar) -> [WeeklyAggregate] {
        var groups: [String: [Double]] = [:]
        for d in daily {
            guard let date = date(fromDayKey: d.day, calendar: calendar), let v = dailyValue(d) else { continue }
            groups[weekKey(date, calendar: calendar), default: []].append(v)
        }
        return groups.keys.sorted().map { k in
            let vals = groups[k]!
            var w = WeeklyAggregate(weekStart: k, days: vals.count)
            w.mean = mean(vals); w.median = median(vals); w.standardDeviation = standardDeviation(vals)
            w.sum = vals.reduce(0, +)
            return w
        }
    }

    // MARK: Sampling and coverage

    public static func samplingFrequency(_ dates: [Date]) -> SamplingFrequencyReport {
        let s = dates.sorted()
        guard s.count >= 2 else {
            return SamplingFrequencyReport(sampleCount: s.count, spanSeconds: 0, medianIntervalSeconds: nil,
                                           meanIntervalSeconds: nil, samplesPerDay: nil, largestGapSeconds: nil,
                                           largestGapStart: nil, isContinuous: false,
                                           note: s.isEmpty ? "No samples." : "One sample; frequency undefined.")
        }
        var intervals: [Double] = []
        intervals.reserveCapacity(s.count - 1)
        var largest = 0.0
        var largestStart = s[0]
        for i in 1..<s.count {
            let dt = s[i].timeIntervalSince(s[i - 1])
            intervals.append(dt)
            if dt > largest { largest = dt; largestStart = s[i - 1] }
        }
        let span = s.last!.timeIntervalSince(s.first!)
        let med = median(intervals)
        let perDay = span > 0 ? Double(s.count) / (span / 86400) : nil
        // "Continuous" here only means the median gap is under 15 minutes. HRV, for instance, is
        // usually sampled a few times a day and must not be treated as a continuous signal.
        let continuous = (med ?? .infinity) < 900
        let note = continuous
            ? "Median interval under 15 min: dense sampling."
            : "Sparse or irregular sampling: treat as point measurements, not a continuous signal."
        return SamplingFrequencyReport(sampleCount: s.count, spanSeconds: span, medianIntervalSeconds: med,
                                       meanIntervalSeconds: mean(intervals), samplesPerDay: perDay,
                                       largestGapSeconds: largest, largestGapStart: largestStart,
                                       isContinuous: continuous, note: note)
    }

    public static func coverage(daily: [DailyAggregate], range: DateRange, calendar: Calendar) -> CoverageReport {
        let startDay = calendar.startOfDay(for: range.start)
        let endDay = calendar.startOfDay(for: range.end)
        let days = max(0, (calendar.dateComponents([.day], from: startDay, to: endDay).day ?? 0)) + 1
        let have = Set(daily.map { $0.day })
        var missing: [String] = []
        var cursor = startDay
        for _ in 0..<min(days, 3660) {
            let k = dayKey(cursor, calendar: calendar)
            if !have.contains(k) { missing.append(k) }
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        let with = days - missing.count
        return CoverageReport(rangeStart: range.start, rangeEnd: range.end, daysInRange: days, daysWithData: with,
                              coverageFraction: days > 0 ? Double(with) / Double(days) : 0, missingDays: missing)
    }

    // MARK: Outliers

    /// Robust z-score: |x − median| / (1.4826 × MAD) above `threshold` (3.5 by Iglewicz–Hoaglin).
    public static func outliers(daily: [DailyAggregate], threshold: Double = 3.5) -> OutlierReport {
        let pts = daily.compactMap { a in dailyValue(a).map { (a.day, $0) } }
        let vals = pts.map { $0.1 }
        guard vals.count >= 5, let med = median(vals), let mad = medianAbsoluteDeviation(vals), mad > 0 else {
            return OutlierReport(method: "robust_z_mad", threshold: threshold, outlierCount: 0, outlierDays: [])
        }
        let scale = 1.4826 * mad
        let days = pts.filter { abs($0.1 - med) / scale > threshold }.map { $0.0 }
        return OutlierReport(method: "robust_z_mad", threshold: threshold, outlierCount: days.count, outlierDays: days)
    }

    // MARK: Longitudinal change

    /// Compares the first and last quarter of the daily series and fits a least-squares slope.
    public static func longitudinalChange(metric: String, unit: String?, daily: [DailyAggregate],
                                          calendar: Calendar) -> LongitudinalChange? {
        let pts = daily.compactMap { a -> (String, Date, Double)? in
            guard let v = dailyValue(a), let d = date(fromDayKey: a.day, calendar: calendar) else { return nil }
            return (a.day, d, v)
        }
        guard pts.count >= 8 else { return nil }
        let q = max(2, pts.count / 4)
        let first = Array(pts.prefix(q)), last = Array(pts.suffix(q))
        let fm = median(first.map { $0.2 }), lm = median(last.map { $0.2 })
        let t0 = pts[0].1
        let xs = pts.map { $0.1.timeIntervalSince(t0) / 86400 }
        let ys = pts.map { $0.2 }
        let slope = linearSlope(xs, ys)
        var c = LongitudinalChange(metric: metric, unit: unit,
                                   firstPeriod: "\(first.first!.0)…\(first.last!.0)", firstPeriodMedian: fm,
                                   lastPeriod: "\(last.first!.0)…\(last.last!.0)", lastPeriodMedian: lm,
                                   absoluteChange: nil, relativeChange: nil, slopePerDay: slope, daysCovered: pts.count)
        if let fm, let lm {
            c.absoluteChange = lm - fm
            if fm != 0 { c.relativeChange = (lm - fm) / abs(fm) }
        }
        return c
    }

    public static func linearSlope(_ x: [Double], _ y: [Double]) -> Double? {
        guard x.count == y.count, x.count >= 2, let mx = mean(x), let my = mean(y) else { return nil }
        var num = 0.0, den = 0.0
        for i in 0..<x.count { num += (x[i] - mx) * (y[i] - my); den += (x[i] - mx) * (x[i] - mx) }
        return den > 0 ? num / den : nil
    }

    // MARK: Correlation

    public static func pearson(_ x: [Double], _ y: [Double]) -> Double? {
        guard x.count == y.count, x.count >= 3, let mx = mean(x), let my = mean(y) else { return nil }
        var sxy = 0.0, sxx = 0.0, syy = 0.0
        for i in 0..<x.count {
            let dx = x[i] - mx, dy = y[i] - my
            sxy += dx * dy; sxx += dx * dx; syy += dy * dy
        }
        guard sxx > 0, syy > 0 else { return nil }
        return sxy / (sxx * syy).squareRoot()
    }

    /// Average ranks for ties.
    public static func ranks(_ x: [Double]) -> [Double] {
        let idx = x.indices.sorted { x[$0] < x[$1] }
        var r = [Double](repeating: 0, count: x.count)
        var i = 0
        while i < idx.count {
            var j = i
            while j + 1 < idx.count, x[idx[j + 1]] == x[idx[i]] { j += 1 }
            let avg = Double(i + j) / 2 + 1
            for k in i...j { r[idx[k]] = avg }
            i = j + 1
        }
        return r
    }

    public static func spearman(_ x: [Double], _ y: [Double]) -> Double? {
        guard x.count == y.count, x.count >= 3 else { return nil }
        return pearson(ranks(x), ranks(y))
    }

    /// Correlates two daily series by day key. `lagDays` > 0 means A on day d is paired with B on day d + lag.
    public static func correlate(metricA: String, a: [String: Double], metricB: String, b: [String: Double],
                                 lagDays: Int, calendar: Calendar, minimumPairs: Int = 7) -> CorrelationResult {
        var xs: [Double] = [], ys: [Double] = []
        for (day, va) in a {
            guard let d = date(fromDayKey: day, calendar: calendar),
                  let shifted = calendar.date(byAdding: .day, value: lagDays, to: d) else { continue }
            if let vb = b[dayKey(shifted, calendar: calendar)] { xs.append(va); ys.append(vb) }
        }
        var r = CorrelationResult(metricA: metricA, metricB: metricB, lagDays: lagDays, pairedPoints: xs.count,
                                  pearsonR: nil, spearmanRho: nil, note: "")
        if xs.count < minimumPairs {
            r.note = "Only \(xs.count) paired days; fewer than \(minimumPairs). Not computed."
            return r
        }
        r.pearsonR = pearson(xs, ys)
        r.spearmanRho = spearman(xs, ys)
        r.note = "Descriptive association over \(xs.count) paired days. Not a causal estimate; no significance test applied."
        return r
    }

    // MARK: Reference range

    public static func referenceRange(metric: String, unit: String?, daily: [DailyAggregate],
                                      coverage: CoverageReport?, calendar: Calendar) -> ReferenceRange? {
        let vals = daily.compactMap { dailyValue($0) }
        guard !vals.isEmpty else { return nil }
        let d = describe(vals)
        var r = ReferenceRange(metric: metric, unit: unit, sampleCount: daily.reduce(0) { $0 + $1.count },
                               daysCovered: vals.count, median: d.median, medianAbsoluteDeviation: d.medianAbsoluteDeviation,
                               percentile5: d.percentile5, percentile25: d.percentile25, percentile75: d.percentile75,
                               percentile95: d.percentile95, mean: d.mean, standardDeviation: d.standardDeviation,
                               lowerUsual: nil, upperUsual: nil, coverageFraction: coverage?.coverageFraction,
                               firstDate: daily.first.flatMap { date(fromDayKey: $0.day, calendar: calendar) },
                               lastDate: daily.last.flatMap { date(fromDayKey: $0.day, calendar: calendar) })
        if let m = d.median, let mad = d.medianAbsoluteDeviation, mad > 0 {
            let scale = 1.4826 * mad
            r.lowerUsual = m - 2.5 * scale
            r.upperUsual = m + 2.5 * scale
        }
        return r
    }

    // MARK: Signal helpers (used by the facial analyzer)

    /// Zero-crossing rate of the mean-removed signal, in crossings per second.
    public static func zeroCrossingRate(_ x: [Double], durationSeconds: Double) -> Double? {
        guard x.count >= 3, durationSeconds > 0, let m = mean(x) else { return nil }
        var crossings = 0
        var prev = x[0] - m
        for v in x.dropFirst() {
            let c = v - m
            if (c > 0 && prev < 0) || (c < 0 && prev > 0) { crossings += 1 }
            if c != 0 { prev = c }
        }
        // Two crossings per cycle.
        return Double(crossings) / 2 / durationSeconds
    }
}
