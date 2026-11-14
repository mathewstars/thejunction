import Foundation
import UIKit

/// What went wrong, in a few kinds the app can act on. The server's own message
/// is never shown to the person.
enum APIError: Error, Equatable {
    case offline                 // no network, timeout, server unreachable
    case badPairingCode          // 400 invalid_pairing_code: used, expired or wrong
    case unauthorized            // 401 / 403: token missing, unknown or expired
    case notFound                // 404
    case conflict                // 409: id reused for a different record
    case rejected(String)        // 413 / 422: shape or plausibility; never resend
    case rateLimited             // 429
    case server                  // 5xx
    case unreadable              // the reply did not match the contract

    /// Worth keeping and sending again later.
    var isTemporary: Bool {
        switch self {
        case .offline, .rateLimited, .server, .unauthorized: return true
        default: return false
        }
    }
}

/// The calls the app makes. Two kinds: the real server and the offline demo.
protocol LanviBackend: Sendable {
    func today() async throws -> API.TodayOut
    func send(_ activity: API.ActivityIn) async throws -> API.ActivityOut
    func checkinOptions() async throws -> API.CheckinOptionsOut
    func setPreferences(_ helps: [String]) async throws -> API.PreferencesOut
    func mind() async throws -> API.MindOut
    func feedback(_ f: API.FeedbackIn) async throws -> API.FeedbackOut
    func note(_ n: API.NoteIn) async throws -> API.NoteOut
    func rejectLesson(id: String) async throws -> API.StatusOut
    func answerQuestion(id: String, answer: String) async throws -> API.StatusOut
}

/// The real server. Pairs once with the configured code, keeps the token in
/// the TokenKeychain, and sends the bearer token on every call.
actor LanviClient: LanviBackend {
    private let base: URL
    private let pairingCode: String?
    private let session: URLSession
    private var token: String?

    init(base: URL, pairingCode: String?) {
        self.base = base
        self.pairingCode = pairingCode
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 12
        cfg.waitsForConnectivity = false
        self.session = URLSession(configuration: cfg)
        self.token = TokenKeychain.token(for: base)
    }

    var isPaired: Bool { token != nil }


    // MARK: Calls

    /// POST /v1/devices/pair, with the code the person typed or, for testers, the
    /// one in the private config. A code works once.
    @discardableResult
    func pair(code typed: String? = nil) async throws -> API.PairOut {
        guard let code = typed ?? pairingCode else { throw APIError.badPairingCode }
        let label = await Self.deviceLabel()
        let body = API.PairIn(pairingCode: code, deviceLabel: label)
        let out: API.PairOut = try await raw("POST", "/v1/devices/pair", body: body, auth: false)
        token = out.deviceToken
        TokenKeychain.save(out.deviceToken, for: base)
        return out
    }

    func today() async throws -> API.TodayOut {
        try await call("GET", "/v1/today", body: Optional<API.PairIn>.none)
    }

    func send(_ activity: API.ActivityIn) async throws -> API.ActivityOut {
        try await call("POST", "/v1/activities", body: activity)
    }

    func checkinOptions() async throws -> API.CheckinOptionsOut {
        try await call("GET", "/v1/checkin/options", body: Optional<API.PairIn>.none)
    }

    func setPreferences(_ helps: [String]) async throws -> API.PreferencesOut {
        try await call("PUT", "/v1/preferences", body: API.PreferencesIn(helps: helps))
    }


    func mind() async throws -> API.MindOut {
        try await call("GET", "/v1/mind", body: Optional<API.PairIn>.none)
    }

    func feedback(_ f: API.FeedbackIn) async throws -> API.FeedbackOut {
        try await call("POST", "/v1/feedback", body: f)
    }

    func note(_ n: API.NoteIn) async throws -> API.NoteOut {
        try await call("POST", "/v1/notes", body: n)
    }

    func rejectLesson(id: String) async throws -> API.StatusOut {
        try await call("POST", "/v1/mind/lessons/\(Self.pathSafe(id))/reject", body: Optional<API.PairIn>.none)
    }

    func answerQuestion(id: String, answer: String) async throws -> API.StatusOut {
        try await call("POST", "/v1/mind/questions/\(Self.pathSafe(id))/answer", body: API.AnswerIn(answer: answer))
    }

    private static func pathSafe(_ id: String) -> String {
        id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? id
    }

    // MARK: Plumbing

    /// A device call: pairs first when there is no token, and once more when
    /// the server no longer knows the token.
    private func call<B: Encodable, R: Decodable>(_ method: String, _ path: String, body: B?) async throws -> R {
        if token == nil {
            // Not paired yet: the person has to type their clinic's code first.
            guard pairingCode != nil else { throw APIError.unauthorized }
            try await pair()
        }
        do {
            return try await raw(method, path, body: body, auth: true)
        } catch APIError.unauthorized {
            token = nil
            TokenKeychain.delete(for: base)
            guard pairingCode != nil else { throw APIError.unauthorized }
            do { try await pair() } catch { throw APIError.unauthorized }
            return try await raw(method, path, body: body, auth: true)
        }
    }

    private func raw<B: Encodable, R: Decodable>(_ method: String, _ path: String, body: B?, auth: Bool) async throws -> R {
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            req.httpBody = try API.encoder.encode(body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if auth, let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw APIError.offline
        }
        guard let http = response as? HTTPURLResponse else { throw APIError.offline }
        guard (200..<300).contains(http.statusCode) else {
            throw Self.error(status: http.statusCode, data: data)
        }
        do {
            return try API.decoder.decode(R.self, from: data)
        } catch {
            throw APIError.unreadable
        }
    }

    private static func error(status: Int, data: Data) -> APIError {
        let code = (try? API.decoder.decode(API.ErrorResponse.self, from: data))?.error.code ?? ""
        switch status {
        case 400 where code == "invalid_pairing_code": return .badPairingCode
        case 401, 403: return .unauthorized
        case 404: return .notFound
        case 409: return .conflict
        case 413, 400, 422: return .rejected(code.isEmpty ? "invalid_request" : code)
        case 429: return .rateLimited
        default: return status >= 500 ? .server : .rejected(code)
        }
    }

    /// "iPhone 16 Pro" style label: letters, digits and spaces only, as the server wants.
    @MainActor private static func deviceLabel() -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 ._-")
        let s = String(UIDevice.current.model.filter { allowed.contains($0) }.prefix(40))
        return s.isEmpty ? "iPhone" : s
    }
}
