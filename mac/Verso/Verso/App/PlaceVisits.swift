import Foundation
import Observation

/// When each place was last visited: the date of its newest photo, for sorting Places by visit (ARCHITECTURE.md,
/// "Verso on the Mac"). Immich's list of cities brings one photo for each, often the newest but not always (16 of 25
/// on Immich's demo, the rest mostly the same day, a few months or years off), so the page sorts by those first; the
/// exact dates are read in the background, one small search for a city's newest photo, six at a time (about 80 ms
/// each, 2 seconds for the demo's 147 cities), and take their place all at once, so the cards move once.
/// They are kept on disk for the account, so a later visit to Places sorts exactly from the start.
@MainActor @Observable
final class PlaceVisits {
    /// The exact dates read, by city.
    private(set) var dates: [String: Date] = [:]
    @ObservationIgnored private var reading: Task<Void, Never>?
    @ObservationIgnored private let key: String

    init(account: String) {
        key = "places.visits." + account
        if let saved = UserDefaults.standard.dictionary(forKey: key) as? [String: Double] {
            dates = saved.mapValues { Date(timeIntervalSince1970: $0) }
        }
    }

    /// Read every city's newest photo again, once at a time, and keep the dates.
    func read(_ cities: [String], client: ImmichClient) {
        guard reading == nil, !cities.isEmpty else { return }
        reading = Task { [weak self] in
            var found: [String: Date] = [:]
            await withTaskGroup(of: (String, Date?).self) { group in
                var waiting = cities[...]
                func next() {
                    guard let city = waiting.popFirst() else { return }
                    group.addTask { (city, await Self.newestPhoto(in: city, client: client)) }
                }
                for _ in 0..<6 { next() }
                for await (city, date) in group {
                    if let date { found[city] = date }
                    next()
                }
            }
            guard let self, !Task.isCancelled else { return }
            self.dates = found
            UserDefaults.standard.set(found.mapValues(\.timeIntervalSince1970), forKey: self.key)
            self.reading = nil
        }
    }

    /// The date of the newest photo taken in `city`, as Places lists cities (on the timeline, not archived).
    nonisolated private static func newestPhoto(in city: String, client: ImmichClient) async -> Date? {
        var request = AdvancedSearchRequest(size: 1)
        request.city = city
        request.visibility = "timeline"
        request.order = "desc"
        guard let newest = try? await client.searchPage(request, smart: false).items.first else { return nil }
        return ImmichDate.parse(newest.localDateTime)
    }
}
