import SwiftUI
import VersoCore

// The card pages of the TV, drawn as the iPhone's: Albums in sections by year, each an album card (ios/Verso/Albums/
// AlbumCard.swift); People as rounded squares with their names on them (People/PersonFace.swift); Places as city cards
// with their country (Places/PlaceCards.swift); Memories as memory cards (Memories/MemoryCard.swift). The cards that
// compile on tvOS are the iPhone's own files; the pages round them are the TV's, with focus in place of a finger.

// MARK: Albums

/// An album as the iPhone's card draws it: its cover large beside two more of its photos, or the cover alone; on a fade
/// at its foot its name, how many and the years they span, and in the corner a mark when it is shared.
struct TVAlbumCard: View {
    let album: Album
    let previews: AlbumPreviews
    @Environment(TVModel.self) private var tv

    var body: some View {
        card
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: album.albumName))
            .accessibilityValue(Text(facts))
            .task(id: album.id + (album.lastModifiedAssetTimestamp ?? "")) {
                guard let client = tv.client else { return }
                await previews.read(album, client: client)
            }
    }

    private var card: some View {
        let others = previews.photos(of: album) ?? []
        return photos(others)
            .aspectRatio(1.3, contentMode: .fit)
            .overlay(alignment: .bottom) { foot }
            .clipShape(.rect(cornerRadius: TVMetrics.cardRadius, style: .continuous))
            .overlay(alignment: .topTrailing) { sharedMark }
            .contentShape(.rect(cornerRadius: TVMetrics.cardRadius, style: .continuous))
    }

    /// The cover large beside two more, or the cover alone.
    @ViewBuilder private func photos(_ others: [String]) -> some View {
        if others.count >= 2 {
            GeometryReader { geometry in
                HStack(spacing: 3) {
                    TVPicture(assetID: album.albumThumbnailAssetId, size: .preview)
                        .frame(width: geometry.size.width * 0.64)
                    VStack(spacing: 3) {
                        TVPicture(assetID: others[0])
                        TVPicture(assetID: others[1])
                    }
                }
            }
        } else {
            TVPicture(assetID: album.albumThumbnailAssetId, size: .preview)
        }
    }

    private var foot: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: album.albumName)
                .font(.headline)
                .lineLimit(1)
            Text(facts)
                .font(.caption)
                .opacity(0.85)
                .lineLimit(1)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 20)
        .padding(.top, 48)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LinearGradient(colors: [.clear, .black.opacity(0.62)], startPoint: .top, endPoint: .bottom))
    }

    @ViewBuilder private var sharedMark: some View {
        if album.shared {
            Image(systemName: "person.2")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 48, height: 48)
                .background(.black.opacity(0.45), in: .circle)
                .padding(14)
        }
    }

    /// How many, and the years they span.
    private var facts: String {
        let count = itemCount(album.assetCount)
        guard let years = Self.years(start: album.startDate, end: album.endDate) else { return count }
        return "\(count) · \(years)"
    }

    /// An album's photos' first and last years: their own wall-clock dates, which the server sends at UTC midnight.
    private static func years(start: String?, end: String?) -> String? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let years = [start, end].compactMap { $0.flatMap(ImmichDate.parse) }.map { calendar.component(.year, from: $0) }
        guard let first = years.min(), let last = years.max() else { return nil }
        return first == last ? String(first) : "\(String(first))–\(String(last))"
    }
}

/// Every album in sections by year, the newest first and each section's albums by their most recent photo, as the
/// iPhone's Albums opens: the arrangement the shared core makes (`AlbumsOptions`, its defaults).
struct TVAlbums: View {
    @Environment(TVModel.self) private var tv
    @State private var albums: [Album] = []
    @State private var phase = TVPhase.loading
    @State private var previews = AlbumPreviews()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                TVPageTitle("Albums")
                switch phase {
                case .loading:
                    ProgressView().frame(maxWidth: .infinity, minHeight: 400)
                case .failed(let message):
                    TVNotice(title: "Can't Load Albums", systemImage: "rectangle.stack", message: message) { Task { await load() } }
                case .loaded:
                    if albums.isEmpty {
                        TVNotice(title: "No Albums", systemImage: "rectangle.stack",
                                 message: String(localized: "Albums you create or that are shared with you appear here."))
                    } else {
                        sections
                    }
                }
            }
        }
        .scrollClipDisabled()
        .task { await load() }
    }

    private var sections: some View {
        LazyVStack(alignment: .leading, spacing: 48) {
            ForEach(AlbumsOptions().groups(albums, userID: nil)) { group in
                VStack(alignment: .leading, spacing: 24) {
                    if let header = group.header { TVSectionHeader(title: title(header), count: group.albums.count) }
                    LazyVGrid(columns: tvColumns(TVMetrics.albumColumns), alignment: .leading, spacing: TVMetrics.cardSpacing) {
                        ForEach(group.albums) { album in
                            NavigationLink { TVAlbumPage(album: album) } label: { TVAlbumCard(album: album, previews: previews) }
                                .buttonStyle(TVLiftStyle(cornerRadius: TVMetrics.cardRadius))
                                .tvLifts()
                        }
                    }
                }
            }
        }
    }

    private func title(_ header: AlbumsGroup.Header) -> String {
        switch header {
        case .year(let year): String(year)
        case .unknownYear: String(localized: "Unknown Year")
        case .mine: String(localized: "My Albums")
        case .owner(let name): name
        }
    }

    private func load() async {
        guard let client = tv.client else { return }
        phase = .loading
        do {
            albums = try await client.albums()
            phase = .loaded
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}

enum TVPhase: Equatable { case loading, loaded, failed(String) }

/// An album's photos, in the order its owner keeps them (newest first, or oldest first for a trip that reads from its
/// start), as the iPhone's album page opens at the first photo of that order.
struct TVAlbumPage: View {
    let album: Album
    @Environment(TVModel.self) private var tv
    @State private var order: String??

    var body: some View {
        Group {
            if let order {
                TVTimeline(query: TimelineQuery(visibility: nil, albumId: album.id, order: order == "asc" ? "asc" : nil),
                           title: album.albumName, line: itemCount(album.assetCount))
            } else {
                ProgressView()
            }
        }
        .task {
            guard order == nil else { return }
            let details = try? await tv.client?.albumDetails(album.id)
            order = .some(details?.order)
        }
    }
}

// MARK: People

/// The people Immich recognises, as the iPhone's People shows them: rounded squares with their names on a fade at their
/// foot, in the server's order, the favorites first. Left out: the hidden, and those without a name, which the iPhone
/// offers to name and a viewer cannot.
struct TVPeople: View {
    @Environment(TVModel.self) private var tv
    @State private var people: [Person] = []
    @State private var phase = TVPhase.loading
    @State private var page = 1
    @State private var hasMore = true
    @State private var reading = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                TVPageTitle("People")
                switch phase {
                case .loading:
                    ProgressView().frame(maxWidth: .infinity, minHeight: 400)
                case .failed(let message):
                    TVNotice(title: "Can't Load People", systemImage: "person.crop.square", message: message) {
                        Task { await loadMore() }
                    }
                case .loaded:
                    if people.isEmpty {
                        TVNotice(title: "No People", systemImage: "person.crop.square",
                                 message: String(localized: "The people Immich recognises in your photos appear here."))
                    } else {
                        faces
                    }
                }
            }
        }
        .scrollClipDisabled()
        .task { await loadMore() }
    }

    private var faces: some View {
        LazyVGrid(columns: tvColumns(TVMetrics.personColumns), alignment: .leading, spacing: TVMetrics.cardSpacing) {
            ForEach(people) { person in
                NavigationLink {
                    TVTimeline(query: TimelineQuery(personId: person.id), title: person.name)
                } label: {
                    if let pipeline = tv.images { PersonFaceTile(pipeline: pipeline, person: person) }
                }
                .buttonStyle(TVLiftStyle(cornerRadius: 14))
                .tvLifts()
                .onAppear { if person.id == people.last?.id { Task { await loadMore() } } }
            }
        }
    }

    /// The next page, read again until it has someone to show.
    private func loadMore() async {
        guard hasMore, !reading, let client = tv.client else { return }
        reading = true
        defer { reading = false }
        let options = PeopleOptions(show: .all, includeHidden: false)
        do {
            var added = 0
            repeat {
                let response = try await client.peoplePage(page: page, withHidden: false)
                let known = Set(people.map(\.id))
                let shown = options.shown(response.people).filter { !$0.name.isEmpty && !known.contains($0.id) }
                people += shown
                added += shown.count
                hasMore = response.hasNextPage ?? (!response.people.isEmpty && page * 100 < response.total)
                page += 1
            } while added == 0 && hasMore
            phase = .loaded
        } catch is CancellationError {
        } catch {
            hasMore = false
            if people.isEmpty { phase = .failed(error.localizedDescription) }
        }
    }
}

// MARK: Places

/// The cities Immich knows, each a card of one of its photos with its name and its country on a fade, the most recently
/// visited first, as the iPhone's Places sorts them; a city opens its photos.
struct TVPlaces: View {
    @Environment(TVModel.self) private var tv
    @State private var cities: [AssetResponse] = []
    @State private var phase = TVPhase.loading

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                TVPageTitle("Places")
                switch phase {
                case .loading:
                    ProgressView().frame(maxWidth: .infinity, minHeight: 400)
                case .failed(let message):
                    TVNotice(title: "Can't Load Places", systemImage: "globe", message: message) { Task { await load() } }
                case .loaded:
                    if cities.isEmpty {
                        TVNotice(title: "No Places", systemImage: "globe",
                                 message: String(localized: "Photos with a place they were taken appear here."))
                    } else {
                        grid
                    }
                }
            }
        }
        .scrollClipDisabled()
        .task { await load() }
    }

    private var grid: some View {
        LazyVGrid(columns: tvColumns(TVMetrics.cityColumns), alignment: .leading, spacing: TVMetrics.cardSpacing) {
            ForEach(cities, id: \.id) { place in
                NavigationLink { TVCityPage(city: place.exifInfo?.city ?? "") } label: {
                    if let pipeline = tv.images { PlaceCityTile(pipeline: pipeline, place: place, showsCountry: true) }
                }
                .buttonStyle(TVLiftStyle(cornerRadius: TVMetrics.cardRadius))
                .tvLifts()
            }
        }
    }

    private func load() async {
        guard let client = tv.client else { return }
        phase = .loading
        do {
            let places = try await client.exploreCities().filter { $0.visibility != "locked" && $0.exifInfo?.city?.isEmpty == false }
            // Until each city's exact last visit is read, the date of the photo Immich sends for it.
            var visits: [String: Date] = [:]
            for place in places {
                guard let city = place.exifInfo?.city, let date = ImmichDate.parse(place.localDateTime) else { continue }
                visits[city] = date
            }
            cities = PlacesOptions(groupBy: .none, sortBy: .recentVisit).sorted(places, visits: visits)
            phase = .loaded
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}

// MARK: Memories

/// The memories Immich made for today, as the iPhone's Memories shows them: cards of three photos each; a click plays
/// the memory as a story, which goes on to the next as one ends.
struct TVMemories: View {
    @Environment(TVModel.self) private var tv
    @State private var memories: [ExploreMemory] = []
    @State private var phase = TVPhase.loading
    @State private var enabled = true
    @State private var duration = 5
    @State private var playing: TVMemoryPlay?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                TVPageTitle("Memories")
                switch phase {
                case .loading:
                    ProgressView().frame(maxWidth: .infinity, minHeight: 400)
                case .failed(let message):
                    TVNotice(title: "Can't Load Memories", systemImage: "sparkles.rectangle.stack", message: message) {
                        Task { await load() }
                    }
                case .loaded:
                    if !enabled {
                        TVNotice(title: "Memories Are Off", systemImage: "sparkles.rectangle.stack",
                                 message: String(localized: "Memories are turned off in your Immich account's settings."))
                    } else if memories.isEmpty {
                        TVNotice(title: "No Memories Today", systemImage: "sparkles.rectangle.stack",
                                 message: String(localized: "Immich makes memories of this day in earlier years."))
                    } else {
                        cards
                    }
                }
            }
        }
        .scrollClipDisabled()
        .task { await load() }
        .fullScreenCover(item: $playing) { play in TVMemoryStory(memories: play.memories, start: play.start, duration: duration) }
    }

    private var cards: some View {
        LazyVGrid(columns: tvColumns(TVMetrics.memoryColumns), alignment: .leading, spacing: TVMetrics.cardSpacing) {
            ForEach(Array(memories.enumerated()), id: \.element.id) { index, memory in
                Button { playing = TVMemoryPlay(memories: memories, start: index) } label: {
                    if let pipeline = tv.images { MemoryCard(pipeline: pipeline, memory: memory) }
                }
                .buttonStyle(TVLiftStyle(cornerRadius: TVMetrics.cardRadius))
                .tvLifts()
            }
        }
    }

    /// As the iPhone reads them: none without photos the account may see, and the account's setting for how long each
    /// photo shows.
    private func load() async {
        guard let client = tv.client else { return }
        phase = .loading
        #if DEBUG
        // A development build shows memories made of the library's own photos (`-tvFakeMemories`), as the demo server
        // has none for the day.
        if UserDefaults.standard.bool(forKey: "tvFakeMemories"), let found = try? await client.searchPage(AdvancedSearchRequest(size: 24), smart: false) {
            let assets = found.items
            memories = [3, 8, 12].enumerated().map { offset, count in
                ExploreMemory(id: "debug-\(offset)", type: "on_this_day", data: .init(year: 2018 + offset),
                              assets: Array(assets.dropFirst(offset * 4).prefix(count)), memoryAt: "2018-11-26T00:00:00.000Z")
            }
            phase = .loaded
            if UserDefaults.standard.bool(forKey: "tvPlayMemory") { playing = TVMemoryPlay(memories: memories, start: 1) }
            return
        }
        #endif
        do {
            let preferences = try await client.explorePreferences()
            enabled = preferences.memories?.enabled == true
            duration = max(1, preferences.memories?.duration ?? 5)
            guard enabled else {
                phase = .loaded
                return
            }
            memories = try await client.exploreMemories(page: 1).map { memory in
                var visible = memory
                visible.assets.removeAll { $0.visibility == "locked" }
                return visible
            }
            .filter { !$0.assets.isEmpty }
            phase = .loaded
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}

/// The memories a story plays, and which one it starts at.
struct TVMemoryPlay: Identifiable {
    let id = UUID()
    let memories: [ExploreMemory]
    let start: Int
}
