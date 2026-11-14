import Foundation

/// Where the server is, read from Info.plist. The values come from the
/// git-ignored `ios/Config.xcconfig` (see `ios/Config.example.xcconfig`), so no
/// address or code is ever committed. Empty values mean offline demo mode.
struct ServerConfig {
    var serverURL: URL?
    var pairingCode: String?

    static let current: ServerConfig = {
        let info = Bundle.main.infoDictionary ?? [:]
        let rawURL = (info["LanviServerURL"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        let rawCode = (info["LanviPairingCode"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        var url: URL?
        if let u = URL(string: rawURL), let scheme = u.scheme, ["http", "https"].contains(scheme), u.host != nil {
            url = u
        }
        return ServerConfig(serverURL: url, pairingCode: rawCode.isEmpty ? openLinkingCode : rawCode)
    }()

    /// Linking is switched off for now (dad, 14 Nov evening): a build with no clinic code
    /// still connects, and the server puts every phone on the shared test profile
    /// (its `OPEN_PAIRING_PATIENT` setting; it does not look at the code while that is on).
    /// The placeholder only has the shape of a code. To bring clinic codes back, set this
    /// to nil: a build without a code then runs on offline sample data again.
    static let openLinkingCode: String? = "OPEN-OPEN-OPEN"
    // static let openLinkingCode: String? = nil

    /// Talk to a real server. `-offline` forces the demo even with a config.
    var isLive: Bool {
        serverURL != nil && !ProcessInfo.processInfo.arguments.contains("-offline")
    }
}
