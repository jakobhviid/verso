import SwiftUI
import VersoCore

// The photo grid on the TV, as the iPhone's (ios/Verso/Grid/TimelineGrid.swift, GridTile.swift): square tiles close
// together, edge to edge, each month under its name, the newest photos first (the iPhone's Newest at the Top). A tile
// lifts under the remote's focus; a click opens the photo in the viewer, which steps through the photos of the page.

/// One square of the grid: the thumbnail filling it, its ThumbHash until the thumbnail comes, a favorite's heart at the
/// bottom left and a video's length at the bottom right on a soft shade, as the iPhone's tile draws them.
struct TVGridTile: View {
    let item: TVItem
    let side: CGFloat
    @Environment(TVModel.self) private var model
    @State private var image: CGImage?
    @State private var shownID: String?

    var body: some View {
        let pipeline = model.images
        // What is already at hand shows from the tile's first frame: nothing fades in as it loads.
        let loaded = shownID == item.id ? image : nil
        let thumbnail = loaded ?? pipeline?.cachedThumbnail(item.id, size: .preview)
            ?? pipeline?.cachedThumbnail(item.id, size: .thumbnail)
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
        if let cached = pipeline.cachedThumbnail(item.id, size: .preview) {
            image = cached
            return
        }
        let loaded = await pipeline.gridThumbnail(item.id, size: .preview)
        guard !Task.isCancelled, let loaded else { return }
        image = loaded
    }
}

/// Photos in rows of tiles a width wide, each a button the focus lifts. The focused tile is above its neighbours, so its
/// lift is not cut by the tile drawn after it.
struct TVTileGrid: View {
    let items: [TVItem]
    let width: CGFloat
    let focused: FocusState<String?>.Binding
    let open: (Int) -> Void
    /// Called as a tile comes into view, for a grid that reads on as the end comes near.
    var appeared: ((Int) -> Void)?
    @Environment(\.tvZoom) private var zoom

    var body: some View {
        let metrics = GridTileMetrics(columns: TVMetrics.tileColumns, width: width, spacing: TVMetrics.tileSpacing)
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(metrics.side), spacing: metrics.spacing), count: metrics.columns),
                  alignment: .leading, spacing: metrics.spacing) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                Button { open(index) } label: { TVGridTile(item: item, side: metrics.side) }
                    .buttonStyle(TVLiftStyle(scale: 1.07))
                    .modifier(TVPhotoMenu(item: item))
                    .tvLifts()
                    .focused(focused, equals: item.id)
                    .zIndex(focused.wrappedValue == item.id ? 1 : 0)
                    .tvZoomSource(item.id, in: zoom)
                    .id(item.id)
                    .onAppear { appeared?(index) }
            }
        }
        .frame(width: width, alignment: .leading)
    }

    /// The height a grid of `count` tiles takes, for a month not read yet to hold its place.
    static func height(count: Int, width: CGFloat) -> CGFloat {
        let metrics = GridTileMetrics(columns: TVMetrics.tileColumns, width: width, spacing: TVMetrics.tileSpacing)
        let rows = (count + metrics.columns - 1) / metrics.columns
        return rows > 0 ? CGFloat(rows) * metrics.pitch - metrics.spacing : 0
    }
}

/// The photos of a timeline (the Library's All Photos, Favorites, the Archive, an album, a person), month by month under
/// the month's name, each month read as it comes into view. `header` stands above them in the same scrolling page.
struct TVTimelineGrid: View {
    let model: TVTimelineModel
    let focused: FocusState<String?>.Binding
    let width: CGFloat
    let open: (TVViewing) -> Void
    @Environment(TVModel.self) private var tv

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 40) {
            ForEach(model.months) { month in
                VStack(alignment: .leading, spacing: 16) {
                    Text(TVFormat.month(month.id))
                        .font(.title3.bold())
                        .accessibilityAddTraits(.isHeader)
                    if let items = month.items {
                        TVTileGrid(items: items, width: width, focused: focused) { index in
                            open(viewing(startingAt: month.id, index: index))
                        }
                    } else {
                        Color.clear.frame(width: width, height: TVTileGrid.height(count: month.count, width: width))
                    }
                }
                .id(month.id)
                .task { await model.read(month.id, client: tv.client) }
            }
        }
    }

    /// The viewer over every photo read so far, which reads the following months as it nears their end.
    private func viewing(startingAt monthID: String, index: Int) -> TVViewing {
        let before = model.months.prefix { $0.id != monthID }.reduce(0) { $0 + ($1.items?.count ?? 0) }
        let client = tv.client
        return TVViewing(items: model.items, index: before + index) { [model] in await model.readNext(client: client) }
    }
}

/// A timeline as a page of its own: its title and the number of photos under it, then the photos by month. Favorites,
/// the Archive, an album and a person open as this.
struct TVTimeline: View {
    let query: TimelineQuery
    var title: String
    var line: String?
    @Environment(TVModel.self) private var tv
    @State private var model: TVTimelineModel
    @State private var viewing: TVViewing?
    @State private var width = TVMetrics.pageWidth
    @FocusState private var focused: String?

    init(query: TimelineQuery, title: String, line: String? = nil) {
        self.query = query
        self.title = title
        self.line = line
        _model = State(initialValue: TVTimelineModel(query: query))
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    TVPageTitle(title, line: line ?? (model.total > 0 ? itemCount(model.total) : ""))
                    content
                }
                .modifier(TVWidth(width: $width))
            }
            .scrollClipDisabled()
            .modifier(TVViewerCover(viewing: $viewing, focused: $focused) { proxy.scrollTo($0, anchor: .center) })
            .environment(\.tvPhotoPage, model)
            .environment(\.tvPhotoPlace, query.visibility == "locked" ? .lockedFolder : query.visibility == "archive" ? .archive : .library)
        }
        .task { await model.load(tv.client) }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, minHeight: 400)
        case .failed(let message):
            TVNotice(title: "Can't Load Photos", systemImage: "wifi.exclamationmark", message: message) {
                Task { await model.reload(tv.client) }
            }
        case .loaded:
            if model.months.isEmpty {
                TVNotice(title: "No Photos", systemImage: "photo.on.rectangle")
            } else {
                TVTimelineGrid(model: model, focused: $focused, width: width) { viewing = $0 }
            }
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

    private(set) var items: [TVItem] = []
    private(set) var phase = Phase.loading
    private(set) var hasMore = true
    private let fetch: @Sendable (Int) async throws -> SearchResponse.Assets
    @ObservationIgnored private var page = 1
    @ObservationIgnored private var reading = false

    init(fetch: @escaping @Sendable (Int) async throws -> SearchResponse.Assets) {
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
            items += TVItem.items(response.items).filter { !known.contains($0.id) }
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

/// A search's or a city's photos as a page: the title, the photos in the same grid, the next page read as the end nears.
struct TVResultsGrid: View {
    let model: TVResultsModel
    let width: CGFloat
    let focused: FocusState<String?>.Binding
    let open: (TVViewing) -> Void
    @Environment(TVModel.self) private var tv

    var body: some View {
        switch model.phase {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, minHeight: 400)
        case .failed(let message):
            TVNotice(title: "Can't Load Photos", systemImage: "wifi.exclamationmark", message: message)
        case .loaded:
            if model.items.isEmpty {
                TVNotice(title: "No Photos", systemImage: "photo.on.rectangle")
            } else {
                TVTileGrid(items: model.items, width: width, focused: focused) { index in
                    open(TVViewing(items: model.items, index: index) { [model] in
                        await model.loadMore()
                        return model.items
                    })
                } appeared: { index in
                    if index >= model.items.count - TVMetrics.tileColumns * 3 { Task { await model.loadMore() } }
                }
            }
        }
    }
}

/// A city's photos, as the iPhone's Places opens one (Route.city).
struct TVCityPage: View {
    let city: String
    @Environment(TVModel.self) private var tv
    @State private var model: TVResultsModel?
    @State private var viewing: TVViewing?
    @State private var width = TVMetrics.pageWidth
    @FocusState private var focused: String?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    TVPageTitle(city, line: model.flatMap { $0.items.isEmpty ? nil : itemCount($0.items.count, more: $0.hasMore) } ?? "")
                    if let model { TVResultsGrid(model: model, width: width, focused: $focused) { viewing = $0 } }
                }
                .modifier(TVWidth(width: $width))
            }
            .scrollClipDisabled()
            .modifier(TVViewerCover(viewing: $viewing, focused: $focused) { proxy.scrollTo($0, anchor: .center) })
            .environment(\.tvPhotoPage, model)
        }
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
