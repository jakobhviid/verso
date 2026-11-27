import TVServices
import UIKit
import VersoCore

/// The Top Shelf's content, written by the app for its extension (TVShelfData): the rows Settings has on, each item a
/// preview saved beside it. Written each time the app starts signed in and as Settings changes the rows, and taken away
/// with a sign-out; the Home Screen is told either way. As the TV reads them: without the Locked Folder, and no
/// memories where the account turned them off.
///
/// What each row holds, and in what order:
/// - Memories: today's, as Immich gives them, each by its first photo.
/// - Recent: the newest photos, by the date they were taken.
/// - Albums: those with the newest photos first, by the date of the newest (the shared core's Most Recent Photo, the
///   order the Albums page runs in, its year sections and the albums in them read one after another), so the albums of
///   the latest trip or day out come first; an empty album, with no cover, is left out.
/// - Favorites: the newest, by the date they were taken.
/// - People: named and not hidden, in People's order (the server's, the favorites first), each by their face.
@MainActor
enum TVTopShelf {
    private static let counts: [TVShelfData.Row: Int] = [.memories: 8, .recent: 12, .albums: 10, .favorites: 12, .people: 10]

    /// The rows Settings has on (TVShelfData.Row.settingKey).
    static var rowsShown: [TVShelfData.Row] {
        TVShelfData.Row.allCases.filter { UserDefaults.standard.object(forKey: $0.settingKey) as? Bool ?? $0.shownByDefault }
    }

    /// Writes the shelf again. A refresh started after this one cancels it, so only the last writes the shelf and sorts
    /// out its pictures.
    static func refresh(client: ImmichClient, images: ImagePipeline) async {
        guard let folder = TVShelfData.folder else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var shelf = TVShelfData(sections: [])
        for row in rowsShown {
            let items = await items(row, count: counts[row] ?? 10, client: client, images: images, folder: folder)
            guard !Task.isCancelled else { return }
            if !items.isEmpty { shelf.sections.append(.init(row: row, items: items)) }
        }
        // Pictures no longer on the shelf go.
        let kept = Set(shelf.sections.flatMap(\.items).map(\.image))
        for file in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] where file.hasSuffix(".jpg") && !kept.contains(file) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(file))
        }
        shelf.write()
        TVTopShelfContentProvider.topShelfContentDidChange()
    }

    private static func items(_ row: TVShelfData.Row, count: Int, client: ImmichClient, images: ImagePipeline,
                              folder: URL) async -> [TVShelfData.Item] {
        var items: [TVShelfData.Item] = []
        switch row {
        case .memories:
            let preferences = try? await client.explorePreferences()
            guard preferences?.memories?.enabled != false else { return [] }
            let memories = ((try? await client.exploreMemories(page: 1)) ?? []).map { memory in
                var visible = memory
                visible.assets.removeAll { $0.visibility == "locked" }
                return visible
            }
            for memory in memories where !memory.assets.isEmpty {
                guard items.count < count else { break }
                guard let cover = memory.assets.first, let file = await save(cover.id, images: images, in: folder) else { continue }
                items.append(.init(title: memory.title, image: file, link: "memory/\(memory.id)"))
            }
        case .recent, .favorites:
            var newest = AdvancedSearchRequest(size: count * 2)
            newest.order = "desc"
            if row == .favorites { newest.isFavorite = true }
            let photos = ((try? await client.searchPage(newest, smart: false))?.items ?? []).filter { $0.visibility != "locked" }
            for asset in photos {
                guard items.count < count else { break }
                guard let file = await save(asset.id, images: images, in: folder) else { continue }
                let taken = ImmichDate.parse(asset.localDateTime)?.formatted(date: .long, time: .omitted) ?? ""
                items.append(.init(title: taken, image: file, link: "photo/\(asset.id)"))
            }
        case .albums:
            let albums = ((try? await client.albums()) ?? []).filter { $0.assetCount > 0 && $0.albumThumbnailAssetId != nil }
            for album in AlbumsSortBy.mostRecentPhoto.sidebar(albums, limit: count) {
                guard let cover = album.albumThumbnailAssetId, let file = await save(cover, images: images, in: folder) else { continue }
                items.append(.init(title: album.albumName, image: file, link: "album/\(album.id)"))
            }
        case .people:
            guard let response = try? await client.peoplePage(page: 1, withHidden: false) else { return [] }
            let people = PeopleOptions(show: .all, includeHidden: false).shown(response.people).filter { !$0.name.isEmpty }
            for person in people {
                guard items.count < count else { break }
                guard let file = await saveFace(person.id, images: images, in: folder) else { continue }
                items.append(.init(title: person.name, image: file, link: "person/\(person.id)"))
            }
        }
        return items
    }

    /// Nothing of the account stays on the shelf once the TV signs out.
    static func clear() {
        if let folder = TVShelfData.folder { try? FileManager.default.removeItem(at: folder) }
        TVTopShelfContentProvider.topShelfContentDidChange()
    }

    /// A photo's preview, saved once as a JPEG named for it.
    private static func save(_ id: String, images: ImagePipeline, in folder: URL) async -> String? {
        await save(name: "\(id).jpg", in: folder) { await images.thumbnail(id, size: .preview) }
    }

    /// A person's face, saved as the photos are.
    private static func saveFace(_ id: String, images: ImagePipeline, in folder: URL) async -> String? {
        await save(name: "person-\(id).jpg", in: folder) { await images.personThumbnail(id) }
    }

    private static func save(name: String, in folder: URL, picture: () async -> CGImage?) async -> String? {
        let file = folder.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: file.path) { return name }
        guard let picture = await picture(), let data = UIImage(cgImage: picture).jpegData(compressionQuality: 0.85) else { return nil }
        return (try? data.write(to: file, options: .atomic)) == nil ? nil : name
    }
}
