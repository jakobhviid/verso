// What Collections shows of its pages before they are opened: the first people, the memories, the places, and the
// counts the server gives cheaply (Archive, Recently Deleted). Each is read once, again on a pull to refresh, and the
// counts again whenever the grids are marked stale, as after a delete.

import Foundation
import Observation

@MainActor @Observable
final class CollectionsPreviews {
    /// The people Immich lists first (favorites, then those in the most photos), the named before the unnamed.
    private(set) var people: [Person] = []
    private(set) var peopleTotal: Int?
    /// Today's memories, those with photos.
    private(set) var memories: [ExploreMemory] = []
    /// Today's memories have been read, so none means there are none.
    private(set) var memoriesRead = false
    /// A photo for each city, as Places has them.
    private(set) var cities: [AssetResponse] = []
    /// The links' counts, where one is known.
    private(set) var counts: [SidebarLink: Int] = [:]
    @ObservationIgnored private var loaded: Set<String> = []

    /// How many people, cards or places a row shows before See All.
    static let rowLimit = 20

    func loadPeople(_ session: LibrarySession, again: Bool = false) async {
        guard again || loaded.insert("people").inserted else { return }
        do {
            let page = try await session.client.peoplePage(page: 1, withHidden: false)
            let named = page.people.filter { !$0.name.isEmpty }
            let unnamed = page.people.filter { $0.name.isEmpty }
            people = Array((named + unnamed).prefix(Self.rowLimit))
            peopleTotal = page.total
        } catch {
            loaded.remove("people")
            session.handle(error)
        }
    }

    func loadMemories(_ session: LibrarySession, again: Bool = false) async {
        guard again || loaded.insert("memories").inserted else { return }
        do {
            memories = try await session.client.exploreMemories(page: 1).filter { memory in
                memory.assets.contains { $0.visibility != "locked" }
            }
            memoriesRead = true
        } catch {
            loaded.remove("memories")
            session.handle(error)
        }
    }

    func loadPlaces(_ session: LibrarySession, again: Bool = false) async {
        guard again || loaded.insert("places").inserted else { return }
        do {
            cities = try await session.client.exploreCities().filter { $0.visibility != "locked" && $0.exifInfo?.city?.isEmpty == false }
        } catch {
            loaded.remove("places")
            session.handle(error)
        }
    }

    /// The counts of the grids that have one at the cost of a request: the timeline's months summed, as the grid
    /// itself counts them.
    func loadCounts(_ session: LibrarySession) async {
        let client = session.client
        let archiveQuery = GridSource.archive.timelineQuery
        let trashQuery = session.features.trash ? GridSource.trash.timelineQuery : nil
        async let archive = Self.timelineCount(client, archiveQuery)
        async let trash = Self.timelineCount(client, trashQuery)
        var counts: [SidebarLink: Int] = [:]
        counts[.archive] = await archive
        counts[.trash] = await trash
        guard !Task.isCancelled else { return }
        self.counts = counts
    }

    /// Everything shown, read again: a pull to refresh.
    func reload(_ session: LibrarySession, people: Bool, memories: Bool, places: Bool) async {
        await loadCounts(session)
        if people { await loadPeople(session, again: true) }
        if memories { await loadMemories(session, again: true) }
        if places { await loadPlaces(session, again: true) }
    }

    nonisolated private static func timelineCount(_ client: ImmichClient, _ query: TimelineQuery?) async -> Int? {
        guard let query, let months = try? await client.timeBuckets(query) else { return nil }
        return months.reduce(0) { $0 + $1.count }
    }
}
