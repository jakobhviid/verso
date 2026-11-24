import Foundation

/// An account as the vault keeps it (AccountVault), and the server last signed in to.
enum AccountStore {
    struct Account: Codable {
        var serverURL: URL
        var apiURL: URL
        var credential: Credential
    }

    private static let lastServerKey = "lastServerURL"

    static var lastServer: String? {
        get { UserDefaults.standard.string(forKey: lastServerKey) }
        set { UserDefaults.standard.set(newValue, forKey: lastServerKey) }
    }
}
