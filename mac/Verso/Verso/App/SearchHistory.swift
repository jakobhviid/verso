import Foundation
import Observation
import VersoCore

/// The account's recent searches, kept in the app's defaults for each server and user. The shared core keeps them, as on
/// Linux (`recentSearchesRemembered`): the newest first, at most 20, the same search in another order once, and one
/// with neither words nor a filter never.
@MainActor @Observable
final class SearchHistory {
    private(set) var entries: [SearchQuery] = []
    private var key = ""
    /// The searches shown, in the form the defaults keep them: read as the account's are loaded, and changed from there.
    @ObservationIgnored private var stored = ""

    func load(session: LibrarySession) {
        guard let userID = session.user?.id else { key = ""; show(recentSearchesRead(stored: "")); return }
        key = recentSearchesKey(apiUrl: session.client.apiURL.absoluteString, userId: userID)
        show(recentSearchesRead(stored: UserDefaults.standard.data(forKey: key).map { String(decoding: $0, as: UTF8.self) } ?? ""))
    }

    func remember(_ query: SearchQuery) {
        guard !key.isEmpty, let search = try? JSONEncoder().encode(query) else { return }
        let remembered = recentSearchesRemembered(stored: stored, search: String(decoding: search, as: UTF8.self))
        guard remembered.stored != stored else { return }
        persist(remembered)
    }

    func clear() { persist(recentSearchesRead(stored: "")) }

    private func persist(_ recent: RecentSearches) {
        show(recent)
        UserDefaults.standard.set(Data(recent.stored.utf8), forKey: key)
    }

    private func show(_ recent: RecentSearches) {
        stored = recent.stored
        entries = recent.searches.compactMap { try? JSONDecoder().decode(SearchQuery.self, from: Data($0.utf8)) }
    }
}
