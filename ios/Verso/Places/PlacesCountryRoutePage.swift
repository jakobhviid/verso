// A country's cities, as Route.country pushes them from Places: the cities as cards in the card sizes every card page
// shares (CardSize), read from the server as Places reads them and kept to the country, in the order Places sorts in,
// each pushing its photos (Route.city). An empty name is the places Immich knows no country for. It reads no visits of
// its own: Places has read them on the way here.

import SwiftUI

struct PlacesCountryRoutePage: View {
    let session: LibrarySession
    let country: String
    @State private var cities: [AssetResponse] = []
    @State private var loaded = false
    /// The server's answers the cities were read after, so coming back from a city keeps them.
    @State private var loadedReconnections: Int?
    @State private var error: String?
    @AppStorage(PlacesCities.sortKey) private var sortBy = PlacesSortBy.recentVisit
    @AppStorage(CardSize.key) private var cardSize = 0
    @Environment(\.pushRoute) private var pushRoute
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var page = CardPageWidth()

    var body: some View {
        content
            .navigationTitle(PlacesCities.title(country: country))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    PlacesViewOptions(sortBy: $sortBy, cardSize: $cardSize, ladder: PlacesLayout.cities, page: cardPage)
                }
            }
            .task(id: session.services.reconnections) {
                guard loadedReconnections != session.services.reconnections || !(loaded || error != nil) else { return }
                loadedReconnections = session.services.reconnections
                await load()
            }
    }

    @ViewBuilder private var content: some View {
        if cities.isEmpty {
            if let error {
                ContentUnavailableView {
                    Label("Can't Load Places", systemImage: "globe")
                } description: {
                    Text(error)
                } actions: {
                    Button("Try Again") { Task { await load() } }
                }
            } else if loaded {
                ContentUnavailableView("No Places", systemImage: "globe",
                                       description: Text("Photos taken in this country appear here."))
            } else {
                ProgressView()
            }
        } else {
            let sorted = PlacesArrangement(groupBy: .none, sortBy: sortBy)
                .sorted(cities, visits: PlacesCities.visits(cities, session: session))
                .filter { $0.exifInfo?.city != nil }
            CardGrid(
                sections: [CardGridSection(id: "cities", count: sorted.count)],
                card: { _, item, _ in
                    let place = sorted[item]
                    return AnyView(PlaceCityTile(pipeline: session.pipeline, place: place, showsCountry: false)
                        .cardOpens { if let city = place.exifInfo?.city { pushRoute(.city(city)) } })
                },
                ladder: PlacesLayout.cities, size: $cardSize, regular: horizontalSizeClass == .regular,
                contentKey: sorted.map(\.id), top: 16, refresh: { await load() })
            .cardPageWidth($page, regular: horizontalSizeClass == .regular)
        }
    }

    /// The width the cards share: the page's, less its margins.
    private var cardPage: CardPageWidth {
        CardPageWidth(width: max(0, page.width - 32), regular: page.regular)
    }

    private func load() async {
        do {
            cities = try await PlacesCities.read(session).filter { PlacesCities.country(of: $0) == country }
            loaded = true
            error = nil
        } catch is CancellationError {
        } catch {
            session.handle(error)
            self.error = error.localizedDescription
        }
    }
}
