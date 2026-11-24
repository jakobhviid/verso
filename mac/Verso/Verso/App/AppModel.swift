#if os(macOS)
import AppKit
/// The system's image type, NSImage on the Mac and UIImage on iOS, so a stored property holding one stays outside
/// `#if`, where `@Observable` would leave it untracked.
typealias PlatformImage = NSImage
#else
import UIKit
typealias PlatformImage = UIImage
#endif
import Network
import Observation
import os

@MainActor @Observable
final class AppModel {
    enum Phase {
        case launching
        case signedOut
        case signedIn(AccountServices)
    }
    private(set) var phase: Phase = .launching {
        didSet { // Widget
            #if os(macOS)
            switch phase {
            case .signedIn(let services): WidgetFeedUpdater.shared.start(services)
            case .signedOut: WidgetFeedUpdater.shared.clear()
            case .launching: break
            }
            #endif
        }
    }
    /// Signing in or out is under way.
    private(set) var switching = false
    var accountError: String?

    var services: AccountServices? {
        if case .signedIn(let services) = phase { services } else { nil }
    }

    @ObservationIgnored private var restoreTask: Task<Void, Never>?

    #if os(macOS)
    init() { MacIntegrationRouter.shared.app = self }
    #else
    init() {}
    #endif

    func restore() async {
        if let restoreTask { await restoreTask.value; return }
        guard case .launching = phase else { return }
        let task = Task { await restoreAccount() }
        restoreTask = task
        await task.value
    }

    private func restoreAccount() async {
        do {
            guard let saved = try AccountVault.load() else {
                phase = .signedOut
                return
            }
            let account = saved.account
            let client = ImmichClient(serverURL: account.serverURL, apiURL: account.apiURL, credential: account.credential)
            let user: User?
            do { user = try await client.currentUser() }
            catch ImmichError.unauthorized {
                #if os(macOS)
                try LockedFolderTouchID.forget(server: saved.account.serverURL, userID: saved.userID)
                #endif
                try AccountVault.forget()
                try removeSavedCache(saved)
                // Verso Drive: the account's location goes too.
                await VersoDrive.shared.accountRemoved(apiURL: saved.account.apiURL, userID: saved.userID, credential: nil)
                phase = .signedOut
                return
            } catch { user = nil }
            if let user { try AccountVault.save(account: account, user: user) }
            start(client: client, user: user, cacheUserID: user?.id ?? saved.userID)
        } catch {
            accountError = error.localizedDescription
            phase = .signedOut
        }
    }

#if DEBUG
    /// Launch arguments a script signs Verso Dev in and out with (the mac-dev skill):
    /// `-signInServer <address>` with `-signInAPIKey <key>`, or with `-signInEmail` and `-signInPassword` for a
    /// session; `-signOut YES`; `-versoDrive on` or `off`, as its switch in Settings on the Mac and in the account's
    /// sheet on iOS. `-versoDrive` alone switches the drive; with `-signInServer` it switches first, so the sign-in
    /// brings the drive up. Each outcome goes to the log (subsystem dev.hviid.Verso, category app).
    func followLaunchArguments() async {
        let arguments = UserDefaults.standard
        let log = Logger(subsystem: "dev.hviid.Verso", category: "app")
        if let wanted = arguments.string(forKey: "versoDrive") {
            await restore()
            await VersoDrive.shared.setOn(wanted == "on")
            log.info("launch arguments: Verso Drive \(VersoDrive.shared.isOn ? "on" : "off", privacy: .public), error: \(VersoDrive.shared.error ?? "none", privacy: .public)")
            guard arguments.string(forKey: "signInServer") != nil else { return }
        }
        if arguments.bool(forKey: "signOut") {
            await restore()
            await signOut()
            log.info("launch arguments: signed out")
            return
        }
        guard let server = arguments.string(forKey: "signInServer") else { return }
        do {
            let client = try await ImmichClient.discover(server)
            let credential: Credential
            if let key = arguments.string(forKey: "signInAPIKey") {
                credential = .apiKey(key)
            } else if let email = arguments.string(forKey: "signInEmail"), let password = arguments.string(forKey: "signInPassword") {
                credential = .accessToken(try await client.login(email: email, password: password))
            } else {
                log.error("launch arguments: -signInServer needs -signInAPIKey, or -signInEmail and -signInPassword")
                return
            }
            await restore()
            try await signIn(client: client, credential: credential)
            log.info("launch arguments: signed in to \(client.serverURL.absoluteString, privacy: .public) as \(self.services?.user?.email ?? "?", privacy: .public)")
        } catch {
            log.error("launch arguments: signing in failed: \(error.localizedDescription, privacy: .public)")
        }
    }
#endif

    func signIn(client: ImmichClient, credential: Credential) async throws {
        guard !switching else { return }
        switching = true
        defer { switching = false }
        let authed = client.with(credential: credential)
        let user = try await authed.currentUser()
        try AccountVault.save(account: .init(serverURL: authed.serverURL, apiURL: authed.apiURL, credential: credential), user: user)
        start(client: authed, user: user, cacheUserID: user.id)
    }

    func signOut() async {
        guard !switching, let services else { return }
        switching = true
        defer { switching = false }
        var userIDForFinder: String?
        do {
            // Persist removal first: a vault failure must leave the live login intact. The kept Locked Folder PIN
            // goes before the account, so it can't outlive it.
            let userID = services.user?.id ?? (try? AccountVault.load())?.userID
            userIDForFinder = userID
            #if os(macOS)
            try LockedFolderTouchID.forget(server: services.client.serverURL, userID: userID)
            #endif
            try AccountVault.forget()
        } catch { accountError = error.localizedDescription; return }
        guard self.services === services else { return }
        endSession(services)
        phase = .signedOut
        // Verso Drive: the account's location goes too.
        if let userID = services.user?.id ?? userIDForFinder {
            await VersoDrive.shared.accountRemoved(apiURL: services.client.apiURL, userID: userID, credential: services.client.credential)
            if let error = VersoDrive.shared.error { accountError = error }
        }
        if case .accessToken = services.client.credential { try? await services.client.logout() }
        do { try clearCache(services) } catch { accountError = error.localizedDescription }
        // The Live Photos' motions the viewer kept are the account's photos too.
        await LiveMotions.shared.removeAll()
    }

    private func endSession(_ services: AccountServices) {
        services.stopWatchingReach()
        services.bootstrapTask?.cancel()
        services.notificationTask?.cancel()
        services.upload.cancelAll()
        for window in services.windows.allObjects { window.endSession() }
        services.pipeline.removeAll()
        #if os(macOS)
        MacIntegrationRouter.shared.pending.removeAll()
        MacIntegrationRouter.shared.widgetLinks.removeAll() // Widget
        MacQuickLook.shared.dismiss()
        #endif
    }

    private func removeSavedCache(_ entry: AccountVault.Entry) throws {
        try ImmichClient.removeAccountCache(apiURL: entry.account.apiURL, userID: entry.userID)
        let fallback = try JSONEncoder().encode(entry.account.credential).base64EncodedString()
        try ImmichClient.removeAccountCache(apiURL: entry.account.apiURL, userID: "offline-" + fallback)
    }

    private func clearCache(_ services: AccountServices) throws {
        if let credential = services.client.credential {
            let fallback = try JSONEncoder().encode(credential).base64EncodedString()
            try ImmichClient.removeAccountCache(apiURL: services.client.apiURL, userID: "offline-" + fallback)
        }
        try ImmichClient.removeAccountCache(apiURL: services.client.apiURL, userID: services.cacheUserID)
        if let id = services.user?.id, id != services.cacheUserID {
            try ImmichClient.removeAccountCache(apiURL: services.client.apiURL, userID: id)
        }
    }

    private func start(client: ImmichClient, user: User?, cacheUserID: String) {
        let isolated = client.accountIsolated(userID: cacheUserID)
        let services = AccountServices(client: isolated, user: user, cacheUserID: cacheUserID)
        services.onUnauthorized = { [weak self, weak services] in
            Task {
                guard let self, self.services === services else { return }
                await self.signOut()
            }
        }
        services.onUserLoaded = { [weak self, weak services] user in
            guard let self, self.services === services, !self.switching, let credential = client.credential else { return }
            do {
                try AccountVault.save(account: .init(serverURL: client.serverURL, apiURL: client.apiURL, credential: credential), user: user)
            } catch { self.accountError = error.localizedDescription }
        }
        if let previous = self.services { endSession(previous) }
        #if os(macOS)
        MacIntegrationRouter.shared.pending.removeAll()
        MacQuickLook.shared.dismiss()
        #endif
        phase = .signedIn(services)
        services.bootstrapTask = Task { await services.bootstrap() }
        VersoDrive.shared.start(client: client, user: user) // Verso Drive: takes the account, and comes up when switched on
    }
}

/// Everything that belongs to one signed-in server/user.
@MainActor @Observable
final class AccountServices {
    let client: ImmichClient
    let sharing: SharingModel // Sharing
    let upload: UploadQueue // Upload
    let metadata = MetadataSharedState()
    /// Albums' other photos, and links' photos, for their cards.
    let albumPreviews = AlbumPreviews()
    let linkPreviews = LinkPreviews()
    /// When each place was last visited, for sorting Places.
    let placeVisits: PlaceVisits
    /// Verso's own notifications (the imports that ended), beside the server's in the bell.
    let versoNotifications: VersoNotifications
    let pipeline: ImagePipeline
    private(set) var user: User?
    private(set) var features = ServerFeatures()
    private(set) var version: ServerVersion?
    private(set) var albums: [Album] = []
    private(set) var preferences: AccountPreferences? // Account: loaded preferences for feature consumers.
    var explorePreferences: ExplorePreferences?
    var exploreTags: [ExploreTag] = []
    var exploreTagsEnabled = false
    @ObservationIgnored private var exploreTagsLoaded = false
    @ObservationIgnored private var exploreTagsTask: Task<Void, Never>?

    func loadExploreTags(refresh: Bool = false) async {
        if let task = exploreTagsTask { await task.value; if !refresh { return } }
        guard refresh || !exploreTagsLoaded else { return }
        let task = Task {
            do {
                explorePreferences = try await client.explorePreferences()
                exploreTagsEnabled = explorePreferences?.tags?.enabled == true
                exploreTags = exploreTagsEnabled ? try await client.exploreTags().sorted { $0.value.localizedStandardCompare($1.value) == .orderedAscending } : []
                exploreTagsLoaded = true
            } catch { handle(error) }
        }
        exploreTagsTask = task
        await task.value
        exploreTagsTask = nil
    }

    let cacheUserID: String
    @ObservationIgnored var onUserLoaded: (User) -> Void = { _ in }
    @ObservationIgnored var onUnauthorized: () -> Void = {}
    @ObservationIgnored let windows = NSHashTable<LibrarySession>.weakObjects()

    init(client: ImmichClient, user: User?, cacheUserID: String) {
        self.cacheUserID = cacheUserID
        self.client = client
        self.placeVisits = PlaceVisits(account: client.apiURL.absoluteString + "|" + cacheUserID)
        self.versoNotifications = VersoNotifications(account: client.apiURL.absoluteString + "|" + cacheUserID)
        self.sharing = SharingModel(client: client)
        self.pipeline = ImagePipeline(client: client)
        self.upload = UploadQueue(client: client)
        self.upload.onFinished = { [weak self] albums in // Upload
            self?.invalidateGrids()
            // An album's page reads its header again, its count following the photos that joined it.
            for album in albums { self?.windows.allObjects.first?.invalidateAlbumGrid(album) }
            Task { await self?.reloadAlbums() }
        }
        self.upload.onError = { [weak self] in self?.handle($0) } // Upload
        self.upload.onEnded = { [weak self] in self?.versoNotifications.add($0) } // Upload
        self.user = user
        // The core's connection outlives a session; a new one starts taking the server as reachable.
        client.setServerReachable(true)
    }

    @ObservationIgnored var bootstrapTask: Task<Void, Never>?
    var notifications: [AccountNotification] = []
    var notificationsAvailable = true
    var notificationError: String?
    @ObservationIgnored var notificationTask: Task<Void, Never>?
    func reloadNotifications() async throws {
        notifications = try await client.accountNotifications().sorted { $0.createdAt > $1.createdAt }
    }
    func startNotifications() {
        notificationTask = Task { [weak self] in
            var delay = 60
            while !Task.isCancelled {
                guard self != nil else { return }
                do {
                    try await self?.reloadNotifications()
                    self?.notificationError = nil
                    delay = 60
                } catch is CancellationError { return }
                catch ImmichError.http(404, _), ImmichError.http(403, _) { self?.notificationsAvailable = false; return }
                catch {
                    self?.notificationError = error.localizedDescription
                    self?.handle(error)
                    delay = min(delay * 2, 900)
                }
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            }
        }
    }

    func bootstrap() async {
        startNotifications()
        async let features = try? client.serverFeatures()
        async let version = try? client.serverVersion()
        async let user = try? client.currentUser()
        self.features = await features ?? ServerFeatures()
        guard !Task.isCancelled else { return }
        self.version = await version
        if let user = await user, !Task.isCancelled { self.user = user; onUserLoaded(user) }
        guard !Task.isCancelled else { return }
        Task { [weak self] in await self?.loadProfilePicture() }
        preferences = try? await client.accountPreferences()
        await reloadAlbums()
        await sharing.reload() // Sharing
        await loadExploreTags()
    }

    /// Preference reads and saves run one after another, so the server ends with the last change and reopening
    /// Settings never reads it before an earlier save has landed.
    @ObservationIgnored private var preferencesQueue: Task<Void, Never>?
    /// Why the last preferences save failed, kept until Settings shows it (a save made as Settings closed).
    var preferencesSaveError: String?

    func queuePreferences<T: Sendable>(_ work: @escaping @MainActor () async throws -> T) async throws -> T {
        let previous = preferencesQueue
        let task = Task { await previous?.value; return try await work() }
        preferencesQueue = Task { _ = await task.result }
        return try await task.value
    }

    var preferencesRevision = 0
    func setPreferences(_ value: AccountPreferences) {
        preferences = value
        preferencesRevision += 1
        Task { await loadExploreTags(refresh: true); await sharing.reload() }
    }

    func refreshAccountUser() async throws {
        user = try await client.currentUser()
        await loadProfilePicture()
    }

    /// Account: the signed-in user's picture, shown in the sidebar and in Settings.
    private(set) var profilePicture: PlatformImage?
    func loadProfilePicture() async {
        guard let user, let path = user.profileImagePath, !path.isEmpty else { profilePicture = nil; return }
        let picture: PlatformImage?
        do {
            var request = try client.request("users/\(user.id)/profile-image")
            request.cachePolicy = .reloadIgnoringLocalCacheData
            picture = PlatformImage(data: try await client.data(for: request))
        } catch { picture = nil }
        // An older load finishing late must not bring back a replaced or removed picture.
        if self.user?.profileImagePath == path { profilePicture = picture }
    }

    var requiresPasswordChange: Bool {
        guard case .accessToken = client.credential else { return false }
        return user?.requiresPasswordChange(passwordLoginEnabled: features.passwordLogin) == true
    }

    func reloadAlbums() async {
        do {
            albums = try await client.albums().sorted { // Albums: owned and shared with the account
                ($0.lastModifiedAssetTimestamp ?? "") > ($1.lastModifiedAssetTimestamp ?? "")
            }
        } catch { handle(error) }
    }

    func invalidateGrids() {
        for window in windows.allObjects { window.invalidateMacWindowGrids() }
        VersoDrive.shared.signalSoon() // Verso Drive
    }

    var hiddenAssetIDs: Set<String> = []

    func removeFromGrids(_ ids: Set<String>) {
        hiddenAssetIDs.formUnion(ids)
        for window in windows.allObjects { window.removeFromGrids(ids) }
        #if os(macOS)
        MacQuickLook.shared.dismiss()
        #endif
        VersoDrive.shared.signalSoon() // Verso Drive
    }

    func handle(_ error: Error) {
        if case ImmichError.unauthorized = error { onUnauthorized(); return }
        if let reason = Self.unreachableReason(error) { askAfterFailure(reason) }
    }

    // MARK: When the server cannot be reached

    /// Why the server cannot be reached, for the banner under each page's header; nil while it answers.
    private(set) var unreachable: String?
    /// Asking whether it is back, from Try Now.
    private(set) var checkingReach = false
    /// Counts the times the server answered again, so the window reads its page again.
    private(set) var reconnections = 0
    @ObservationIgnored private var reachTask: Task<Void, Never>?
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    /// When a failure last had the server asked, so a burst of failures asks once.
    @ObservationIgnored private var lastAsked: Date?

    /// A request failed in a way that may mean the server went away: as on Linux, the server is asked, and taken as
    /// unreachable only when it does not answer either. A busy server (a 5xx, a 429) or a slow request is not one
    /// that went away.
    private func askAfterFailure(_ reason: String) {
        guard unreachable == nil else { return }
        if let lastAsked, Date().timeIntervalSince(lastAsked) < 10 { return }
        lastAsked = Date()
        Task { [weak self] in
            guard let self else { return }
            do { try await self.client.pingServer() } catch { self.serverUnreachable(reason) }
        }
    }

    /// The session ends: stop asking, and leave the core's connection, which outlives it, taking the server as
    /// reachable for the next.
    func stopWatchingReach() {
        reachTask?.cancel()
        reachTask = nil
        pathMonitor?.cancel()
        pathMonitor = nil
        unreachable = nil
        client.setServerReachable(true)
    }

    /// The server is taken as unreachable after a failure that says so, as on Linux (ARCHITECTURE.md, "Verso on the
    /// Mac"): the core's requests then fail at once, and it is asked every 10 seconds, and on a change of network,
    /// until it answers.
    private func serverUnreachable(_ reason: String) {
        unreachable = reason
        client.setServerReachable(false)
        guard reachTask == nil else { return }
        reachTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard let self, self.unreachable != nil else { return }
                await self.checkReach()
            }
        }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            // A new network's addresses and names may not be ready at once.
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(3))
                await self?.checkReach()
            }
        }
        monitor.start(queue: .main)
        pathMonitor = monitor
    }

    /// Ask the server whether it answers (Try Now, and every 10 seconds while it does not); when it does, the core's
    /// requests go out again, and the window reads its page again.
    func checkReach() async {
        guard unreachable != nil, !checkingReach else { return }
        checkingReach = true
        defer { checkingReach = false }
        do {
            try await client.pingServer()
        } catch {
            if let reason = Self.unreachableReason(error) { unreachable = reason }
            return
        }
        unreachable = nil
        client.setServerReachable(true)
        reachTask?.cancel()
        reachTask = nil
        pathMonitor?.cancel()
        pathMonitor = nil
        reconnections += 1
        for window in windows.allObjects { window.serverAnswered() }
        await reloadAlbums()
        await sharing.reload()
        await loadExploreTags(refresh: true)
    }

    /// The failures that mean the server could not be reached, rather than that it refused.
    static func unreachableReason(_ error: Error) -> String? {
        guard let urlError = error as? URLError else { return nil }
        switch urlError.code {
        case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .notConnectedToInternet, .networkConnectionLost,
             .timedOut, .internationalRoamingOff, .dataNotAllowed, .secureConnectionFailed:
            return urlError.localizedDescription
        default:
            return nil
        }
    }
}

/// Navigation, selection and presentations belong to one window.
@MainActor @Observable
final class LibrarySession {
    let services: AccountServices
    /// Set for the session that shows an unlocked Locked Folder inside a window.
    let lockedFolder: LockedFolderMedia?
    @ObservationIgnored var lockFolder: () -> Void = {}
    @ObservationIgnored var closeViewer: () -> Void = {}
    #if os(macOS)
    /// The library window showing this session (Widget: clicks open photos in the frontmost one).
    @ObservationIgnored weak var macWindow: NSWindow?
    #endif
    func endSession() { lockFolder(); closeViewer(); lockFolder = {}; closeViewer = {} }
    let albumActions = AlbumsActions()
    let metadata: MetadataState
    let sharing: SharingModel
    @ObservationIgnored private var gridModels: [GridSource: AssetGridModel] = [:]
    var client: ImmichClient { lockedFolder?.client ?? services.client }
    var pipeline: ImagePipeline { lockedFolder?.pipeline ?? services.pipeline }
    var upload: UploadQueue { services.upload }
    var user: User? { services.user }
    var features: ServerFeatures { services.features }
    var version: ServerVersion? { services.version }
    var albums: [Album] { services.albums }
    var preferences: AccountPreferences? { services.preferences }
    var preferencesRevision: Int { services.preferencesRevision }
    var exploreTags: [ExploreTag] { services.exploreTags }
    var exploreTagsEnabled: Bool { services.exploreTagsEnabled }
    var cacheUserID: String { services.cacheUserID }
    init(services: AccountServices, lockedFolder: LockedFolderMedia? = nil) {
        self.services = services
        self.lockedFolder = lockedFolder
        metadata = MetadataState(shared: services.metadata)
        sharing = SharingModel(client: services.client, data: services.sharing.data)
        services.windows.add(self)
    }
    func reloadAlbums() async { await services.reloadAlbums() }
    func loadExploreTags(refresh: Bool = false) async { await services.loadExploreTags(refresh: refresh) }
    /// Grid models are cached per source so switching sidebar items keeps loaded data.
    func gridModel(for source: GridSource) -> AssetGridModel {
        if let model = gridModels[source] { return model }
        let previousSearch = gridModels.first { key, _ in
            if case .filteredSearch = key { return true }; return false
        }?.value
        // Only retain the current search, including its loaded pages.
        switch source {
        case .search, .filteredSearch:
            gridModels = gridModels.filter { key, model in
                switch key {
                case .search, .filteredSearch: model.cancelLoading(); return false
                default: return true
                }
            }
        default: break
        }
        let model = AssetGridModel(source: source, session: self, reusing: previousSearch)
        gridModels[source] = model
        return model
    }

    /// A photo some grid of this window has loaded, as Share reads whether it is a video.
    func loadedItem(_ id: String) -> AssetItem? {
        gridModels.values.lazy.compactMap { $0.item(id) }.first
    }

    func invalidateAlbumGrid(_ id: String) {
        VersoDrive.shared.signalSoon() // Verso Drive
        for window in services.windows.allObjects {
            window.gridModels[.album(id)]?.markStale()
            window.albumActions.revisions[id, default: 0] += 1
        }
    }

    func discardAlbumGrid(_ id: String) {
        gridModels.removeValue(forKey: .album(id))
        albumActions.details.removeValue(forKey: id)
    }

    var macGridRevision = 0

    func invalidateMacWindowGrids() {
        for model in gridModels.values { model.markStale() }
        macGridRevision += 1
    }

    /// Mutations affect cached grids in every window for this account.
    /// The server answers again: what failed to load reads again at once, and the rest when it is next shown.
    func serverAnswered() {
        for model in gridModels.values {
            if case .failed = model.state { Task { await model.reload() } } else { model.markStale() }
        }
        macGridRevision += 1
    }

    func invalidateGrids(except keep: AssetGridModel? = nil) {
        for model in gridModels.values where model !== keep { model.markStale() }
        macGridRevision += 1
        for window in services.windows.allObjects where window !== self { window.invalidateMacWindowGrids() }
        VersoDrive.shared.signalSoon() // Verso Drive
    }

    func setLocationInGrids(_ ids: [String], latitude: Double, longitude: Double) {
        for window in services.windows.allObjects {
            for model in window.gridModels.values { model.setLocation(ids, latitude: latitude, longitude: longitude) }
        }
    }

    // Explore
    func exploreRemoveFromGrids(_ ids: Set<String>) {
        services.removeFromGrids(ids)
    }

    func removeFromGrids(_ ids: Set<String>) {
        if let snapshot = metadata.viewerSnapshot, ids.contains(snapshot.id) { metadata.viewerSnapshot = nil }
        for model in gridModels.values {
            // Items moved into the Locked Folder from elsewhere belong in this grid.
            if model.source == .locked { model.markStale(); continue }
            if let id = model.viewerID, ids.contains(id) { closeViewer() }
            model.exploreRemove(ids)
        }
    }

    func handle(_ error: Error) {
        // An expired unlock fails Locked Folder requests; that locks the folder, it doesn't sign out.
        if let lockedFolder { if !error.isCancellation { lockedFolder.requestFailed() }; return }
        services.handle(error)
    }
}
