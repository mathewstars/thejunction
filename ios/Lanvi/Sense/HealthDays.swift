import Foundation

/// One day for `POST /v1/daily`, field for field as `DayIn` in `docs/api/openapi.json`:
/// `date` (yyyy-MM-dd), `steps` (whole steps, required), `walking_speed_m_s` (m/s),
/// `hrv_ms` (SDNN, ms, watch only), `sleep_h` (hours asleep, watch only).
struct HealthDay: Codable, Equatable, Sendable {
    var date: String
    var steps: Int
    var walkingSpeedMS: Double?
    var hrvMs: Double?
    var sleepH: Double?

    enum CodingKeys: String, CodingKey {
        case date, steps
        case walkingSpeedMS = "walking_speed_m_s"
        case hrvMs = "hrv_ms"
        case sleepH = "sleep_h"
    }
}

/// Where the days come from: Apple Health on a real phone, sample days in the
/// simulator and the offline demo. Same shape either way.
protocol HealthSource: Sendable {
    /// Shows the system permission sheet. True when the sheet was answered
    /// (HealthKit never says whether reading was allowed; an empty answer is normal).
    func requestAccess() async -> Bool
    /// Whole days from `first` to `last` (both yyyy-MM-dd, local time), only days with steps.
    func days(from first: Date, through last: Date) async -> [HealthDay]
}

enum HealthCalendar {
    static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = .current
        return c
    }

    static func key(_ date: Date) -> String {
        let f = DateFormatter()
        f.calendar = calendar
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    static func date(_ key: String) -> Date? {
        let f = DateFormatter()
        f.calendar = calendar
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: key)
    }

    static func startOfDay(_ d: Date) -> Date { calendar.startOfDay(for: d) }

    static func addDays(_ n: Int, to d: Date) -> Date {
        calendar.date(byAdding: .day, value: n, to: d) ?? d.addingTimeInterval(Double(n) * 86_400)
    }
}

// Apple Health itself is read through Peter's `HealthKitManager`: see `HarnessHealth.swift`.

/// Sleep arithmetic, kept apart so it can be tested without HealthKit.
enum SleepMath {
    /// Merges overlapping stretches, then sums each merged stretch into the day it ended on.
    static func hoursPerDay(_ spans: [(Date, Date)], from start: Date, to end: Date) -> [String: Double] {
        let sorted = spans.filter { $0.1 > $0.0 }.sorted { $0.0 < $1.0 }
        var merged: [(Date, Date)] = []
        for s in sorted {
            if let last = merged.last, s.0 <= last.1 {
                merged[merged.count - 1].1 = max(last.1, s.1)
            } else {
                merged.append(s)
            }
        }
        var out: [String: Double] = [:]
        for m in merged where m.1 >= start && m.1 < end {
            out[HealthCalendar.key(m.1), default: 0] += m.1.timeIntervalSince(m.0) / 3600
        }
        // A day with more than 20 hours "asleep" is a recording mistake, not a night.
        return out.filter { $0.value > 0 && $0.value <= 20 }
    }
}

// MARK: - Sample days (simulator, offline demo)

/// Believable days so the whole flow can be shown without a real phone: a person
/// who walks a bit more on weekends, sleeps around seven hours, with a watch on
/// most nights. The same numbers every time (seeded), so screenshots repeat.
///
/// `-sampleDays N` sets how many days of history the "phone" holds (default 90),
/// `-sampleDip` makes the last five days quieter (fewer steps, slower, shorter sleep).
struct SampleHealthSource: HealthSource {
    var historyDays: Int
    var dip: Bool

    init(arguments: [String] = ProcessInfo.processInfo.arguments) {
        func value(_ key: String) -> String? {
            guard let i = arguments.firstIndex(of: key), i + 1 < arguments.count else { return nil }
            return arguments[i + 1]
        }
        historyDays = value("-sampleDays").flatMap(Int.init).map { min(max($0, 0), 400) } ?? 90
        dip = arguments.contains("-sampleDip")
    }

    init(historyDays: Int, dip: Bool = false) {
        self.historyDays = historyDays
        self.dip = dip
    }

    func requestAccess() async -> Bool { true }

    func days(from first: Date, through last: Date) async -> [HealthDay] {
        let today = HealthCalendar.startOfDay(Date())
        let oldest = HealthCalendar.addDays(-historyDays, to: today)
        var out: [HealthDay] = []
        var d = max(HealthCalendar.startOfDay(first), oldest)
        let stop = min(HealthCalendar.startOfDay(last), HealthCalendar.addDays(-1, to: today))
        while d <= stop {
            out.append(Self.day(d, today: today, dip: dip))
            d = HealthCalendar.addDays(1, to: d)
        }
        return out
    }

    static func day(_ d: Date, today: Date, dip: Bool) -> HealthDay {
        let key = HealthCalendar.key(d)
        var rng = SeededRandom(seed: UInt64(abs(key.hashValueStable)))
        let weekday = HealthCalendar.calendar.component(.weekday, from: d)   // 1 Sunday ... 7 Saturday
        let weekend = weekday == 1 || weekday == 7
        let daysAgo = HealthCalendar.calendar.dateComponents([.day], from: d, to: today).day ?? 0
        let low = dip && daysAgo <= 5

        var steps = (weekend ? 8200.0 : 6400.0) + rng.normal() * 1100
        var speed = 1.27 + rng.normal() * 0.04
        var sleep = 7.1 + rng.normal() * 0.5
        var hrv = 44 + rng.normal() * 6
        if low {
            steps *= 0.45
            speed -= 0.12
            sleep -= 1.4
            hrv -= 9
        }
        let watch = rng.next() % 10 != 0   // the watch stays on the charger now and then
        return HealthDay(date: key,
                         steps: max(300, Int(steps.rounded())),
                         walkingSpeedMS: (max(0.6, speed) * 100).rounded() / 100,
                         hrvMs: watch ? (max(12, hrv) * 10).rounded() / 10 : nil,
                         sleepH: watch ? (min(max(3.5, sleep), 10) * 100).rounded() / 100 : nil)
    }
}

/// Small repeatable random numbers (SplitMix64), so sample days look the same every run.
struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }

    /// Roughly normal, mean 0, sd 1 (Box-Muller).
    mutating func normal() -> Double {
        let u = max(unit(), 1e-12)
        let v = unit()
        return sqrt(-2 * log(u)) * cos(2 * .pi * v)
    }
}

private extension String {
    /// A hash that is the same on every launch (Swift's own hashValue is not).
    var hashValueStable: Int64 {
        var h: UInt64 = 1_469_598_103_934_665_603
        for b in utf8 { h = (h ^ UInt64(b)) &* 1_099_511_628_211 }
        return Int64(bitPattern: h & 0x7FFF_FFFF_FFFF_FFFF)
    }
}
