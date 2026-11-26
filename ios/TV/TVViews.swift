import AVKit
import SwiftUI

// The TV's places, by priority (ROADMAP.md, "Verso on the Apple TV"): Library, Albums, Search, People, Places,
// Memories, Favorites and Archive, in tvOS's sidebar-style tab view; one grid size for the sofa, and the photo fills
// the screen. Nothing here changes the library: the TV's key may only read.

struct TVRootView: View {
    @Environment(TVModel.self) private var model

    var body: some View {
        if model.client == nil {
            TVSetUpView()
        } else {
            TabView {
                Tab("Library", systemImage: "photo.on.rectangle") { NavigationStack { TVTimeline(query: TimelineQuery(withPartners: true)) } }
                Tab("Albums", systemImage: "rectangle.stack") { NavigationStack { TVAlbums() } }
                Tab("Memories", systemImage: "sparkles.rectangle.stack") { NavigationStack { TVMemories() } }
                Tab(role: .search) { NavigationStack { TVSearch() } }
                TabSection("Collections") {
                    Tab("Favorites", systemImage: "heart") {
                        NavigationStack { TVTimeline(query: TimelineQuery(isFavorite: true)) }
                    }
                    Tab("People", systemImage: "person.2") { NavigationStack { TVPeople() } }
                    Tab("Places", systemImage: "map") { NavigationStack { TVPlaces() } }
                    Tab("Archive", systemImage: "archivebox") {
                        NavigationStack { TVTimeline(query: TimelineQuery(visibility: "archive")) }
                    }
                }
            }
            .tabViewStyle(.sidebarAdaptable)
        }
    }
}

/// A photo or video as the TV shows it.
struct TVItem: Identifiable, Hashable, Sendable {
    let id: String
    let isVideo: Bool
    /// A Live Photo's movie, which the remote's play/pause plays.
    var livePhotoVideoID: String?

    init(id: String, isVideo: Bool, livePhotoVideoID: String? = nil) {
        self.id = id
        self.isVideo = isVideo
        self.livePhotoVideoID = livePhotoVideoID
    }

    init(_ asset: AssetResponse) {
        self.init(id: asset.id, isVideo: asset.type == .video, livePhotoVideoID: asset.livePhotoVideoId)
    }
}

/// Which photos the viewer steps through, and where it starts.
struct TVViewing: Identifiable {
    let id = UUID()
    let items: [TVItem]
    let index: Int
}

// MARK: Grids

/// The photos of a timeline (the Library, Favorites, the Archive, an album, a person), month by month, each month's
/// read as it comes into view.
struct TVTimeline: View {
    let query: TimelineQuery
    var title: String?
    @Environment(TVModel.self) private var model
    @State private var buckets: [TimeBucket] = []
    @State private var items: [String: [TVItem]] = [:]
    @State private var viewing: TVViewing?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 48) {
                ForEach(buckets, id: \.timeBucket) { bucket in
                    VStack(alignment: .leading, spacing: 20) {
                        Text(TVFormat.month(bucket.timeBucket)).font(.title3).bold()
                        TVItemGrid(items: items[bucket.timeBucket] ?? []) { index in
                            // The months read so far, in order, so the viewer steps on past this one.
                            let before = buckets.prefix { $0.timeBucket != bucket.timeBucket }
                                .reduce(0) { $0 + (items[$1.timeBucket]?.count ?? 0) }
                            viewing = TVViewing(items: buckets.flatMap { items[$0.timeBucket] ?? [] }, index: before + index)
                        }
                    }
                    .task { await load(bucket.timeBucket) }
                }
            }
            .padding(.horizontal, 60)
        }
        .navigationTitle(title ?? "")
        .task { buckets = ((try? await model.client?.timeBuckets(query)) ?? nil) ?? [] }
        .fullScreenCover(item: $viewing) { viewing in TVViewer(items: viewing.items, index: viewing.index) }
    }

    private func load(_ bucket: String) async {
        guard items[bucket] == nil, let assets = (try? await model.client?.timeBucket(bucket, query)) ?? nil else { return }
        items[bucket] = assets.id.indices.map {
            TVItem(id: assets.id[$0], isVideo: !assets.isImage[$0], livePhotoVideoID: assets.livePhotoVideoId[$0])
        }
    }
}

/// Photos in rows of five, each a card the remote's focus lifts.
struct TVItemGrid: View {
    let items: [TVItem]
    let open: (Int) -> Void

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 40), count: 5), spacing: 40) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                Button { open(index) } label: {
                    TVThumbnail(id: item.id)
                        .overlay(alignment: .bottomTrailing) {
                            if item.isVideo { Image(systemName: "play.fill").padding(10).shadow(radius: 3) }
                        }
                }
                .buttonStyle(.card)
            }
        }
    }
}

/// A photo's thumbnail, square, filled.
struct TVThumbnail: View {
    let id: String
    var person = false
    @Environment(TVModel.self) private var model
    @State private var image: CGImage?

    var body: some View {
        Color.secondary.opacity(0.15)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image { Image(decorative: image, scale: 1).resizable().scaledToFill() }
            }
            .clipped()
            .task(id: id) {
                image = person ? await model.images?.personThumbnail(id) : await model.images?.thumbnail(id, size: .thumbnail)
            }
    }
}

// MARK: Places

struct TVAlbums: View {
    @Environment(TVModel.self) private var model
    @State private var albums: [Album] = []

    var body: some View {
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 48), count: 4), spacing: 60) {
                ForEach(albums) { album in
                    NavigationLink {
                        TVTimeline(query: TimelineQuery(visibility: nil, albumId: album.id), title: album.albumName)
                    } label: {
                        TVCover(id: album.albumThumbnailAssetId, title: album.albumName, detail: "\(album.assetCount)")
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(60)
        }
        .task { albums = ((try? await model.client?.albums()) ?? nil) ?? [] }
    }
}

struct TVPeople: View {
    @Environment(TVModel.self) private var model
    @State private var people: [Person] = []

    var body: some View {
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 48), count: 6), spacing: 60) {
                ForEach(people) { person in
                    NavigationLink {
                        TVTimeline(query: TimelineQuery(personId: person.id), title: person.name)
                    } label: {
                        VStack {
                            TVThumbnail(id: person.id, person: true).clipShape(Circle())
                            Text(person.name).lineLimit(1)
                        }
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(60)
        }
        .task {
            let page = try? await model.client?.peoplePage(page: 1, withHidden: false)
            people = (page?.people ?? []).filter { !$0.name.isEmpty }
        }
    }
}

/// Cities, each with a photo taken there, and its photos.
struct TVPlaces: View {
    @Environment(TVModel.self) private var model
    @State private var cities: [AssetResponse] = []

    var body: some View {
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 48), count: 4), spacing: 60) {
                ForEach(cities, id: \.id) { asset in
                    let city = asset.exifInfo?.city ?? ""
                    NavigationLink { TVSearchResults(request: { var request = AdvancedSearchRequest(size: 250); request.city = city; return request }(), smart: false, title: city) } label: {
                        TVCover(id: asset.id, title: city, detail: asset.exifInfo?.country ?? "")
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(60)
        }
        .task { cities = ((try? await model.client?.exploreCities()) ?? []).filter { $0.exifInfo?.city?.isEmpty == false } }
    }
}

struct TVMemories: View {
    @Environment(TVModel.self) private var model
    @State private var memories: [ExploreMemory] = []
    @State private var viewing: TVViewing?

    var body: some View {
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 48), count: 4), spacing: 60) {
                ForEach(memories) { memory in
                    Button {
                        viewing = TVViewing(items: memory.assets.map(TVItem.init), index: 0)
                    } label: {
                        TVCover(id: memory.assets.first?.id, title: memory.title, detail: "\(memory.assets.count)")
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(60)
        }
        .task {
            memories = ((try? await model.client?.exploreMemories(page: 1)) ?? []).filter { !$0.assets.isEmpty }
        }
        .fullScreenCover(item: $viewing) { viewing in TVViewer(items: viewing.items, index: viewing.index, slideshow: true) }
    }
}

/// Immich's smart search, typed or spoken with the Siri Remote.
struct TVSearch: View {
    @State private var text = ""
    @State private var submitted = ""

    var body: some View {
        Group {
            if submitted.isEmpty {
                Text("Search your library: a dog on the beach, a red car, snow.").foregroundStyle(.secondary)
            } else {
                TVSearchResults(request: { var request = AdvancedSearchRequest(size: 250); request.query = submitted; return request }(),
                                smart: true, title: nil)
                    .id(submitted)
            }
        }
        .searchable(text: $text)
        .onSubmit(of: .search) { submitted = text }
    }
}

struct TVSearchResults: View {
    let request: AdvancedSearchRequest
    let smart: Bool
    let title: String?
    @Environment(TVModel.self) private var model
    @State private var items: [TVItem] = []
    @State private var viewing: TVViewing?

    var body: some View {
        ScrollView {
            TVItemGrid(items: items) { viewing = TVViewing(items: items, index: $0) }.padding(60)
        }
        .navigationTitle(title ?? "")
        .task { items = ((try? await model.client?.searchPage(request, smart: smart))?.items ?? []).map(TVItem.init) }
        .fullScreenCover(item: $viewing) { viewing in TVViewer(items: viewing.items, index: viewing.index) }
    }
}

/// An album's, a city's or a memory's cover, with its name and a detail beneath.
struct TVCover: View {
    let id: String?
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let id { TVThumbnail(id: id) } else { Color.secondary.opacity(0.15).aspectRatio(1, contentMode: .fit) }
            Text(title).lineLimit(1)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: The viewer

/// A photo filling the screen, the preview first and then the full-size image a 4K screen wants; left and right on the
/// remote step through, and a video plays. In a slideshow the photos follow each other by themselves.
struct TVViewer: View {
    let items: [TVItem]
    var slideshow = false
    @State private var index: Int
    @State private var image: CGImage?
    @State private var player: AVPlayer?
    @Environment(TVModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    init(items: [TVItem], index: Int, slideshow: Bool = false) {
        self.items = items
        self.slideshow = slideshow
        _index = State(initialValue: index)
    }

    var body: some View {
        ZStack {
            Color.black
            if let player {
                VideoPlayer(player: player)
            } else if let image {
                Image(decorative: image, scale: 1).resizable().scaledToFit().transition(.opacity)
            } else {
                ProgressView()
            }
        }
        .ignoresSafeArea()
        .focusable()
        .onMoveCommand { direction in
            switch direction {
            case .left: step(-1)
            case .right: step(1)
            default: break
            }
        }
        .onPlayPauseCommand { playLive() }
        .onExitCommand { dismiss() }
        .task(id: index) { await show() }
    }

    /// A Live Photo's movie, once, over the photo; then the photo again.
    private func playLive() {
        guard items.indices.contains(index), let live = items[index].livePhotoVideoID, let client = model.client else { return }
        let item = AVPlayerItem(asset: VideoStream.asset(client.videoURL(live), headers: client.credential?.headers ?? [:]))
        let player = AVPlayer(playerItem: item)
        self.player = player
        NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { _ in
            Task { @MainActor in if self.player === player { self.player = nil } }
        }
        player.play()
    }

    private func step(_ by: Int) {
        let next = index + by
        guard items.indices.contains(next) else { return }
        index = next
    }

    private func show() async {
        guard items.indices.contains(index), let images = model.images, let client = model.client else { return }
        let item = items[index]
        player?.pause()
        player = nil
        image = await images.thumbnail(item.id, size: .preview)
        if item.isVideo {
            let asset = VideoStream.asset(client.videoURL(item.id), headers: client.credential?.headers ?? [:])
            let player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
            self.player = player
            player.play()
            return
        }
        if let full = await images.thumbnail(item.id, size: .fullsize), items[index].id == item.id {
            withAnimation(.easeInOut(duration: 0.3)) { image = full }
        }
        if slideshow {
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled { withAnimation(.easeInOut(duration: 0.6)) { step(1) } }
        }
    }
}

enum TVFormat {
    /// "May 2024" from a time bucket's "2024-05-01T00:00:00.000Z".
    static func month(_ bucket: String) -> String {
        let parts = bucket.prefix(7).split(separator: "-")
        guard parts.count == 2, let year = Int(parts[0]), let month = Int(parts[1]),
              let date = Calendar.current.date(from: DateComponents(year: year, month: month)) else { return bucket }
        return date.formatted(.dateTime.month(.wide).year())
    }
}
