// Written by ios/tools/cut_puppet_parts.py. Do not edit by hand: re-run the script.
// Each puppet part's size in pixels on the 2048 x 2048 art sheet.
import CoreGraphics

enum LanviArt {
    static let size: [String: CGSize] = [
        "ear-left": CGSize(width: 392, height: 644),
        "head": CGSize(width: 813, height: 749),
        "ear-right": CGSize(width: 392, height: 644),
        "body": CGSize(width: 750, height: 699),
        "tail": CGSize(width: 666, height: 630),
        "leg-left": CGSize(width: 207, height: 540),
        "leg-right": CGSize(width: 211, height: 541),
        "eyes-open-l": CGSize(width: 197, height: 191),
        "eyes-open-r": CGSize(width: 197, height: 191),
        "eyes-half-l": CGSize(width: 203, height: 179),
        "eyes-half-r": CGSize(width: 203, height: 179),
        "eyes-closed-l": CGSize(width: 179, height: 79),
        "eyes-closed-r": CGSize(width: 181, height: 79),
        "eyes-happy-l": CGSize(width: 187, height: 71),
        "eyes-happy-r": CGSize(width: 186, height: 71),
        "eyes-left-l": CGSize(width: 199, height: 194),
        "eyes-left-r": CGSize(width: 199, height: 194),
        "eyes-right-l": CGSize(width: 198, height: 194),
        "eyes-right-r": CGSize(width: 199, height: 194),
        "eyes-up-l": CGSize(width: 201, height: 204),
        "eyes-up-r": CGSize(width: 200, height: 204),
        "eyes-wide-l": CGSize(width: 204, height: 220),
        "eyes-wide-r": CGSize(width: 202, height: 220),
        "mouth-smile": CGSize(width: 195, height: 53),
        "mouth-o": CGSize(width: 80, height: 100),
        "mouth-happy": CGSize(width: 220, height: 151),
        "mouth-yawn": CGSize(width: 121, height: 132),
        "mouth-flat": CGSize(width: 155, height: 42),
    ]

    /// Each eye half: where the eye's centre is in its image.
    static let eyeCenter: [String: CGPoint] = [
        "eyes-open-l": CGPoint(x: 93, y: 95),
        "eyes-open-r": CGPoint(x: 104, y: 95),
        "eyes-half-l": CGPoint(x: 93, y: 90),
        "eyes-half-r": CGPoint(x: 110, y: 90),
        "eyes-closed-l": CGPoint(x: 83, y: 44),
        "eyes-closed-r": CGPoint(x: 98, y: 40),
        "eyes-happy-l": CGPoint(x: 85, y: 37),
        "eyes-happy-r": CGPoint(x: 100, y: 33),
        "eyes-left-l": CGPoint(x: 97, y: 97),
        "eyes-left-r": CGPoint(x: 102, y: 97),
        "eyes-right-l": CGPoint(x: 96, y: 99),
        "eyes-right-r": CGPoint(x: 102, y: 97),
        "eyes-up-l": CGPoint(x: 97, y: 104),
        "eyes-up-r": CGPoint(x: 104, y: 104),
        "eyes-wide-l": CGPoint(x: 98, y: 111),
        "eyes-wide-r": CGPoint(x: 104, y: 111),
    ]

    static func px(_ name: String) -> CGSize { size[name] ?? CGSize(width: 1, height: 1) }
}
