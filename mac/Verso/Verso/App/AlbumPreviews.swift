import Foundation
import Observation

/// An album's photos besides its cover, for its card: read as the card first shows (the album's newest month, through
/// the timeline), and kept for the session, read again only when the album changes.
@MainActor @Observable
final class AlbumPreviews {
    private var photos: [String: [String]] = [:]
    @ObservationIgnored private var reading: Set<String> = []

    private static func key(_ album: Album) -> String { album.id + "|" + (album.lastModifiedAssetTimestamp ?? album.updatedAt ?? "") }

    /// Up to two photos of the album other than its cover; nil until read.
    func photos(of album: Album) -> [String]? { photos[Self.key(album)] }

    func read(_ album: Album, client: ImmichClient) async {
        let key = Self.key(album)
        guard photos[key] == nil, !reading.contains(key), album.assetCount > 1 else { return }
        reading.insert(key)
        defer { reading.remove(key) }
        let query = TimelineQuery(visibility: nil, albumId: album.id)
        var found: [String] = []
        do {
            for month in try await client.timeBuckets(query).prefix(3) where found.count < 2 {
                let assets = try await client.timeBucket(month.timeBucket, query)
                found += assets.id.filter { $0 != album.albumThumbnailAssetId && !found.contains($0) }.prefix(2 - found.count)
            }
        } catch { return }
        photos[key] = found
    }
}

/// A link to chosen photos' first photos, for its card: Immich lists each link with its first photo only, so the card
/// reads the link whole as it first shows, once for the session, again when the link changes.
@MainActor @Observable
final class LinkPreviews {
    private var photos: [String: [String]] = [:]
    private var counts: [String: Int] = [:]
    @ObservationIgnored private var reading: Set<String> = []

    /// Up to three of the link's photos; nil until read.
    func photos(of link: SharedLink) -> [String]? { photos[link.id] }

    /// How many photos the link shares; nil until read.
    func count(of link: SharedLink) -> Int? { counts[link.id] }

    func read(_ link: SharedLink, client: ImmichClient) async {
        guard photos[link.id] == nil, !reading.contains(link.id), link.type == "INDIVIDUAL" else { return }
        reading.insert(link.id)
        defer { reading.remove(link.id) }
        guard let whole = try? await client.sharedLink(link.id) else { return }
        let shown = whole.assets.filter { $0.visibility != "locked" }
        photos[link.id] = Array(shown.prefix(3).map(\.id))
        counts[link.id] = shown.count
    }

    /// The link changed: read it again when its card next shows.
    func forget(_ id: String) {
        photos[id] = nil
        counts[id] = nil
    }
}
