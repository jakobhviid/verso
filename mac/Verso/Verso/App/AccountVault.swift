import Foundation
import Security

/// The one account Verso is signed in to, as on Linux (ARCHITECTURE.md, "Verso on the Mac"), kept in the Keychain: the
/// server, its API address and the credential, and whose it is. A sign-in replaces it; signing out forgets it.
///
/// The item lands in the app's default Keychain group, the first its entitlements list, which is the group it shares
/// with its extensions: Verso in Messages reads the account from there (ios/Messages), naming the app's bundle
/// identifier, the item's service, in its Info.plist (`VersoAppIdentity`). It is kept on this device only: readable
/// after the first unlock, as backing up in the background needs, and never carried to another device by a backup,
/// Quick Start or Migration Assistant, as it opens the whole library; a new device signs in once. On the Mac that is
/// the data protection Keychain, which an app asks for; the login Keychain ignores the setting and travels with the
/// Mac's backups, so an account kept there by an earlier Verso is moved over as it is read.
enum AccountVault {
    struct Entry: Codable {
        var name: String
        var email: String
        var userID: String
        var account: AccountStore.Account
    }
    /// The app's bundle identifier, in the app and in an extension of it alike.
    private static let service = Bundle.main.object(forInfoDictionaryKey: "VersoAppIdentity") as? String
        ?? Bundle.main.bundleIdentifier ?? "Verso"
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: "account-v1",
         kSecUseDataProtectionKeychain as String: true]
    }

    private static let accessible = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String

    /// The account signed in to; nil when none is. Unreadable contents are an error, which a sign-in replaces.
    static func load() throws -> Entry? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecReturnAttributes as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return moveFromLoginKeychain() }
        guard status == errSecSuccess, let item = result as? [String: Any], let data = item[kSecValueData as String] as? Data else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        // Kept by an earlier Verso, which let it travel: kept on this device, in place.
        if item[kSecAttrAccessible as String] as? String != accessible {
            SecItemUpdate(Self.query as CFDictionary, [kSecAttrAccessible as String: accessible] as CFDictionary)
        }
        return try JSONDecoder().decode(Entry.self, from: data)
    }

    /// On the Mac, an account an earlier Verso kept in the login Keychain: moved into this one, and removed there.
    /// Elsewhere there is no other Keychain.
    private static func moveFromLoginKeychain() -> Entry? {
        #if os(macOS)
        var found = loginQuery
        found[kSecReturnData as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(found as CFDictionary, &result) == errSecSuccess, let data = result as? Data,
              let entry = try? JSONDecoder().decode(Entry.self, from: data) else { return nil }
        // Where it cannot be moved, it is used where it is, and moved at the next read.
        if (try? save(entry)) != nil { SecItemDelete(loginQuery as CFDictionary) }
        return entry
        #else
        return nil
        #endif
    }

    #if os(macOS)
    /// The same item in the login Keychain, where an earlier Verso on the Mac kept it.
    private static var loginQuery: [String: Any] {
        var login = query
        login.removeValue(forKey: kSecUseDataProtectionKeychain as String)
        return login
    }
    #endif

    /// Keep this account, in place of any other.
    static func save(account: AccountStore.Account, user: User) throws {
        try save(Entry(name: user.name, email: user.email, userID: user.id, account: account))
    }

    private static func save(_ entry: Entry) throws {
        let data = try JSONEncoder().encode(entry)
        let attributes: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: accessible,
            kSecAttrLabel as String: "Verso account"]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item.merge(attributes) { _, new in new }
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "Could not save the account to Keychain (\(status))."])
        }
        AccountStore.lastServer = entry.account.serverURL.absoluteString
    }

    /// Forget the account, as signing out does.
    static func forget() throws {
        #if os(macOS)
        // One an earlier Verso left in the login Keychain goes too, or the next read would move it back.
        SecItemDelete(loginQuery as CFDictionary)
        #endif
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "Could not remove the account from Keychain (\(status))."])
        }
    }
}
