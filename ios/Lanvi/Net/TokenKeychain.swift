import Foundation
import Security

/// The device token lives in the TokenKeychain, one per server address, so switching
/// servers never sends one server's token to another.
enum TokenKeychain {
    private static let service = "app.lanvi.device-token"

    static func token(for server: URL) -> String? {
        var query = base(server)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ token: String, for server: URL) {
        delete(for: server)
        var item = base(server)
        item[kSecValueData as String] = Data(token.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }

    static func delete(for server: URL) {
        SecItemDelete(base(server) as CFDictionary)
    }

    private static func base(_ server: URL) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: server.absoluteString]
    }
}
