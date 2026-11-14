import SwiftUI

/// The first-time coach: the first time a player meets a move, the scene sinks under a soft
/// veil except a pool of light around the thing to touch, a ghost fingertip of light shows
/// the move in a slow loop, and one short line sits in a small frosted bubble beside it. It
/// never stops anyone: the first touch melts it away and the game simply continues.
///
/// Shown only in round one, and only until the player has done that move once ever
/// (remembered across launches). `-revontuletCoach` forces it on, `-revontuletNoCoach` off.
enum RevontuletCoachKind: String, Equatable, CaseIterable {
    case start, choice, trace, sling, embers, stroke

    /// The one short line.
    var words: String {
        switch self {
        case .start: return "Touch the spark"
        case .choice: return "Small and easy, or big and bright?"
        case .trace: return "Trace the light"
        case .sling: return "Pull back, then let go"
        case .embers: return "Tap the ember"
        case .stroke: return "Brush the snow away"
        }
    }

    /// The light (choice) coach has no veil over the fox's moves, only both lines lit.
    var veil: Double {
        switch self {
        case .choice: return 0.38
        case .stroke: return 0.3     // over the fox: lighter, and no rim of light on it
        default: return 0.52
        }
    }
}

struct RevontuletCoachState: Equatable {
    var kind: RevontuletCoachKind
    /// When it began to appear, and when a touch melted it away.
    var since: Double
    var endedAt: Double?
    /// For the embers: which one is held in the spotlight.
    var ember = 0

    func alpha(_ now: Double) -> Double {
        let k = min(1, max(0, (now - since) / 0.3))
        let inn = k * k * (3 - 2 * k)
        guard let e = endedAt else { return inn }
        return inn * max(0, 1 - (now - e) / 0.2)
    }

    func visible(_ now: Double) -> Bool { alpha(now) > 0.001 && now >= since }
}

/// Which moves this player has already done (across launches).
enum RevontuletCoachMemory {
    private static let args = ProcessInfo.processInfo.arguments
    static let forced = args.contains("-revontuletCoach")
    static let off = args.contains("-revontuletNoCoach")

    /// Forced (the film, stills): every move is shown once per run, then the game is wordless.
    nonisolated(unsafe) private static var learnedThisRun: Set<RevontuletCoachKind> = []

    static func needs(_ k: RevontuletCoachKind) -> Bool {
        if off { return false }
        if forced { return !learnedThisRun.contains(k) }
        return !UserDefaults.standard.bool(forKey: "lanvi.revontulet.learned.\(k.rawValue)")
    }

    static func learned(_ k: RevontuletCoachKind) {
        learnedThisRun.insert(k)
        guard !forced else { return }
        UserDefaults.standard.set(true, forKey: "lanvi.revontulet.learned.\(k.rawValue)")
    }
}

/// The coach's one line: dark frosted glass with a soft edge, Nunito, a few words.
struct RevontuletCoachBubble: View {
    var text: String

    var body: some View {
        Text(text)
            .font(Theme.rounded(17, .heavy))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(red: 0.05, green: 0.09, blue: 0.24).opacity(0.62))
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .environment(\.colorScheme, .dark)
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(LinearGradient(colors: [.white.opacity(0.28), .white.opacity(0.05)], startPoint: .top, endPoint: .bottom), lineWidth: 1))
                    .shadow(color: Color(red: 0.02, green: 0.04, blue: 0.14).opacity(0.35), radius: 14, y: 6)
            }
            .fixedSize()
    }
}
