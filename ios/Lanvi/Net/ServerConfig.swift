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
        return ServerConfig(serverURL: url, pairingCode: rawCode.isEmpty ? nil : rawCode)
    }()

    /// Talk to a real server. `-offline` forces the demo even with a config.
    var isLive: Bool {
        serverURL != nil && !ProcessInfo.processInfo.arguments.contains("-offline")
    }
}
