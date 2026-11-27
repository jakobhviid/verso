import SwiftUI
import VersoCore

// The Library on the TV, as the iPhone's (ios/Verso/Library/LibraryOverviewPage.swift, LibraryTabView.swift): a large
// "Library" title with a menu of Years, Months and All Photos beside it. Years are a card for each year, a photo from its fullest
// month with the year written over it; Months are each month's name over a mosaic of a few photos from different days,
// the day written on each; All Photos is the grid. What Years and Months show is arranged by the shared core
// (`overviewYears`, `overviewPicks`), as on the iPhone. Newest first, the iPhone's Newest at the Top.

struct TVLibrary: View {
    @Environment(TVModel.self) private var tv
    @State private var model = TVTimelineModel(query: TimelineQuery(withPartners: true))
    @State private var mode = LibraryMode.all
    /// All Photos' Filter menu (TVFilter): the favorites as a timeline of their own, or the videos as a search.
    @State private var filter = TVFilter()
    @State private var favorites: TVTimelineModel?
    @State private var videos: TVResultsModel?
    @State private var viewing: TVViewing?
    /// All Photos' grid, which Months scrolls and focuses at a photo picked there.
    @State private var grid = TVTileFrames()

    init() {
        #if DEBUG
        if let name = UserDefaults.standard.string(forKey: "tvLibraryMode"), let start = LibraryMode(rawValue: name) {
            _mode = State(initialValue: start)
        }
        // All Photos filtered to its videos (`-tvFilterVideos YES`), for the remote's tests of a video (VersoTVUITests).
        if UserDefaults.standard.bool(forKey: "tvFilterVideos") { _filter = State(initialValue: TVFilter(videos: true)) }
        #endif
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            TVPageTitle(title: String(localized: "Library"), line: count) {
                HStack(spacing: 24) {
                    if mode == .all { TVFilterMenu(filter: $filter) }
                    modePicker
                }
            }
            // Up from anywhere in the photos comes to the filter and the modes, however few the photos.
            .focusSection()
            if mode == .all {
                TVPhotos(content: videos.map { .results($0) } ?? .timeline(favorites ?? model)) { viewing = $0 } retry: {
                    Task { if filter.isOn { await show(filter) } else { await model.reload(tv.client) } }
                }
            } else {
                ScrollViewReader { proxy in
                    ScrollView { overview(proxy) }
                        .scrollClipDisabled()
                }
            }
        }
        .modifier(TVViewerCover(viewing: $viewing, frames: grid))
        .environment(\.tvPhotoPage, videos ?? favorites ?? model)
        .task(id: filter) { if filter.isOn || videos != nil || favorites != nil { await show(filter) } }
        // Years and Months show the whole library: the filter is All Photos'.
        .onChange(of: mode) { if mode != .all { filter = TVFilter() } }
        .task {
            await model.load(tv.client)
            #if DEBUG
            // A development build opens the viewer at a photo of the newest month (`-tvOpenPhoto 3`), to look at it.
            if let first = model.months.first, UserDefaults.standard.object(forKey: "tvOpenPhoto") != nil {
                await model.read(first.id, client: tv.client)
                // Once its tile is on screen, which the viewer zooms out of.
                try? await Task.sleep(for: .seconds(3))
                viewing = TVViewing(items: model.items, index: UserDefaults.standard.integer(forKey: "tvOpenPhoto"))
            }
            // Or at the newest videos (`-tvOpenVideo YES`), for the UI tests of the system's player (VersoTVUITests).
            if UserDefaults.standard.bool(forKey: "tvOpenVideo"), let client = tv.client {
                var videos = AdvancedSearchRequest(size: 5)
                videos.type = "VIDEO"
                videos.order = "desc"
                let found = TVItem.items((try? await client.searchPage(videos, smart: false))?.items ?? [])
                if !found.isEmpty { viewing = TVViewing(items: found, index: 0) }
            }
            #endif
        }
    }

    /// Years, Months or All Photos: the system's segmented control, as the iPhone has them.
    private var count: String {
        if let videos { return videos.items.isEmpty ? "" : itemCount(videos.items.count, more: videos.hasMore) }
        let shown = favorites ?? model
        return shown.total > 0 ? itemCount(shown.total) : ""
    }

    /// All Photos as the filter has them: the favorites, as a timeline of their own, or the videos, from a search.
    private func show(_ filter: TVFilter) async {
        guard let client = tv.client else { return }
        if filter.videos {
            let found = TVResultsModel { page in
                try await client.searchPage(TimelineQuery().videos(filter, page: page), smart: false)
            }
            videos = found
            await found.loadMore()
        } else {
            videos = nil
            favorites = filter.favorites ? TVTimelineModel(query: model.query.filtered(filter)) : nil
            await favorites?.load(client)
        }
    }

    /// Years, Months or All Photos, as a menu: the one shown on its button, the three in its list. A segmented control
    /// changed the page as the focus crossed it on the way to the Filter menu.
    private var modePicker: some View {
        Menu {
            Picker("Years, Months or All", selection: $mode) {
                Label("Years", systemImage: "square.grid.2x2").tag(LibraryMode.years)
                Label("Months", systemImage: "rectangle.grid.1x2").tag(LibraryMode.months)
                Label("All Photos", systemImage: "square.grid.3x3").tag(LibraryMode.all)
            }
        } label: {
            Label(modeTitle, systemImage: "chevron.up.chevron.down")
                .labelStyle(.titleAndIcon)
        }
        .fixedSize()
    }

    private var modeTitle: String { String(localized: mode.title) }

    /// Years or Months.
    @ViewBuilder
    private func overview(_ proxy: ScrollViewProxy) -> some View {
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
                if mode == .years { years(proxy) } else { months(proxy) }
            }
        }
    }

    // MARK: Years

    private func years(_ proxy: ScrollViewProxy) -> some View {
        // Oldest first from the core, shown newest first.
        let years = overviewYears(months: model.months.reversed().map { OverviewMonth(bucket: $0.id, count: UInt32(clamping: $0.count)) })
        return LazyVGrid(columns: tvColumns(TVMetrics.yearColumns), alignment: .leading, spacing: TVMetrics.cardSpacing) {
            ForEach(Array(years.reversed())) { year in
                Button { open(year, proxy) } label: { TVYearCard(model: model, year: year) }
                    .buttonStyle(TVLiftStyle(scale: 1.05, cornerRadius: 28))
                    .tvLifts()
                    .accessibilityLabel(Text(verbatim: year.id))
            }
        }
    }

    /// Months, at the year: its newest month first, as the months run from the newest down.
    private func open(_ year: OverviewYear, _ proxy: ScrollViewProxy) {
        mode = .months
        guard let month = year.months.last else { return }
        Task {
            try? await Task.sleep(for: .milliseconds(200))
            proxy.scrollTo(month, anchor: .top)
        }
    }

    // MARK: Months

    private func months(_ proxy: ScrollViewProxy) -> some View {
        LazyVGrid(columns: tvColumns(TVMetrics.monthColumns), alignment: .leading, spacing: 48) {
            ForEach(model.months) { month in
                TVMonthCell(model: model, month: month) { photo in show(photo, in: month.id, proxy) }
            }
        }
    }

    /// A photo picked in Months: All Photos at it, once its month is read.
    private func show(_ photo: String, in month: String, _ proxy: ScrollViewProxy) {
        mode = .all
        Task {
            try? await Task.sleep(for: .milliseconds(250))
            grid.scrollToSection?(month)
            try? await Task.sleep(for: .milliseconds(600))
            grid.scroll?(photo)
            grid.focus?(photo)
        }
    }
}

/// A month's photos as the shared core picks from them.
private func overviewPhotos(_ items: [TVItem]) -> [OverviewPhoto] {
    items.map { OverviewPhoto(id: $0.id, taken: $0.date, isVideo: $0.isVideo) }
}

/// A year: a photo from its fullest month, the year written over it.
private struct TVYearCard: View {
    let model: TVTimelineModel
    let year: OverviewYear
    @Environment(TVModel.self) private var tv

    var body: some View {
        let items = model.months.first { $0.id == year.keyMonth }?.items
        let photo = items.flatMap { overviewPicks(photos: overviewPhotos($0), limit: 1).first }
        Color.clear
            .aspectRatio(4 / 3, contentMode: .fit)
            .overlay { TVPicture(assetID: photo?.id, size: .preview) }
            .clipShape(.rect(cornerRadius: 28, style: .continuous))
            .overlay(alignment: .topLeading) {
                Text(verbatim: year.id)
                    .font(.system(size: 52, weight: .bold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.45), radius: 8)
                    .padding(28)
            }
            .contentShape(.rect(cornerRadius: 28, style: .continuous))
            .task { await model.read(year.keyMonth, client: tv.client) }
    }
}

/// A month in Months: its name over its mosaic, read as it comes into view.
private struct TVMonthCell: View {
    let model: TVTimelineModel
    let month: TVTimelineModel.Month
    let openPhoto: (String) -> Void
    @Environment(TVModel.self) private var tv

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(TVFormat.month(month.id))
                .font(.title3.bold())
                .accessibilityAddTraits(.isHeader)
            TVMonthMosaic(items: month.items, openPhoto: openPhoto)
        }
        .id(month.id)
        .task { await model.read(month.id, client: tv.client) }
    }
}

/// A month: one large photo and up to three beside it, each from a different day, the day written on it.
private struct TVMonthMosaic: View {
    let items: [TVItem]?
    let openPhoto: (String) -> Void
    private let spacing = 6.0

    var body: some View {
        let picks = items.map { overviewPicks(photos: overviewPhotos($0), limit: 4) } ?? []
        Color.clear
            .aspectRatio(1.5, contentMode: .fit)
            .overlay {
                if picks.isEmpty {
                    RoundedRectangle(cornerRadius: 24, style: .continuous).fill(.quaternary)
                } else {
                    GeometryReader { geometry in
                        HStack(spacing: spacing) {
                            tile(picks[0])
                                .frame(width: picks.count > 1
                                       ? (geometry.size.width - spacing) * (picks.count > 2 ? 2 / 3 : 1 / 2)
                                       : geometry.size.width)
                            if picks.count > 1 {
                                VStack(spacing: spacing) {
                                    ForEach(picks.dropFirst(), id: \.id) { tile($0) }
                                }
                            }
                        }
                    }
                    .clipShape(.rect(cornerRadius: 24, style: .continuous))
                }
            }
    }

    private func tile(_ pick: OverviewPick) -> some View {
        Button { openPhoto(pick.id) } label: {
            TVPicture(assetID: pick.id, size: .preview)
                .overlay(alignment: .topLeading) {
                    if let day = pick.day {
                        Text(verbatim: String(day))
                            .font(.title3.bold())
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.45), radius: 4)
                            .padding(14)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(TVRingStyle())
        .tvLifts()
    }
}

/// A button whose focus rings it in white, for tiles that lie edge to edge inside a card, where a lift would be cut.
struct TVRingStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Ringed(label: configuration.label, isPressed: configuration.isPressed)
    }

    private struct Ringed<Label: View>: View {
        let label: Label
        let isPressed: Bool
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            label
                .overlay { Rectangle().strokeBorder(.white, lineWidth: isFocused ? 6 : 0) }
                .brightness(isPressed ? -0.1 : 0)
                .animation(.easeOut(duration: 0.15), value: isFocused)
        }
    }
}

/// A photo by its ID alone, filling the frame it is given: a year's card, a mosaic's tile, an album's cover.
struct TVPicture: View {
    let assetID: String?
    var size: ImmichClient.ThumbnailSize = .thumbnail
    @Environment(TVModel.self) private var model

    var body: some View {
        if let pipeline = model.images {
            ExploreThumbnail(pipeline: pipeline, assetID: assetID, size: size)
        } else {
            Rectangle().fill(.quaternary)
        }
    }
}
