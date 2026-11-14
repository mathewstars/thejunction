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
        "eyes-open": CGSize(width: 394, height: 191),
        "eyes-half": CGSize(width: 406, height: 179),
        "eyes-closed": CGSize(width: 360, height: 79),
        "eyes-happy": CGSize(width: 373, height: 71),
        "eyes-left": CGSize(width: 398, height: 194),
        "eyes-right": CGSize(width: 397, height: 194),
        "eyes-up": CGSize(width: 401, height: 204),
        "eyes-wide": CGSize(width: 406, height: 220),
        "mouth-smile": CGSize(width: 195, height: 53),
        "mouth-o": CGSize(width: 80, height: 100),
        "mouth-happy": CGSize(width: 220, height: 151),
        "mouth-yawn": CGSize(width: 121, height: 132),
        "mouth-flat": CGSize(width: 155, height: 42),
    ]

    /// Eye pairs: where the image splits between the eyes, and each eye's centre.
    static let eyeSplit: [String: (split: CGFloat, left: CGPoint, right: CGPoint)] = [
        "eyes-open": (197, CGPoint(x: 93, y: 95), CGPoint(x: 301, y: 95)),
        "eyes-half": (203, CGPoint(x: 93, y: 90), CGPoint(x: 313, y: 90)),
        "eyes-closed": (179, CGPoint(x: 83, y: 44), CGPoint(x: 277, y: 40)),
        "eyes-happy": (187, CGPoint(x: 85, y: 37), CGPoint(x: 287, y: 33)),
        "eyes-left": (199, CGPoint(x: 97, y: 97), CGPoint(x: 301, y: 97)),
        "eyes-right": (198, CGPoint(x: 96, y: 99), CGPoint(x: 300, y: 97)),
        "eyes-up": (201, CGPoint(x: 97, y: 104), CGPoint(x: 305, y: 104)),
        "eyes-wide": (204, CGPoint(x: 98, y: 111), CGPoint(x: 308, y: 111)),
    ]

    static func px(_ name: String) -> CGSize { size[name] ?? CGSize(width: 1, height: 1) }
}
