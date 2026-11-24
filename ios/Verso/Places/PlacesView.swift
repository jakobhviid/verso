// Places: where the photos were taken, as Map or Places, switched by a segmented picker in the middle of the toolbar,
// as Photos would. Map is the photos on the map, as Photos' Places opens, with Immich's map filters, and a tap on a
// cluster pushes the photos in its box. Places is the countries as cards, as the Mac's and Linux's Places grouped by
// country (PlacesArrangement), in the card sizes every card page shares (CardSize), sorted by when each was last
// visited, most recent first, or by name (PlaceVisits reads the exact dates in the background); a country pushes its
// cities (PlacesCountryRoutePage), and a city its photos. Names lead to photos, never back to the map. Every page it
// opens is a Route, pushed onto the stack it is shown in; with Map in the tab bar it is that tab's first page.

import SwiftUI

/// What Places shows.
enum PlacesMode: String, CaseIterable, Identifiable {
    case map, places
    var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .map: "Map"
        case .places: "Places"
        }
    }
}

struct PlacesView: View {
    let session: LibrarySession
    @Environment(\.pushRoute) private var pushRoute
    @State private var mode: PlacesMode
    @State private var cities: [AssetResponse] = []
    @State private var citiesLoaded = false
    /// The server's answers the cities were read after, so coming back from a place keeps them.
    @State private var citiesReconnections: Int?
    @State private var error: String?
    @State private var mapFilters = PlacesMapFilters()
    /// Most recent visit first by default: the places just visited are the ones looked for.
    @AppStorage(PlacesCities.sortKey) private var sortBy = PlacesSortBy.recentVisit
    @AppStorage(CardSize.key) private var cardSize = 0
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var page = CardPageWidth()

    /// Places opens on `mode`: the map, as Photos' Places does, unless the caller wants the places by name.
    init(session: LibrarySession, mode: PlacesMode = .map) {
        self.session = session
        _mode = State(initialValue: mode)
    }

    var body: some View {
        Group {
            switch mode {
            case .map:
                PlacesMap(session: session, filters: mapFilters) { query, title in
                    pushRoute(.photos(.explore(.map(query)), title: title))
                }
            case .places:
                countries
            }
        }
        .navigationTitle("Places")
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("View", selection: $mode) {
                    ForEach(PlacesMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
            ToolbarItem(placement: .topBarTrailing) {
                if mode == .map {
                    mapFiltersMenu
                } else {
                    PlacesViewOptions(sortBy: $sortBy, cardSize: $cardSize, ladder: PlacesLayout.countries, page: cardPage)
                }
            }
        }
        // The cities are read once Places shows them, and again when the server answers after it could not be reached.
        .task(id: "\(mode)-\(session.services.reconnections)") {
            guard mode == .places else { return }
            guard citiesReconnections != session.services.reconnections || !(citiesLoaded || error != nil) else { return }
            citiesReconnections = session.services.reconnections
            await loadCities()
        }
    }

    // MARK: The countries

    @ViewBuilder private var countries: some View {
        if cities.isEmpty {
            if let error {
                ContentUnavailableView {
                    Label("Can't Load Places", systemImage: "globe")
                } description: {
                    Text(error)
                } actions: {
                    Button("Try Again") { Task { await loadCities() } }
                }
            } else if citiesLoaded {
                ContentUnavailableView("No Places", systemImage: "globe",
                                       description: Text("Photos with a place they were taken appear here."))
            } else {
                ProgressView()
            }
        } else {
            let groups = PlacesArrangement(groupBy: .country, sortBy: sortBy)
                .groups(cities, visits: PlacesCities.visits(cities, session: session))
            CardGrid(
                sections: [CardGridSection(id: "countries", count: groups.count)],
                card: { _, item, _ in
                    let group = groups[item]
                    let country = PlacesCities.country(of: group.header)
                    return AnyView(PlaceCountryCard(pipeline: session.pipeline, title: PlacesCities.title(country: country),
                                                    places: group.places)
                        .cardOpens { pushRoute(.country(country)) })
                },
                ladder: PlacesLayout.countries, size: $cardSize, regular: horizontalSizeClass == .regular,
                contentKey: groups.map { group in [group.id] + group.places.map(\.id) },
                top: 16, refresh: { await loadCities() })
            .cardPageWidth($page, regular: horizontalSizeClass == .regular)
        }
    }

    /// The width the cards share: the page's, less its margins.
    private var cardPage: CardPageWidth {
        CardPageWidth(width: max(0, page.width - 32), regular: page.regular)
    }

    private func loadCities() async {
        do {
            cities = try await PlacesCities.read(session)
            citiesLoaded = true
            error = nil
            // Each city's last visit, read in the background; the cards move once, when they are in.
            session.services.placeVisits.read(cities.compactMap { $0.exifInfo?.city }, client: session.client)
        } catch is CancellationError {
        } catch {
            session.handle(error)
            self.error = error.localizedDescription
        }
    }

    // MARK: The map's filters

    private var mapFiltersMenu: some View {
        Menu {
            Toggle("Favorites Only", systemImage: "heart", isOn: $mapFilters.favorites)
            Toggle("Include Archived", systemImage: "archivebox", isOn: $mapFilters.archived)
            Toggle("Include Partners", systemImage: "person.2", isOn: $mapFilters.partners)
            Picker("Date Range", selection: Binding(get: { mapFilters.range }, set: { mapFilters.select($0) })) {
                ForEach(PlacesMapRange.allCases) { range in
                    Text(range.title).tag(range)
                }
            }
            .pickerStyle(.menu)
        } label: {
            Label("Map Filters", systemImage: mapFilters.isFiltered ? "line.3.horizontal.decrease.circle.fill"
                                                                    : "line.3.horizontal.decrease")
        }
    }
}
