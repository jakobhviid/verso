import Foundation

/// Places: grouping follows the Immich web app's places page.
@main struct PlacesArrangementChecks {
    static func main() throws {
        // The server's order: by city name.
        let json = #"""
        [
          {"id":"1", "type":"IMAGE", "originalFileName":"a.jpg", "fileCreatedAt":"", "localDateTime":"", "isFavorite":false, "isTrashed":false,
           "exifInfo":{"city":"Aarhus", "country":"Denmark"}},
          {"id":"2", "type":"IMAGE", "originalFileName":"b.jpg", "fileCreatedAt":"", "localDateTime":"", "isFavorite":false, "isTrashed":false,
           "exifInfo":{"city":"Atlantis"}},
          {"id":"3", "type":"IMAGE", "originalFileName":"c.jpg", "fileCreatedAt":"", "localDateTime":"", "isFavorite":false, "isTrashed":false,
           "exifInfo":{"city":"Bologna", "country":"Italy"}},
          {"id":"4", "type":"IMAGE", "originalFileName":"d.jpg", "fileCreatedAt":"", "localDateTime":"", "isFavorite":false, "isTrashed":false,
           "exifInfo":{"city":"Copenhagen", "country":"Denmark"}},
          {"id":"5", "type":"IMAGE", "originalFileName":"e.jpg", "fileCreatedAt":"", "localDateTime":"", "isFavorite":false, "isTrashed":false,
           "exifInfo":{"city":"Ys", "country":""}},
          {"id":"6", "type":"IMAGE", "originalFileName":"f.jpg", "fileCreatedAt":"", "localDateTime":"", "isFavorite":false, "isTrashed":false,
           "exifInfo":{"city":"Århus", "country":"australia"}}
        ]
        """#
        let places = try JSONDecoder().decode([AssetResponse].self, from: Data(json.utf8))

        // Immich's default: one group without a header, in the server's order.
        let none = PlacesArrangement().groups(places)
        precondition(none.count == 1 && none[0].header == nil && none[0].places.map(\.id) == ["1", "2", "3", "4", "5", "6"])
        precondition(PlacesArrangement(groupBy: .country).groups([]).isEmpty)

        // Countries by name (case-insensitively, as Immich's localeCompare), places without one last.
        let countries = PlacesArrangement(groupBy: .country).groups(places)
        precondition(countries.map(\.header) == [.country("australia"), .country("Denmark"), .country("Italy"), .unknownCountry])
        precondition(countries[1].places.map(\.id) == ["1", "4"])
        precondition(countries[3].places.map(\.id) == ["2", "5"])

        // Sorted by when each city was last visited, most recent first by default; one not known yet goes last.
        let day = { (offset: Double) in Date(timeIntervalSince1970: 1_700_000_000 + offset * 86_400) }
        let visits = ["Aarhus": day(1), "Bologna": day(9), "Copenhagen": day(5), "Ys": day(3), "Århus": day(7)]
        let recent = PlacesArrangement().groups(places, visits: visits)
        precondition(recent[0].places.map(\.id) == ["3", "6", "4", "5", "1", "2"], "recent: \(recent[0].places.map(\.id))")
        let oldest = PlacesArrangement(sortBy: .oldestVisit).sorted(places, visits: visits)
        precondition(oldest.map(\.id) == ["1", "5", "4", "6", "3", "2"], "oldest: \(oldest.map(\.id))")
        // By name, as the Mac's language orders names (Å after Z in Danish, beside A in English).
        let byName = PlacesArrangement(sortBy: .name).sorted(places.reversed(), visits: visits).compactMap(\.exifInfo?.city)
        let names = places.compactMap(\.exifInfo?.city).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        precondition(byName == names, "by name: \(byName)")
        // Countries follow their most recent city: Italy (Bologna), australia (Århus), Denmark (Copenhagen), then the
        // places without a country.
        let recentCountries = PlacesArrangement(groupBy: .country).groups(places, visits: visits)
        precondition(recentCountries.map(\.header) == [.country("Italy"), .country("australia"), .country("Denmark"), .unknownCountry])
        precondition(recentCountries[2].places.map(\.id) == ["4", "1"])
        precondition(PlacesSortBy(rawValue: "RecentVisit") == .recentVisit)

        // Settings saved by the app use Immich's names.
        precondition(PlacesGroupBy(rawValue: "Country") == .country && PlacesGroupBy(rawValue: "None") == PlacesGroupBy.none)
        print("Places grouping checks passed.")
    }
}
