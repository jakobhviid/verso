import Foundation

/// What of Verso Drive the app keeps, for its `VersoDrive` (ARCHITECTURE.md, "Verso on the Mac"): the account the
/// drive signs in with, in the Keychain group and App Group its extension reads (`Account`, compiled
/// into this module from mac/Shared), the drive's settings (`config.toml`, the settings table Linux has), and what
/// the extension last saw of the server.
public enum DriveCore {
    /// Whether the drive is switched on (`mount.enabled`): off until the user switches it on, as on Linux.
    public static var isSwitchedOn: Bool { driveSwitchedOn(config: AppGroup.configText) }

    /// The location's name (`mount.name`).
    public static var name: String { driveName(config: AppGroup.configText) }

    /// Change one of the drive's settings in `config.toml`; refused with a message when the value does not fit.
    public static func set(_ key: String, to value: String) throws {
        let text = try setPreference(config: AppGroup.configText, key: key, value: value)
        try FileManager.default.createDirectory(at: AppGroup.container, withIntermediateDirectories: true)
        try text.write(to: AppGroup.configFile, atomically: true, encoding: .utf8)
    }

    /// The drive's settings with their values, for its Settings pane.
    public static func panes() throws -> SettingsPanes { try settingsPanes(config: AppGroup.configText) }

    /// The server the drive keeps an account for; nil when it keeps none.
    public static var server: String? { Account.load()?.server }

    /// Keep the gallery's account for the drive: one sign-in serves both, as on Linux. One of `apiKey` and
    /// `sessionToken`; `certificate` is the one trusted for the server where the system does not trust its own.
    public static func keepAccount(server: String, apiKey: String?, sessionToken: String?, certificate: String?,
                                   email: String?) throws {
        guard let credential = apiKey.map({ Credential.apiKey(key: $0) }) ?? sessionToken.map({ Credential.session(token: $0) })
        else { return }
        try Account(server: server, credential: credential, certificate: certificate).save()
        Account.keepEmail(email)
    }

    /// Forget the drive's account and what its extension kept: the credential, the address, the email, the last
    /// status and the metadata store. The session is the gallery's, so it stays.
    public static func forgetAccount() {
        Account.forget()
        try? FileManager.default.removeItem(at: AppGroup.libraryDirectory)
    }

    /// What the extension last saw of the server; nil before it ran.
    public static var status: DriveStatus? {
        Status.load().map { DriveStatus(online: $0.online, problem: $0.problem, version: $0.version, checked: $0.checked) }
    }

    /// The format of the bridge's items, part of every item's version: when it changes, the system reads them again.
    public static var currentItemFormat: UInt32 { itemFormat() }

    /// The App Group's folder, which the app and the extension share.
    public static var container: URL { AppGroup.container }
}

/// What the drive's extension last saw of the server.
public struct DriveStatus: Equatable, Sendable {
    public let online: Bool
    /// Why the server could not be reached, when it could not.
    public let problem: String?
    /// Immich's version, as `v3.3.5`, once known.
    public let version: String?
    public let checked: Date
}
