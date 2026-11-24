// Every page a tab can push, as one list of values, and where each leads (ROADMAP.md, M10). Each tab's NavigationStack
// registers them once at its root (`versoDestinations`), and every link in the app pushes a `Route` value: a stack
// that mixes value links with links that build their page directly puts the value pages beneath the others.

import SwiftUI

enum Route: Hashable {
    case albums
    case album(Album)
    case sharedLinks
    case people
    case person(Person)
    /// The map and the places by name, the one destination for where photos were taken.
    case places
    /// A country's cities.
    case country(String)
    /// A city's photos.
    case city(String)
    /// The memories, with the story of one playing once they are read.
    case memories(opening: String? = nil)
    /// Any source's photos, under a title.
    case photos(GridSource, title: String)
    /// A page of Collections' own that is not a grid: Tags, Folders and a folder, Duplicates, the Locked Folder.
    case collections(CollectionsRoute)
}

extension View {
    /// Registers where every `Route` leads, once, at the root of a tab's NavigationStack.
    func versoDestinations(session: LibrarySession) -> some View {
        navigationDestination(for: Route.self) { route in
            RouteDestination(session: session, route: route)
        }
    }
}

/// The page a route leads to.
struct RouteDestination: View {
    let session: LibrarySession
    let route: Route

    var body: some View {
        switch route {
        case .albums: AlbumsView(session: session)
        case .album(let album): AlbumPage(session: session, album: album)
        case .sharedLinks: SharedLinksView(session: session)
        case .people: PeopleView(session: session)
        case .person(let person): PersonPage(session: session, person: person)
        case .places: PlacesView(session: session)
        case .country(let country): PlacesCountryRoutePage(session: session, country: country)
        case .city(let city): AssetGridPage(session: session, source: .explore(.city(city)), title: city)
        case .memories(let opening): MemoriesView(session: session, opening: opening)
        // A link's photos on the link's own page, with its header and its menu.
        case .photos(.sharedLink(let linkID), let title): SharedLinkPage(session: session, linkID: linkID, title: title)
        case .photos(let source, let title): AssetGridPage(session: session, source: source, title: title)
        case .collections(let page): CollectionsRouteDestination(session: session, route: page)
        }
    }
}

/// Pushes a route onto the tab's stack, for a push that comes from code rather than from a link (an album opened once
/// made, a memory's photos after its story). Each tab's stack provides it with its path: `pushRoute(.album(album))`.
struct PushRoute {
    let push: (Route) -> Void

    func callAsFunction(_ route: Route) {
        push(route)
    }
}

extension EnvironmentValues {
    @Entry var pushRoute = PushRoute { _ in }
}
