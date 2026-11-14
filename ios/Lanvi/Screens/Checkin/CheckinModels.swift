import Foundation

/// One tappable thing in the check-in catalog (`GET /v1/checkin/options`).
struct CheckinOption: Identifiable, Hashable, Codable {
    let id: String
    let label: String
}

/// What the evening check-in offers to tap. Mirrors `CheckinOptionsOut` on the server.
struct CheckinOptions: Hashable, Codable {
    var goodThings: [CheckinOption]
    var plans: [CheckinOption]

    enum CodingKeys: String, CodingKey {
        case goodThings = "good_things"
        case plans
    }

    func planLabel(_ id: String) -> String? { plans.first { $0.id == id }?.label }
    func goodThingLabel(_ id: String) -> String? { goodThings.first { $0.id == id }?.label }

    /// The same list as `engine/clinic_engine/data/checkin_catalog.json`, so the screen works with no server.
    static let sample = CheckinOptions(
        goodThings: [
            .init(id: "walked", label: "I went for a walk"),
            .init(id: "outside", label: "I was outside"),
            .init(id: "good_food", label: "I ate something good"),
            .init(id: "talked_to_someone", label: "I talked to someone"),
            .init(id: "music", label: "I listened to music"),
            .init(id: "rested", label: "I rested"),
            .init(id: "got_something_done", label: "I got something done"),
            .init(id: "laughed", label: "I laughed"),
            .init(id: "kind_moment", label: "Someone was kind, or I was"),
        ],
        plans: [
            .init(id: "walk", label: "A walk"),
            .init(id: "coffee_outside", label: "Coffee outside"),
            .init(id: "call_someone", label: "Call someone"),
            .init(id: "music", label: "Listen to a song I like"),
            .init(id: "cook_something", label: "Cook something simple"),
            .init(id: "daylight", label: "Sit in the daylight"),
            .init(id: "tidy_one_thing", label: "Tidy one small thing"),
            .init(id: "rest_early", label: "Go to bed a bit earlier"),
        ])
}

/// Yesterday's plan to ask about tonight (`plan_to_ask` in `GET /v1/today`).
/// `planId` is nil when the plan was typed; the app keeps those words on the phone and passes them as `label`.
struct CheckinPlanQuestion: Hashable {
    var checkinId: String
    var planId: String?
    var label: String

    /// Builds the question from the server's `plan_to_ask`, looking the label up in the catalog.
    /// `typedText` is the words the person typed yesterday (kept on the phone) when `planId` is nil.
    init?(checkinId: String, planId: String?, options: CheckinOptions, typedText: String? = nil) {
        let label = planId.flatMap { options.planLabel($0) } ?? typedText
        guard let label, !label.isEmpty else { return nil }
        self.init(checkinId: checkinId, planId: planId, label: label)
    }

    init(checkinId: String, planId: String?, label: String) {
        self.checkinId = checkinId
        self.planId = planId
        self.label = label
    }

    static let sample = CheckinPlanQuestion(checkinId: "sample-checkin", planId: "coffee_outside", label: "Coffee outside")
}

/// One good thing or plan: a catalog id the person tapped, or a few typed words (never both).
/// Encodes as `{"catalog_id": "walked"}` or `{"text": "a few words"}`.
enum CheckinItem: Hashable, Codable {
    case catalog(String)
    case text(String)

    static let maxTextLength = 120

    /// A typed item, trimmed and cut to 120 characters. Nil when nothing is left.
    static func typed(_ raw: String) -> CheckinItem? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return .text(String(trimmed.prefix(maxTextLength)))
    }

    var catalogId: String? { if case .catalog(let id) = self { id } else { nil } }
    var typedText: String? { if case .text(let t) = self { t } else { nil } }

    private enum CodingKeys: String, CodingKey { case catalogId = "catalog_id", text }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let id = try c.decodeIfPresent(String.self, forKey: .catalogId) {
            self = .catalog(id)
        } else {
            self = .text(try c.decode(String.self, forKey: .text))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .catalog(let id): try c.encode(id, forKey: .catalogId)
        case .text(let t): try c.encode(t, forKey: .text)
        }
    }
}

/// Whether yesterday's plan happened. Raw values match the server's `plan_done`.
enum CheckinPlanDone: String, Codable {
    case yes, no
    case notAsked = "not_asked"
}

/// What the person told Lanvi tonight. Maps one to one onto the server's `checkin` activity fields:
/// `good_things`, `plan`, `plan_done`, plus `started_at` and the duration (`ended_at - started_at`).
struct CheckinResult: Hashable, Codable {
    var goodThings: [CheckinItem]   // 0 to 3
    var plan: CheckinItem?
    var planDone: CheckinPlanDone
    var startedAt: Date
    var endedAt: Date

    var durationSeconds: Double { max(0, endedAt.timeIntervalSince(startedAt)) }

    enum CodingKeys: String, CodingKey {
        case goodThings = "good_things"
        case plan
        case planDone = "plan_done"
        case startedAt = "started_at"
        case endedAt = "ended_at"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(goodThings, forKey: .goodThings)
        try c.encode(plan, forKey: .plan) // null when skipped, as the server expects
        try c.encode(planDone, forKey: .planDone)
        try c.encode(startedAt, forKey: .startedAt)
        try c.encode(endedAt, forKey: .endedAt)
    }
}
