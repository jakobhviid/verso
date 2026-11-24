import Foundation
import Observation

@MainActor @Observable
final class AlbumsActions {
    var revisions: [String: Int] = [:]
    var navigationAlbumID: String?
    @ObservationIgnored private weak var selectionModel: AssetGridModel?
    var details: [String: AlbumDetails] = [:]
    var creating = false
    var initialAssetIDs: [String] = []
    var error: String?
    /// Add to Album…: the photos to add, while the album chooser is open.
    var choosing: AlbumChoice?

    /// Open the album chooser for these photos.
    func chooseAlbum(ids: [String], model: AssetGridModel?) {
        choosing = AlbumChoice(ids: ids, model: model)
    }

    func newAlbum(ids: [String] = [], model: AssetGridModel? = nil) {
        selectionModel = model
        initialAssetIDs = ids
        creating = true
    }

    func didCreate(_ albumID: String) {
        selectionModel?.selection = []
        selectionModel = nil
        navigationAlbumID = albumID
    }

    func perform(session: LibrarySession, albumID: String, reloadTimeline: Bool = true, operation: @escaping () async throws -> Void) {
        Task {
            do { try await operation() }
            catch { session.handle(error); self.error = error.localizedDescription }
            if reloadTimeline {
                session.invalidateAlbumGrid(albumID)
                revisions[albumID, default: 0] += 1
            }
            await session.reloadAlbums()
        }
    }
}

/// Photos on their way into an album, chosen in the album chooser.
struct AlbumChoice: Identifiable {
    let id = UUID()
    let ids: [String]
    weak var model: AssetGridModel?
}

extension GridSource {
    var albumID: String? { if case .album(let id) = self { id } else { nil } }
    var linkID: String? { if case .sharedLink(let id) = self { id } else { nil } }
    var memoryID: String? { if case .memory(let id) = self { id } else { nil } }
    /// ⌫ takes photos out of what the grid shows, an album, a link or a memory, rather than deleting them, as in Photos.
    var removesInsteadOfDeleting: Bool { albumID != nil || linkID != nil || memoryID != nil }
}
