import Foundation
import Security

/// The server and the read-only key the iPhone made for this TV, kept in the TV's Keychain. The person never sees the key:
/// the iPhone makes it and hands it over, and Forget on the iPhone's Apple TV page, or deleting it in Immich, ends it.
struct TVAccount: Codable, Sendable {
    let server: String
    let key: String

    private static let service = (Bundle.main.bundleIdentifier ?? "dev.hviid.Verso") + ".tv-account"

    static func load() -> TVAccount? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(TVAccount.self, from: data)
    }

    func save() {
        Self.remove()
        guard let data = try? JSONEncoder().encode(self) else { return }
        let item: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service,
                                   kSecValueData as String: data,
                                   kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        SecItemAdd(item as CFDictionary, nil)
    }

    static func remove() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary)
    }
}
