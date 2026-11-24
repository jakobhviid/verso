import Foundation
import VersoCore

// People: the favorite and hidden filters of the Immich web app's people page (PeopleFilterModal.svelte).
// Immich v3.3 filters on the server; older servers send every page and the app filters it. Order stays
// the server's: favorites, then named people, then by how often they appear. The shared core decides whom the options
// show and what the server is asked (`peopleFilter`, `peopleShown`), as on Linux.

/// Whom People shows, kept in the settings by its code, the same as Linux's.
enum PeopleShow: String, CaseIterable, Identifiable {
    case all = "All", favorites = "Favorites", hidden = "Hidden"
    var id: Self { self }
    var title: LocalizedStringResource {
        switch self {
        case .all: "All People"
        case .favorites: "Favorites"
        case .hidden: "Hidden People"
        }
    }
}

extension PeopleOptions {
    init(show: PeopleShow, includeHidden: Bool) {
        self.init(show: show.rawValue, includeHidden: includeHidden)
    }

    /// What the options mean with a server of this version.
    func filter(server version: ServerVersion?) -> PeopleFilter {
        let server = version.map { GalleryVersion(major: UInt32(clamping: $0.major), minor: UInt32(clamping: $0.minor), patch: UInt32(clamping: $0.patch)) }
        return peopleFilter(options: self, server: server)
    }

    /// The people of a page the options show, in the server's order.
    func shown(_ people: [Person]) -> [Person] {
        peopleShown(options: self, people: people.map { PeoplePerson(isFavorite: $0.isFavorite, isHidden: $0.isHidden) }).map { people[Int($0)] }
    }
}

extension PeopleFilter {
    /// The filters for `GET /people` the server understands, which Immich added in v3.3.
    var query: [String: String] {
        if favoritesOnly { return ["isFavorite": "true"] }
        if hiddenOnly { return ["isHidden": "true"] }
        return [:]
    }
}
