import Foundation

// Places: the Immich web app's places grouping (web/src/routes/(user)/places/PlacesList.svelte), and Verso's sorting by
// when each place was last visited (ARCHITECTURE.md, "Verso on the Mac"). The server sends cities by name.

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

struct PlacesArrangement {
    var groupBy = PlacesGroupBy.none
    var sortBy = PlacesSortBy.recentVisit

    /// The places in the chosen order. `visits` has when each city was last visited, by its name; a place without one
    /// goes last, and places alike keep the server's order.
    func sorted(_ places: [AssetResponse], visits: [String: Date] = [:]) -> [AssetResponse] {
        func city(_ place: AssetResponse) -> String { place.exifInfo?.city ?? "" }
        return Array(places.enumerated()).sorted { first, second in
            switch sortBy {
            case .name:
                let order = city(first.element).localizedStandardCompare(city(second.element))
                if order != .orderedSame { return order == .orderedAscending }
            case .recentVisit, .oldestVisit:
                if let earlier = Self.before(visits[city(first.element)], visits[city(second.element)], newestFirst: sortBy == .recentVisit) {
                    return earlier
                }
            }
            return first.offset < second.offset
        }
        .map(\.element)
    }

    func groups(_ places: [AssetResponse], visits: [String: Date] = [:]) -> [PlacesGroup] {
        guard !places.isEmpty else { return [] }
        guard groupBy == .country else { return [PlacesGroup(id: "places", header: nil, places: sorted(places, visits: visits))] }
        let countries = Dictionary(grouping: places) { place -> String? in
            place.exifInfo?.country.flatMap { $0.isEmpty ? nil : $0 }
        }
        // A country's visit is its most recent city's (or, sorting by the oldest, its least recent city's).
        func visit(_ members: [AssetResponse]) -> Date? {
            let dates = members.compactMap { visits[$0.exifInfo?.city ?? ""] }
            return sortBy == .oldestVisit ? dates.min() : dates.max()
        }
        // By visit or by name, ties by name; places without a country last.
        return countries.sorted { a, b in
            switch (a.key, b.key) {
            case let (x?, y?):
                if sortBy != .name, let earlier = Self.before(visit(a.value), visit(b.value), newestFirst: sortBy == .recentVisit) {
                    return earlier
                }
                return x.localizedCompare(y) == .orderedAscending
            case (_?, nil): return true
            default: return false
            }
        }
        .map { country, members in
            PlacesGroup(id: country.map { "country-\($0)" } ?? "country-unknown",
                        header: country.map { .country($0) } ?? .unknownCountry, places: sorted(members, visits: visits))
        }
    }

    /// Whether `first` comes before `second` by date, or nil when they are alike; an unknown date goes last.
    private static func before(_ first: Date?, _ second: Date?, newestFirst: Bool) -> Bool? {
        switch (first, second) {
        case let (first?, second?) where first != second: newestFirst ? first > second : first < second
        case (_?, nil): true
        case (nil, _?): false
        default: nil
        }
    }
}
