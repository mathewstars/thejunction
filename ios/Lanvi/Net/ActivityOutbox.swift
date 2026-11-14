import Foundation

/// Small JSON files in Application Support: the activities not sent yet, and
/// the last "today" the server gave, so the app has something to show offline.
enum LanviDisk {
    private static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lanvi", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    static func load<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(name)) else { return nil }
        return try? API.decoder.decode(T.self, from: data)
    }

    static func save<T: Encodable>(_ value: T, _ name: String) {
        guard let data = try? API.encoder.encode(value) else { return }
        try? data.write(to: folder.appendingPathComponent(name), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    static func remove(_ name: String) {
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
    }
}

/// Answers to a suggestion that have not reached the server yet (same idea as
/// the activity outbox; each keeps its own id, so a repeat is safe).
struct FeedbackOutbox {
    private static let file = "feedback-outbox.json"
    private(set) var items: [API.FeedbackIn]

    init() { items = LanviDisk.load([API.FeedbackIn].self, Self.file) ?? [] }

    mutating func add(_ f: API.FeedbackIn) {
        guard !items.contains(where: { $0.id == f.id }) else { return }
        items.append(f)
        LanviDisk.save(items, Self.file)
    }

    mutating func remove(id: String) {
        items.removeAll { $0.id == id }
        LanviDisk.save(items, Self.file)
    }
}

/// Days spent with Lanvi, kept on the phone. Only ever grows: a day is added
/// when something was done together, and nothing is ever removed.
struct DaysTogether: Codable, Equatable {
    var dates: [String] = []          // yyyy-MM-dd, local time
    var today: String = ""
    var kindsToday: [String] = []     // activity kinds done today
    var done: DoneToday?              // today's one thing, once done

    static func load(_ file: String) -> DaysTogether { LanviDisk.load(DaysTogether.self, file) ?? DaysTogether() }
    func save(_ file: String) { LanviDisk.save(self, file) }

    static func key(_ date: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    /// A new day starts with a fresh "today", the count stays.
    mutating func roll(to date: Date) {
        let k = Self.key(date)
        if today != k {
            today = k
            kindsToday = []
            done = nil
        }
    }

    mutating func markTogether(_ date: Date) {
        roll(to: date)
        if !dates.contains(today) { dates.append(today) }
    }
}

/// Today's one thing, done: what it was and a tiny log line.
struct DoneToday: Codable, Equatable {
    var kind: String       // focus, breathing, checkin, or a real-world action
    var log: String        // "Breathed together, 1 min"
    var restful: Bool = false   // "Not today": calm, no log
}

/// Finished activities that have not reached the server yet. Each keeps its own
/// id, so sending one twice is safe (the server answers the repeat with 0 XP).
struct ActivityOutbox {
    private static let file = "outbox.json"
    private(set) var items: [API.ActivityIn]

    init() { items = LanviDisk.load([API.ActivityIn].self, Self.file) ?? [] }

    mutating func add(_ a: API.ActivityIn) {
        guard !items.contains(where: { $0.id == a.id }) else { return }
        items.append(a)
        LanviDisk.save(items, Self.file)
    }

    mutating func remove(id: String) {
        items.removeAll { $0.id == id }
        LanviDisk.save(items, Self.file)
    }
}
