import Foundation

/// `POST /v1/daily` answer (`DailyOut`).
struct DailyResult: Decodable, Equatable, Sendable {
    struct Rejected: Decodable, Equatable, Sendable {
        var date: String
        var reason: String
    }
    var accepted: [String]
    var rejected: [Rejected]
    var status: String
}

/// Where the days go: the real server, or the offline demo.
protocol DailyUploader: Sendable {
    func upload(_ days: [HealthDay]) async throws -> DailyResult
}

/// The real server. Uses the device token the app got at pairing (the Keychain
/// holds it once the store has talked to the server); no token yet means "later".
struct LiveDailyUploader: DailyUploader {
    var base: URL

    func upload(_ days: [HealthDay]) async throws -> DailyResult {
        guard let token = TokenKeychain.token(for: base) else { throw APIError.unauthorized }
        var req = URLRequest(url: base.appendingPathComponent("/v1/daily"))
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONEncoder().encode(["days": days])
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession(configuration: .ephemeral).data(for: req)
        } catch {
            throw APIError.offline
        }
        guard let http = response as? HTTPURLResponse else { throw APIError.offline }
        switch http.statusCode {
        case 200..<300:
            guard let out = try? JSONDecoder().decode(DailyResult.self, from: data) else { throw APIError.unreadable }
            return out
        case 401, 403: throw APIError.unauthorized
        case 429: throw APIError.rateLimited
        case 500...: throw APIError.server
        default: throw APIError.rejected("daily_\(http.statusCode)")
        }
    }
}

/// Offline demo: keeps the days in memory and answers like the server would
/// (fewer than 14 days is "no_baseline").
actor DemoDailyUploader: DailyUploader {
    private var held: [String: HealthDay] = [:]

    func upload(_ days: [HealthDay]) async throws -> DailyResult {
        try? await Task.sleep(for: .milliseconds(300))
        for d in days { held[d.date] = d }
        return DailyResult(accepted: days.map(\.date), rejected: [],
                           status: held.count < 14 ? "no_baseline" : "within")
    }
}

/// Apple Health to the server: the history once, then the missing days each time
/// the app opens. Quiet: never blocks a screen, retries a little on its own,
/// and otherwise tries again on the next open. Re-sending a day is safe (the
/// server upserts by date).
///
/// Launch arguments: `-healthReset` forgets the answer and what was sent,
/// `-healthAsk` shows the first-run screen again, `-healthAllowed` counts as
/// allowed without the screen (simulator tests), `-sampleHealth` uses sample
/// days on a real phone. The simulator and the offline demo always use sample days.
@MainActor
final class HealthSync {
    static let shared = HealthSync()

    /// The server takes at most this many days in one call.
    static let maxDays = 400

    private enum Key {
        static let asked = "lanvi.health.asked"
        static let allowed = "lanvi.health.allowed"
        static func sent(_ scope: String) -> String { "lanvi.health.sent.\(scope)" }
    }

    private let defaults = UserDefaults.standard
    private var running = false
    private var retryTask: Task<Void, Never>?
    /// Offline demo days live only as long as the app runs.
    private var demoUploader = DemoDailyUploader()
    private var demoSent: String?
    /// The last answer, for the first-run screen and the logs.
    private(set) var lastResult: DailyResult?

    private init() {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-healthReset") {
            for k in defaults.dictionaryRepresentation().keys where k.hasPrefix("lanvi.health.") {
                defaults.removeObject(forKey: k)
            }
        }
        if args.contains("-healthAllowed") {
            defaults.set(true, forKey: Key.asked)
            defaults.set(true, forKey: Key.allowed)
        }
    }

    var asked: Bool { defaults.bool(forKey: Key.asked) }
    var allowed: Bool { defaults.bool(forKey: Key.allowed) }

    /// The first-run screen should show: not asked yet, and there is something to read.
    var shouldAsk: Bool {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-healthAsk") { return true }
        if args.contains("-demo") { return false }
        return !asked && hasSource
    }

    private var hasSource: Bool {
        #if canImport(HealthKit)
        return Self.useSamples || HealthKitSource.isAvailable
        #else
        return true
        #endif
    }

    private static var useSamples: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return ProcessInfo.processInfo.arguments.contains("-sampleHealth") || !ServerConfig.current.isLive
        #endif
    }

    private func source() -> (any HealthSource)? {
        if Self.useSamples { return SampleHealthSource() }
        #if canImport(HealthKit)
        return HealthKitSource.isAvailable ? HealthKitSource() : nil
        #else
        return nil
        #endif
    }

    // MARK: The first-run screen

    /// "Allow": the system sheet, then the history upload. Answers the number of days
    /// the server took (nil when nothing could be sent yet; it will be sent later).
    func allow(_ store: AppStore) async -> Int? {
        defaults.set(true, forKey: Key.asked)
        guard let src = source() else { return nil }
        let answered = await src.requestAccess()
        defaults.set(answered, forKey: Key.allowed)
        guard answered else { return nil }
        // Make sure the store has paired before the first upload.
        await store.start()
        let result = await sync(store)
        return result?.accepted.count
    }

    /// "Not now": the app works without it. Not asked again by itself.
    func skip() {
        defaults.set(true, forKey: Key.asked)
        defaults.set(false, forKey: Key.allowed)
    }

    // MARK: Sending

    /// Sends the days the server does not have yet. Safe to call often: one run at a time.
    @discardableResult
    func sync(_ store: AppStore) async -> DailyResult? {
        guard allowed, !running, let src = source() else { return nil }
        let uploader: any DailyUploader
        let scope: String?
        switch store.mode {
        case .live:
            guard let base = ServerConfig.current.serverURL else { return nil }
            uploader = LiveDailyUploader(base: base)
            scope = base.absoluteString
        case .demo:
            uploader = demoUploader
            scope = nil
        }
        running = true
        defer { running = false }

        let today = HealthCalendar.startOfDay(Date())
        let yesterday = HealthCalendar.addDays(-1, to: today)
        let lastSent = scope.flatMap { defaults.string(forKey: Key.sent($0)) } ?? (scope == nil ? demoSent : nil)
        let window = Self.window(lastSent: lastSent, today: today)
        guard window.first <= yesterday else { return nil }

        let days = await src.days(from: window.first, through: yesterday).suffix(Self.maxDays)
        let done = HealthCalendar.key(yesterday)
        guard !days.isEmpty else {
            markSent(done, scope: scope)
            return nil
        }
        do {
            let out = try await uploader.upload(Array(days))
            lastResult = out
            markSent(done, scope: scope)
            retryTask?.cancel()
            retryTask = nil
            log("daily: sent \(days.count), accepted \(out.accepted.count), rejected \(out.rejected.count), status \(out.status)")
            if !out.accepted.isEmpty { await store.refresh() }
            return out
        } catch let e as APIError where e.isTemporary || e == .unreadable {
            log("daily: will try again (\(e))")
            scheduleRetry(store)
            return nil
        } catch {
            // Refused as a whole (should not happen: bad days come back one by one).
            // Leave the marker, so the next open tries the same days again.
            log("daily: refused (\(error))")
            return nil
        }
    }

    /// Which days to ask Health for. Never sent: the history (up to 400 days).
    /// Otherwise from two days before the last one sent, because a watch may sync
    /// last night's sleep late; re-sending is safe.
    static func window(lastSent: String?, today: Date) -> (first: Date, last: Date) {
        let yesterday = HealthCalendar.addDays(-1, to: today)
        let oldest = HealthCalendar.addDays(-maxDays, to: today)
        guard let key = lastSent, let sent = HealthCalendar.date(key) else { return (oldest, yesterday) }
        return (max(oldest, HealthCalendar.addDays(-2, to: sent)), yesterday)
    }

    private func markSent(_ key: String, scope: String?) {
        if let scope { defaults.set(key, forKey: Key.sent(scope)) } else { demoSent = key }
    }

    /// Two quiet tries more in this session (after 20 s and 90 s), then the next open.
    private func scheduleRetry(_ store: AppStore) {
        guard retryTask == nil else { return }
        retryTask = Task { [weak self] in
            for wait in [20.0, 90.0] {
                try? await Task.sleep(for: .seconds(wait))
                guard !Task.isCancelled, let self else { return }
                if await self.sync(store) != nil { break }
            }
            self?.retryTask = nil
        }
    }

    private func log(_ s: String) {
        #if DEBUG
        print("lanvi-sense: \(s)")
        #endif
    }
}
