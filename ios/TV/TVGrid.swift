import SwiftUI
import VersoCore

// The photos on the TV, as the iPhone's grid has them (ios/Verso/Grid/TimelineGrid.swift, GridTile.swift): square
// tiles close together, edge to edge, each month under its name, the newest photos first (the iPhone's Newest at the
// Top), in UIKit's collection view (TVPhotoGrid); a click opens the photo in the viewer, which steps through the photos
// of the page. Here: the tile, a timeline's page, a list read page by page, and a city's page.

/// One square of the grid: the thumbnail filling it, its ThumbHash until the thumbnail comes, a favorite's heart at the
/// bottom left and a video's length at the bottom right on a soft shade, as the iPhone's tile draws them.
struct TVGridTile: View {
    let item: TVItem
    let side: CGFloat
    /// The pixels a tile's picture is decoded at, on its longer side: a tile's 280 points at a 4K screen's two pixels to
    /// a point, so the 1440 the server sends are not decoded whole for it (ImagePipeline.tileThumbnail).
    static let pixels = 640
    @Environment(TVModel.self) private var model
    @State private var image: CGImage?
    @State private var shownID: String?

    var body: some View {
        let pipeline = model.images
        // What is already at hand shows from the tile's first frame: nothing fades in as it loads.
        let loaded = shownID == item.id ? image : nil
        let thumbnail = loaded ?? pipeline?.cachedTile(item.id, size: .preview, pixels: Self.pixels)
            ?? pipeline?.cachedThumbnail(item.id, size: .preview)
        let hashed = thumbnail == nil ? item.thumbhash.flatMap { ThumbHash.cachedImage(base64: $0) } : nil
        square(thumbnail ?? hashed)
            .task(id: item.id) { await load() }
            .accessibilityLabel(item.isVideo ? Text("Video") : Text("Photo"))
    }

    private func square(_ picture: CGImage?) -> some View {
        Rectangle()
            .fill(.quaternary)
            .frame(width: side, height: side)
            .overlay {
                if let picture { Image(decorative: picture, scale: 1).resizable().scaledToFill() }
            }
            .overlay(alignment: .bottom) { badges }
            .clipped()
            .contentShape(Rectangle())
    }

    @ViewBuilder
    private var badges: some View {
        if item.isFavorite || item.isVideo {
            HStack(spacing: 4) {
                if item.isFavorite { Image(systemName: "heart.fill") }
                Spacer(minLength: 0)
                if item.isVideo {
                    if let duration = item.durationMS {
                        Text(Duration.formatMilliseconds(duration)).monospacedDigit()
                    } else {
                        Image(systemName: "video.fill")
                    }
                }
            }
            .font(.callout.weight(.semibold))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.5), radius: 2)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(alignment: .bottom) {
                LinearGradient(colors: [.clear, .black.opacity(0.35)], startPoint: .top, endPoint: .bottom)
            }
            .accessibilityHidden(true)
        }
    }

    private func load() async {
        guard let pipeline = model.images else { return }
        if shownID != item.id {
            image = nil
            shownID = item.id
        }
        if let cached = pipeline.cachedTile(item.id, size: .preview, pixels: Self.pixels) {
            image = cached
            return
        }
        let loaded = await pipeline.tileThumbnail(item.id, size: .preview, pixels: Self.pixels)
        guard !Task.isCancelled, let loaded else { return }
        image = loaded
    }
}

/// A timeline as a page of its own: its title and the number of photos under it, with the Filter menu beside them, then
/// the photos by month. Favorites, the Archive, an album, a person and the Locked Folder open as this. The header is a
/// focus area of its own, so up from anywhere in the grid's first row comes to the Filter menu, however few the photos.
struct TVTimeline: View {
    let query: TimelineQuery
    var title: String
    var line: String?
    @Environment(TVModel.self) private var tv
    @State private var model: TVTimelineModel
    @State private var viewing: TVViewing?
    /// The Filter menu's choice (TVFilter), and the videos it found where it asks for them.
    @State private var filter = TVFilter()
    @State private var videos: TVResultsModel?

    init(query: TimelineQuery, title: String, line: String? = nil) {
        self.query = query
        self.title = title
        self.line = line
        _model = State(initialValue: TVTimelineModel(query: query))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            TVPageTitle(title: title, line: line ?? count) {
                TVFilterMenu(filter: $filter, offersVideos: query.searchable)
            }
            .focusSection()
            TVPhotos(content: videos.map { .results($0) } ?? .timeline(model)) { viewing = $0 } retry: {
                Task { await show(filter) }
            }
        }
        .modifier(TVViewerCover(viewing: $viewing))
        .environment(\.tvPhotoPage, videos ?? model)
        .environment(\.tvPhotoPlace, query.visibility == "locked" ? .lockedFolder : query.visibility == "archive" ? .archive : .library)
        .task(id: filter) { await show(filter) }
    }

    private var count: String {
        if let videos { return videos.items.isEmpty ? "" : itemCount(videos.items.count, more: videos.hasMore) }
        return model.total > 0 ? itemCount(model.total) : ""
    }

    /// The page's photos as the filter has them: the timeline, narrowed to the favorites where asked, or its videos;
    /// each choice a list of its own, read afresh, so a month the last choice had is never left unread.
    private func show(_ filter: TVFilter) async {
        guard let client = tv.client else { return }
        if filter.videos {
            let query = query
            let found = TVResultsModel(keepsLocked: query.visibility == "locked") { page in
                try await client.searchPage(query.videos(filter, page: page), smart: false)
            }
            videos = found
            await found.loadMore()
            return
        }
        videos = nil
        let filtered = query.filtered(filter)
        if model.query != filtered || model.phase != .loaded { model = TVTimelineModel(query: filtered) }
        await model.load(client)
    }
}

/// A grid's photos as a page shows them: loading, failed with a retry, none, or the grid, which fills the page down to
/// the screen's foot.
struct TVPhotos: View {
    let content: TVPhotoGridContent
    let open: (TVViewing) -> Void
    var retry: (() -> Void)?

    var body: some View {
        switch content.phase {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, minHeight: 400)
        case .failed(let message):
            TVNotice(title: "Can't Load Photos", systemImage: "wifi.exclamationmark", message: message, retry: retry)
        case .loaded where content.sections.allSatisfy { $0.count == 0 }:
            TVNotice(title: "No Photos", systemImage: "photo.on.rectangle")
        case .loaded:
            TVPhotoGrid(content: content, revision: content.revision, open: open)
                .ignoresSafeArea(edges: .bottom)
        }
    }
}

/// "1 item" or "12,345 items"; with `more`, "100+ items" for a list that reads on.
func itemCount(_ count: Int, more: Bool = false) -> String {
    if more { return String(localized: "\(count.formatted())+ items") }
    return count == 1 ? String(localized: "1 item") : String(localized: "\(count.formatted()) items")
}

// MARK: Results

/// A list of photos read page by page: a search's results, a city's photos.
@MainActor @Observable
final class TVResultsModel: TVPhotoPage {
    enum Phase: Equatable { case loading, loaded, failed(String) }

    private(set) var items: [TVItem] = [] { didSet { revision += 1 } }
    /// Counts every change to the photos, which the grid redraws by (TVPhotoGrid).
    private(set) var revision = 0
    private(set) var phase = Phase.loading
    private(set) var hasMore = true
    private let fetch: @Sendable (Int) async throws -> SearchResponse.Assets
    @ObservationIgnored private var page = 1
    @ObservationIgnored private var reading = false

    /// The Locked Folder's photos are kept where the list is its own (its videos, filtered), and left out elsewhere.
    private let keepsLocked: Bool

    init(keepsLocked: Bool = false, fetch: @escaping @Sendable (Int) async throws -> SearchResponse.Assets) {
        self.keepsLocked = keepsLocked
        self.fetch = fetch
    }

    /// A photo a menu changed (TVPhotoMenu): a favorite's heart, or gone from the results.
    func apply(_ change: TVPhotoChange) {
        guard let at = items.firstIndex(where: { $0.id == change.id }) else { return }
        if case .favorite(_, let on) = change { items[at].isFavorite = on } else { items.remove(at: at) }
    }

    func loadMore() async {
        guard hasMore, !reading else { return }
        reading = true
        defer { reading = false }
        do {
            let response = try await fetch(page)
            let known = Set(items.map(\.id))
            items += TVItem.items(response.items, keepsLocked: keepsLocked).filter { !known.contains($0.id) }
            hasMore = response.nextPage.flatMap(Int.init).map { $0 > page } ?? false
            page += 1
            phase = .loaded
        } catch is CancellationError {
        } catch {
            hasMore = false
            if items.isEmpty { phase = .failed(error.localizedDescription) }
        }
    }
}

/// A city's photos, as the iPhone's Places opens one (Route.city).
struct TVCityPage: View {
    let city: String
    @Environment(TVModel.self) private var tv
    @State private var model: TVResultsModel?
    @State private var viewing: TVViewing?

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            TVPageTitle(city, line: model.flatMap { $0.items.isEmpty ? nil : itemCount($0.items.count, more: $0.hasMore) } ?? "")
            if let model { TVPhotos(content: .results(model)) { viewing = $0 } }
        }
        .modifier(TVViewerCover(viewing: $viewing))
        .environment(\.tvPhotoPage, model)
        .task {
            guard model == nil, let client = tv.client else { return }
            let city = city
            let made = TVResultsModel { page in
                try await client.exploreAssets(.city(city), page: ImmichClient.SearchPage(page: page))
            }
            model = made
            await made.loadMore()
        }
    }
}
