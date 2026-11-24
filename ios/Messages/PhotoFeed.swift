// One of the picker's lists of photos (PickerLibrary), read a page at a time as the person scrolls to its end: from
// Immich's timeline a month at a time, newest first (the library, its favorites, an album), or from its search a page
// at a time. Photos alone: videos, the Locked Folder's photos and the trash are left out.

import Foundation
import Observation

@MainActor @Observable
final class PhotoFeed {
    enum Source {
        /// Immich's timeline with these filters, its months newest first.
        case timeline(TimelineQuery)
        /// Immich's search for the text: by meaning (smart search), or by file name where the server has no smart
        /// search.
        case search(String, smart: Bool)
    }

    /// About how many photos a page brings: a screenful of tiles and more.
    private static let pageSize = 60
    private static let searchPageSize = 100

    private(set) var photos: [PickerPhoto] = []
    private(set) var isLoading = false
    private(set) var reachedEnd = false
    private(set) var problem: String?
    @ObservationIgnored var onUnauthorized: (() -> Void)?

    private let client: ImmichClient
    let source: Source
    @ObservationIgnored private var months: [TimeBucket]?
    @ObservationIgnored private var nextMonth = 0
    @ObservationIgnored private var nextPage = 1
    @ObservationIgnored private var seen: Set<String> = []

    init(client: ImmichClient, source: Source) {
        self.client = client
        self.source = source
    }

    /// The next page, unless one is being read or the list is whole.
    func loadMore() async {
        guard !isLoading, !reachedEnd else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            problem = nil
            switch source {
            case .timeline(let query): try await readMonths(query)
            case .search(let text, let smart): try await readSearchPage(text, smart: smart)
            }
        } catch {
            guard !error.isCancellation else { return }
            if error.isUnauthorized {
                onUnauthorized?()
                return
            }
            problem = error.localizedDescription
        }
    }

    private func readMonths(_ query: TimelineQuery) async throws {
        let months: [TimeBucket]
        if let known = self.months {
            months = known
        } else {
            months = try await client.timeBuckets(query)
            self.months = months
        }
        var added = 0
        while added < Self.pageSize, nextMonth < months.count {
            let month = try await client.timeBucket(months[nextMonth].timeBucket, query)
            nextMonth += 1
            added += append(Self.photos(in: month))
        }
        reachedEnd = nextMonth >= months.count
    }

    private func readSearchPage(_ text: String, smart: Bool) async throws {
        var query = SearchQuery()
        query.text = text
        query.mode = smart ? .context : .fileName
        query.mediaType = AssetType.image.rawValue
        let page = try await client.advancedSearch(query, smartEnabled: smart, page: .init(page: nextPage))
        nextPage += 1
        append(page.items
            .filter { $0.type == .image && !$0.isTrashed && $0.visibility != "locked" }
            .map { PickerPhoto(id: $0.id, thumbhash: $0.thumbhash) })
        reachedEnd = page.nextPage == nil || page.items.isEmpty
    }

    /// Adds the photos not already listed (a stack's or a search's repeats); how many were added.
    @discardableResult
    private func append(_ more: [PickerPhoto]) -> Int {
        let fresh = more.filter { seen.insert($0.id).inserted }
        photos += fresh
        return fresh.count
    }

    /// A month's photos, in the timeline's order.
    private static func photos(in month: TimeBucketAssets) -> [PickerPhoto] {
        month.id.indices.compactMap { index in
            guard month.isImage[index], !month.isTrashed[index],
                  month.visibility?[index] != "locked" else { return nil }
            return PickerPhoto(id: month.id[index], thumbhash: month.thumbhash[index])
        }
    }
}
