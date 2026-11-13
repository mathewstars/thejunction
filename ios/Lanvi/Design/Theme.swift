import SwiftUI

extension Color {
    /// Colour from a hex number, e.g. Color(hex: 0x3D63DD).
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}

/// Lanvi's blue and white palette, matched to the fox's periwinkle fur.
enum Theme {
    static let brand = Color(hex: 0x3D63DD)        // buttons, wordmark
    static let brandEdge = Color(hex: 0x2C4BB3)    // 3D button edge
    static let skyTop = Color(hex: 0x1E3A9A)
    static let skyBottom = Color(hex: 0x7EA2F0)
    static let nightTop = Color(hex: 0x15296E)
    static let nightBottom = Color(hex: 0x4F78E0)
    static let ink = Color(hex: 0x1C2753)          // main text
    static let inkSecondary = Color(hex: 0x5D6B94)
    static let snow = Color(hex: 0xF5F8FF)
    static let line = Color(hex: 0xDFE6F8)
    static let tint = Color(hex: 0xE9EFFF)
    static let glow = Color(hex: 0xA8C4FF)
    static let aurora = Color(hex: 0xA8E3FF)
    static let auroraViolet = Color(hex: 0xC9B8FF)

    /// Rounded system font, close to Duolingo's feel. Swap for Nunito later if wanted.
    static func rounded(_ size: CGFloat, _ weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}
