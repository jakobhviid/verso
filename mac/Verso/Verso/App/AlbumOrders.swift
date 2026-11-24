import Foundation

/// The order an album's photos read in, newest first (`desc`, Immich's default) or oldest first (`asc`), album by
/// album, so a trip reads from its start while a work album shows its latest. Immich keeps one order with each album
/// (`order`), which its owner changes for everyone who sees it, Immich's web app too; anyone else chooses one on this
/// device for that album alone, which counts before the owner's. The page opens at the first photo of its order.
enum AlbumOrders {
    /// This device's choices, by album ({"<album id>": "asc"}).
    static let storageKey = "albums.order"
    static let newestFirst = "desc"
    static let oldestFirst = "asc"

    /// The order to read the album in: this device's choice for it, else its owner's.
    static func order(of album: AlbumDetails, stored: String) -> String {
        choices(stored)[album.id] ?? album.order ?? newestFirst
    }

    /// The stored choices with this device's for one album changed: kept where it differs from the owner's order,
    /// dropped where it is the same (or `nil`), so the album then follows its owner again.
    static func choosing(_ order: String?, for album: AlbumDetails, in stored: String) -> String {
        var choices = choices(stored)
        choices[album.id] = order == (album.order ?? newestFirst) ? nil : order
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return String(decoding: (try? encoder.encode(choices)) ?? Data("{}".utf8), as: UTF8.self)
    }

    private static func choices(_ stored: String) -> [String: String] {
        (try? JSONDecoder().decode([String: String].self, from: Data(stored.utf8))) ?? [:]
    }
}
