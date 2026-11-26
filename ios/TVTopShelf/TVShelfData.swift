import Foundation

/// What the Top Shelf shows, in the App Group the TV app shares with its Top Shelf extension: the app writes it each
/// time it starts signed in (TVTopShelf), with each picture as a file beside it, and the extension reads it as the Home
/// Screen asks, so the extension needs no key and no network. Nothing of the Locked Folder is ever in it.
struct TVShelfData: Codable, Sendable {
    struct Item: Codable, Sendable {
        let title: String
        /// The picture's file, in `folder`.
        let image: String
        /// Where the app opens: `memory/<id>` or `photo/<id>`, after the app's own scheme.
        let link: String
    }

    /// Today's memories, each by its first photo.
    var memories: [Item]
    /// The library's newest photos.
    var recent: [Item]

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
