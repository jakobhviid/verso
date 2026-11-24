import Foundation

extension ImmichClient {
    func updateMetadata(_ update: MetadataUpdate) async throws {
        let changes = AssetChangeSet(dateTimeOriginal: update.dateTimeOriginal, dateTimeRelative: update.dateTimeRelative,
                                     timeZone: update.timeZone, latitude: update.latitude, longitude: update.longitude,
                                     description: update.description, rating: update.rating, clearRating: update.clearRating)
        if try await typedAssetChange(update.ids, changes) { return }
        try await send("PUT", "assets", body: update)
    }

    func metadataPreferences() async throws -> MetadataPreferences {
        try await get("users/me/preferences")
    }

    func metadataEdits(_ id: String) async throws -> MetadataEdits {
        if let typed = try await Self.core?(apiURL, credential)?.metadataEdits(id) { return typed }
        return try await get("assets/\(id)/edits")
    }

    func saveMetadataEdits(_ id: String, edits: [MetadataEdit]) async throws {
        if try await Self.core?(apiURL, credential)?.saveMetadataEdits(id, edits: edits) == true { return }
        if edits.isEmpty { try await send("DELETE", "assets/\(id)/edits") }
        else { try await send("PUT", "assets/\(id)/edits", body: MetadataEdits(edits: edits)) }
    }
}
