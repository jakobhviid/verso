import Foundation

// The shared Rust core as Verso's Mac app uses it (ARCHITECTURE.md, "Verso on the Mac"). This file is compiled with the
// bridge's generated bindings (mac/build/Generated, from shared/verso-bridge) into the module VersoCore, apart
// from the app's own, so the bindings' types (its `Credential`, `Item`) do not meet the app's of the same names.

/// Start the core's log. Once, first thing, in the app and in each extension that talks to Immich.
public func startVersoCore() {
    startLogging()
}

/// One account's way to Immich's API through the core, which adds the credential, the user agent, retries as the
/// method allows and the reachability gate. It answers as URLSession does: the data and an `HTTPURLResponse`, whatever
/// the status, or a `URLError` when no answer came.
public final class CoreConnection: Sendable {
    private let connection: ApiConnection
    private let apiURL: URL
    private let credential: Credential?

    /// An account's connection: `apiKey` or `sessionToken`, or neither before signing in.
    public init(apiURL: URL, apiKey: String? = nil, sessionToken: String? = nil) throws {
        let credential: Credential? = apiKey.map { .apiKey(key: $0) } ?? sessionToken.map { .session(token: $0) }
        connection = try ApiConnection(api: apiURL.absoluteString, credential: credential)
        self.apiURL = apiURL
        self.credential = credential
    }

    /// Send a request made for this API (`apiURL` and an endpoint below it). The credential, user agent and framing
    /// headers it carries are the core's to set, and left out.
    public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        guard let url = request.url, let path = endpoint(of: url) else { throw URLError(.unsupportedURL) }
        let query = (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .map { ApiField(name: $0.name, value: $0.value ?? "") }
        let headers = (request.allHTTPHeaderFields ?? [:]).map { ApiField(name: $0.key, value: $0.value) }
        let answer: ApiAnswer
        do {
            answer = try await connection.send(method: request.httpMethod ?? "GET", path: path, query: query,
                                               headers: headers, body: request.httpBody)
        } catch BridgeError.ServerUnreachable(message: let message) {
            throw URLError(.cannotConnectToHost, userInfo: [NSLocalizedDescriptionKey: message])
        } catch {
            throw URLError(.cannotLoadFromNetwork, userInfo: [NSLocalizedDescriptionKey: error.localizedDescription])
        }
        let fields = Dictionary(answer.headers.map { ($0.name, $0.value) }, uniquingKeysWith: { first, _ in first })
        guard let response = HTTPURLResponse(url: url, statusCode: Int(answer.status), httpVersion: "HTTP/1.1",
                                             headerFields: fields)
        else { throw URLError(.badServerResponse) }
        return (answer.body, response)
    }

    /// The endpoint below the API's address that `url` names, as `assets/{id}`, not percent-encoded; nil for a URL
    /// elsewhere.
    private func endpoint(of url: URL) -> String? {
        guard url.scheme == apiURL.scheme, url.host == apiURL.host, url.port == apiURL.port else { return nil }
        let base = apiURL.path.hasSuffix("/") ? String(apiURL.path.dropLast()) : apiURL.path
        guard url.path.hasPrefix(base + "/") else { return nil }
        return String(url.path.dropFirst(base.count + 1))
    }
}

// MARK: Typed calls

/// Why a typed call failed, in the kinds the app tells apart: signed out, refused, gone, out of reach, turned down
/// with a status of the server's own (a validation failure's 400) and its reason.
public enum CoreError: LocalizedError, Sendable {
    case signedOut
    case notPermitted(String)
    case notFound
    case unreachable(String)
    case refused(status: Int, message: String)
    case failed(String)

    init(_ error: BridgeError) {
        switch error {
        case .NotAuthenticated: self = .signedOut
        case .NotPermitted(let message): self = .notPermitted(message)
        case .NoSuchItem: self = .notFound
        case .ServerUnreachable(let message): self = .unreachable(message)
        case .Refused(let status, let message): self = .refused(status: Int(status), message: message)
        case .Failed(let message): self = .failed(message)
        case .AnchorExpired, .Cancelled: self = .failed(error.localizedDescription)
        }
    }

    public var errorDescription: String? {
        switch self {
        case .signedOut: "signed out of Immich"
        case .notPermitted(let message), .unreachable(let message), .refused(_, let message), .failed(let message): message
        case .notFound: "not found on the Immich server"
        }
    }
}

extension CoreConnection {
    /// A timeline's months, through immich-api's own call (ARCHITECTURE.md, "Verso on the Mac", "Typed calls").
    public func timelineMonths(_ source: TimelineSource, _ settings: TimelineSettings) async throws -> [TimelineMonth] {
        try await typed { try await connection.timelineMonths(source: source, settings: settings) }
    }

    /// One month of a timeline, by its bucket key.
    public func timelineMonth(_ source: TimelineSource, _ settings: TimelineSettings, bucket: String) async throws -> [TimelineAsset] {
        try await typed { try await connection.timelineMonth(source: source, settings: settings, bucket: bucket) }
    }

    /// The account's albums: its own and those shared with it.
    public func galleryAlbums() async throws -> [GalleryAlbum] {
        try await typed { try await connection.albums() }
    }

    /// One album, without its Assets.
    public func galleryAlbum(id: String) async throws -> GalleryAlbum {
        try await typed { try await connection.album(id: id) }
    }

    /// One page of people.
    public func galleryPeoplePage(_ query: GalleryPeopleQuery) async throws -> GalleryPeoplePage {
        try await typed { try await connection.peoplePage(query: query) }
    }

    public func galleryPerson(id: String) async throws -> GalleryPerson {
        try await typed { try await connection.person(id: id) }
    }

    /// How many Assets show the person.
    public func galleryPersonStatistics(id: String) async throws -> UInt64 {
        try await typed { try await connection.personStatistics(id: id) }
    }

    /// One photo or video, read whole.
    public func galleryAsset(id: String) async throws -> GalleryAsset {
        try await typed { try await connection.asset(id: id) }
    }

    public func gallerySharedLinks() async throws -> [GallerySharedLink] {
        try await typed { try await connection.sharedLinks() }
    }

    public func gallerySharedLink(id: String) async throws -> GallerySharedLink {
        try await typed { try await connection.sharedLink(id: id) }
    }

    /// `shared-by` or `shared-with`.
    public func galleryPartners(direction: String) async throws -> [GalleryPartner] {
        try await typed { try await connection.partners(direction: direction) }
    }

    public func galleryUsers() async throws -> [GalleryUser] {
        try await typed { try await connection.users() }
    }

    /// One page of a search: smart, or by its filters.
    public func gallerySearch(_ search: GallerySearch, smart: Bool) async throws -> GallerySearchPage {
        try await typed { try await connection.search(search: search, smart: smart) }
    }

    public func galleryAdminUsers(withDeleted: Bool) async throws -> [GalleryAdminUser] {
        try await typed { try await connection.adminUsers(withDeleted: withDeleted) }
    }

    public func galleryLibraries() async throws -> [GalleryLibrary] {
        try await typed { try await connection.libraries() }
    }

    public func galleryQueues() async throws -> [GalleryQueue] {
        try await typed { try await connection.queues() }
    }

    /// Change the same things on every photo in `ids`.
    public func galleryUpdateAssets(_ ids: [String], _ changes: GalleryAssetChanges) async throws {
        try await typed { try await connection.updateAssets(ids: ids, changes: changes) }
    }

    public func galleryDeleteAssets(_ ids: [String], force: Bool) async throws {
        try await typed { try await connection.deleteAssets(ids: ids, force: force) }
    }

    public func galleryRestoreAssets(_ ids: [String]) async throws {
        _ = try await typed { try await connection.restoreAssets(ids: ids) }
    }

    public func galleryCreateAlbum(name: String, description: String?, assetIds: [String]) async throws -> GalleryAlbum {
        try await typed { try await connection.createAlbum(name: name, description: description, assetIds: assetIds) }
    }

    public func galleryUpdateAlbum(id: String, _ changes: GalleryAlbumChanges) async throws -> GalleryAlbum {
        try await typed { try await connection.updateAlbum(id: id, changes: changes) }
    }

    public func galleryDeleteAlbum(id: String) async throws {
        try await typed { try await connection.deleteAlbum(id: id) }
    }

    /// Add photos to an album, or take them out: each photo's outcome.
    public func galleryChangeAlbumAssets(id: String, assetIds: [String], removing: Bool) async throws -> [GalleryIdResult] {
        try await typed { try await connection.changeAlbumAssets(id: id, assetIds: assetIds, removing: removing) }
    }

    /// Share an album with an account, as `editor` or `viewer`.
    public func galleryAddAlbumMember(id: String, userId: String, role: String) async throws {
        try await typed { try await connection.addAlbumMember(id: id, userId: userId, role: role) }
    }

    public func galleryUpdateAlbumMember(id: String, userId: String, role: String) async throws {
        try await typed { try await connection.updateAlbumMember(id: id, userId: userId, role: role) }
    }

    public func galleryRemoveAlbumMember(id: String, userId: String) async throws {
        try await typed { try await connection.removeAlbumMember(id: id, userId: userId) }
    }

    public func galleryCreatePerson(name: String) async throws -> GalleryPerson {
        try await typed { try await connection.createPerson(name: name) }
    }

    public func galleryUpdatePerson(id: String, _ changes: GalleryPersonChanges) async throws -> GalleryPerson {
        try await typed { try await connection.updatePerson(id: id, changes: changes) }
    }

    /// Merge people into the person `id`: an outcome for `id` first, then one per merged person.
    public func galleryMergePeople(id: String, mergedIds: [String]) async throws -> [GalleryIdResult] {
        try await typed { try await connection.mergePeople(id: id, mergedIds: mergedIds) }
    }

    /// Give a face to another person; the person it now shows.
    public func galleryReassignFace(faceId: String, personId: String) async throws -> GalleryPerson {
        try await typed { try await connection.reassignFace(faceId: faceId, personId: personId) }
    }

    public func galleryDeleteFace(faceId: String) async throws {
        try await typed { try await connection.deleteFace(faceId: faceId) }
    }

    /// A link to an album, or to chosen photos when `albumId` is nil.
    public func galleryCreateSharedLink(albumId: String?, assetIds: [String], _ options: GallerySharingOptions) async throws -> GallerySharedLink {
        try await typed { try await connection.createSharedLink(albumId: albumId, assetIds: assetIds, options: options) }
    }

    public func galleryUpdateSharedLink(id: String, _ options: GallerySharingOptions) async throws -> GallerySharedLink {
        try await typed { try await connection.updateSharedLink(id: id, options: options) }
    }

    public func galleryDeleteSharedLink(id: String) async throws {
        try await typed { try await connection.deleteSharedLink(id: id) }
    }

    /// Add photos to a link to chosen photos, or take them out: each photo's outcome.
    public func galleryChangeSharedLinkAssets(id: String, assetIds: [String], removing: Bool) async throws -> [GalleryIdResult] {
        try await typed { try await connection.changeSharedLinkAssets(id: id, assetIds: assetIds, removing: removing) }
    }

    public func galleryAddPartner(userId: String) async throws {
        try await typed { try await connection.addPartner(userId: userId) }
    }

    public func galleryRemovePartner(userId: String) async throws {
        try await typed { try await connection.removePartner(userId: userId) }
    }

    public func gallerySetPartnerInTimeline(userId: String, inTimeline: Bool) async throws {
        try await typed { try await connection.setPartnerInTimeline(userId: userId, inTimeline: inTimeline) }
    }

    /// The server's version; needs no credential.
    public func galleryServerVersion() async throws -> GalleryVersion {
        try await typed { try await connection.serverVersion() }
    }

    /// The server's switches; needs no credential.
    public func galleryServerFeatures() async throws -> GalleryFeatures {
        try await typed { try await connection.serverFeatures() }
    }

    /// The signed-in account.
    public func galleryMe() async throws -> GalleryAccount {
        try await typed { try await connection.me() }
    }

    public func galleryAuthStatus() async throws -> GalleryAuthStatus {
        try await typed { try await connection.authStatus() }
    }

    public func galleryTags() async throws -> [GalleryTag] {
        try await typed { try await connection.tags() }
    }

    public func galleryMapMarkers(_ query: GalleryMapQuery) async throws -> [GalleryMarker] {
        try await typed { try await connection.mapMarkers(query: query) }
    }

    /// Every server folder that holds the account's photos.
    public func galleryFolderPaths() async throws -> [String] {
        try await typed { try await connection.folderPaths() }
    }

    /// The photos directly in one server folder.
    public func galleryFolderAssets(path: String) async throws -> [GalleryAsset] {
        try await typed { try await connection.folderAssets(path: path) }
    }

    /// One photo for each city the account has photos in.
    public func galleryCityAssets() async throws -> [GalleryAsset] {
        try await typed { try await connection.cityAssets() }
    }

    /// One page of the memories shown on `day` (`2026-11-15`), neither trashed nor upcoming.
    public func galleryMemories(day: String, page: UInt32, size: UInt32) async throws -> [GalleryMemory] {
        try await typed { try await connection.memories(day: day, page: page, size: size) }
    }

    public func galleryStack(id: String) async throws -> GalleryStackDetails {
        try await typed { try await connection.stack(id: id) }
    }

    public func galleryDuplicates() async throws -> [GalleryDuplicateGroup] {
        try await typed { try await connection.duplicates() }
    }

    /// The faces on a photo.
    public func galleryFaces(assetId: String) async throws -> [GalleryFace] {
        try await typed { try await connection.faces(assetId: assetId) }
    }

    /// A photo's edit steps, in order.
    public func galleryAssetEdits(id: String) async throws -> [GalleryEdit] {
        try await typed { try await connection.assetEdits(id: id) }
    }

    /// An album's comments and likes, oldest first, or one photo's in it.
    public func galleryActivities(albumId: String, assetId: String?) async throws -> [GalleryActivity] {
        try await typed { try await connection.activities(albumId: albumId, assetId: assetId) }
    }

    public func galleryActivityStatistics(albumId: String, assetId: String?) async throws -> GalleryActivityStatistics {
        try await typed { try await connection.activityStatistics(albumId: albumId, assetId: assetId) }
    }

    public func gallerySuggestions(_ query: GallerySuggestionQuery) async throws -> [String] {
        try await typed { try await connection.suggestions(query: query) }
    }

    /// Explore's groups: places, and things where the server recognises them.
    public func galleryExplore() async throws -> [GalleryExploreGroup] {
        try await typed { try await connection.explore() }
    }

    /// The extensions of the images and videos the server takes; needs no credential.
    public func galleryMediaTypes() async throws -> [String] {
        try await typed { try await connection.mediaTypes() }
    }

    /// Stack photos, the first the primary.
    public func galleryCreateStack(assetIds: [String]) async throws -> GalleryStackDetails {
        try await typed { try await connection.createStack(assetIds: assetIds) }
    }

    public func gallerySetStackPrimary(id: String, assetId: String) async throws -> GalleryStackDetails {
        try await typed { try await connection.setStackPrimary(id: id, assetId: assetId) }
    }

    /// Unstack: the photos stay.
    public func galleryDeleteStack(id: String) async throws {
        try await typed { try await connection.deleteStack(id: id) }
    }

    public func galleryRemoveFromStack(id: String, assetId: String) async throws {
        try await typed { try await connection.removeFromStack(id: id, assetId: assetId) }
    }

    public func galleryDismissDuplicates(id: String) async throws {
        try await typed { try await connection.dismissDuplicates(id: id) }
    }

    /// Keep some of a group's photos and move the rest to the trash: each outcome.
    public func galleryResolveDuplicates(id: String, keep: [String], trash: [String]) async throws -> [GalleryIdResult] {
        try await typed { try await connection.resolveDuplicates(id: id, keep: keep, trash: trash) }
    }

    /// Make a tag at a path (`Parent/Child`), its parents too.
    public func galleryUpsertTag(path: String) async throws {
        try await typed { try await connection.upsertTag(path: path) }
    }

    /// Rename a tag and give it a colour, or none when `color` is empty.
    public func galleryUpdateTag(id: String, name: String, color: String) async throws {
        try await typed { try await connection.updateTag(id: id, name: name, color: color) }
    }

    public func galleryDeleteTag(id: String) async throws {
        try await typed { try await connection.deleteTag(id: id) }
    }

    /// Tag photos, or untag them: each photo's outcome.
    public func galleryChangeTagAssets(id: String, assetIds: [String], removing: Bool) async throws -> [GalleryIdResult] {
        try await typed { try await connection.changeTagAssets(id: id, assetIds: assetIds, removing: removing) }
    }

    public func galleryMarkMemorySeen(id: String) async throws {
        try await typed { try await connection.markMemorySeen(id: id) }
    }

    /// Keep a memory, so Immich's cleanup leaves it, or let it go again.
    public func gallerySetMemorySaved(id: String, saved: Bool) async throws {
        try await typed { try await connection.setMemorySaved(id: id, saved: saved) }
    }

    public func galleryDeleteMemory(id: String) async throws {
        try await typed { try await connection.deleteMemory(id: id) }
    }

    public func galleryRemoveMemoryAssets(id: String, assetIds: [String]) async throws -> [GalleryIdResult] {
        try await typed { try await connection.removeMemoryAssets(id: id, assetIds: assetIds) }
    }

    /// Open the Locked Folder for this session with the PIN code, setting it first when `setUp`.
    public func galleryUnlockLockedFolder(pinCode: String, setUp: Bool) async throws {
        try await typed { try await connection.unlockLockedFolder(pinCode: pinCode, setUp: setUp) }
    }

    public func galleryLockLockedFolder() async throws {
        try await typed { try await connection.lockLockedFolder() }
    }

    /// A photo's edit steps, in order; none undoes its edit.
    public func gallerySetAssetEdits(id: String, edits: [GalleryEdit]) async throws {
        try await typed { try await connection.setAssetEdits(id: id, edits: edits) }
    }

    /// A comment, or a like when `comment` is nil; on a photo of the album when `assetId` is set.
    public func galleryAddActivity(albumId: String, assetId: String?, comment: String?) async throws -> GalleryActivity {
        try await typed { try await connection.addActivity(albumId: albumId, assetId: assetId, comment: comment) }
    }

    public func galleryDeleteActivity(id: String) async throws {
        try await typed { try await connection.deleteActivity(id: id) }
    }

    /// Rename the account; the account as it then is.
    public func galleryRenameAccount(name: String) async throws -> GalleryAccount {
        try await typed { try await connection.renameAccount(name: name) }
    }

    public func galleryChangePassword(current: String, new: String, signOutOthers: Bool) async throws {
        try await typed { try await connection.changePassword(current: current, new: new, signOutOthers: signOutOthers) }
    }

    /// Set the account's picture from a JPEG.
    public func gallerySetProfilePicture(jpeg: Data) async throws {
        try await typed { try await connection.setProfilePicture(jpeg: jpeg) }
    }

    public func galleryRemoveProfilePicture() async throws {
        try await typed { try await connection.removeProfilePicture() }
    }

    public func galleryApiKeys() async throws -> [GalleryApiKey] {
        try await typed { try await connection.apiKeys() }
    }

    /// A new key, with its secret, shown only now.
    public func galleryCreateApiKey(name: String, permissions: [String]) async throws -> GalleryNewApiKey {
        try await typed { try await connection.createApiKey(name: name, permissions: permissions) }
    }

    public func galleryRenameApiKey(id: String, name: String) async throws {
        try await typed { try await connection.renameApiKey(id: id, name: name) }
    }

    public func galleryDeleteApiKey(id: String) async throws {
        try await typed { try await connection.deleteApiKey(id: id) }
    }

    /// The devices signed in to the account.
    public func gallerySessions() async throws -> [GallerySession] {
        try await typed { try await connection.sessions() }
    }

    public func galleryDeleteSession(id: String) async throws {
        try await typed { try await connection.deleteSession(id: id) }
    }

    /// Sign every other device out.
    public func galleryDeleteOtherSessions() async throws {
        try await typed { try await connection.deleteOtherSessions() }
    }

    public func galleryNotifications() async throws -> [GalleryNotification] {
        try await typed { try await connection.notifications() }
    }

    /// Mark notifications read, now.
    public func galleryMarkNotificationsRead(ids: [String]) async throws {
        try await typed { try await connection.markNotificationsRead(ids: ids) }
    }

    public func galleryDeleteNotification(id: String) async throws {
        try await typed { try await connection.deleteNotification(id: id) }
    }

    /// Make an account; needs an administrator, as the calls below do.
    public func galleryCreateAccount(_ settings: GalleryAccountSettings) async throws {
        try await typed { try await connection.createAccount(settings: settings) }
    }

    /// Change an account: an empty password leaves it as it is.
    public func galleryUpdateAccount(id: String, _ settings: GalleryAccountSettings) async throws {
        try await typed { try await connection.updateAccount(id: id, settings: settings) }
    }

    public func galleryDeleteAccount(id: String, force: Bool) async throws {
        try await typed { try await connection.deleteAccount(id: id, force: force) }
    }

    public func galleryRestoreAccount(id: String) async throws {
        try await typed { try await connection.restoreAccount(id: id) }
    }

    public func galleryCreateLibrary(ownerId: String, _ settings: GalleryLibrarySettings) async throws {
        try await typed { try await connection.createLibrary(ownerId: ownerId, settings: settings) }
    }

    public func galleryUpdateLibrary(id: String, _ settings: GalleryLibrarySettings) async throws {
        try await typed { try await connection.updateLibrary(id: id, settings: settings) }
    }

    public func galleryScanLibrary(id: String) async throws {
        try await typed { try await connection.scanLibrary(id: id) }
    }

    public func galleryDeleteLibrary(id: String) async throws {
        try await typed { try await connection.deleteLibrary(id: id) }
    }

    /// `pause`, `resume`, `empty`, `clear-failed` or `start` (every photo with `force`) a job queue.
    public func galleryCommandQueue(name: String, command: String, force: Bool) async throws {
        try await typed { try await connection.commandQueue(name: name, command: command, force: force) }
    }

    /// Sign in with a password at this connection's server, through the core's sign-in: the
    /// session's token. Its refusals are messages for people ("Wrong email or password.").
    public func gallerySignIn(email: String, password: String) async throws -> String {
        let signedIn = try await typed { try await signInWithPassword(server: apiURL.absoluteString, email: email, password: password) }
        guard case .session(let token) = signedIn.credential else { throw CoreError.failed("the server answered without a session") }
        return token
    }

    /// End this connection's session on the server, as signing out does; an API key has none. Whatever the server
    /// says, signing out goes on.
    public func galleryEndSession() async {
        guard let credential else { return }
        await endSession(server: apiURL.absoluteString, credential: credential)
    }

    /// Tell the connection whether the server can be reached: while it cannot, its requests fail at once.
    public func gallerySetReachable(_ reachable: Bool) {
        connection.setReachable(reachable: reachable)
    }

    /// Whether the server answers, within a few seconds, even while it is taken as unreachable.
    public func galleryPing() async throws {
        try await typed { try await connection.ping() }
    }

    private func typed<Value>(_ call: () async throws -> Value) async throws -> Value {
        do {
            return try await call()
        } catch let error as BridgeError {
            throw CoreError(error)
        }
    }
}

// MARK: Arrangements

// What the gallery arranges comes from the core (`overviewYears`, `overviewPicks`, `mapClusters`; ARCHITECTURE.md,
// "Verso on the Mac"), the same as on Linux. In SwiftUI's lists a year of the Library's Years is known by its year,
// and a cluster of the map by its first photo.
extension OverviewYear: Identifiable {}
extension MapCluster: Identifiable {}
