import XCTest
@testable import Lanvi

final class HealthTests: XCTestCase {

    func testDayUsesTheServerNamesAndLeavesOutMissingValues() throws {
        let watch = HealthDay(date: "2026-11-13", steps: 6400, walkingSpeedMS: 1.24, hrvMs: 42, sleepH: 7.1)
        let phone = HealthDay(date: "2026-11-12", steps: 5100, walkingSpeedMS: 1.2)
        let data = try JSONEncoder().encode(["days": [watch, phone]])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: [[String: Any]]])
        let days = try XCTUnwrap(json["days"])
        XCTAssertEqual(Set(days[0].keys), ["date", "steps", "walking_speed_m_s", "hrv_ms", "sleep_h"])
        XCTAssertEqual(days[0]["walking_speed_m_s"] as? Double, 1.24)
        XCTAssertEqual(days[0]["steps"] as? Int, 6400)
        // No watch: no hrv_ms, no sleep_h (not null, simply absent).
        XCTAssertEqual(Set(days[1].keys), ["date", "steps", "walking_speed_m_s"])
    }

    func testSleepMergesOverlapsAndCountsTheMorning() throws {
        let cal = HealthCalendar.calendar
        let day = try XCTUnwrap(cal.date(from: DateComponents(year: 2026, month: 11, day: 13)))
        func at(_ h: Double) -> Date { day.addingTimeInterval(h * 3600) }
        // Watch: 23:00 to 06:30. Phone: 00:00 to 07:00 (overlaps). A nap at 14:00 for 30 min.
        let spans = [(at(-1), at(6.5)), (at(0), at(7)), (at(14), at(14.5))]
        let out = SleepMath.hoursPerDay(spans, from: day, to: day.addingTimeInterval(86_400))
        XCTAssertEqual(out["2026-11-13"] ?? 0, 8.5, accuracy: 0.001)   // 23:00 to 07:00, plus the nap
        XCTAssertNil(out["2026-11-12"])
    }

    @MainActor
    func testWindowIsTheHistoryFirstThenTheMissingDays() throws {
        let today = HealthCalendar.startOfDay(Date())
        let first = HealthSync.window(lastSent: nil, today: today)
        XCTAssertEqual(HealthCalendar.calendar.dateComponents([.day], from: first.first, to: today).day, 400)
        XCTAssertEqual(first.last, HealthCalendar.addDays(-1, to: today))

        let fourDaysAgo = HealthCalendar.key(HealthCalendar.addDays(-4, to: today))
        let later = HealthSync.window(lastSent: fourDaysAgo, today: today)
        // Two days before the last one sent (a watch may sync late), through yesterday.
        XCTAssertEqual(HealthCalendar.key(later.first), HealthCalendar.key(HealthCalendar.addDays(-6, to: today)))
    }

    func testSampleDaysAreBelievableAndNeverToday() async {
        let src = SampleHealthSource(historyDays: 60)
        let today = HealthCalendar.startOfDay(Date())
        let days = await src.days(from: HealthCalendar.addDays(-400, to: today), through: today)
        XCTAssertEqual(days.count, 60)
        XCTAssertFalse(days.contains { $0.date == HealthCalendar.key(today) })
        XCTAssertEqual(Set(days.map(\.date)).count, days.count, "one record per day")
        for d in days {
            XCTAssert((300...20_000).contains(d.steps))
            XCTAssert((0.6...2.0).contains(d.walkingSpeedMS ?? 0))
            if let s = d.sleepH { XCTAssert((3.5...10).contains(s)) }
        }
        XCTAssert(days.contains { $0.sleepH == nil }, "some nights without the watch")
        // Same numbers on every run.
        let again = await src.days(from: HealthCalendar.addDays(-400, to: today), through: today)
        XCTAssertEqual(days, again)
    }

    func testSampleDipIsQuieter() async {
        let today = HealthCalendar.startOfDay(Date())
        let calm = await SampleHealthSource(historyDays: 30).days(from: HealthCalendar.addDays(-5, to: today), through: today)
        let dip = await SampleHealthSource(historyDays: 30, dip: true).days(from: HealthCalendar.addDays(-5, to: today), through: today)
        XCTAssertLessThan(dip.map(\.steps).reduce(0, +), calm.map(\.steps).reduce(0, +) * 6 / 10)
    }

    func testDemoUploaderNeedsTwoWeeksForABaseline() async throws {
        let up = DemoDailyUploader()
        let src = SampleHealthSource(historyDays: 10)
        let today = HealthCalendar.startOfDay(Date())
        let ten = await src.days(from: HealthCalendar.addDays(-30, to: today), through: today)
        let first = try await up.upload(ten)
        XCTAssertEqual(first.status, "no_baseline")
        let more = await SampleHealthSource(historyDays: 30).days(from: HealthCalendar.addDays(-30, to: today), through: today)
        let second = try await up.upload(more)
        XCTAssertEqual(second.status, "within")
        XCTAssertEqual(second.accepted.count, 30)
    }
}
