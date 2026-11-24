// The memories Immich made for today, shared by the Memories page and the story that plays them, so a memory kept,
// seen, changed or deleted in one shows so in the other. As on the Mac: a memory without photos the account may see
// (the Locked Folder's are left out) is not shown, and a memory is New until it has been opened.

import Foundation
import Observation

@MainActor @Observable
final class MemoriesModel {
    enum LoadState: Equatable {
        case loading, loaded, disabled, failed(String)
    }

    let session: LibrarySession
    private(set) var memories: [ExploreMemory] = []
    private(set) var state = LoadState.loading
    private(set) var hasMore = false
    /// How long each photo shows in the story, in seconds: the account's setting in Immich, five by default.
    private(set) var duration = 5
    @ObservationIgnored private var page = 1
    /// The server's answers the memories were read after, so coming back to the page keeps them.
    @ObservationIgnored private var loadedReconnections: Int?
    @ObservationIgnored private var loadingPage = false

    init(session: LibrarySession) {
        self.session = session
    }

    func memory(_ id: String) -> ExploreMemory? {
        memories.first { $0.id == id }
    }

    /// Reads the memories once, and again after the server answers again once it could not be reached.
    func load(reconnections: Int) async {
        guard loadedReconnections != reconnections || state == .loading else { return }
        loadedReconnections = reconnections
        await reload()
    }

    /// Reads the memories again from the first page.
    func reload() async {
        if memories.isEmpty { state = .loading }
        do {
            let preferences = try await session.client.explorePreferences()
            guard preferences.memories?.enabled == true else {
                memories = []
                state = .disabled
                return
            }
            duration = max(1, preferences.memories?.duration ?? 5)
            page = 1
            hasMore = true
            let first = try await nextPage()
            memories = first
            state = .loaded
        } catch is CancellationError {
        } catch {
            session.handle(error)
            if memories.isEmpty { state = .failed(error.localizedDescription) }
        }
    }

    /// The next page, as the end of the list comes into view.
    func loadMore() async {
        guard hasMore, !loadingPage, state == .loaded else { return }
        do {
            let more = try await nextPage()
            let known = Set(memories.map(\.id))
            memories += more.filter { !known.contains($0.id) }
        } catch is CancellationError {
        } catch {
            session.handle(error)
            hasMore = false
        }
    }

    private func nextPage() async throws -> [ExploreMemory] {
        loadingPage = true
        defer { loadingPage = false }
        let batch = try await session.client.exploreMemories(page: page)
        page += 1
        hasMore = batch.count == 100
        return batch.map { memory in
            var visible = memory
            visible.assets.removeAll { $0.visibility == "locked" }
            return visible
        }
        .filter { !$0.assets.isEmpty }
    }

    /// Keeps a memory, so Immich's cleanup leaves it (it removes a memory after 30 days otherwise), or lets it go.
    func setKept(_ id: String, _ keep: Bool) async throws {
        try await session.client.exploreKeepMemory(id, keep: keep)
        if let index = memories.firstIndex(where: { $0.id == id }) { memories[index].isSaved = keep }
    }

    /// The memory was opened: it is no longer New.
    func markSeen(_ id: String) {
        guard let index = memories.firstIndex(where: { $0.id == id }), memories[index].seenAt == nil else { return }
        memories[index].seenAt = Date().ISO8601Format()
        Task {
            do { try await session.client.exploreSeenMemory(id) }
            catch { session.handle(error) }
        }
    }

    /// Deletes a memory; its photos stay in the library.
    func delete(_ id: String) async throws {
        try await session.client.exploreDeleteMemory(id)
        memories.removeAll { $0.id == id }
    }

    /// Takes a photo out of a memory; it stays in the library. A memory left without photos goes from the list.
    func remove(_ assetID: String, from memoryID: String) async throws {
        try await session.client.exploreRemoveMemoryAsset(memoryID, asset: assetID)
        guard let index = memories.firstIndex(where: { $0.id == memoryID }) else { return }
        memories[index].assets.removeAll { $0.id == assetID }
        if memories[index].assets.isEmpty { memories.remove(at: index) }
        // The memory's grid, where it was opened as one, reads it again.
        session.gridModel(for: .memory(memoryID)).markStale()
    }
}
