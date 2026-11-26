import SwiftUI

// The TV's places, by priority (ROADMAP.md, "Verso on the Apple TV"): Library, Albums, Search, People, Places, Memories,
// Favorites and Archive, in tvOS's sidebar-style tab view, each drawn as the iPhone draws its own (DESIGN.md, "The
// apps' interfaces"); one grid size for the sofa, and the photo fills the screen. Nothing here changes the library: the
// TV's key may only read.

struct TVRootView: View {
    @Environment(TVModel.self) private var model
    @State private var place = TVPlace.library

    init() {
        #if DEBUG
        if let name = UserDefaults.standard.string(forKey: "tvPlace"), let start = TVPlace(rawValue: name) {
            _place = State(initialValue: start)
        }
        #endif
    }

    var body: some View {
        if model.client == nil {
            TVSetUpView()
        } else {
            TabView(selection: $place) {
                Tab("Library", systemImage: "photo.on.rectangle", value: TVPlace.library) { NavigationStack { TVLibrary() } }
                Tab("Albums", systemImage: "rectangle.stack", value: TVPlace.albums) { NavigationStack { TVAlbums() } }
                Tab("Memories", systemImage: "sparkles.rectangle.stack", value: TVPlace.memories) { NavigationStack { TVMemories() } }
                Tab(value: TVPlace.search, role: .search) { TVSearch() }
                TabSection("Collections") {
                    Tab("Favorites", systemImage: "heart", value: TVPlace.favorites) {
                        NavigationStack { TVTimeline(query: TimelineQuery(isFavorite: true), title: String(localized: "Favorites")) }
                    }
                    Tab("People", systemImage: "person.2", value: TVPlace.people) { NavigationStack { TVPeople() } }
                    Tab("Places", systemImage: "map", value: TVPlace.places) { NavigationStack { TVPlaces() } }
                    Tab("Archive", systemImage: "archivebox", value: TVPlace.archive) {
                        NavigationStack { TVTimeline(query: TimelineQuery(visibility: "archive"), title: String(localized: "Archive")) }
                    }
                }
            }
            .tabViewStyle(.sidebarAdaptable)
        }
    }
}

/// The TV's places, the tab view's selection. A development build opens at one named by `-tvPlace`.
enum TVPlace: String, Hashable {
    case library, albums, memories, search, favorites, people, places, archive
}
