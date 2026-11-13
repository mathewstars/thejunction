import SwiftUI

/// Instrument palette. Graphite surfaces, two channel colours (left = blue, right = amber, as on a
/// two-channel oscilloscope), one teal accent for primary traces, and status lamps.
enum Theme {
    static let background = Color(red: 0.063, green: 0.075, blue: 0.094)      // #10131
    static let panel = Color(red: 0.090, green: 0.106, blue: 0.133)           // #171B22
    static let panelRaised = Color(red: 0.118, green: 0.137, blue: 0.169)     // #1E232B
    static let border = Color(red: 0.149, green: 0.173, blue: 0.212)          // #262C36
    static let grid = Color(red: 0.149, green: 0.173, blue: 0.212).opacity(0.7)
    static let textPrimary = Color(red: 0.902, green: 0.914, blue: 0.937)     // #E6E9EF
    static let textSecondary = Color(red: 0.545, green: 0.580, blue: 0.647)   // #8B94A5
    static let textTertiary = Color(red: 0.380, green: 0.412, blue: 0.470)

    static let accent = Color(red: 0.373, green: 0.761, blue: 0.839)          // #5FC2D6 teal
    static let left = Color(red: 0.435, green: 0.714, blue: 1.0)              // #6FB6FF blue
    static let right = Color(red: 1.0, green: 0.702, blue: 0.420)             // #FFB36B amber
    static let trace3 = Color(red: 0.780, green: 0.627, blue: 1.0)            // #C7A0FF violet
    static let trace4 = Color(red: 0.596, green: 0.882, blue: 0.620)          // #98E19E green

    static let ok = Color(red: 0.357, green: 0.816, blue: 0.541)              // #5BD08A
    static let warn = Color(red: 0.949, green: 0.757, blue: 0.306)            // #F2C14E
    static let bad = Color(red: 0.949, green: 0.427, blue: 0.427)             // #F26D6D
    static let recording = Color(red: 1.0, green: 0.302, blue: 0.302)         // #FF4D4D

    static let panelRadius: CGFloat = 10
    static let controlRadius: CGFloat = 7

    static func channel(_ side: BlendShapeSide) -> Color {
        switch side {
        case .left: return left
        case .right: return right
        case .none: return accent
        }
    }

    static func category(_ c: BlendShapeCategory) -> Color {
        switch c {
        case .eyes: return left
        case .eyebrows: return trace3
        case .mouth: return right
        case .cheeks: return trace4
        case .nose: return accent
        case .other: return textSecondary
        }
    }
}

/// Number formatting for readouts. Keeps digits stable so values do not jump around.
enum Fmt {
    static func f(_ v: Float?, _ digits: Int = 3) -> String {
        guard let v, v.isFinite else { return "—" }
        return String(format: "%.\(digits)f", v)
    }
    static func f(_ v: Double?, _ digits: Int = 3) -> String {
        guard let v, v.isFinite else { return "—" }
        return String(format: "%.\(digits)f", v)
    }
    static func signed(_ v: Float?, _ digits: Int = 3) -> String {
        guard let v, v.isFinite else { return "—" }
        return String(format: "%+.\(digits)f", v)
    }
    static func deg(_ radians: Float?, _ digits: Int = 1) -> String {
        guard let r = radians, r.isFinite else { return "—" }
        return String(format: "%+.\(digits)f°", r * 180 / .pi)
    }
    static func degValue(_ degrees: Float?, _ digits: Int = 1) -> String {
        guard let d = degrees, d.isFinite else { return "—" }
        return String(format: "%+.\(digits)f°", d)
    }
    static func mm(_ metres: Float?) -> String {
        guard let m = metres, m.isFinite else { return "—" }
        return String(format: "%.0f mm", m * 1000)
    }
    static func ms(_ seconds: Double?) -> String {
        guard let s = seconds, s.isFinite else { return "—" }
        return String(format: "%.0f ms", s * 1000)
    }
    static func duration(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded(.down)))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, sec) }
        return String(format: "%02d:%02d", m, sec)
    }
    static func bytes(_ b: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
    }
    static func int(_ v: Int?) -> String { v.map { String($0) } ?? "—" }
    static func pct(_ v: Double?) -> String {
        guard let v, v.isFinite else { return "—" }
        return String(format: "%.0f%%", v * 100)
    }
    static func time(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: date)
    }
    static func dateTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }
}
