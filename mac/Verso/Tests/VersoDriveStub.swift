// The offline checks' stand-in for Verso Drive (Verso/App/VersoDrive.swift), which needs the shared Rust core
// (VersoCore): the app model's hooks, doing nothing.
import Foundation
import Observation

@MainActor @Observable
final class VersoDrive {
    static let shared = VersoDrive()
    var error: String?

    func start(client: ImmichClient, user: User?) {}
    func signalSoon() {}
    func certificateChanged() {}
    func accountRemoved(apiURL: URL, userID: String, credential: Credential?) async {}
}
