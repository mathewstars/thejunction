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
