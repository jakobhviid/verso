// Verso on the Apple TV's Top Shelf (ROADMAP.md, "Verso on the Apple TV"): with Verso in the Home Screen's top row, the
// shelf above it shows the rows chosen in the app's Settings (today's memories and the library's newest photos until
// changed; albums, favorites and people once turned on), as the app last wrote them (TVShelfData); a click opens the
// app there. With nothing written yet, or signed out, the static Top Shelf image shows instead.

import TVServices

final class ContentProvider: TVTopShelfContentProvider {
    override func loadTopShelfContent(completionHandler: @escaping ((any TVTopShelfContent)?) -> Void) {
        guard let shelf = TVShelfData.read(), let folder = TVShelfData.folder else {
            completionHandler(nil)
            return
        }
        var sections: [TVTopShelfItemCollection<TVTopShelfSectionedItem>] = []
        for row in shelf.sections {
            // People's faces are square; the rest are photos, wide.
            let shape: TVTopShelfSectionedItem.ImageShape = row.row == .people ? .square : .hdtv
            let items = row.items.compactMap { Self.item($0, shape: shape, in: folder) }
            guard !items.isEmpty else { continue }
            let section = TVTopShelfItemCollection(items: items)
            section.title = row.row.title
            sections.append(section)
        }
        completionHandler(sections.isEmpty ? nil : TVTopShelfSectionedContent(sections: sections))
    }

    private static func item(_ entry: TVShelfData.Item, shape: TVTopShelfSectionedItem.ImageShape,
                             in folder: URL) -> TVTopShelfSectionedItem? {
        let picture = folder.appendingPathComponent(entry.image)
        guard let link = TVShelfData.url(entry.link), FileManager.default.fileExists(atPath: picture.path) else { return nil }
        let item = TVTopShelfSectionedItem(identifier: entry.link)
        item.title = entry.title
        item.imageShape = shape
        item.setImageURL(picture, for: .screenScale1x)
        item.setImageURL(picture, for: .screenScale2x)
        item.displayAction = TVTopShelfAction(url: link)
        item.playAction = TVTopShelfAction(url: link)
        return item
    }
}
