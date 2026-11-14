import Foundation
import Harness
#if canImport(HealthKit)
import HealthKit
#endif

/// The four Apple Health types Lanvi reads, taken from Peter's `HealthTypeCatalog`.
/// Nothing else is asked for: "I only look at how much you move and sleep."
enum LanviHealthTypes {
    static let stepsID = "HKQuantityTypeIdentifierStepCount"
    static let walkingSpeedID = "HKQuantityTypeIdentifierWalkingSpeed"
    static let hrvID = "HKQuantityTypeIdentifierHeartRateVariabilitySDNN"
    static let sleepID = "HKCategoryTypeIdentifierSleepAnalysis"

    static let all: [HealthTypeDescriptor] =
        [stepsID, walkingSpeedID, hrvID, sleepID].compactMap(HealthTypeCatalog.descriptor(for:))
}

#if canImport(HealthKit)
/// Apple Health through Peter's `HealthKitManager` (the harness on `finalish-testing-app`):
/// his permission request limited to our four types, his HealthKit-merged daily step
/// totals, his historical sample reader and his summary builder for the daily means.
/// The only Lanvi part is `HealthDayAdapter`, which turns his output into the exact
/// `POST /v1/daily` days.
@MainActor
final class HarnessHealthSource: HealthSource {
    nonisolated static var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    private let hk: HealthKitManager = {
        let m = HealthKitManager()
        m.calendar = HealthCalendar.calendar
        return m
    }()

    func requestAccess() async -> Bool {
        do {
            _ = try await hk.requestHealthPermissions(types: LanviHealthTypes.all)
            return true
        } catch {
            return false
        }
    }

    func days(from first: Date, through last: Date) async -> [HealthDay] {
        guard hk.checkHealthKitAvailability().isAvailable else { return [] }
        let start = HealthCalendar.startOfDay(first)
        let end = HealthCalendar.addDays(1, to: HealthCalendar.startOfDay(last))
        func type(_ id: String) -> HealthTypeDescriptor? { HealthTypeCatalog.descriptor(for: id) }

        // A type that was not allowed or has no data simply gives nothing (no watch is normal).
        var steps: [HealthSample] = []
        if let d = type(LanviHealthTypes.stepsID) {
            steps = (try? await hk.fetchDailyStatistics(type: d, from: start, to: end)) ?? []
        }
        var means: [HealthSample] = []
        for id in [LanviHealthTypes.walkingSpeedID, LanviHealthTypes.hrvID] {
            guard let d = type(id) else { continue }
            means += (try? await hk.fetchHistoricalSamples(type: d, from: start, to: end)) ?? []
        }
        var sleep: [HealthSample] = []
        if let d = type(LanviHealthTypes.sleepID) {
            // Nights that end on the first day began the evening before.
            sleep = (try? await hk.fetchHistoricalSamples(type: d, from: start.addingTimeInterval(-18 * 3600), to: end)) ?? []
        }
        let summary = hk.generateHealthDataSummary(samples: means, range: DateRange(start: start, end: end))
        return HealthDayAdapter.days(steps: steps, summary: summary, sleep: sleep, from: start, to: end)
    }
}
#endif

/// Peter's output to `POST /v1/daily` days (`DayIn` in `docs/api/openapi.json`).
/// Plain data in, plain data out, so it is tested without HealthKit.
enum HealthDayAdapter {
    /// - steps: Peter's `fetchDailyStatistics` result (one HealthKit-merged total per day).
    /// - summary: Peter's `HealthDataSummary`; walking speed and HRV are its daily means.
    /// - sleep: Peter's sleep-analysis samples. Hours asleep use `SleepMath` rather than
    ///   the summary's sleep metric: a watch writes a night as many stage pieces, and the
    ///   summary credits each piece to the day it ended, so the part before midnight would
    ///   land on the wrong day. `SleepMath` joins the pieces into one night first.
    /// Only days with steps are sent (the server requires `steps`).
    static func days(steps: [HealthSample], summary: HealthDataSummary, sleep: [HealthSample],
                     from start: Date, to end: Date) -> [HealthDay] {
        let cal = HealthCalendar.calendar
        var stepsByDay: [String: Double] = [:]
        for s in steps {
            guard let v = s.value, v.isFinite, v >= 0 else { continue }
            stepsByDay[LocalStatistics.dayKey(s.startDate, calendar: cal)] = v
        }
        func dailyMeans(_ id: String) -> [String: Double] {
            guard let m = summary.metrics.first(where: { $0.typeIdentifier == id }) else { return [:] }
            var out: [String: Double] = [:]
            for d in m.daily { if let v = d.mean, v.isFinite { out[d.day] = v } }
            return out
        }
        let speed = dailyMeans(LanviHealthTypes.walkingSpeedID)
        let hrv = dailyMeans(LanviHealthTypes.hrvID)
        let asleep = sleep
            .filter { $0.categoryValue.map(HealthTypeCatalog.isAsleep(categoryValue:)) ?? false }
            .map { ($0.startDate, $0.endDate) }
        let sleepH = SleepMath.hoursPerDay(asleep, from: start, to: end)

        var out: [HealthDay] = []
        var d = HealthCalendar.startOfDay(start)
        while d < end {
            let k = HealthCalendar.key(d)
            if let s = stepsByDay[k] {
                out.append(HealthDay(date: k, steps: Int(s.rounded()),
                                     walkingSpeedMS: speed[k].map { ($0 * 100).rounded() / 100 },
                                     hrvMs: hrv[k].map { ($0 * 10).rounded() / 10 },
                                     sleepH: sleepH[k].map { ($0 * 100).rounded() / 100 }))
            }
            d = HealthCalendar.addDays(1, to: d)
        }
        return out
    }
}
