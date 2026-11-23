import Foundation
import VersoCore

// Places: the Immich web app's places grouping (web/src/routes/(user)/places/PlacesList.svelte), and Verso's sorting by
// when each was last visited (ARCHITECTURE.md, "Verso on the Mac"). The server sends cities by name. The shared core
// groups and sorts them (`placesSections`, `placesSorted`), as on Linux; the order of names is the person's language's,
// as Finder sorts names, which only the app knows.

enum PlacesGroupBy: String, CaseIterable, Identifiable {
    case none = "None", country = "Country"
    var id: Self { self }
    /// Grouped by country, the places page shows a card per country.
    var title: LocalizedStringResource { self == .none ? "Cities" : "Countries" }
}

/// How places are sorted: by when each was last visited (its newest photo), most recent first by default, or by name.
enum PlacesSortBy: String, CaseIterable, Identifiable {
    case recentVisit = "RecentVisit", oldestVisit = "OldestVisit", name = "Name"
    var id: Self { self }
    var title: LocalizedStringResource {
        switch self {
        case .recentVisit: "Most Recent Visit"
        case .oldestVisit: "Oldest Visit"
        case .name: "Name"
        }
    }
}

struct PlacesGroup: Identifiable {
    enum Header: Hashable {
        case country(String), unknownCountry
    }
    let id: String
    let header: Header?
    var places: [AssetResponse]
}

extension PlacesOptions {
    init(groupBy: PlacesGroupBy = .none, sortBy: PlacesSortBy = .recentVisit) {
        self.init(groupBy: groupBy.rawValue, sortBy: sortBy.rawValue)
    }

    /// The places in the chosen order. `visits` has when each city was last visited, by its name; a place without one
    /// goes last, and places alike keep the server's order.
    func sorted(_ places: [AssetResponse], visits: [String: Date] = [:]) -> [AssetResponse] {
        placesSorted(cities: Self.cities(places, visits: visits), sortBy: sortBy, names: Self.names(places)).map { places[Int($0)] }
    }

    /// The places in one group, or grouped by country: countries by visit or by name, ties by name, places without a
    /// country last; within each group the places as `sorted` orders them.
    func groups(_ places: [AssetResponse], visits: [String: Date] = [:]) -> [PlacesGroup] {
        placesSections(cities: Self.cities(places, visits: visits), options: self, names: Self.names(places)).map { section in
            let header: PlacesGroup.Header? = switch section.header {
            case .country(let name)?: .country(name)
            case .unknownCountry?: .unknownCountry
            case nil: nil
            }
            return PlacesGroup(id: section.id, header: header, places: section.cities.map { places[Int($0)] })
        }
    }

    private static func cities(_ places: [AssetResponse], visits: [String: Date]) -> [PlacesCity] {
        places.map { place in
            let city = place.exifInfo?.city ?? ""
            return PlacesCity(name: city, country: place.exifInfo?.country, visit: visits[city])
        }
    }

    /// Each city's and country's name by its place in the order of the person's language, as Finder sorts names; names
    /// alike in it share one.
    private static func names(_ places: [AssetResponse]) -> [String: UInt32] {
        nameOrder(places.flatMap { [$0.exifInfo?.city ?? "", $0.exifInfo?.country ?? ""] }) { $0.localizedStandardCompare($1) }
    }
}
