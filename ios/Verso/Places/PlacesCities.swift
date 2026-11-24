// The places Immich knows, as Places and a country's page read them: Immich's list of cities, one photo for each, and
// when each was last visited, for the order the person chose (PlacesSortBy, kept under one key for both pages), and
// the two pages' View Options.

import SwiftUI

@MainActor
enum PlacesCities {
    /// The `@AppStorage` key of the order Places and a country's page sort in.
    static let sortKey = "places.sortBy"

    /// The cities, one photo for each, without the Locked Folder's.
    static func read(_ session: LibrarySession) async throws -> [AssetResponse] {
        try await session.client.exploreCities().filter { $0.visibility != "locked" }
    }

    /// When each city was last visited: the exact dates PlaceVisits has read, or until then the date of the photo
    /// Immich sends for it.
    static func visits(_ cities: [AssetResponse], session: LibrarySession) -> [String: Date] {
        var visits: [String: Date] = [:]
        for city in cities {
            guard let name = city.exifInfo?.city, let date = ImmichDate.parse(city.localDateTime) else { continue }
            visits[name] = date
        }
        return visits.merging(session.services.placeVisits.dates) { _, exact in exact }
    }

    /// A place's country as `Route.country` names it: empty for the places Immich knows no country for.
    static func country(of place: AssetResponse) -> String {
        place.exifInfo?.country ?? ""
    }

    /// The country of a group of places by country, as `Route.country` names it.
    static func country(of header: PlacesGroup.Header?) -> String {
        switch header {
        case .country(let country): country
        case .unknownCountry, nil: ""
        }
    }

    /// A country's title: its name, or Unknown Country.
    static func title(country: String) -> String {
        country.isEmpty ? String(localized: "Unknown Country") : country
    }
}

/// View Options of Places and of a country's page: the cards' size, Zoom Out and Zoom In side by side as the pinch
/// does it, and the order of the places.
struct PlacesViewOptions: View {
    @Binding var sortBy: PlacesSortBy
    @Binding var cardSize: Int
    let ladder: CardLadder
    let page: CardPageWidth

    var body: some View {
        Menu {
            CardZoomControls(size: $cardSize, ladder: ladder, page: page)
            Picker("Sort By", selection: $sortBy) {
                ForEach(PlacesSortBy.allCases) { order in
                    Text(order.title).tag(order)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Label("View Options", systemImage: "line.3.horizontal.decrease")
        }
    }
}
