import Foundation

extension ImmichClient {
    func albumDetails(_ id: String) async throws -> AlbumDetails {
        if let album = try await Self.core?(apiURL, credential)?.albumDetails(id) { return album }
        return try await get("albums/\(id)", query: ["withoutAssets": "true"])
    }

    func createAlbum(name: String, description: String? = nil, assetIDs: [String]) async throws -> AlbumDetails {
        if let typed = try await Self.core?(apiURL, credential)?.createAlbum(name: name, description: description, assetIDs: assetIDs) { return typed }
        struct Body: Encodable { let albumName: String; let description: String?; let assetIds: [String] }
        return try await send("POST", "albums", body: Body(albumName: name, description: description == "" ? nil : description, assetIds: assetIDs))
    }

    func updateAlbum(_ id: String, _ update: AlbumUpdate) async throws -> AlbumDetails {
        if let typed = try await Self.core?(apiURL, credential)?.updateAlbum(id, update) { return typed }
        return try await send("PATCH", "albums/\(id)", body: update)
    }

    func deleteAlbum(_ id: String) async throws {
        if try await Self.core?(apiURL, credential)?.deleteAlbum(id) == true { return }
        try await send("DELETE", "albums/\(id)")
    }

    func changeAlbumAssets(_ id: String, ids: [String], removing: Bool = false) async throws {
        struct Body: Encodable { let ids: [String] }
        let results: [AlbumAssetResult]
        if let typed = try await Self.core?(apiURL, credential)?.changeAlbumAssets(id, ids: ids, removing: removing) { results = typed }
        else { results = try await send(removing ? "DELETE" : "PUT", "albums/\(id)/assets", body: Body(ids: ids)) }
        let failures = results.filter { !$0.success && $0.error != "duplicate" }
        if !failures.isEmpty {
            throw ImmichError.http(400, removing ? String(localized: "\(failures.count) items could not be removed: \(failures.compactMap(\.error).joined(separator: ", ")).") : String(localized: "\(failures.count) items could not be added: \(failures.compactMap(\.error).joined(separator: ", "))."))
        }
    }

    func albumUsers() async throws -> [User] { try await sharingUsers() }

    func addAlbumUser(_ id: String, userID: String, role: String) async throws {
        if try await Self.core?(apiURL, credential)?.addAlbumUser(id, userID: userID, role: role) == true { return }
        struct Member: Encodable { let userId: String; let role: String }
        struct Body: Encodable { let albumUsers: [Member] }
        try await send("PUT", "albums/\(id)/users", body: Body(albumUsers: [Member(userId: userID, role: role)]))
    }

    func updateAlbumUser(_ id: String, userID: String, role: String) async throws {
        if try await Self.core?(apiURL, credential)?.updateAlbumUser(id, userID: userID, role: role) == true { return }
        struct Body: Encodable { let role: String }
        try await send("PUT", "albums/\(id)/user/\(userID)", body: Body(role: role))
    }

    func removeAlbumUser(_ id: String, userID: String) async throws {
        if try await Self.core?(apiURL, credential)?.removeAlbumUser(id, userID: userID) == true { return }
        try await send("DELETE", "albums/\(id)/user/\(userID)")
    }

    func albumActivities(_ id: String, assetID: String?) async throws -> [AlbumActivity] {
        if let typed = try await Self.core?(apiURL, credential)?.albumActivities(id, assetID: assetID) { return typed }
        return try await get("activities", query: ["albumId": id, "assetId": assetID])
    }

    func albumActivityStatistics(_ id: String, assetID: String?) async throws -> AlbumActivityStatistics {
        if let typed = try await Self.core?(apiURL, credential)?.albumActivityStatistics(id, assetID: assetID) { return typed }
        return try await get("activities/statistics", query: ["albumId": id, "assetId": assetID])
    }

    func createAlbumActivity(_ id: String, assetID: String?, comment: String?) async throws -> AlbumActivity {
        if let typed = try await Self.core?(apiURL, credential)?.createAlbumActivity(id, assetID: assetID, comment: comment) { return typed }
        struct Body: Encodable { let albumId: String; let assetId: String?; let type: String; let comment: String? }
        return try await send("POST", "activities", body: Body(albumId: id, assetId: assetID, type: comment == nil ? "like" : "comment", comment: comment))
    }

    func deleteAlbumActivity(_ id: String) async throws {
        if try await Self.core?(apiURL, credential)?.deleteAlbumActivity(id) == true { return }
        try await send("DELETE", "activities/\(id)")
    }
}
