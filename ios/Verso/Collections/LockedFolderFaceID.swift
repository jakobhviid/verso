// Face ID (Touch ID on an iPad that has it) for the Locked Folder on the iPhone and the iPad. Immich unlocks the folder
// only with the PIN, so the PIN that last unlocked it is kept in the Keychain, on this device alone, under an access
// control that asks for the faces or fingers enrolled when it was kept (biometryCurrentSet): iOS reads the face before
// it gives the PIN back, and the device's passcode never does. The Mac keeps its PIN behind the app's own Touch ID
// check (LockedFolderTouchID); here the Keychain is the guard. Enrolling another face or finger, a PIN the server
// turns down, signing out and turning Unlock with Face ID off forget it; until it is kept, the PIN is typed.

import LocalAuthentication
import Security
import SwiftUI

@MainActor
enum LockedFolderFaceID {
    /// Account ▸ Locked Folder ▸ Unlock with Face ID; on unless turned off.
    static let enabledKey = "lockedFolder.faceID"
    nonisolated private static let service = (Bundle.main.bundleIdentifier ?? "Verso") + ".locked-folder"

    /// Bumped whenever kept PINs are forgotten, so an unlock that started before cannot keep its PIN afterwards.
    private(set) static var epoch = 0

    enum Outcome { case pin(String), cancelled, unavailable }

    static var isEnabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    /// Face ID or Touch ID, as the device has it, enrolled or not; nil on a device with neither.
    static var biometryName: String? {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch context.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return nil
        }
    }

    /// The faces or fingers enrolled now, nil when none can be used.
    private static var enrollment: Data? {
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) else { return nil }
        return context.domainState.biometry.stateHash
    }

    /// The kept PINs are per server and user; there is no key without a user.
    static func key(server: URL, userID: String?) -> String? {
        guard let userID, !userID.isEmpty else { return nil }
        return server.absoluteString + "|" + userID
    }

    static func key(_ services: AccountServices) -> String? {
        key(server: services.client.serverURL, userID: services.cacheUserID)
    }

    nonisolated private static func query(_ key: String?) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        if let key { query[kSecAttrAccount as String] = key }
        return query
    }

    /// The enrollment the kept PIN was kept with, read without asking for a face; nil when no PIN is kept.
    private static func keptEnrollment(_ key: String) -> Data? {
        var query = query(key)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let attributes = result as? [String: Any] else { return nil }
        return attributes[kSecAttrGeneric as String] as? Data ?? Data()
    }

    /// A PIN is kept for the key, with the faces enrolled now, and Face ID is on: the Locked Folder may offer it.
    static func canUnlock(_ key: String?) -> Bool {
        guard isEnabled, let key, let kept = keptEnrollment(key) else { return false }
        return kept == enrollment
    }

    /// Keeps the PIN that was just typed and unlocked the folder, unless Face ID is off or none is enrolled, or PINs
    /// were forgotten since `epoch`. Throws when the Keychain refuses it.
    static func save(_ pin: String, for key: String, since epoch: Int) throws {
        guard isEnabled, epoch == self.epoch, let enrollment else { return }
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
                                                           .biometryCurrentSet, &error) else {
            throw error!.takeRetainedValue() as any Error
        }
        // An item behind Face ID is replaced by deleting it, which asks for no face, and adding the new one.
        SecItemDelete(query(key) as CFDictionary)
        var item = query(key)
        item[kSecValueData as String] = Data(pin.utf8)
        item[kSecAttrAccessControl as String] = access
        item[kSecAttrGeneric as String] = enrollment
        item[kSecAttrLabel as String] = "Verso Locked Folder"
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainFailure(status: status) }
    }

    /// Asks for Face ID, through the Keychain, and gives the kept PIN. A PIN kept with other faces enrolled, or one the
    /// Keychain no longer gives, is forgotten; a cancelled or failed face keeps it for the next time.
    static func pin(for key: String) async -> Outcome {
        guard let kept = keptEnrollment(key) else { return .unavailable }
        guard kept == enrollment else {
            forget(key)
            return .unavailable
        }
        let epoch = self.epoch, reason = String(localized: "Unlock the Locked Folder")
        let (status, pin) = await Task.detached { Self.read(key, reason: reason) }.value
        guard epoch == self.epoch else { return .unavailable }
        switch status {
        case errSecSuccess:
            guard let pin else { return .unavailable }
            return .pin(pin)
        case errSecItemNotFound:
            return .unavailable
        case errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed:
            return .cancelled
        default:
            forget(key)
            return .unavailable
        }
    }

    /// The Keychain's read, which shows Face ID and waits for it, off the main thread.
    nonisolated private static func read(_ key: String, reason: String) -> (OSStatus, String?) {
        let context = LAContext()
        context.localizedReason = reason
        var query = query(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationContext as String] = context
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, (result as? Data).flatMap { String(data: $0, encoding: .utf8) })
    }

    /// The server's answer to a wrong PIN: Immich's unlock replies 400 "Wrong PIN code", or 400 when the account has no
    /// PIN any more. 401 is the sign-in, and timeouts, server errors and offline keep the PIN.
    nonisolated static func rejectsPIN(_ error: any Error) -> Bool {
        if case ImmichError.http(400, _) = error { return true }
        return false
    }

    static func forget(_ key: String) {
        epoch += 1
        SecItemDelete(query(key) as CFDictionary)
    }

    /// Signing out forgets the account's PIN, and only its.
    static func forget(server: URL, userID: String?) {
        guard let key = key(server: server, userID: userID) else { return }
        forget(key)
    }

    /// Turning Face ID off or on forgets every kept PIN.
    static func forgetAll() {
        epoch += 1
        SecItemDelete(query(nil) as CFDictionary)
    }

    struct KeychainFailure: LocalizedError {
        let status: OSStatus
        var errorDescription: String? {
            String(localized: "The Keychain could not keep the Locked Folder PIN for Face ID (\(String(status))).")
        }
    }
}
