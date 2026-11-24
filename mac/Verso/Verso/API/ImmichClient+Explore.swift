import Foundation

extension ImmichClient {
    func explorePreferences() async throws -> ExplorePreferences { try await get("users/me/preferences") }
    func exploreTags() async throws -> [ExploreTag] {
        if let typed = try await Self.core?(apiURL, credential)?.exploreTags() { return typed }
        return try await get("tags")
    }
    func exploreCities() async throws -> [AssetResponse] {
        if let typed = try await Self.core?(apiURL, credential)?.exploreCities() { return typed }
        return try await get("search/cities")
    }
    func explorePaths() async throws -> [String] {
        if let typed = try await Self.core?(apiURL, credential)?.explorePaths() { return typed }
        return try await get("view/folder/unique-paths")
    }
    func exploreMarkers(favorites: Bool, archived: Bool, partners: Bool, after: Date?, before: Date?) async throws -> [ExploreMarker] {
        if let typed = try await Self.core?(apiURL, credential)?.exploreMarkers(favorites: favorites, archived: archived, partners: partners,
                                                                               after: after, before: before) { return typed }
        return try await get("map/markers", query: ["isFavorite": favorites ? "true" : nil,
            "isArchived": archived ? "true" : nil, "withPartners": String(partners),
            "fileCreatedAfter": after.map { $0.ISO8601Format() }, "fileCreatedBefore": before.map { $0.ISO8601Format() }])
    }
    func exploreAssets(_ source: ExploreSource, page: SearchPage) async throws -> SearchResponse.Assets {
        switch source {
        case .folder(let path):
            let assets: [AssetResponse]
            if let typed = try await Self.core?(apiURL, credential)?.folderAssets(path) { assets = typed }
            else { assets = try await get("view/folder", query: ["path": path]) }
            return .init(items: assets.filter { $0.visibility != "locked" })
        case .city(let city):
            var body = AdvancedSearchRequest(size: 250)
            body.city = city
            body.visibility = "timeline"
            body.page = page.page
            body.cursor = page.cursor
            return try await searchPage(body, smart: false)
        case .tag, .map: return .init(items: []) // Tags use the timeline endpoint.
        }
    }
    func exploreCreateTag(_ path: String) async throws {
        if try await Self.core?(apiURL, credential)?.exploreCreateTag(path) == true { return }
        struct Body: Encodable { let tags: [String] }
        let _: [ExploreTag] = try await send("PUT", "tags", body: Body(tags: [path]))
    }
    func exploreUpdateTag(_ tag: ExploreTag, name: String, color: String) async throws {
        if try await Self.core?(apiURL, credential)?.exploreUpdateTag(tag.id, name: name, color: color) == true { return }
        struct Body: Encodable {
            let name: String
            let color: String?
            enum CodingKeys: String, CodingKey { case name, color }
            func encode(to encoder: Encoder) throws {
                var values = encoder.container(keyedBy: CodingKeys.self)
                try values.encode(name, forKey: .name)
                try values.encode(color, forKey: .color)
            }
        }
        let _: ExploreTag = try await send("PUT", "tags/\(tag.id)", body: Body(name: name, color: color.isEmpty ? nil : color))
    }
    func exploreDeleteTag(_ id: String) async throws {
        if try await Self.core?(apiURL, credential)?.exploreDeleteTag(id) == true { return }
        try await send("DELETE", "tags/\(id)")
    }
    func exploreTagAssets(_ ids: [String], tag: String, remove: Bool) async throws {
        let result: [ExploreBulkResult]
        if let typed = try await Self.core?(apiURL, credential)?.exploreTagAssets(ids, tag: tag, remove: remove) { result = typed }
        else { result = try await send(remove ? "DELETE" : "PUT", "tags/\(tag)/assets", body: ExploreIDs(ids: ids)) }
        if result.contains(where: { !$0.isAccepted(removing: remove) }) { throw ImmichError.http(400, String(localized: "Some items could not be updated. Refresh and try again.")) }
    }
    func exploreMemories(page: Int) async throws -> [ExploreMemory] {
        let day = String(Date().ISO8601Format().prefix(10))
        if let typed = try await Self.core?(apiURL, credential)?.exploreMemories(day: day, page: page, size: 100) { return typed }
        return try await get("memories", query: ["for": day, "page": String(page), "size": "100", "isTrashed": "false", "isUpcoming": "false"])
    }
    /// One memory, with its photos.
    func exploreMemory(_ id: String) async throws -> ExploreMemory { try await get("memories/\(id)") }

    /// Keep a memory, so Immich's cleanup leaves it, or let it go again.
    func exploreKeepMemory(_ id: String, keep: Bool) async throws {
        if try await Self.core?(apiURL, credential)?.exploreKeepMemory(id, keep: keep) == true { return }
        struct Body: Encodable { let isSaved: Bool }
        let _: ExploreMemory = try await send("PUT", "memories/\(id)", body: Body(isSaved: keep))
    }
    func exploreSeenMemory(_ id: String) async throws {
        if try await Self.core?(apiURL, credential)?.exploreSeenMemory(id) == true { return }
        struct Body: Encodable { let seenAt: String }
        let _: ExploreMemory = try await send("PUT", "memories/\(id)", body: Body(seenAt: Date().ISO8601Format()))
    }
    func exploreDeleteMemory(_ id: String) async throws {
        if try await Self.core?(apiURL, credential)?.exploreDeleteMemory(id) == true { return }
        try await send("DELETE", "memories/\(id)")
    }
    func exploreRemoveMemoryAsset(_ memory: String, asset: String) async throws {
        let result: [ExploreBulkResult]
        if let typed = try await Self.core?(apiURL, credential)?.exploreRemoveMemoryAsset(memory, asset: asset) { result = typed }
        else { result = try await send("DELETE", "memories/\(memory)/assets", body: ExploreIDs(ids: [asset])) }
        guard result.allSatisfy(\.success) else { throw ImmichError.http(400, String(localized: "The photo could not be removed from this memory.")) }
    }
    func exploreAuth() async throws -> ExploreAuthStatus {
        if let typed = try await Self.core?(apiURL, credential)?.exploreAuth() { return typed }
        return try await get("auth/status")
    }
    func exploreUnlock(_ pin: String, setup: Bool) async throws {
        guard exploreSupportsLockedFolder else { throw ImmichError.http(400, String(localized: "Locked Folder requires a session-token login.")) }
        if try await Self.core?(apiURL, credential)?.exploreUnlock(pin, setup: setup) == true { return }
        struct Body: Encodable { let pinCode: String }
        if setup { try await send("POST", "auth/pin-code", body: Body(pinCode: pin)) }
        try await send("POST", "auth/session/unlock", body: Body(pinCode: pin))
    }
    func exploreLock() async throws {
        if try await Self.core?(apiURL, credential)?.exploreLock() == true { return }
        try await send("POST", "auth/session/lock")
    }
    var exploreSupportsLockedFolder: Bool {
        if case .accessToken = credential { return true }
        return false
    }
    /// No URL cache, so Locked Folder media never reaches the disk cache.
    func explorePrivateClient(transferRoot: URL? = nil) -> ImmichClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpAdditionalHeaders = ["User-Agent": Self.userAgent]
        configuration.httpMaximumConnectionsPerHost = 8
        configuration.timeoutIntervalForRequest = 30
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return ImmichClient(serverURL: serverURL, apiURL: apiURL, credential: credential, session: ServerTrust.session(configuration),
                            transferRoot: transferRoot)
    }
}
