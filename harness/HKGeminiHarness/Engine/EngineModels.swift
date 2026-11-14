import Foundation

// Mirrors of the clinic engine's request and reply models (engine/clinic_engine/models.py,
// docs/api/README.md, docs/face-raw.md). The engine rejects unknown fields, so these structs carry
// exactly the documented keys and nothing else.

/// `POST /v1/daily` → one day of Apple Health values. `steps` is required by the engine.
public struct EngineDayRecord: Codable, Hashable, Identifiable {
    public var id: String { date }
    public var date: String            // yyyy-MM-dd
    public var steps: Int
    public var walkingSpeedMS: Double?
    public var hrvMs: Double?
    public var sleepH: Double?

    enum CodingKeys: String, CodingKey {
        case date, steps
        case walkingSpeedMS = "walking_speed_m_s"
        case hrvMs = "hrv_ms"
        case sleepH = "sleep_h"
    }
}

public struct EngineDailyIn: Codable { public var days: [EngineDayRecord] }

public struct EngineDailyOut: Codable {
    public struct Rejected: Codable, Hashable { public var date: String; public var reason: String }
    public var accepted: [String]
    public var rejected: [Rejected]
    public var status: String
}

/// `face_raw` on a focus or breathing activity: raw ARKit numbers per frame, nothing computed.
public struct EngineFaceRaw: Codable {
    public var rateHz: Double
    public var channels: [String]
    public var samples: [[Double]]
    /// nil when every frame was tracked.
    public var tracked: [Int]?
    public var momentsMs: [Int]?

    enum CodingKeys: String, CodingKey {
        case rateHz = "rate_hz", channels, samples, tracked
        case momentsMs = "moments_ms"
    }

    /// The 52 ARKit blend-shape names the engine accepts (BlendShapeLocation.rawValue spelling,
    /// e.g. mouthSmileLeft) plus the three head angles in degrees.
    public static let allowedBlendShapes: Set<String> = [
        "browDownLeft", "browDownRight", "browInnerUp", "browOuterUpLeft", "browOuterUpRight", "cheekPuff", "cheekSquintLeft",
        "cheekSquintRight", "eyeBlinkLeft", "eyeBlinkRight", "eyeLookDownLeft", "eyeLookDownRight", "eyeLookInLeft", "eyeLookInRight",
        "eyeLookOutLeft", "eyeLookOutRight", "eyeLookUpLeft", "eyeLookUpRight", "eyeSquintLeft", "eyeSquintRight", "eyeWideLeft",
        "eyeWideRight", "jawForward", "jawLeft", "jawOpen", "jawRight", "mouthClose", "mouthDimpleLeft", "mouthDimpleRight",
        "mouthFrownLeft", "mouthFrownRight", "mouthFunnel", "mouthLeft", "mouthLowerDownLeft", "mouthLowerDownRight", "mouthPressLeft",
        "mouthPressRight", "mouthPucker", "mouthRight", "mouthRollLower", "mouthRollUpper", "mouthShrugLower", "mouthShrugUpper",
        "mouthSmileLeft", "mouthSmileRight", "mouthStretchLeft", "mouthStretchRight", "mouthUpperUpLeft", "mouthUpperUpRight",
        "noseSneerLeft", "noseSneerRight", "tongueOut"
    ]
    public static let headChannels = ["headPitch", "headYaw", "headRoll"]
    public static let requiredChannels = ["mouthSmileLeft", "mouthSmileRight", "eyeBlinkLeft", "eyeBlinkRight"]
    public static let maxChannels = 60
    public static let maxSamples = 12_000
    public static let maxMoments = 20
    public static let rateRange: ClosedRange<Double> = 5...60
}

/// One activity record for `POST /v1/activities`. Only the fields of the chosen `type` are set;
/// optionals that stay nil are not encoded, which is what the engine's strict models need.
public struct EngineActivity: Codable, Identifiable {
    public var id: String
    public var type: String               // "breathing" | "focus"
    public var startedAt: String          // ISO 8601 with zone
    public var durationS: Double
    public var completed: Bool
    public var endedBy: String            // finished | user_stopped | interrupted
    public var suggestionId: String?
    // breathing
    public var timePlayedS: Double?
    public var breathsCompleted: Int?
    // focus
    public var correctTaps: Int?
    public var wrongTaps: Int?
    public var misses: Int?
    public var reactionMs: [Int]?
    // either
    public var faceRaw: EngineFaceRaw?

    enum CodingKeys: String, CodingKey {
        case id, type, completed, misses
        case startedAt = "started_at"
        case durationS = "duration_s"
        case endedBy = "ended_by"
        case suggestionId = "suggestion_id"
        case timePlayedS = "time_played_s"
        case breathsCompleted = "breaths_completed"
        case correctTaps = "correct_taps"
        case wrongTaps = "wrong_taps"
        case reactionMs = "reaction_ms"
        case faceRaw = "face_raw"
    }

    /// Client ids must match ^[A-Za-z0-9_-]{8,64}$.
    public static func clientID(from raw: String) -> String {
        var s = String(raw.map { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" ? $0 : "-" })
        s = String(s.unicodeScalars.filter { $0.isASCII }.map(Character.init))
        if s.count > 64 { s = String(s.prefix(64)) }
        while s.count < 8 { s += "-" }
        return s
    }
}

public struct EngineLine: Codable, Hashable { public var templateId: String; public var text: String
    enum CodingKeys: String, CodingKey { case templateId = "template_id", text } }

public struct EngineActivityOut: Codable {
    public var id: String
    public var type: String
    public var xpGained: Int
    public var xpTotal: Int
    public var stage: String
    public var nextStageAt: Int?
    public var glow: Double
    public var wandering: String
    public var line: EngineLine
    public var crisis: Bool
    /// pending | ready | failed | off | not_allowed | not_applicable
    public var reading: String

    enum CodingKeys: String, CodingKey {
        case id, type, stage, glow, wandering, line, crisis, reading
        case xpGained = "xp_gained"
        case xpTotal = "xp_total"
        case nextStageAt = "next_stage_at"
    }
}

public struct EngineReadingOut: Codable, Hashable {
    public var status: String
    public var line: String?
}

public struct EnginePairOut: Codable {
    public var deviceToken: String
    public var patientId: String
    enum CodingKeys: String, CodingKey { case deviceToken = "device_token", patientId = "patient_id" }
}

public struct EngineLoginOut: Codable {
    public var sessionToken: String
    public var expiresAt: String
    enum CodingKeys: String, CodingKey { case sessionToken = "session_token", expiresAt = "expires_at" }
}

/// Error body the engine returns: {"error": {"code", "message", "request_id"}}.
public struct EngineError: LocalizedError, Codable, Hashable {
    public var httpStatus: Int
    public var code: String
    public var message: String
    public var requestId: String?
    public var errorDescription: String? { "HTTP \(httpStatus) \(code): \(message)" + (requestId.map { " (request \($0))" } ?? "") }
}

/// What the build of a `face_raw` payload did to the recording, for the developer screen and the docs.
public struct FaceRawBuildReport: Codable, Hashable {
    public var sessionID: String
    public var rateHz: Double
    public var requestedRateHz: Double
    public var channelCount: Int
    public var blendShapeChannels: Int
    public var droppedBlendShapes: [String]
    public var sampleCount: Int
    public var trackedFraction: Double
    public var spanSeconds: Double
    public var truncatedSeconds: Double
    public var headAngleSource: String
    public var momentCount: Int
    public var approximateBytes: Int
    public var warnings: [String]
}

/// One call to the engine, kept for the developer screen. Secrets are redacted before storing.
public struct EngineExchange: Identifiable, Codable {
    public var id: String
    public var at: Date
    public var method: String
    public var path: String
    public var request: JSONValue?
    public var httpStatus: Int?
    public var response: JSONValue?
    public var latencyMs: Double
    public var error: String?
}
