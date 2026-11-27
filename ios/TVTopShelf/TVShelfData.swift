import Foundation

/// What the Top Shelf shows, in the App Group the TV app shares with its Top Shelf extension: the app writes it each
/// time it starts signed in and as Settings changes the rows (TVTopShelf), with each picture as a file beside it, and
/// the extension reads it as the Home Screen asks, so the extension needs no key and no network. Nothing of the Locked
/// Folder is ever in it.
struct TVShelfData: Codable, Sendable {
    /// A row of the shelf, in the order the shelf and Settings show them: what is new today first, then what lasts.
    enum Row: String, Codable, CaseIterable, Sendable {
        /// Today's memories, each by its first photo.
        case memories
        /// The library's newest photos.
        case recent
        /// The albums with the newest photos, each by its cover, as Albums orders them.
        case albums
        /// The newest favorites.
        case favorites
        /// The people Immich recognises, by their faces, in People's order.
        case people

        var title: String {
            switch self {
            case .memories: String(localized: "Memories")
            case .recent: String(localized: "Recent")
            case .albums: String(localized: "Albums")
            case .favorites: String(localized: "Favorites")
            case .people: String(localized: "People")
            }
        }

        /// Memories and the newest photos are on the shelf until turned off; the rest once turned on.
        var shownByDefault: Bool { self == .memories || self == .recent }

        /// The app's setting for the row (Settings, Top Shelf).
        var settingKey: String { "topShelf." + rawValue }
    }

    struct Item: Codable, Sendable {
        let title: String
        /// The picture's file, in `folder`.
        let image: String
        /// Where the app opens: `memory/<id>`, `photo/<id>`, `album/<id>` or `person/<id>`, after the app's own scheme.
        let link: String
    }

    struct Section: Codable, Sendable {
        let row: Row
        var items: [Item]
    }

    /// The rows turned on, in `Row`'s order, each with something to show.
    var sections: [Section]

    /// The folder in the App Group the app and the extension share, from the Info.plist both carry.
    static var folder: URL? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "VersoAppGroup") as? String, !group.isEmpty,
              let base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else { return nil }
        return base.appendingPathComponent("Library/Caches/TopShelf", isDirectory: true)
    }

    private static var file: URL? { folder?.appendingPathComponent("shelf.json") }

    static func read() -> TVShelfData? {
        guard let file, let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(TVShelfData.self, from: data)
    }

    func write() {
        guard let file = Self.file, let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: file, options: .atomic)
    }

    /// A link into the app, with its own scheme (`verso`, Verso Dev's `verso-dev`).
    static func url(_ link: String) -> URL? {
        guard let scheme = Bundle.main.object(forInfoDictionaryKey: "VersoURLScheme") as? String, !scheme.isEmpty else { return nil }
        return URL(string: "\(scheme)://\(link)")
    }
}
