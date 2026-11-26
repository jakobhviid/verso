import TVServices
import UIKit

/// The Top Shelf's content, written by the app for its extension (TVShelfData): today's memories, each by its first
/// photo, and the library's newest photos, each picture a preview saved beside it. Written each time the app starts
/// signed in, and taken away with a sign-out; the Home Screen is told either way. As the TV reads them: without the
/// Locked Folder, and no memories where the account turned them off.
@MainActor
enum TVTopShelf {
    private static let memoryCount = 8
    private static let recentCount = 12

    static func refresh(client: ImmichClient, images: ImagePipeline) async {
        guard let folder = TVShelfData.folder else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var memories: [ExploreMemory] = []
        let preferences = try? await client.explorePreferences()
        if preferences?.memories?.enabled != false {
            memories = ((try? await client.exploreMemories(page: 1)) ?? []).map { memory in
                var visible = memory
                visible.assets.removeAll { $0.visibility == "locked" }
                return visible
            }
            .filter { !$0.assets.isEmpty }
        }
        var newest = AdvancedSearchRequest(size: recentCount * 2)
        newest.order = "desc"
        let recent = ((try? await client.searchPage(newest, smart: false))?.items ?? []).filter { $0.visibility != "locked" }

        var shelf = TVShelfData(memories: [], recent: [])
        for memory in memories.prefix(memoryCount) {
            guard let cover = memory.assets.first, let file = await save(cover.id, images: images, in: folder) else { continue }
            shelf.memories.append(.init(title: memory.title, image: file, link: "memory/\(memory.id)"))
        }
        for asset in recent.prefix(recentCount) {
            guard let file = await save(asset.id, images: images, in: folder) else { continue }
            let taken = ImmichDate.parse(asset.localDateTime)?.formatted(date: .long, time: .omitted) ?? ""
            shelf.recent.append(.init(title: taken, image: file, link: "photo/\(asset.id)"))
        }
        // Pictures no longer on the shelf go.
        let kept = Set((shelf.memories + shelf.recent).map(\.image))
        for file in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] where file.hasSuffix(".jpg") && !kept.contains(file) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(file))
        }
        shelf.write()
        TVTopShelfContentProvider.topShelfContentDidChange()
    }

    /// Nothing of the account stays on the shelf once the TV signs out.
    static func clear() {
        if let folder = TVShelfData.folder { try? FileManager.default.removeItem(at: folder) }
        TVTopShelfContentProvider.topShelfContentDidChange()
    }

    /// A photo's preview, saved once as a JPEG named for it.
    private static func save(_ id: String, images: ImagePipeline, in folder: URL) async -> String? {
        let name = "\(id).jpg"
        let file = folder.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: file.path) { return name }
        guard let picture = await images.thumbnail(id, size: .preview),
              let data = UIImage(cgImage: picture).jpegData(compressionQuality: 0.85) else { return nil }
        return (try? data.write(to: file, options: .atomic)) == nil ? nil : name
    }
}
