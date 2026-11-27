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
                // Leaving the front locks the Locked Folder.
                .task(id: phase) {
                    if phase == .active { await model.checkKey() } else { model.lockFolder() }
                }
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
    /// The Locked Folder while the iPhone has it open on this TV (TVLockedFolder), in memory alone.
    private(set) var lockedFolder: TVLockedFolderVisit?
    /// Why the Locked Folder did not open, or locked by itself.
    var lockedFolderReason: String?
    /// The Locked Folder is the place on screen, so a token the iPhone sends opens it; else it is ended at once.
    var lockedFolderInFront = false
    @ObservationIgnored private var checkingKey = false
    /// A token is being checked to open the Locked Folder: a second one meanwhile is let go, as ending its visit would
    /// end the session both share where it is the same token.
    @ObservationIgnored private var openingLockedFolder = false
    @ObservationIgnored private var topShelfRefresh: Task<Void, Never>?

    /// With Manage Photos on, the client of the second key, which may change and delete photos (TVPhotoMenu).
    private(set) var changes: ImmichClient?
    /// Why Manage Photos turned itself off, said on its page.
    var changesReason: String?
    @ObservationIgnored private var account: TVAccount?
    /// The TV's own model, for the Locked Folder's, whose photos are changed through its session but only where the TV's
    /// Manage Photos is on.
    @ObservationIgnored private(set) weak var owner: TVModel?

    /// The TV's own model: this, or the one a Locked Folder's model belongs to.
    var root: TVModel { owner ?? self }

    /// The Locked Folder's model: its session's client and pictures, which its grid and viewer read in place of the TV's.
    init(lockedFolder client: ImmichClient, images: ImagePipeline, owner: TVModel) {
        self.client = client
        self.images = images
        self.owner = owner
    }

    init() {
        #if DEBUG
        followLaunchArguments()
        #endif
        if client == nil, let account = TVAccount.load() { use(account) }
        // A key forgotten on the iPhone or deleted in Immich, met by any call while the TV is in use.
        ImmichClient.onUnauthorized = { [weak self] in
            Task { @MainActor in await self?.unauthorizedSeen() }
        }
    }

    func use(_ account: TVAccount) {
        guard let server = URL(string: account.server) else { return }
        let client = ImmichClient(serverURL: server, apiURL: server.appendingPathComponent("api"),
                                  credential: .apiKey(account.key))
        self.account = account
        self.client = client
        images = ImagePipeline(client: client)
        changes = account.changeKey.map {
            ImmichClient(serverURL: server, apiURL: server.appendingPathComponent("api"), credential: .apiKey($0))
        }
    }

    /// Manage Photos on, with the second key the iPhone sent.
    func allowChanges(key: String) {
        guard var account else { return }
        account.changeKey = key
        account.save()
        use(account)
        changesReason = nil
    }

    /// Manage Photos off: the second key goes from this TV at once, and asks nothing. It stays in Immich, as a key may
    /// not delete itself, until Read Only or Forget on the iPhone's Apple TV page.
    func stopChanges(reason: String? = nil) {
        guard var account, account.changeKey != nil else { return }
        account.changeKey = nil
        account.save()
        use(account)
        changesReason = reason
    }

    func signIn(_ account: TVAccount) {
        account.save()
        use(account)
        signedOutReason = nil
    }

    /// Signs out of this Apple TV. The key stays in Immich until the iPhone forgets the TV or it is deleted there: a
    /// read-only key may not delete itself.
    func signOut() {
        lockFolder()
        topShelfRefresh?.cancel()
        TVAccount.remove()
        account = nil
        client = nil
        changes = nil
        images = nil
        TVTopShelf.clear()
    }

    /// Asks Immich about the key as the TV comes back to Verso. A key turned down signs it out (`keyRejected`, which the
    /// client tells of too, from any call); any other failure (the server out of reach, no network) keeps it, so an
    /// outage never makes the person pair again. A reinstall keeps the key as well: the Keychain outlives the app, and
    /// tvOS offloads and reinstalls apps by itself when space runs low.
    func checkKey() async {
        guard let client else { return }
        _ = try? await client.currentUser()
    }

    /// A call met Immich's 401: the TV's key turned down, or the Locked Folder's session ended. Immich's answer about
    /// the key itself decides, asked past the client's own check so it tells of nothing more; the Locked Folder's
    /// session is checked too.
    func unauthorizedSeen() async {
        await lockedFolder?.verify()
        guard let client, !checkingKey, var request = try? client.request("users/me") else { return }
        request.cachePolicy = .reloadIgnoringLocalCacheData
        checkingKey = true
        defer { checkingKey = false }
        guard let (_, response) = try? await client.session.data(for: request) else { return }
        if (response as? HTTPURLResponse)?.statusCode == 401, self.client === client { keyRejected() }
    }

    /// Opens the Locked Folder with the token the iPhone sent: only for a session the server has unlocked, of the
    /// TV's own account, while the folder is still the place on screen; else the session is ended at once.
    func openLockedFolder(token: String) async {
        guard let client, lockedFolder == nil, !openingLockedFolder else { return }
        openingLockedFolder = true
        defer { openingLockedFolder = false }
        let visit = TVLockedFolderVisit(server: client.serverURL, apiURL: client.apiURL, token: token, owner: self)
        do {
            let status = try await visit.status()
            guard status.isElevated else { throw ImmichError.http(403, String(localized: "The server did not unlock the Locked Folder.")) }
            let (theirs, ours) = (try await visit.user(), try await client.currentUser())
            guard theirs.id == ours.id else { throw ImmichError.http(403, String(localized: "That iPhone is signed in to another account than this Apple TV.")) }
            guard lockedFolderInFront, self.client === client, lockedFolder == nil else { return visit.end() }
            visit.onExpired = { [weak self] reason in self?.lockFolder(reason) }
            visit.scheduleCheck(status.pinExpiresAt)
            lockedFolder = visit
        } catch {
            visit.end()
            lockedFolderReason = error.localizedDescription
        }
    }

    /// Locks the Locked Folder: its session ends on the server, and its pictures go.
    func lockFolder(_ reason: String? = nil) {
        guard let visit = lockedFolder else { return }
        lockedFolder = nil
        visit.end()
        lockedFolderReason = reason
    }

    /// Immich turned the key down: the TV was forgotten on the iPhone, or its key deleted in Immich. Its copy goes from
    /// the Keychain, the Top Shelf empties, and Set Up with iPhone says why.
    func keyRejected() {
        guard client != nil else { return }
        signOut()
        signedOutReason = String(localized: "This Apple TV was forgotten on your iPhone, or its key was deleted in Immich. Set it up again to come back.")
    }

    /// The Top Shelf's rows, written again (TVTopShelf); a refresh still running is cancelled, so the last one writes.
    func refreshTopShelf() async {
        guard let client, let images else { return }
        topShelfRefresh?.cancel()
        let refresh = Task { await TVTopShelf.refresh(client: client, images: images) }
        topShelfRefresh = refresh
        await refresh.value
    }

    /// A link from the Top Shelf: `memory/<id>`, `photo/<id>`, `album/<id>` or `person/<id>`, after the app's scheme.
    func open(_ url: URL) {
        let id = url.lastPathComponent
        switch url.host() {
        case "memory": opening = .memory(id)
        case "photo": opening = .photo(id)
        case "album": opening = .album(id)
        case "person": opening = .person(id)
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
            // Manage Photos' second key (`-tvChangeKey`), as the iPhone sends it.
            if let changeKey = defaults.string(forKey: "tvChangeKey") { allowChanges(key: changeKey) }
        } else if let token = defaults.string(forKey: "signInAccessToken") {
            // A session from logging in (`-signInAccessToken`), for servers such as Immich's demo that make no keys.
            let client = ImmichClient(serverURL: url, apiURL: url.appendingPathComponent("api"), credential: .accessToken(token))
            self.client = client
            images = ImagePipeline(client: client)
        }
    }
    #endif
}

/// Where a Top Shelf item opens the app: a memory's story, a photo in the viewer, an album's or a person's photos.
enum TVOpening: Equatable {
    case memory(String)
    case photo(String)
    case album(String)
    case person(String)
}
