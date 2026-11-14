import Foundation

/// Client for the clinic engine (Mathew's server, `engine/`). This is the server-side Gemini
/// integration: the engine computes the face measures from `face_raw`, compares them with the
/// person's own normal, and runs the level-2 "session reading" through Gemini behind its own gates.
///
/// Device calls use the device token from pairing (Keychain). Clinician calls use a short-lived
/// session token kept in memory only. Every call is logged as an `EngineExchange` with secrets removed.
@MainActor
public final class EngineClient: ObservableObject {

    public static let defaultBaseURL = "https://lanvi.app"
    private static let baseURLKey = "engine.baseURL"
    private static let patientIDKey = "engine.patientID"
    private static let deviceTokenKey = "engine.deviceToken"

    @Published public var baseURL: String { didSet { UserDefaults.standard.set(baseURL, forKey: Self.baseURLKey) } }
    @Published public private(set) var patientID: String? { didSet { UserDefaults.standard.set(patientID, forKey: Self.patientIDKey) } }
    @Published public private(set) var hasDeviceToken: Bool
    @Published public private(set) var clinicianLoggedIn = false
    @Published public private(set) var exchanges: [EngineExchange] = []

    private var clinicianToken: String?
    private let session: URLSession

    public init() {
        baseURL = UserDefaults.standard.string(forKey: Self.baseURLKey) ?? Self.defaultBaseURL
        patientID = UserDefaults.standard.string(forKey: Self.patientIDKey)
        hasDeviceToken = !(KeychainStore.get(Self.deviceTokenKey) ?? "").isEmpty
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 60
        c.waitsForConnectivity = true
        session = URLSession(configuration: c)
    }

    public var deviceToken: String? {
        get { KeychainStore.get(Self.deviceTokenKey) }
        set { KeychainStore.set(newValue ?? "", for: Self.deviceTokenKey); hasDeviceToken = !(newValue ?? "").isEmpty }
    }

    public func forgetDevice() {
        deviceToken = nil
        patientID = nil
    }

    // MARK: Device calls

    /// Exchanges the clinic's one-time code for a device token. The code works once.
    public func pair(code: String, deviceLabel: String = "HKGeminiHarness") async throws -> EnginePairOut {
        struct PairIn: Encodable { var pairing_code: String; var device_label: String; var platform = "ios" }
        let out: EnginePairOut = try await call("POST", "/v1/devices/pair", body: PairIn(pairing_code: code, device_label: deviceLabel), auth: .none,
                                                redact: ["pairing_code"])
        deviceToken = out.deviceToken
        patientID = out.patientId
        return out
    }

    public func sendDaily(_ days: [EngineDayRecord]) async throws -> EngineDailyOut {
        try await call("POST", "/v1/daily", body: EngineDailyIn(days: days), auth: .device)
    }

    public func sendActivity(_ activity: EngineActivity) async throws -> EngineActivityOut {
        try await call("POST", "/v1/activities", body: activity, auth: .device, logRequestBody: false)
    }

    public func reading(activityID: String) async throws -> EngineReadingOut {
        try await call("GET", "/v1/activities/\(activityID)/reading", body: Optional<Int>.none, auth: .device)
    }

    /// Polls the session reading until it leaves `pending` or `maxSeconds` pass.
    public func waitForReading(activityID: String, maxSeconds: Double = 120, every: Double = 5) async throws -> EngineReadingOut {
        let deadline = Date().addingTimeInterval(maxSeconds)
        var last = try await reading(activityID: activityID)
        while last.status == "pending", Date() < deadline {
            try await Task.sleep(nanoseconds: UInt64(every * 1_000_000_000))
            last = try await reading(activityID: activityID)
        }
        return last
    }

    public func today() async throws -> JSONValue {
        try await call("GET", "/v1/today", body: Optional<Int>.none, auth: .device)
    }

    // MARK: Clinician calls (to inspect what the server computed and what Gemini said)

    public func clinicLogin(username: String, password: String) async throws {
        struct LoginIn: Encodable { var username: String; var password: String }
        let out: EngineLoginOut = try await call("POST", "/v1/clinic/login", body: LoginIn(username: username, password: password), auth: .none,
                                                 redact: ["password"])
        clinicianToken = out.sessionToken
        clinicianLoggedIn = true
    }

    public func clinicLogout() { clinicianToken = nil; clinicianLoggedIn = false }

    /// Patient detail: activities with the server-computed face summary, z against own normal, the
    /// checked session reading and dropped claims.
    public func patientDetail(patientID id: String? = nil) async throws -> JSONValue {
        guard let pid = id ?? patientID else { throw EngineError(httpStatus: 0, code: "no_patient", message: "Pair a device first (or enter a patient id).", requestId: nil) }
        return try await call("GET", "/v1/clinic/patients/\(pid)", body: Optional<Int>.none, auth: .clinician)
    }

    /// Raw model exchanges: exactly what the engine sent to Gemini (or the local model) and what it answered.
    public func modelExchanges(patientID id: String? = nil, task: String? = "session_reading", limit: Int = 20) async throws -> JSONValue {
        guard let pid = id ?? patientID else { throw EngineError(httpStatus: 0, code: "no_patient", message: "Pair a device first (or enter a patient id).", requestId: nil) }
        var q = "?limit=\(limit)"
        if let task { q += "&task=\(task)" }
        return try await call("GET", "/v1/clinic/patients/\(pid)/exchanges\(q)", body: Optional<Int>.none, auth: .clinician)
    }

    public func clearLog() { exchanges.removeAll() }

    // MARK: Transport

    enum Auth { case none, device, clinician }

    private func call<B: Encodable, R: Decodable>(_ method: String, _ path: String, body: B?, auth: Auth,
                                                  redact: [String] = [], logRequestBody: Bool = true) async throws -> R {
        guard let base = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)), let host = base.host else {
            throw EngineError(httpStatus: 0, code: "bad_url", message: "Engine URL is not set (Settings).", requestId: nil)
        }
        if base.scheme != "https", !(host == "localhost" || host == "127.0.0.1" || host.hasPrefix("192.168.") || host.hasPrefix("10.")) {
            throw EngineError(httpStatus: 0, code: "bad_url", message: "Engine URL must use https (http only for local addresses).", requestId: nil)
        }
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        let pathOnly = path.split(separator: "?", maxSplits: 1).map(String.init)
        components.path = (components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path) + pathOnly[0]
        if pathOnly.count == 2 { components.percentEncodedQuery = pathOnly[1] }
        guard let url = components.url else { throw EngineError(httpStatus: 0, code: "bad_url", message: "Could not build URL for \(path)", requestId: nil) }

        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        switch auth {
        case .none: break
        case .device:
            guard let t = deviceToken, !t.isEmpty else { throw EngineError(httpStatus: 0, code: "not_paired", message: "No device token. Pair first.", requestId: nil) }
            req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
        case .clinician:
            guard let t = clinicianToken else { throw EngineError(httpStatus: 0, code: "not_logged_in", message: "Clinician login needed.", requestId: nil) }
            req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
        }
        var logged: JSONValue? = nil
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let data = try JSONValue.encoder(pretty: false).encode(body)
            req.httpBody = data
            if logRequestBody, var j = try? JSONValue.decoder().decode(JSONValue.self, from: data) {
                if var o = j.objectValue { for k in redact where o[k] != nil { o[k] = .string("<redacted>") }; j = .object(o) }
                logged = j
            } else if !logRequestBody {
                logged = .object(["_note": .string("body not logged (\(data.count) bytes of raw frames); see the preview before sending")])
            }
        }

        let started = Date()
        var ex = EngineExchange(id: UUID().uuidString, at: started, method: method, path: path, request: logged, httpStatus: nil,
                                response: nil, latencyMs: 0, error: nil)
        defer { exchanges.insert(ex, at: 0); if exchanges.count > 200 { exchanges.removeLast() } }
        do {
            let (data, resp) = try await session.data(for: req)
            let http = resp as? HTTPURLResponse
            ex.httpStatus = http?.statusCode
            ex.latencyMs = Date().timeIntervalSince(started) * 1000
            var json = try? JSONValue.decoder().decode(JSONValue.self, from: data)
            if var o = json?.objectValue {
                for k in ["device_token", "session_token"] where o[k] != nil { o[k] = .string("<redacted>") }
                ex.response = .object(o)
            } else { ex.response = json }
            guard let status = http?.statusCode, (200..<300).contains(status) else {
                let errBody = json?["error"]?.objectValue
                let e = EngineError(httpStatus: http?.statusCode ?? 0, code: errBody?["code"]?.stringValue ?? "http_error",
                                    message: errBody?["message"]?.stringValue ?? String(decoding: data.prefix(300), as: UTF8.self),
                                    requestId: errBody?["request_id"]?.stringValue ?? http?.value(forHTTPHeaderField: "X-Request-Id"))
                ex.error = e.errorDescription
                throw e
            }
            if json == nil { json = .null }
            return try JSONValue.decoder().decode(R.self, from: data)
        } catch let e as EngineError {
            throw e
        } catch {
            ex.latencyMs = Date().timeIntervalSince(started) * 1000
            ex.error = error.localizedDescription
            throw EngineError(httpStatus: 0, code: "network", message: error.localizedDescription, requestId: nil)
        }
    }
}
