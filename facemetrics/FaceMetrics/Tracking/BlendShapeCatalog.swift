import Foundation

/// Categories used for filtering in the explorer. Assignment is by identifier prefix so any
/// coefficient the running SDK exposes lands somewhere, including ones added after this code was written.
enum BlendShapeCategory: String, CaseIterable, Codable, Identifiable {
    case eyes = "Eyes"
    case eyebrows = "Eyebrows"
    case mouth = "Mouth"
    case cheeks = "Cheeks"
    case nose = "Nose"
    case other = "Other"

    var id: String { rawValue }

    static func category(for rawIdentifier: String) -> BlendShapeCategory {
        let id = rawIdentifier.lowercased()
        if id.hasPrefix("eye") { return .eyes }
        if id.hasPrefix("brow") { return .eyebrows }
        if id.hasPrefix("mouth") || id.hasPrefix("jaw") { return .mouth }
        if id.hasPrefix("cheek") { return .cheeks }
        if id.hasPrefix("nose") { return .nose }
        return .other
    }
}

enum BlendShapeSide: String, Codable {
    case left, right, none
}

/// Naming helpers around ARKit's raw identifiers. ARKit's BlendShapeLocation.rawValue uses
/// "_L" / "_R" suffixes (e.g. "eyeBlink_L"), while the Swift constants are eyeBlinkLeft etc.
enum BlendShapeCatalog {

    /// "eyeBlink_L" -> "eyeBlinkLeft"
    static func friendlyName(for rawIdentifier: String) -> String {
        if rawIdentifier.hasSuffix("_L") { return String(rawIdentifier.dropLast(2)) + "Left" }
        if rawIdentifier.hasSuffix("_R") { return String(rawIdentifier.dropLast(2)) + "Right" }
        return rawIdentifier
    }

    static func side(of rawIdentifier: String) -> BlendShapeSide {
        if rawIdentifier.hasSuffix("_L") { return .left }
        if rawIdentifier.hasSuffix("_R") { return .right }
        return .none
    }

    /// "eyeBlink_L" -> "eyeBlink"; identifiers without a side suffix return themselves.
    static func pairBase(of rawIdentifier: String) -> String {
        if rawIdentifier.hasSuffix("_L") || rawIdentifier.hasSuffix("_R") {
            return String(rawIdentifier.dropLast(2))
        }
        return rawIdentifier
    }

    /// Stable column ordering for exports: alphabetical by raw identifier.
    static func sortedIdentifiers(_ ids: some Sequence<String>) -> [String] {
        ids.sorted()
    }
}
