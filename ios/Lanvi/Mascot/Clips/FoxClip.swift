import SwiftUI

// The clip fox: Lanvi as short hand-animated-looking video clips (HEVC with alpha)
// instead of the paper puppet. Behind a switch while the captain compares the two:
// launch with `-foxClips YES`, or flip "Fox: puppet / clips" at the bottom of Help.
//
// The clips live in `Clips/Media/fox-<name>.mov`, made by `ios/tools/fox_clips.py`
// from the green-screen originals. Every clip starts and ends on the same rest frame
// (`fox-clip-rest` in the asset catalog), so any clip can follow any other.

/// One clip. A clip that is not in the app (not made yet, or judged unusable) is
/// replaced by `stand-in` wherever it is asked for.
enum FoxClip: String, CaseIterable {
    case idle, look, happy, talk, sleepy, wave, listen, pet, giggle, nod

    var url: URL? { Bundle.main.url(forResource: "fox-" + rawValue, withExtension: "mov") }
    var isAvailable: Bool { FoxClip.available.contains(self) }
    static let available: Set<FoxClip> = Set(allCases.filter { $0.url != nil })

    /// What plays when this clip is missing.
    var standIn: FoxClip {
        switch self {
        case .pet: return .giggle
        case .wave: return .happy
        case .giggle: return .happy
        case .nod, .listen: return .look
        default: return .idle
        }
    }

    /// This clip, or the nearest one the app has.
    var resolved: FoxClip {
        var c = self
        for _ in 0..<4 where !c.isAvailable { c = c.standIn }
        return c.isAvailable ? c : .idle
    }

    /// The clip a reaction asks for (by the mood's name, so newer moods map too).
    static func forReaction(_ mood: LanviMood) -> FoxClip? {
        switch mood.rawValue {
        case "happy", "proud": return .happy
        case "curious", "thinking": return .look
        case "surprised": return .giggle
        case "sleepy": return .sleepy
        case "listening": return .listen
        case "greeting": return .wave
        case "okay": return .nod
        default: return nil
        }
    }
}

/// The switch between the puppet and the clips (default: puppet).
enum LanviFoxStyle {
    static let key = "foxClips"
    /// `-foxClips YES` on launch, or the Help toggle.
    static var clips: Bool { UserDefaults.standard.bool(forKey: key) }
}

/// "Fox: puppet / clips", a quiet line at the bottom of Help for comparing the two.
struct LanviFoxStyleSwitch: View {
    @AppStorage(LanviFoxStyle.key) private var clips = false

    var body: some View {
        Button {
            clips.toggle()
        } label: {
            HStack(spacing: 4) {
                Text("Fox:")
                Text("puppet").foregroundStyle(clips ? Theme.inkSecondary : Theme.ink)
                Text("/")
                Text("clips").foregroundStyle(clips ? Theme.ink : Theme.inkSecondary)
            }
            .font(Theme.rounded(13, .bold))
            .foregroundStyle(Theme.inkSecondary)
            .frame(maxWidth: .infinity)
            .padding(.top, 8)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(clips ? "Fox style: clips" : "Fox style: puppet")
        .accessibilityIdentifier("help.foxStyle")
    }
}
