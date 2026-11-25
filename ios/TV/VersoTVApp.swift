// Verso on the Apple TV (ROADMAP.md, "Verso on the Apple TV"): a viewer for the living room, on the iPhone's API layer
// and the same Rust core. It signs in from the iPhone alone, with a read-only key of its own the person never sees.

import SwiftUI

@main
struct VersoTVApp: App {
    @State private var model = TVModel()

    init() {
        CoreTransport.install()
    }

    var body: some Scene {
        WindowGroup {
            TVRootView()
                .environment(model)
        }
    }
}

/// The signed-in server, as the TV keeps it, and the client and pictures made from it.
@MainActor @Observable
final class TVModel {
    private(set) var client: ImmichClient?
    private(set) var images: ImagePipeline?

    init() {
        #if DEBUG
        followLaunchArguments()
        #endif
        if client == nil, let account = TVAccount.load() { use(account) }
    }

    func use(_ account: TVAccount) {
        guard let server = URL(string: account.server) else { return }
        let client = ImmichClient(serverURL: server, apiURL: server.appendingPathComponent("api"),
                                  credential: .apiKey(account.key))
        self.client = client
        images = ImagePipeline(client: client)
    }

    func signIn(_ account: TVAccount) {
        account.save()
        use(account)
    }

    func signOut() {
        TVAccount.remove()
        client = nil
        images = nil
    }

    #if DEBUG
    /// A development build signs in from its launch arguments (`-signInServer URL -signInAPIKey KEY`), as Verso Dev does
    /// on the iPhone and the Mac, until the iPhone's Set Up Apple TV hands the key over.
    private func followLaunchArguments() {
        let defaults = UserDefaults.standard
        guard let server = defaults.string(forKey: "signInServer"), let url = URL(string: server) else { return }
        if let key = defaults.string(forKey: "signInAPIKey") {
            signIn(TVAccount(server: server, key: key))
        } else if let token = defaults.string(forKey: "signInAccessToken") {
            // A session from logging in (`-signInAccessToken`), for servers such as Immich's demo that make no keys.
            let client = ImmichClient(serverURL: url, apiURL: url.appendingPathComponent("api"), credential: .accessToken(token))
            self.client = client
            images = ImagePipeline(client: client)
        }
    }
    #endif
}
