"""Exercise the real vault code against a unique test-only Keychain service.

No app launch, network calls, real AccountStore implementation, or real defaults.
"""
import pathlib
import subprocess
import uuid

root = pathlib.Path(__file__).resolve().parents[1]
output = root / 'build/AccountVaultChecks'
output.mkdir(parents=True, exist_ok=True)
service = 'Verso.AccountVaultChecks.' + str(uuid.uuid4())
vault = (root / 'Verso/App/AccountVault.swift').read_text()
vault = vault.replace('Bundle.main.bundleIdentifier ?? "Verso"', '"' + service + '"')
vault = vault.replace('UserDefaults.standard', 'UserDefaults(suiteName: "' + service + '")!')
# An unsigned tool has no Keychain group, which the data protection Keychain needs: the checks run on the login Keychain.
vault = vault.replace('kSecUseDataProtectionKeychain as String: true', 'kSecUseDataProtectionKeychain as String: false')
(output / 'AccountVault.swift').write_text(vault)
checks = r'''
import Foundation
import Security

enum AccountStore {
    struct Account: Codable {
        var serverURL: URL
        var apiURL: URL
        var credential: Credential
        var certificate: String? = nil
    }
    nonisolated(unsafe) static var lastServer: String?
}

@main struct VaultChecks {
    @MainActor static func main() async throws {
        let service = "TEST_SERVICE"
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: "account-v1"]
        defer {
            SecItemDelete(query as CFDictionary)
            UserDefaults(suiteName: service)!.removePersistentDomain(forName: service)
        }
        func user(_ id: String) throws -> User {
            try JSONDecoder().decode(User.self, from: Data("""
            {"id":"\(id)", "email":"\(id)@example.invalid", "name":"Test", "shouldChangePassword":true}
            """.utf8))
        }
        precondition(try AccountVault.load() == nil)
        let account = AccountStore.Account(serverURL: URL(string: "https://demo.immich.app")!,
            apiURL: URL(string: "https://demo.immich.app/api")!, credential: .accessToken("test-only"))
        try AccountVault.save(account: account, user: user("first"))
        precondition(try AccountVault.load()?.account.credential == account.credential)
        // One account: another sign-in takes its place.
        let other = AccountStore.Account(serverURL: URL(string: "https://other.invalid")!,
            apiURL: URL(string: "https://other.invalid/api")!, credential: .apiKey("other-key"))
        try AccountVault.save(account: other, user: user("second"))
        let replaced = try AccountVault.load()
        precondition(replaced?.userID == "second" && replaced?.account.credential == other.credential)
        // Unreadable contents are an error until a sign-in replaces them.
        let corrupt = Data("invalid-json".utf8)
        precondition(SecItemUpdate(query as CFDictionary, [kSecValueData as String: corrupt] as CFDictionary) == errSecSuccess)
        do { _ = try AccountVault.load(); preconditionFailure() } catch {}
        try AccountVault.save(account: account, user: user("first"))
        precondition(try AccountVault.load()?.userID == "first")
        // The certificate trusted for the account's server is kept with it, and trusted for that server alone.
        let pin = ServerTrust.fingerprint(of: Data("a certificate".utf8))
        try AccountVault.keep(certificate: pin.lowercased())
        precondition(try AccountVault.load()?.account.certificate == pin.lowercased())
        precondition(ServerTrust.certificate(for: account.apiURL) == pin)
        try AccountVault.save(account: other, user: user("second"))
        precondition(ServerTrust.certificate(for: account.apiURL) == nil, "another account's sign-in leaves it")
        try AccountVault.save(account: account, user: user("first"))
        try AccountVault.keep(certificate: nil)
        precondition(try AccountVault.load()?.account.certificate == nil && ServerTrust.certificate(for: account.apiURL) == nil)
        try AccountVault.forget()
        try AccountVault.forget()  // Forgetting none is no failure.
        precondition(try AccountVault.load() == nil)
        let mutation = AccountOperation()
        mutation.run { throw ImmichError.http(404, "Already deleted") }
        while mutation.busy { await Task.yield() }
        precondition(!mutation.unavailable && mutation.error == "Already deleted")
        let probe = AccountOperation()
        probe.run(probe: true) { throw ImmichError.http(404, nil) }
        while probe.busy { await Task.yield() }
        precondition(probe.unavailable)
        precondition(accountDate("2026-01-01T00:00:00.123Z") != "2026-01-01T00:00:00.123Z")
        precondition(accountDate("2026-01-01T00:00:00Z") != "2026-01-01T00:00:00Z")
        print("Vault/operation checks passed; temporary test service removed.")
    }
}
'''.replace('TEST_SERVICE', service)
# precondition's autoclosure cannot throw.
checks = checks.replace('precondition(try ', 'precondition(try! ')
(output / 'Checks.swift').write_text(checks)
sources = [str(p.relative_to(root)) for p in sorted((root / 'Verso/API').glob('*.swift'))] + ['Verso/App/AccountOperation.swift']
subprocess.run(['swiftc', '-swift-version', '6', *sources, str(output / 'AccountVault.swift'),
                str(output / 'Checks.swift'), '-o', str(output / 'check')], cwd=root, check=True)
subprocess.run([str(output / 'check')], cwd=root, check=True)
