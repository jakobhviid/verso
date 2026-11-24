import Foundation

/// An account as the vault keeps it (AccountVault), and the server last signed in to.
enum AccountStore {
    struct Account: Codable {
        var serverURL: URL
        var apiURL: URL
        var credential: Credential
        /// The certificate trusted for the server where the system does not trust its own: its SHA-256 fingerprint,
        /// kept with the server it was trusted for (ServerTrust; ARCHITECTURE.md, "A certificate of the server's own").
        var certificate: String? = nil
    }

    private static let lastServerKey = "lastServerURL"

    static var lastServer: String? {
        get { UserDefaults.standard.string(forKey: lastServerKey) }
        set { UserDefaults.standard.set(newValue, forKey: lastServerKey) }
    }
}
