import Foundation

/// The server's data types, field for field as in `docs/api/openapi.json`.
/// Kept inside `API` so the names never clash with the screens' own types.
/// JSON keys are snake_case on the wire; the coders convert them (see `API.decoder`).
enum API {

    // MARK: Coders

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        return e
    }()

    /// ISO time with a zone, as the server wants for `started_at`.
    static func isoString(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    static func date(from iso: String?) -> Date? {
        guard let iso else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: iso) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: iso)
    }

    // MARK: Pairing (POST /v1/devices/pair)

    struct PairIn: Codable {
        var pairingCode: String
        var deviceLabel: String
        var platform: String = "ios"
    }

    struct PairOut: Codable {
        var deviceToken: String
        var patientId: String
    }

    // MARK: Today (GET /v1/today)

    struct TodayOut: Codable, Equatable {
        var status: Status
        var suggestion: SuggestionOut?
        var lanvi: LanviOut
        var roundConfig: JSONValue?      // deprecated, kept so the shape matches
        var attention: String
        var crisis: CrisisBlock
        var productName: String
    }

    enum Status: String, Codable, Equatable {
        case noBaseline = "no_baseline", within, outside, noData = "no_data"

        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Status(rawValue: raw) ?? .noData
        }
    }

    struct SuggestionOut: Codable, Equatable {
        var id: String
        var action: String   // breathing, focus_game, checkin, walk_10min, daylight_10min, call_someone
        var text: String
        var createdAt: String
    }

    struct LanviOut: Codable, Equatable {
        var xp: Int
        var stage: Stage
        var nextStageAt: Int?
        var glow: Double
        var wandering: WanderingOut
        var line: LineOut
        var planToAsk: PlanToAsk?
    }

    enum Stage: String, Codable, Equatable {
        case kit, youngFox = "young_fox", grownFox = "grown_fox"

        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Stage(rawValue: raw) ?? .kit
        }
    }

    enum WanderingState: String, Codable, Equatable {
        case home, away, back

        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = WanderingState(rawValue: raw) ?? .home
        }
    }

    struct WanderingOut: Codable, Equatable {
        var state: WanderingState
        var id: String?
        var returnsAt: String?
        var story: StoryOut?
    }

    struct StoryOut: Codable, Equatable {
        var id: String
        var text: String
        var question: String
        var answers: [StoryAnswer]
    }

    struct StoryAnswer: Codable, Equatable {
        var id: String   // "a" or "b"
        var text: String
    }

    struct LineOut: Codable, Equatable {
        var templateId: String
        var text: String
    }

    struct PlanToAsk: Codable, Equatable {
        var checkinId: String
        var planId: String?
    }

    struct CrisisBlock: Codable, Equatable {
        var text: String
        var contacts: [CrisisContact]
        var reviewedByClinician: Bool
    }

    struct CrisisContact: Codable, Equatable {
        var label: String
        var phone: String
    }

    // MARK: Activities (POST /v1/activities)

    enum ActivityType: String, Codable { case focus, breathing, checkin }
    enum EndedBy: String, Codable { case finished, userStopped = "user_stopped", interrupted }
    enum PlanDone: String, Codable { case yes, no, notAsked = "not_asked" }

    /// One record for `POST /v1/activities`. One struct for the three types
    /// (`FocusActivityIn`, `BreathingActivityIn`, `CheckinActivityIn`); fields that
    /// do not belong to the type stay nil and are left out of the JSON, because the
    /// server refuses unknown fields.
    struct ActivityIn: Codable, Equatable, Identifiable {
        // every record
        var id: String
        var type: ActivityType
        var startedAt: String
        var durationS: Double
        var completed: Bool
        var endedBy: EndedBy
        var suggestionId: String?
        // focus
        var correctTaps: Int?
        var wrongTaps: Int?
        var misses: Int?
        var reactionMs: [Int]?
        // breathing
        var timePlayedS: Double?
        var breathsCompleted: Int?
        // focus and breathing
        var face: FaceSummary?
        // checkin
        var goodThings: [CheckinItem]?
        var plan: CheckinItem?
        var planDone: PlanDone?

        /// A fresh id the server accepts (8 to 64 of A-Z a-z 0-9 _ -).
        static func newId() -> String { UUID().uuidString.lowercased() }
    }

    struct FaceSummary: Codable, Equatable {
        var smileRatePerMin: Double?
        var smileIntensity: Double?
        var facialActivity: Double?
        var blinkRatePerMin: Double?
        var lookDownShare: Double?
        var headTiltDeg: Double?
        var trackingQuality: Double
    }

    /// Either a catalog id or a few typed words, never both.
    struct CheckinItem: Codable, Equatable {
        var catalogId: String?
        var text: String?
    }

    struct ActivityOut: Codable, Equatable {
        var id: String
        var type: String
        var xpGained: Int
        var xpTotal: Int
        var stage: Stage
        var nextStageAt: Int?
        var glow: Double
        var wandering: WanderingState
        var line: LineOut
        var crisis: Bool?
        var crisisBlock: CrisisBlock?
        var reading: String
    }

    // MARK: Check-in options (GET /v1/checkin/options)

    struct CheckinOptionsOut: Codable, Equatable {
        var goodThings: [CheckinOption]
        var plans: [CheckinOption]
    }

    struct CheckinOption: Codable, Equatable, Identifiable {
        var id: String
        var label: String
    }

    // MARK: Preferences (PUT /v1/preferences)

    struct PreferencesIn: Codable {
        var helps: [String]   // up to four of music, moving, people, quiet
    }

    struct PreferencesOut: Codable, Equatable {
        var helps: [String]
        var line: LineOut
    }

    // MARK: Wandering answer (POST /v1/lanvi/wanderings/{id}/answer)

    struct WanderingAnswerIn: Codable {
        var answer: String   // "a" or "b"
    }

    /// The contract leaves this body open; the engine sends these three.
    struct WanderingAnswerOut: Codable, Equatable {
        var id: String?
        var answer: String?
        var wandering: WanderingOut?
    }

    // MARK: Answer a suggestion (POST /v1/feedback)

    /// `FeedbackIn`. Idempotent by `id` (8 to 64 of A-Z a-z 0-9 _ -).
    struct FeedbackIn: Codable, Equatable {
        var id: String
        var suggestionId: String
        var answer: String          // did_it, not_today, something_else
        var felt: String? = nil     // rough, ok, good
    }

    /// The contract leaves this body open; the engine sends `{"ok": true}`.
    struct FeedbackOut: Codable, Equatable {
        var ok: Bool?
    }

    // MARK: What Lanvi has learned (GET /v1/mind and its answers)
    // The contract leaves these bodies open; the shapes below are what the engine sends
    // (`engine/clinic_engine/mind/views.py`, `mind_view`).

    struct MindOut: Codable, Equatable {
        var rules: [JSONValue]
        var lessons: [Lesson]
        var questions: [Question]
    }

    struct Lesson: Codable, Equatable, Identifiable {
        var id: String
        var text: String
        var action: String?
        var effect: JSONValue?
        var context: JSONValue?
        var configId: String?
        var evidenceCount: Int?
        var createdAt: String?
    }

    struct Question: Codable, Equatable, Identifiable {
        var id: String
        var text: String
        var answers: [String]   // yes, no, not_sure
    }

    /// `AnswerIn`: yes, no or not_sure.
    struct AnswerIn: Codable {
        var answer: String
    }

    /// Reply to a lesson reject or a question answer: `{id, status}`.
    struct StatusOut: Codable, Equatable {
        var id: String?
        var status: String?
    }

    // MARK: Errors

    struct ErrorResponse: Codable {
        var error: ErrorBody
    }

    struct ErrorBody: Codable {
        var code: String
        var message: String
        var requestId: String
    }
}

/// Any JSON value, for the one deprecated free-form field.
enum JSONValue: Codable, Equatable {
    case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .bool(let b): try c.encode(b)
        case .object(let o): try c.encode(o)
        case .array(let a): try c.encode(a)
        case .null: try c.encodeNil()
        }
    }
}
