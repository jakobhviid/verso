import Foundation

extension ImmichClient {
    func assetsCreateStack(_ ids: [String]) async throws -> AssetsStack {
        if let typed = try await Self.core?(apiURL, credential)?.assetsCreateStack(ids) { return typed }
        struct Body: Encodable { let assetIds: [String] }
        return try await send("POST", "stacks", body: Body(assetIds: ids))
    }

    func assetsStack(_ id: String) async throws -> AssetsStack {
        if let typed = try await Self.core?(apiURL, credential)?.assetsStack(id) { return typed }
        return try await get("stacks/\(id)")
    }

    func assetsSetPrimary(stack: String, asset: String) async throws -> AssetsStack {
        if let typed = try await Self.core?(apiURL, credential)?.assetsSetPrimary(stack: stack, asset: asset) { return typed }
        struct Body: Encodable { let primaryAssetId: String }
        return try await send("PUT", "stacks/\(stack)", body: Body(primaryAssetId: asset))
    }

    func assetsUnstack(_ id: String) async throws {
        if try await Self.core?(apiURL, credential)?.assetsUnstack(id) == true { return }
        try await send("DELETE", "stacks/\(id)")
    }
    func assetsRemoveFromStack(_ id: String, asset: String) async throws {
        if try await Self.core?(apiURL, credential)?.assetsRemoveFromStack(id, asset: asset) == true { return }
        try await send("DELETE", "stacks/\(id)/assets/\(asset)")
    }

    func assetsDuplicates() async throws -> [AssetsDuplicate] {
        if let typed = try await Self.core?(apiURL, credential)?.assetsDuplicates() { return typed }
        return try await get("duplicates")
    }
    func assetsDismissDuplicate(_ id: String) async throws {
        if try await Self.core?(apiURL, credential)?.assetsDismissDuplicate(id) == true { return }
        try await send("DELETE", "duplicates/\(id)")
    }
    func assetsResolveDuplicate(_ group: AssetsDuplicate, keep: Set<String>) async throws {
        struct Group: Encodable { let duplicateId: String; let keepAssetIds: [String]; let trashAssetIds: [String] }
        struct Body: Encodable { let groups: [Group] }
        let kept = group.assets.map(\.id).filter { keep.contains($0) }
        let trashed = group.assets.map(\.id).filter { !keep.contains($0) }
        let results: [AssetsBulkResult]
        if let typed = try await Self.core?(apiURL, credential)?.assetsResolveDuplicate(group.id, keep: kept, trash: trashed) { results = typed }
        else {
            results = try await send("POST", "duplicates/resolve", body: Body(groups: [
                Group(duplicateId: group.id, keepAssetIds: kept, trashAssetIds: trashed)
            ]))
        }
        if results.contains(where: { !$0.success }) { throw ImmichError.http(409, String(localized: "The duplicate group could not be resolved. Reload and try again.")) }
    }

    // Deprecated since v3.2.0 in favor of searchAssets; retained for the v3.3.5 web utility contract.
    /// `type` is Immich's AssetType ("IMAGE" or "VIDEO").
    func assetsLargeFiles(type: String? = nil, isFavorite: Bool? = nil) async throws -> [AssetResponse] {
        if let isFavorite {
            // The largest favorites (or not), through metadata search sorted by size (Immich 3.2's `filter`).
            struct Filter: Encodable {
                let type: [String: String]?
                let isFavorite: [String: Bool]
                let visibility = ["ne": "locked"]
            }
            struct Body: Encodable {
                let filter: Filter
                let orderBy = ["field": "fileSizeInBytes", "direction": "desc"]
                let size = 250
                let withExif = true
            }
            let response: SearchResponse = try await send("POST", "search/metadata", body: Body(
                filter: Filter(type: type.map { ["eq": $0] }, isFavorite: ["eq": isFavorite])))
            return response.assets.items
        }
        let data = try await apiData(for: request("search/large-assets", method: "POST", query: ["minFileSize": "0", "type": type]))
        return try JSONDecoder().decode([AssetResponse].self, from: data)
    }

    func assetsSetLocation(_ ids: [String], latitude: Double, longitude: Double) async throws {
        guard latitude.isFinite, longitude.isFinite, (-90...90).contains(latitude), (-180...180).contains(longitude) else {
            throw ImmichError.http(400, String(localized: "Enter latitude from -90 to 90 and longitude from -180 to 180."))
        }
        if try await typedAssetChange(ids, AssetChangeSet(latitude: latitude, longitude: longitude)) { return }
        struct Body: Encodable { let ids: [String]; let latitude: Double; let longitude: Double }
        try await send("PUT", "assets", body: Body(ids: ids, latitude: latitude, longitude: longitude))
    }

    func assetsDownloadInfo(ids: [String]?, album: String?, archiveSize: Int64?) async throws -> AssetsDownloadInfo {
        struct Body: Encodable { let assetIds: [String]?; let albumId: String?; let archiveSize: Int64? }
        return try await send("POST", "download/info", body: Body(assetIds: ids, albumId: album, archiveSize: archiveSize))
    }

    func assetsArchiveRequest(_ ids: [String], archiveName: String) throws -> URLRequest {
        struct Body: Encodable { let assetIds: [String]; let archiveName: String }
        return try request("download/archive", method: "POST", body: Body(assetIds: ids, archiveName: archiveName))
    }
}
