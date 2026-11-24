import Foundation

enum Credential: Codable, Sendable, Equatable {
    /// Session token from `POST /auth/login`. Shows up under "Authorized devices" in Immich.
    case accessToken(String)
    /// API key created in Immich → Account Settings → API Keys.
    case apiKey(String)

    var headers: [String: String] {
        switch self {
        case .accessToken(let token): ["Authorization": "Bearer \(token)"]
        case .apiKey(let key): ["x-api-key": key]
        }
    }
}

enum ImmichError: LocalizedError {
    case invalidServerURL
    case serverUnreachable(String)
    case unauthorized(String?)
    case http(Int, String?)

    var errorDescription: String? {
        switch self {
        case .invalidServerURL:
            String(localized: "That doesn't look like a valid server address.")
        case .serverUnreachable(let detail):
            String(localized: "Couldn't reach an Immich server at that address. \(detail)")
        case .unauthorized(let message):
            message ?? String(localized: "Your session has expired or the credentials are wrong.")
        case .http(let code, let message):
            message ?? String(localized: "The server returned an error (\(code)).")
        }
    }
}

/// A way for endpoint calls to reach Immich other than the client's own URLSession, answering as URLSession does.
/// It may also answer an area's calls itself, typed (the shared Rust core's immich-api, ARCHITECTURE.md, "Verso on
/// the Mac"): nil from one sends that call as a request instead.
protocol ImmichTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
    func timeBuckets(_ timeline: any TimelineRequest) async throws -> [TimeBucket]?
    func timeBucket(_ bucket: String, _ timeline: any TimelineRequest) async throws -> TimeBucketAssets?
    func albums() async throws -> [Album]?
    func albumDetails(_ id: String) async throws -> AlbumDetails?
    func peoplePage(page: Int, size: Int, withHidden: Bool, name: String?, filters: [String: String]) async throws -> PeopleResponse?
    func person(_ id: String) async throws -> Person?
    func personStatistics(_ id: String) async throws -> PeopleStatistics?
    func asset(_ id: String) async throws -> AssetResponse?
    func sharedLinks() async throws -> [SharedLink]?
    func sharedLink(_ id: String) async throws -> SharedLink?
    func sharingPartners(direction: String) async throws -> [SharingPartner]?
    func users() async throws -> [User]?
    func search(_ request: AdvancedSearchRequest, smart: Bool) async throws -> SearchResponse.Assets?
    func adminUsers() async throws -> [AdminUser]?
    func adminLibraries() async throws -> [AdminLibrary]?
    func adminQueues() async throws -> [AdminQueue]?
    // Changes answer true once done, false to send them as requests.
    func updateAssets(_ ids: [String], _ changes: AssetChangeSet) async throws -> Bool
    func deleteAssets(_ ids: [String], force: Bool) async throws -> Bool
    func restoreAssets(_ ids: [String]) async throws -> Bool
    func createAlbum(name: String, description: String?, assetIDs: [String]) async throws -> AlbumDetails?
    func updateAlbum(_ id: String, _ update: AlbumUpdate) async throws -> AlbumDetails?
    func deleteAlbum(_ id: String) async throws -> Bool
    func changeAlbumAssets(_ id: String, ids: [String], removing: Bool) async throws -> [AlbumAssetResult]?
    func addAlbumUser(_ id: String, userID: String, role: String) async throws -> Bool
    func updateAlbumUser(_ id: String, userID: String, role: String) async throws -> Bool
    func removeAlbumUser(_ id: String, userID: String) async throws -> Bool
    func createPerson(name: String) async throws -> Person?
    func editPerson(_ id: String, _ edit: PersonEdit) async throws -> Person?
    func mergePeople(into id: String, ids: [String]) async throws -> [PeopleOperationResult]?
    func reassignFace(_ faceID: String, to personID: String) async throws -> Person?
    func removeFace(_ id: String) async throws -> Bool
    func createSharedLink(albumID: String?, assetIDs: [String], options: SharingOptions) async throws -> SharedLink?
    func editSharedLink(_ id: String, options: SharingOptions, keepPassword: Bool) async throws -> SharedLink?
    func deleteSharedLink(_ id: String) async throws -> Bool
    func changeSharedLinkAssets(_ id: String, assetIDs: [String], adding: Bool) async throws -> [AlbumAssetResult]?
    func addSharingPartner(_ id: String) async throws -> Bool
    func removeSharingPartner(_ id: String) async throws -> Bool
    func updateSharingPartner(_ id: String, inTimeline: Bool) async throws -> Bool
    func serverVersion() async throws -> ServerVersion?
    func serverFeatures() async throws -> ServerFeatures?
    func currentUser() async throws -> User?
    func exploreAuth() async throws -> ExploreAuthStatus?
    func exploreTags() async throws -> [ExploreTag]?
    func exploreMarkers(favorites: Bool, archived: Bool, partners: Bool, after: Date?, before: Date?) async throws -> [ExploreMarker]?
    func explorePaths() async throws -> [String]?
    func folderAssets(_ path: String) async throws -> [AssetResponse]?
    func exploreCities() async throws -> [AssetResponse]?
    func exploreMemories(day: String, page: Int, size: Int) async throws -> [ExploreMemory]?
    func assetsStack(_ id: String) async throws -> AssetsStack?
    func assetsDuplicates() async throws -> [AssetsDuplicate]?
    func faces(assetID: String) async throws -> [PeopleFace]?
    func metadataEdits(_ id: String) async throws -> MetadataEdits?
    func albumActivities(_ id: String, assetID: String?) async throws -> [AlbumActivity]?
    func albumActivityStatistics(_ id: String, assetID: String?) async throws -> AlbumActivityStatistics?
    func searchSuggestions(type: String, country: String?, state: String?, make: String?, model: String?) async throws -> [String]?
    func searchExplore() async throws -> [SearchExploreGroup]?
    func uploadMediaTypes() async throws -> UploadMediaTypes?
    func assetsCreateStack(_ ids: [String]) async throws -> AssetsStack?
    func assetsSetPrimary(stack: String, asset: String) async throws -> AssetsStack?
    func assetsUnstack(_ id: String) async throws -> Bool
    func assetsRemoveFromStack(_ id: String, asset: String) async throws -> Bool
    func assetsDismissDuplicate(_ id: String) async throws -> Bool
    func assetsResolveDuplicate(_ id: String, keep: [String], trash: [String]) async throws -> [AssetsBulkResult]?
    func exploreCreateTag(_ path: String) async throws -> Bool
    func exploreUpdateTag(_ id: String, name: String, color: String) async throws -> Bool
    func exploreDeleteTag(_ id: String) async throws -> Bool
    func exploreTagAssets(_ ids: [String], tag: String, remove: Bool) async throws -> [ExploreBulkResult]?
    func exploreSeenMemory(_ id: String) async throws -> Bool
    func exploreKeepMemory(_ id: String, keep: Bool) async throws -> Bool
    func exploreDeleteMemory(_ id: String) async throws -> Bool
    func exploreRemoveMemoryAsset(_ memory: String, asset: String) async throws -> [ExploreBulkResult]?
    func exploreUnlock(_ pin: String, setup: Bool) async throws -> Bool
    func exploreLock() async throws -> Bool
    func saveMetadataEdits(_ id: String, edits: [MetadataEdit]) async throws -> Bool
    func createAlbumActivity(_ id: String, assetID: String?, comment: String?) async throws -> AlbumActivity?
    func deleteAlbumActivity(_ id: String) async throws -> Bool
    func updateAccountName(_ name: String) async throws -> User?
    func changeAccountPassword(current: String, new: String, invalidateSessions: Bool) async throws -> Bool
    func uploadAccountPicture(_ jpeg: Data) async throws -> Bool
    func removeAccountPicture() async throws -> Bool
    func accountKeys() async throws -> [AccountAPIKey]?
    func createAccountKey(name: String, permissions: [String]) async throws -> AccountAPIKeySecret?
    func renameAccountKey(id: String, name: String) async throws -> Bool
    func deleteAccountKey(_ id: String) async throws -> Bool
    func accountDevices() async throws -> [AccountDevice]?
    func deleteAccountDevice(_ id: String) async throws -> Bool
    func deleteOtherAccountDevices() async throws -> Bool
    func accountNotifications() async throws -> [AccountNotification]?
    func readAccountNotifications(_ ids: [String]) async throws -> Bool
    func deleteAccountNotification(_ id: String) async throws -> Bool
    func adminSaveUser(id: String?, input: AdminUserInput) async throws -> Bool
    func adminDeleteUser(_ id: String, force: Bool) async throws -> Bool
    func adminRestoreUser(_ id: String) async throws -> Bool
    func adminSaveLibrary(id: String?, input: AdminLibraryInput) async throws -> Bool
    func adminScanLibrary(_ id: String) async throws -> Bool
    func adminDeleteLibrary(_ id: String) async throws -> Bool
    func adminQueueCommand(_ name: String, command: String, force: Bool?) async throws -> Bool
    func passwordSession(email: String, password: String) async throws -> String?
    func endSession() async -> Bool
    func setReachable(_ reachable: Bool) -> Bool
    func ping() async throws -> Bool
}

/// What to change on photos, for a transport's typed call; nil leaves a field as it is.
struct AssetChangeSet: Sendable {
    var isFavorite: Bool?
    var visibility: String?
    var dateTimeOriginal: String?
    var dateTimeRelative: Int?
    var timeZone: String?
    var latitude: Double?
    var longitude: Double?
    var description: String?
    var rating: Int?
    var clearRating = false
}

extension ImmichTransport {
    func timeBuckets(_ timeline: any TimelineRequest) async throws -> [TimeBucket]? { nil }
    func timeBucket(_ bucket: String, _ timeline: any TimelineRequest) async throws -> TimeBucketAssets? { nil }
    func albums() async throws -> [Album]? { nil }
    func albumDetails(_ id: String) async throws -> AlbumDetails? { nil }
    func peoplePage(page: Int, size: Int, withHidden: Bool, name: String?, filters: [String: String]) async throws -> PeopleResponse? { nil }
    func person(_ id: String) async throws -> Person? { nil }
    func personStatistics(_ id: String) async throws -> PeopleStatistics? { nil }
    func asset(_ id: String) async throws -> AssetResponse? { nil }
    func sharedLinks() async throws -> [SharedLink]? { nil }
    func sharedLink(_ id: String) async throws -> SharedLink? { nil }
    func sharingPartners(direction: String) async throws -> [SharingPartner]? { nil }
    func users() async throws -> [User]? { nil }
    func search(_ request: AdvancedSearchRequest, smart: Bool) async throws -> SearchResponse.Assets? { nil }
    func adminUsers() async throws -> [AdminUser]? { nil }
    func adminLibraries() async throws -> [AdminLibrary]? { nil }
    func adminQueues() async throws -> [AdminQueue]? { nil }
    func updateAssets(_ ids: [String], _ changes: AssetChangeSet) async throws -> Bool { false }
    func deleteAssets(_ ids: [String], force: Bool) async throws -> Bool { false }
    func restoreAssets(_ ids: [String]) async throws -> Bool { false }
    func createAlbum(name: String, description: String?, assetIDs: [String]) async throws -> AlbumDetails? { nil }
    func updateAlbum(_ id: String, _ update: AlbumUpdate) async throws -> AlbumDetails? { nil }
    func deleteAlbum(_ id: String) async throws -> Bool { false }
    func changeAlbumAssets(_ id: String, ids: [String], removing: Bool) async throws -> [AlbumAssetResult]? { nil }
    func addAlbumUser(_ id: String, userID: String, role: String) async throws -> Bool { false }
    func updateAlbumUser(_ id: String, userID: String, role: String) async throws -> Bool { false }
    func removeAlbumUser(_ id: String, userID: String) async throws -> Bool { false }
    func createPerson(name: String) async throws -> Person? { nil }
    func editPerson(_ id: String, _ edit: PersonEdit) async throws -> Person? { nil }
    func mergePeople(into id: String, ids: [String]) async throws -> [PeopleOperationResult]? { nil }
    func reassignFace(_ faceID: String, to personID: String) async throws -> Person? { nil }
    func removeFace(_ id: String) async throws -> Bool { false }
    func createSharedLink(albumID: String?, assetIDs: [String], options: SharingOptions) async throws -> SharedLink? { nil }
    func editSharedLink(_ id: String, options: SharingOptions, keepPassword: Bool) async throws -> SharedLink? { nil }
    func deleteSharedLink(_ id: String) async throws -> Bool { false }
    func changeSharedLinkAssets(_ id: String, assetIDs: [String], adding: Bool) async throws -> [AlbumAssetResult]? { nil }
    func addSharingPartner(_ id: String) async throws -> Bool { false }
    func removeSharingPartner(_ id: String) async throws -> Bool { false }
    func updateSharingPartner(_ id: String, inTimeline: Bool) async throws -> Bool { false }
    func serverVersion() async throws -> ServerVersion? { nil }
    func serverFeatures() async throws -> ServerFeatures? { nil }
    func currentUser() async throws -> User? { nil }
    func exploreAuth() async throws -> ExploreAuthStatus? { nil }
    func exploreTags() async throws -> [ExploreTag]? { nil }
    func exploreMarkers(favorites: Bool, archived: Bool, partners: Bool, after: Date?, before: Date?) async throws -> [ExploreMarker]? { nil }
    func explorePaths() async throws -> [String]? { nil }
    func folderAssets(_ path: String) async throws -> [AssetResponse]? { nil }
    func exploreCities() async throws -> [AssetResponse]? { nil }
    func exploreMemories(day: String, page: Int, size: Int) async throws -> [ExploreMemory]? { nil }
    func assetsStack(_ id: String) async throws -> AssetsStack? { nil }
    func assetsDuplicates() async throws -> [AssetsDuplicate]? { nil }
    func faces(assetID: String) async throws -> [PeopleFace]? { nil }
    func metadataEdits(_ id: String) async throws -> MetadataEdits? { nil }
    func albumActivities(_ id: String, assetID: String?) async throws -> [AlbumActivity]? { nil }
    func albumActivityStatistics(_ id: String, assetID: String?) async throws -> AlbumActivityStatistics? { nil }
    func searchSuggestions(type: String, country: String?, state: String?, make: String?, model: String?) async throws -> [String]? { nil }
    func searchExplore() async throws -> [SearchExploreGroup]? { nil }
    func uploadMediaTypes() async throws -> UploadMediaTypes? { nil }
    func assetsCreateStack(_ ids: [String]) async throws -> AssetsStack? { nil }
    func assetsSetPrimary(stack: String, asset: String) async throws -> AssetsStack? { nil }
    func assetsUnstack(_ id: String) async throws -> Bool { false }
    func assetsRemoveFromStack(_ id: String, asset: String) async throws -> Bool { false }
    func assetsDismissDuplicate(_ id: String) async throws -> Bool { false }
    func assetsResolveDuplicate(_ id: String, keep: [String], trash: [String]) async throws -> [AssetsBulkResult]? { nil }
    func exploreCreateTag(_ path: String) async throws -> Bool { false }
    func exploreUpdateTag(_ id: String, name: String, color: String) async throws -> Bool { false }
    func exploreDeleteTag(_ id: String) async throws -> Bool { false }
    func exploreTagAssets(_ ids: [String], tag: String, remove: Bool) async throws -> [ExploreBulkResult]? { nil }
    func exploreSeenMemory(_ id: String) async throws -> Bool { false }
    func exploreKeepMemory(_ id: String, keep: Bool) async throws -> Bool { false }
    func exploreDeleteMemory(_ id: String) async throws -> Bool { false }
    func exploreRemoveMemoryAsset(_ memory: String, asset: String) async throws -> [ExploreBulkResult]? { nil }
    func exploreUnlock(_ pin: String, setup: Bool) async throws -> Bool { false }
    func exploreLock() async throws -> Bool { false }
    func saveMetadataEdits(_ id: String, edits: [MetadataEdit]) async throws -> Bool { false }
    func createAlbumActivity(_ id: String, assetID: String?, comment: String?) async throws -> AlbumActivity? { nil }
    func deleteAlbumActivity(_ id: String) async throws -> Bool { false }
    func updateAccountName(_ name: String) async throws -> User? { nil }
    func changeAccountPassword(current: String, new: String, invalidateSessions: Bool) async throws -> Bool { false }
    func uploadAccountPicture(_ jpeg: Data) async throws -> Bool { false }
    func removeAccountPicture() async throws -> Bool { false }
    func accountKeys() async throws -> [AccountAPIKey]? { nil }
    func createAccountKey(name: String, permissions: [String]) async throws -> AccountAPIKeySecret? { nil }
    func renameAccountKey(id: String, name: String) async throws -> Bool { false }
    func deleteAccountKey(_ id: String) async throws -> Bool { false }
    func accountDevices() async throws -> [AccountDevice]? { nil }
    func deleteAccountDevice(_ id: String) async throws -> Bool { false }
    func deleteOtherAccountDevices() async throws -> Bool { false }
    func accountNotifications() async throws -> [AccountNotification]? { nil }
    func readAccountNotifications(_ ids: [String]) async throws -> Bool { false }
    func deleteAccountNotification(_ id: String) async throws -> Bool { false }
    func adminSaveUser(id: String?, input: AdminUserInput) async throws -> Bool { false }
    func adminDeleteUser(_ id: String, force: Bool) async throws -> Bool { false }
    func adminRestoreUser(_ id: String) async throws -> Bool { false }
    func adminSaveLibrary(id: String?, input: AdminLibraryInput) async throws -> Bool { false }
    func adminScanLibrary(_ id: String) async throws -> Bool { false }
    func adminDeleteLibrary(_ id: String) async throws -> Bool { false }
    func adminQueueCommand(_ name: String, command: String, force: Bool?) async throws -> Bool { false }
    func passwordSession(email: String, password: String) async throws -> String? { nil }
    func endSession() async -> Bool { false }
    func setReachable(_ reachable: Bool) -> Bool { false }
    func ping() async throws -> Bool { false }
}

/// Thin, stateless client for the Immich REST API.
final class ImmichClient: Sendable {
    let serverURL: URL
    let apiURL: URL
    let credential: Credential?
    let session: URLSession
    /// Where originals for Quick Look, drags and copied files go when not the shared temporary folders (Locked Folder).
    let transferRoot: URL?

    static let userAgent: String = {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        #if os(macOS)
        let system = "macOS"
        #else
        let system = "iOS"
        #endif
        return "verso/\(version) (\(system) \(os.majorVersion).\(os.minorVersion))"
    }()

    /// Bootstrap session. Media caching begins only after choosing an account identity. Like every session that talks
    /// to Immich, it takes the certificate trusted for the server (ServerTrust).
    static let sharedSession: URLSession = {
        let config = URLSessionConfiguration.default
        // Authentication and bootstrap requests do not need a persistent media cache.
        config.urlCache = nil
        config.httpAdditionalHeaders = ["User-Agent": userAgent]
        config.httpMaximumConnectionsPerHost = 8
        config.timeoutIntervalForRequest = 30
        return ServerTrust.session(config)
    }()

    init(serverURL: URL, apiURL: URL, credential: Credential?, session: URLSession = ImmichClient.sharedSession,
         transferRoot: URL? = nil) {
        self.serverURL = serverURL
        self.apiURL = apiURL
        self.credential = credential
        self.session = session
        self.transferRoot = transferRoot
    }

    func with(credential: Credential) -> ImmichClient {
        ImmichClient(serverURL: serverURL, apiURL: apiURL, credential: credential, session: session, transferRoot: transferRoot)
    }

    // MARK: - Request plumbing

    func url(_ path: String, query: [String: String?] = [:]) -> URL {
        var components = URLComponents(url: apiURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        let items = query.compactMap { key, value in value.map { URLQueryItem(name: key, value: $0) } }
        if !items.isEmpty { components.queryItems = items.sorted { $0.name < $1.name } }
        return components.url!
    }

    func request(_ path: String, method: String = "GET", query: [String: String?] = [:], body: (any Encodable)? = nil) throws -> URLRequest {
        var request = URLRequest(url: url(path, query: query))
        request.httpMethod = method
        credential?.headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        return request
    }

    /// The endpoint calls' way to Immich through the shared Rust core, which the app and its Finder extension install
    /// as they start (`CoreTransport.install()`; ARCHITECTURE.md, "Verso on the Mac"): it makes the transport for an
    /// API address and credential. Without it, as in the offline checks, endpoint calls go through the session too.
    nonisolated(unsafe) static var core: (@Sendable (_ apiURL: URL, _ credential: Credential?) -> (any ImmichTransport)?)?

    /// Media and anything else not an endpoint call: through the session, whose cache keeps thumbnails.
    @discardableResult
    func data(for request: URLRequest) async throws -> Data {
        try Self.refuseIfClosed(session)
        let (data, response) = try await session.data(for: request)
        return try Self.checked(data, response)
    }

    /// Ends a session views may still hold (an account signed out of, the Locked Folder left): its requests are
    /// cancelled and new ones refused at once as cancelled, and the session itself is invalidated half a minute later,
    /// when nothing can still be starting on it. URLSession aborts the app when a task is made on an invalidated
    /// session, which a thumbnail still loading as its grid goes would otherwise do, as on a sign-out right after
    /// launch.
    static func close(_ session: URLSession) {
        ClosedSessions.shared.insert(session)
        session.getAllTasks { tasks in tasks.forEach { $0.cancel() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 30) {
            session.invalidateAndCancel()
        }
    }

    /// A request on a session closed above stops before it starts.
    static func refuseIfClosed(_ session: URLSession) throws {
        if ClosedSessions.shared.contains(session) { throw CancellationError() }
    }

    /// An endpoint call's answer: through the core when it is installed, else through the session.
    @discardableResult
    func apiData(for request: URLRequest) async throws -> Data {
        guard let transport = Self.core?(apiURL, credential) else { return try await data(for: request) }
        let (data, response) = try await transport.data(for: request)
        return try Self.checked(data, response)
    }

    private static func checked(_ data: Data, _ response: URLResponse) throws -> Data {
        guard let http = response as? HTTPURLResponse else { return data }
        switch http.statusCode {
        case 200..<300: return data
        case 401:
            throw ImmichError.unauthorized((try? JSONDecoder().decode(ServerErrorBody.self, from: data))?.text)
        default:
            let message = (try? JSONDecoder().decode(ServerErrorBody.self, from: data))?.text
            throw ImmichError.http(http.statusCode, message)
        }
    }

    func get<T: Decodable>(_ path: String, query: [String: String?] = [:]) async throws -> T {
        let data = try await apiData(for: request(path, query: query))
        return try JSONDecoder().decode(T.self, from: data)
    }

    func send<T: Decodable>(_ method: String, _ path: String, body: (any Encodable)? = nil) async throws -> T {
        let data = try await apiData(for: request(path, method: method, body: body))
        return try JSONDecoder().decode(T.self, from: data)
    }

    func send(_ method: String, _ path: String, body: (any Encodable)? = nil) async throws {
        try await apiData(for: request(path, method: method, body: body))
    }

    private struct ServerErrorBody: Decodable {
        var message: FlexibleMessage?
        var text: String? { message?.text }

        enum FlexibleMessage: Decodable {
            case one(String), many([String])
            init(from decoder: Decoder) throws {
                let c = try decoder.singleValueContainer()
                if let s = try? c.decode(String.self) { self = .one(s) } else { self = .many(try c.decode([String].self)) }
            }
            var text: String { switch self { case .one(let s): s; case .many(let a): a.joined(separator: "\n") } }
        }
    }
}

// MARK: - Server discovery

extension ImmichClient {
    /// Resolves what the user typed into a reachable Immich API endpoint.
    /// Mirrors the official mobile app: honours `/.well-known/immich`, falls back to `<server>/api`,
    /// and tries https before http when no scheme was given. Plain http after a failed https only for a server on
    /// the local network, and never after a certificate's error: anyone on the way to a server elsewhere could make
    /// https fail (a certificate of their own, a blocked port) to read the password and every photo sent. Typed with
    /// `http://`, an address is reached as typed. A certificate the system does not trust, nor the one trusted for the
    /// server (ServerTrust), comes back as `ServerTrust.Refused`, for the person to decide on.
    static func discover(_ input: String) async throws -> ImmichClient {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        if text.lowercased().hasSuffix("/api") { text.removeLast(4) }
        guard !text.isEmpty else { throw ImmichError.invalidServerURL }

        let typedScheme = text.contains("://")
        let candidates = typedScheme ? [text] : ["https://\(text)", "http://\(text)"]
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.httpAdditionalHeaders = ["User-Agent": userAgent]
        let probe = ServerTrust.session(config)
        defer { probe.finishTasksAndInvalidate() }

        var lastError: Error = ImmichError.invalidServerURL
        var certificateFailed = false
        for candidate in candidates {
            guard let base = URL(string: candidate), let host = base.host() else { continue }
            if !typedScheme, base.scheme == "http" {
                if certificateFailed {
                    lastError = ImmichError.serverUnreachable(String(localized: "The server's certificate isn't trusted. To connect without encryption anyway, type the address with http://."))
                    break
                }
                guard ServerAddress.isLocalNetwork(host) else {
                    let reason = lastError.localizedDescription
                    lastError = ImmichError.serverUnreachable(String(localized: "\(reason) To connect to a server on the internet without encryption, type the address with http://."))
                    break
                }
            }
            let api = await wellKnownEndpoint(base: base, session: probe) ?? base.appendingPathComponent("api")
            do {
                let (data, _) = try await probe.data(from: api.appendingPathComponent("server/ping"))
                struct Pong: Decodable { let res: String }
                if (try? JSONDecoder().decode(Pong.self, from: data))?.res == "pong" {
                    return ImmichClient(serverURL: base, apiURL: api, credential: nil)
                }
                lastError = ImmichError.serverUnreachable(String(localized: "The server answered, but it isn't Immich."))
            } catch {
                if let refused = ServerTrust.refused(in: error) { throw refused }
                certificateFailed = certificateFailed || ServerAddress.isCertificateError(error)
                lastError = ImmichError.serverUnreachable(error.localizedDescription)
            }
        }
        throw lastError
    }

    /// The certificate the server presents now, over a connection of its own, when the system refuses it and it is
    /// not the one trusted for the server; nil when it is trusted, or the server is reached without TLS. Throws when
    /// the server cannot be reached.
    func refusedCertificate() async throws -> ServerTrust.Refused? {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.httpAdditionalHeaders = ["User-Agent": Self.userAgent]
        let looking = ServerTrust.session(config)
        defer { looking.finishTasksAndInvalidate() }
        do {
            _ = try await looking.data(from: apiURL.appendingPathComponent("server/ping"))
            return nil
        } catch {
            if let refused = ServerTrust.refused(in: error) { return refused }
            throw error
        }
    }

    private static func wellKnownEndpoint(base: URL, session: URLSession) async -> URL? {
        struct WellKnown: Decodable { struct API: Decodable { let endpoint: String }; let api: API }
        guard let (data, response) = try? await session.data(from: base.appendingPathComponent(".well-known/immich")),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let wellKnown = try? JSONDecoder().decode(WellKnown.self, from: data),
              let url = URL(string: wellKnown.api.endpoint, relativeTo: base)?.absoluteURL
        else { return nil }
        return url
    }
}

// MARK: - Endpoints

/// A timeline to read, month by month (`GET /timeline/buckets` and `GET /timeline/bucket`): the request's query, and
/// for a transport that answers it typed, what it asks in the core's terms (the app's `CoreTimeline`, which the core
/// makes for a page with its view options). A transport answers nil for one it does not know, which goes as a request.
protocol TimelineRequest: Sendable {
    var parameters: [String: String?] { get }
}

/// A timeline asked as a request, with the filters `GET /timeline/buckets` and `GET /timeline/bucket` understand: the
/// map's area, which no typed call asks, and the Messages extension's timelines, which it reads without the core.
struct TimelineQuery: TimelineRequest, Hashable {
    var visibility: String? = "timeline"
    var isFavorite: Bool?
    var isTrashed: Bool?
    var albumId: String?
    var personId: String?
    var userId: String? // Sharing
    var tagId: String? // Explore
    var withPartners: Bool?
    var withStacked: Bool? = true
    var bbox: String? // Explore
    var order: String? // Timeline view options: "asc" for oldest first.
    var orderBy: String? // Timeline view options: "createdAt" for date added (Immich v3.0).
    var withCoordinates: Bool? // Assign Location: GPS badges.

    var parameters: [String: String?] {
        [
            "bbox": bbox, // Explore
            "visibility": visibility,
            "isFavorite": isFavorite.map(String.init),
            "isTrashed": isTrashed.map(String.init),
            "albumId": albumId,
            "personId": personId,
            "userId": userId, // Sharing
            "tagId": tagId, // Explore
            "withPartners": withPartners.map(String.init),
            "withStacked": withStacked.map(String.init),
            "order": order,
            "orderBy": orderBy,
            "withCoordinates": withCoordinates.map(String.init),
        ]
    }
}

extension ImmichClient {
    func serverVersion() async throws -> ServerVersion {
        if let typed = try await Self.core?(apiURL, credential)?.serverVersion() { return typed }
        return try await get("server/version")
    }
    func serverFeatures() async throws -> ServerFeatures {
        if let typed = try await Self.core?(apiURL, credential)?.serverFeatures() { return typed }
        return try await get("server/features")
    }
    func currentUser() async throws -> User {
        if let typed = try await Self.core?(apiURL, credential)?.currentUser() { return typed }
        return try await get("users/me")
    }

    /// Sign in with a password: the session's token.
    func login(email: String, password: String) async throws -> String {
        if let token = try await Self.core?(apiURL, nil)?.passwordSession(email: email, password: password) { return token }
        struct Body: Encodable { let email: String; let password: String }
        let response: LoginResponse = try await send("POST", "auth/login", body: Body(email: email, password: password))
        return response.accessToken
    }

    /// Tell the core whether the server can be reached: while it cannot, the core's requests fail at once rather than
    /// wait out their timeouts.
    func setServerReachable(_ reachable: Bool) {
        _ = Self.core?(apiURL, credential)?.setReachable(reachable)
    }

    /// Whether the server answers now, even while it is taken as unreachable.
    func pingServer() async throws {
        if try await Self.core?(apiURL, credential)?.ping() == true { return }
        struct Pong: Decodable { let res: String }
        let _: Pong = try await get("server/ping")
    }

    /// End this session on the server; an API key has none to end.
    func logout() async throws {
        if await Self.core?(apiURL, credential)?.endSession() == true { return }
        try await send("POST", "auth/logout")
    }

    func timeBuckets(_ timeline: any TimelineRequest) async throws -> [TimeBucket] {
        if let months = try await Self.core?(apiURL, credential)?.timeBuckets(timeline) { return months }
        return try await get("timeline/buckets", query: timeline.parameters)
    }

    func timeBucket(_ bucket: String, _ timeline: any TimelineRequest) async throws -> TimeBucketAssets {
        if let month = try await Self.core?(apiURL, credential)?.timeBucket(bucket, timeline) { return month }
        var parameters = timeline.parameters
        parameters["timeBucket"] = bucket
        return try await get("timeline/bucket", query: parameters)
    }

    func asset(_ id: String) async throws -> AssetResponse {
        if let typed = try await Self.core?(apiURL, credential)?.asset(id) { return typed }
        return try await get("assets/\(id)")
    }

    /// Owned albums plus albums shared with the user.
    func albums() async throws -> [Album] {
        if let albums = try await Self.core?(apiURL, credential)?.albums() { return albums }
        return try await get("albums")
    }

    func albums(containing assetID: String) async throws -> [Album] {
        try await get("albums", query: ["assetId": assetID])
    }

    func people(page: Int, size: Int = 500) async throws -> PeopleResponse {
        if let typed = try await Self.core?(apiURL, credential)?.peoplePage(page: page, size: size, withHidden: false, name: nil, filters: [:]) {
            return typed
        }
        return try await get("people", query: ["page": String(page), "size": String(size), "withHidden": "false"])
    }

    struct SearchPage: Sendable {
        var page: Int?
        var cursor: String?
    }

    /// Smart (CLIP) search. Uses `page` paging, which every server version understands.
    func smartSearch(_ text: String, page: Int, size: Int = 100) async throws -> SearchResponse.Assets {
        var body = AdvancedSearchRequest(size: size)
        body.query = text
        body.page = page
        return try await searchPage(body, smart: true)
    }

    /// Metadata search (used for filename search and media-type collections).
    func metadataSearch(
        type: AssetType? = nil, fileName: String? = nil, visibility: String? = nil, isFavorite: Bool? = nil,
        personIds: [String]? = nil, tagIds: [String]? = nil, order: String = "desc", withExif: Bool? = nil, page: SearchPage, size: Int = 250
    ) async throws -> SearchResponse.Assets {
        var body = AdvancedSearchRequest(size: size)
        body.type = type?.rawValue
        body.originalFileName = fileName
        body.visibility = visibility
        body.isFavorite = isFavorite
        body.personIds = personIds
        body.tagIds = tagIds
        body.page = page.page
        body.cursor = page.cursor
        body.order = order
        body.withExif = withExif
        body.withStacked = true
        return try await searchPage(body, smart: false)
    }

    /// A change to photos through the core's typed call; false when no core answers it, and it goes as a request.
    func typedAssetChange(_ ids: [String], _ changes: AssetChangeSet) async throws -> Bool {
        try await Self.core?(apiURL, credential)?.updateAssets(ids, changes) == true
    }

    func setFavorite(_ ids: [String], _ isFavorite: Bool) async throws {
        if try await typedAssetChange(ids, AssetChangeSet(isFavorite: isFavorite)) { return }
        struct Body: Encodable { let ids: [String]; let isFavorite: Bool }
        try await send("PUT", "assets", body: Body(ids: ids, isFavorite: isFavorite))
    }

    func setVisibility(_ ids: [String], _ visibility: String) async throws {
        if try await typedAssetChange(ids, AssetChangeSet(visibility: visibility)) { return }
        struct Body: Encodable { let ids: [String]; let visibility: String }
        try await send("PUT", "assets", body: Body(ids: ids, visibility: visibility))
    }

    /// Moves to trash, or deletes permanently when `force` is true.
    func delete(_ ids: [String], force: Bool) async throws {
        if try await Self.core?(apiURL, credential)?.deleteAssets(ids, force: force) == true { return }
        struct Body: Encodable { let ids: [String]; let force: Bool }
        try await send("DELETE", "assets", body: Body(ids: ids, force: force))
    }

    func restore(_ ids: [String]) async throws {
        if try await Self.core?(apiURL, credential)?.restoreAssets(ids) == true { return }
        struct Body: Encodable { let ids: [String] }
        try await send("POST", "trash/restore/assets", body: Body(ids: ids))
    }

    // MARK: Media URLs

    enum ThumbnailSize: String, Sendable { case thumbnail, preview, fullsize }

    func thumbnailRequest(_ id: String, size: ThumbnailSize, edited: Bool = true) -> URLRequest {
        try! request("assets/\(id)/thumbnail", query: ["size": size.rawValue, "edited": String(edited)])
    }

    func originalRequest(_ id: String, edited: Bool = false) -> URLRequest {
        try! request("assets/\(id)/original", query: ["edited": String(edited)])
    }

    func personThumbnailRequest(_ id: String) -> URLRequest {
        try! request("people/\(id)/thumbnail")
    }

    func videoURL(_ id: String) -> URL { url("assets/\(id)/video/playback") }
}

/// The sessions ImmichClient.close ended, which take no new request.
private final class ClosedSessions: @unchecked Sendable {
    static let shared = ClosedSessions()
    private let lock = NSLock()
    private var closed = Set<ObjectIdentifier>()

    func insert(_ session: URLSession) { lock.withLock { _ = closed.insert(ObjectIdentifier(session)) } }
    func contains(_ session: URLSession) -> Bool { lock.withLock { closed.contains(ObjectIdentifier(session)) } }
}
