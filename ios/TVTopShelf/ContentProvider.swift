// Verso on the Apple TV's Top Shelf (ROADMAP.md, "Verso on the Apple TV"): with Verso in the Home Screen's top row, the
// shelf above it shows today's memories and the library's newest photos, as the app last wrote them (TVShelfData); a
// click opens the app at that memory or photo. With nothing written yet, or signed out, the static Top Shelf image
// shows instead.

import TVServices

final class ContentProvider: TVTopShelfContentProvider {
    override func loadTopShelfContent(completionHandler: @escaping ((any TVTopShelfContent)?) -> Void) {
        guard let shelf = TVShelfData.read(), let folder = TVShelfData.folder else {
            completionHandler(nil)
            return
        }
        var sections: [TVTopShelfItemCollection<TVTopShelfSectionedItem>] = []
        for (title, entries) in [(String(localized: "Memories"), shelf.memories), (String(localized: "Recent"), shelf.recent)] {
            let items = entries.compactMap { Self.item($0, in: folder) }
            guard !items.isEmpty else { continue }
            let section = TVTopShelfItemCollection(items: items)
            section.title = title
            sections.append(section)
        }
        completionHandler(sections.isEmpty ? nil : TVTopShelfSectionedContent(sections: sections))
    }

    private static func item(_ entry: TVShelfData.Item, in folder: URL) -> TVTopShelfSectionedItem? {
        let picture = folder.appendingPathComponent(entry.image)
        guard let link = TVShelfData.url(entry.link), FileManager.default.fileExists(atPath: picture.path) else { return nil }
        let item = TVTopShelfSectionedItem(identifier: entry.link)
        item.title = entry.title
        item.imageShape = .hdtv
        item.setImageURL(picture, for: .screenScale1x)
        item.setImageURL(picture, for: .screenScale2x)
        item.displayAction = TVTopShelfAction(url: link)
        item.playAction = TVTopShelfAction(url: link)
        return item
    }
}
