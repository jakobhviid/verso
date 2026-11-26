// Verso on the Apple TV (ROADMAP.md, "Verso on the Apple TV"): a viewer for the living room, on the iPhone's API layer
// and the same Rust core. It signs in from the iPhone alone, with a read-only key of its own the person never sees.

import SwiftUI

@main
struct VersoTVApp: App {
    @State private var model = TVModel()
    @Environment(\.scenePhase) private var phase

    init() {
        CoreTransport.install()
    }

    var body: some Scene {
        WindowGroup {
            TVRootView()
                .environment(model)
                // A Top Shelf item: a memory or a photo (TVShelfData).
                .onOpenURL { model.open($0) }
                // Each time the TV comes back to Verso: a key forgotten on the iPhone, or deleted in Immich, signs it out.
                .task(id: phase) { if phase == .active { await model.checkKey() } }
        }
    }
}

/// The signed-in server, as the TV keeps it, and the client and pictures made from it.
@MainActor @Observable
final class TVModel {
    private(set) var client: ImmichClient?
    private(set) var images: ImagePipeline?
    /// What a Top Shelf item asked to open, until the place it opens in has opened it.
    var opening: TVOpening?
    /// Why the TV signed itself out, said on Set Up with iPhone.
    var signedOutReason: String?

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
        signedOutReason = nil
    }

    /// Signs out of this Apple TV. The key stays in Immich until the iPhone forgets the TV or it is deleted there: a
    /// read-only key may not delete itself.
    func signOut() {
        TVAccount.remove()
        client = nil
        images = nil
        TVTopShelf.clear()
    }

    /// Immich turning the key down means the TV was forgotten: it signs out and says so. Any other failure (the server
    /// out of reach) leaves it signed in.
    func checkKey() async {
        guard let client else { return }
        do {
            _ = try await client.currentUser()
        } catch ImmichError.unauthorized {
            signOut()
            signedOutReason = String(localized: "This Apple TV was forgotten on your iPhone, or its key was deleted in Immich. Set it up again to come back.")
        } catch {}
    }

    /// The Top Shelf's memories and newest photos, written again (TVTopShelf).
    func refreshTopShelf() async {
        guard let client, let images else { return }
        await TVTopShelf.refresh(client: client, images: images)
    }

    /// A link from the Top Shelf: `memory/<id>` or `photo/<id>`, after the app's scheme.
    func open(_ url: URL) {
        let id = url.lastPathComponent
        switch url.host() {
        case "memory": opening = .memory(id)
        case "photo": opening = .photo(id)
        default: break
        }
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

/// Where a Top Shelf item opens the app: a memory's story, or a photo in the viewer.
enum TVOpening: Equatable {
    case memory(String)
    case photo(String)
}
