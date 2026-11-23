import SwiftUI
import VersoCore

enum ExplorePage: String, CaseIterable, Hashable {
    case map = "Map", places = "Places", memories = "Memories", tags = "Tags", folders = "Folders", locked = "Locked Folder"
    var title: LocalizedStringResource {
        switch self {
        case .map: "Map"
        case .places: "Places"
        case .memories: "Memories"
        case .tags: "Tags"
        case .folders: "Folders"
        case .locked: "Locked Folder"
        }
    }
    var icon: String {
        switch self {
        case .map: "map"
        case .places: "globe.europe.africa"
        case .memories: "sparkles.rectangle.stack"
        case .tags: "tag"
        case .folders: "folder"
        case .locked: "lock"
        }
    }
}

struct ExploreView: View {
    let page: ExplorePage
    var body: some View {
        Group {
            switch page {
            case .map: ExploreMapView()
            case .places: ExplorePlacesView()
            case .memories: ExploreMemoriesView()
            case .tags: ExploreTagsView()
            case .folders: ExploreFoldersView()
            case .locked: ExploreLockedView()
            }
        }.navigationTitle(String(localized: page.title))
    }
}

struct ExplorePlacesView: View {
    @Environment(LibrarySession.self) private var session
    @State private var cities: [AssetResponse] = []
    @State private var error: String?
    // Places: Immich's grouping setting and default. Grouped by country, the page shows a card per country
    // that opens its cities, since one long page of country sections is hard to find your way in.
    @AppStorage("places.groupBy") private var groupBy = PlacesGroupBy.none
    /// Most recent visit first by default: the places just visited are the ones looked for.
    @AppStorage("places.sortBy") private var sortBy = PlacesSortBy.recentVisit
    @AppStorage(CardSize.key) private var cardSize = 0
    @State private var cardZoom = CardZoom()

    private var options: PlacesOptions { PlacesOptions(groupBy: groupBy, sortBy: sortBy) }

    /// The cards at each size: countries' or cities'.
    private var cards: CardLayout { CardLayout(widths: groupBy == .country ? ExploreCountryCard.widths : ExplorePlaceCell.widths) }

    /// When each city was last visited: the exact dates read, or until then the date of the photo Immich sends for it.
    private var visits: [String: Date] {
        var visits: [String: Date] = [:]
        for city in cities {
            guard let name = city.exifInfo?.city, let date = ImmichDate.parse(city.localDateTime) else { continue }
            visits[name] = date
        }
        return visits.merging(session.services.placeVisits.dates) { _, exact in exact }
    }

    var body: some View {
        let visits = visits
        let groups = options.groups(cities, visits: visits)
        ScrollView {
            LazyVGrid(columns: cards.columns(cardSize), spacing: 20) {
                if groupBy == .country {
                    ForEach(groups) { group in
                        NavigationLink(value: PlacesCountryRoute(title: Self.title(group.header), ids: group.places.map(\.id))) {
                            ExploreCountryCard(title: Self.title(group.header), places: group.places)
                        }.buttonStyle(.plain)
                        .cardZoomItem(group.id)
                    }
                } else {
                    ForEach(groups.first?.places ?? []) { place in
                        ExplorePlaceCell(asset: place, showsCountry: true).cardZoomItem(place.id)
                    }
                }
            }
            .cardGrid(cards)
            .padding(20)
            // Switching between cities and countries replaces the grid with a transition, as Photos switches views.
            .id(groupBy)
            .transition(.blurReplace)
        }
        .cardZoom($cardSize, cardZoom)
        .navigationDestination(for: PlacesCountryRoute.self) { route in
            ExplorePlacesCountryView(title: route.title, places: options.sorted(cities.filter { route.ids.contains($0.id) }, visits: visits))
        }
        .cardSizeCommands($cardSize, zoom: cardZoom)
        .pageToolbar("places") {
            ToolbarItem(id: "show", placement: .principal) {
                ToolbarModePicker(selection: $groupBy.animation(.smooth(duration: 0.35)), options: PlacesGroupBy.allCases) { $0.title }
            }
            CardSizeToolbarItems(size: $cardSize, zoom: cardZoom)
            // Sorting, always in the top bar (DESIGN.md, "The toolbar's places").
            ToolbarItem(id: "placesSort") {
                Menu {
                    Picker("Sort By", selection: $sortBy) {
                        ForEach(PlacesSortBy.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.inline)
                } label: { Label("Sort", systemImage: "arrow.up.arrow.down") }
                .menuIndicator(.hidden)
                .help("Sort Places")
            }
        }
        .overlay { if let error { ContentUnavailableView("Places Unavailable", systemImage: "globe", description: Text(error)) } }
        .task(id: session.services.reconnections) {
            do {
                cities = try await session.client.exploreCities().filter { $0.visibility != "locked" }
                error = nil
                // Each city's last visit, read in the background; the cards move once when they are in.
                session.services.placeVisits.read(cities.compactMap { $0.exifInfo?.city }, client: session.client)
            } catch { self.error = error.localizedDescription }
        }
    }

    static func title(_ header: PlacesGroup.Header?) -> String {
        switch header {
        case .country(let country): country
        case .unknownCountry, nil: String(localized: "Unknown Country")
        }
    }
}

struct PlacesCountryRoute: Hashable {
    let title: String
    let ids: [String]
}

/// A country's cities, opened from its card.
struct ExplorePlacesCountryView: View {
    let title: String
    let places: [AssetResponse]
    @AppStorage(CardSize.key) private var cardSize = 0
    @State private var cardZoom = CardZoom()
    private static let cards = CardLayout(widths: ExplorePlaceCell.widths)
    var body: some View {
        ScrollView {
            LazyVGrid(columns: Self.cards.columns(cardSize), spacing: 20) {
                ForEach(places) { place in ExplorePlaceCell(asset: place, showsCountry: false).cardZoomItem(place.id) }
            }
            .cardGrid(Self.cards)
            .padding(20)
        }
        .cardZoom($cardSize, cardZoom)
        .navigationTitle(title)
        .cardSizeCommands($cardSize, zoom: cardZoom)
        .pageToolbar("placesCountry") { CardSizeToolbarItems(size: $cardSize, zoom: cardZoom) }
    }
}

/// A country as a card, as Linux shows it (ARCHITECTURE.md, "Verso on the Mac"): three of its places' photos, one large
/// beside two small, each labelled with its city in small dimmed letters; on a fade at the card's foot the country's
/// name and how many places; its first twelve places by name over the dimmed photos while the pointer is on it. Linux
/// also shows the years its photos span, which the cities list (one photo per city) does not carry.
private struct ExploreCountryCard: View {
    /// The narrowest a country's card may be at each card size.
    static let widths: [CGFloat] = [240, 300, 370, 450, 520]
    @Environment(LibrarySession.self) private var session
    let title: String
    let places: [AssetResponse]
    var body: some View {
        photos
            .aspectRatio(1.3, contentMode: .fit)
            .overlay(alignment: .bottom) { foot }
            .clipShape(.rect(cornerRadius: 12))
            .albumDescriptionOnHover(placeNames, cornerRadius: 12)
            .contentShape(Rectangle())
    }

    /// One large beside two small, or the first alone.
    @ViewBuilder private var photos: some View {
        if places.count >= 3 {
            GeometryReader { geometry in
                HStack(spacing: 2) {
                    labelled(places[0], size: .preview).frame(width: geometry.size.width * 0.64)
                    VStack(spacing: 2) {
                        labelled(places[1])
                        labelled(places[2])
                    }
                }
            }
        } else {
            labelled(places.first, size: .preview)
        }
    }

    /// A place's photo with its city in small dimmed letters, context for the photo below the country's name.
    private func labelled(_ place: AssetResponse?, size: ImmichClient.ThumbnailSize = .thumbnail) -> some View {
        RemoteThumbnail(pipeline: session.pipeline, assetID: place?.id, size: size)
            .overlay(alignment: .topLeading) {
                if let city = place?.exifInfo?.city, !city.isEmpty {
                    Text(city)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                        .shadow(color: .black.opacity(0.7), radius: 2)
                        .padding(6)
                }
            }
    }

    private var foot: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.headline).lineLimit(1)
            Text(places.count == 1 ? String(localized: "1 place") : String(localized: "\(places.count) places"))
                .font(.caption).opacity(0.85)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12).padding(.top, 28).padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LinearGradient(colors: [.clear, .black.opacity(0.62)], startPoint: .top, endPoint: .bottom))
    }

    /// Its first twelve places by name, for the hover.
    private var placeNames: String {
        let names = places.compactMap { $0.exifInfo?.city }.filter { !$0.isEmpty }
        let shown = names.prefix(12).joined(separator: ", ")
        return names.count > 12 ? shown + " …" : shown
    }
}

/// A city: its photo with its name on it, and its country under the name, as Linux shows it (ARCHITECTURE.md, "Verso on
/// the Mac"), sized with the page's − and +.
private struct ExplorePlaceCell: View {
    /// The narrowest a city may be at each card size.
    static let widths: [CGFloat] = [170, 210, 260, 320, 400]
    @Environment(LibrarySession.self) private var session
    let asset: AssetResponse
    let showsCountry: Bool
    var body: some View {
        if let city = asset.exifInfo?.city {
            NavigationLink(value: GridRoute(source: .explore(.city(city)), title: city)) {
                RemoteThumbnail(pipeline: session.pipeline, assetID: asset.id, size: .preview)
                    .aspectRatio(1, contentMode: .fit)
                    .overlay(alignment: .bottomLeading) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(city).font(.headline).lineLimit(1)
                            if showsCountry, let country = asset.exifInfo?.country, !country.isEmpty {
                                Text(country).font(.caption).opacity(0.85).lineLimit(1)
                            }
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10).padding(.top, 24).padding(.bottom, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom))
                    }
                    .clipShape(.rect(cornerRadius: 10))
                    .contentShape(Rectangle())
            }.buttonStyle(.plain)
            .contextMenu { CrosslinkMenuItems(item: .place(.init(city: city, country: asset.exifInfo?.country))) } // Crosslink
        }
    }
}

struct ExploreFoldersView: View {
    @Environment(LibrarySession.self) private var session
    @State private var roots: [ExploreFolderNode] = []
    @State private var error: String?
    var body: some View {
        List(roots, children: \.children) { node in
            NavigationLink(value: node) {
                Label(node.name, systemImage: "folder")
            }.help(node.id)
        }
        .navigationDestination(for: ExploreFolderNode.self) { node in
            ExploreFolderView(node: node)
        }
        .overlay { if let error { ContentUnavailableView("Folders Unavailable", systemImage: "folder", description: Text(error)) } }
        .pageToolbar("folders")
        .task(id: session.services.reconnections) {
            do { roots = ExploreFolderNode.tree(try await session.client.explorePaths()); error = nil }
            catch { self.error = error.localizedDescription }
        }
    }
}

private struct ExploreFolderView: View {
    let node: ExploreFolderNode

    var body: some View {
        // Like an album's or a person's page: the folder's name, its path and its subfolders head the page and scroll
        // away with its photos, and the toolbar shows the name once they have.
        AssetGridContainer(source: .explore(.folder(node.id)), title: Text(verbatim: node.name), headerScrolls: true) {
            header
        }
        // The subfolders are what a folder without photos of its own holds, so its empty page only says so quietly.
        .environment(\.gridEmptyNote, node.children == nil ? nil : "No photos directly in this folder")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: node.name).font(.largeTitle.bold()).lineLimit(1)
                .help(node.name)
                .accessibilityAddTraits(.isHeader)
            Text(verbatim: node.id).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                .textSelection(.enabled)
            if let children = node.children {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 104, maximum: 140), spacing: 8)], spacing: 8) {
                    ForEach(children) { ExploreSubfolderTile(node: $0) }
                }
                .padding(.top, 12)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 12)
    }
}

/// A subfolder, as Finder's icon view shows one: opening it shows its photos and its own subfolders.
private struct ExploreSubfolderTile: View {
    let node: ExploreFolderNode
    @State private var hovering = false

    var body: some View {
        NavigationLink(value: node) {
            VStack(spacing: 6) {
                Image(systemName: "folder.fill")
                    .symbolRenderingMode(.hierarchical)
                    .font(.system(size: 40))
                    .foregroundStyle(.tint)
                    .frame(height: 44)
                    .accessibilityHidden(true)
                Text(verbatim: node.name).font(.callout).lineLimit(2).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10).padding(.horizontal, 6)
            .background(.quaternary.opacity(hovering ? 1 : 0), in: .rect(cornerRadius: 8))
            .contentShape(.rect(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(node.id)
    }
}
