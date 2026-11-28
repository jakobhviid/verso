import SwiftUI

// The TV's places, by priority (ARCHITECTURE.md, "Verso on the Apple TV"): Library, Albums, Search, People, Places,
// Memories, Favorites and Archive, the Locked Folder where Settings shows it (TVLockedFolder), and Settings at the
// foot, in tvOS's sidebar-style tab view, each drawn as the iPhone draws its own (DESIGN.md, "The apps' interfaces");
// one grid size for the sofa, and the photo fills the screen. Nothing here changes the library: the TV's key may only
// read.

struct TVRootView: View {
    @Environment(TVModel.self) private var model
    @State private var place = TVPlace.library
    /// A photo a Top Shelf item opened.
    @State private var viewing: TVViewing?
    @AppStorage(TVLockedFolderSetting.key) private var showsLockedFolder = false

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
                    if showsLockedFolder {
                        Tab("Locked Folder", systemImage: "lock", value: TVPlace.lockedFolder) { NavigationStack { TVLockedFolder() } }
                    }
                }
                // In a section of its own, as tvOS puts loose tabs above the sections: at the sidebar's foot.
                TabSection {
                    Tab("Settings", systemImage: "gear", value: TVPlace.settings) { NavigationStack { TVSettings() } }
                } header: {
                    EmptyView()
                }
            }
            .tabViewStyle(.sidebarAdaptable)
            .task { await model.refreshTopShelf() }
            .task(id: model.opening) { await follow(model.opening) }
            .fullScreenCover(item: $viewing) { viewing in TVViewer(viewing: viewing) }
            // Leaving the Locked Folder for another place locks it; so does hiding it in Settings.
            .onChange(of: place, initial: true) { _, place in
                model.lockedFolderInFront = place == .lockedFolder
                if place != .lockedFolder { model.lockFolder() }
            }
            .onChange(of: showsLockedFolder) { _, shown in
                if !shown { model.lockFolder() }
            }
        }
    }

    /// A Top Shelf item: a memory opens in Memories, which plays it; an album in Albums and a person in People, which
    /// open their pages; a photo opens in the viewer here.
    private func follow(_ opening: TVOpening?) async {
        switch opening {
        case .memory:
            place = .memories
        case .album:
            place = .albums
        case .person:
            place = .people
        case .photo(let id):
            model.opening = nil
            guard let client = model.client, let asset = try? await client.asset(id), asset.visibility != "locked" else { return }
            viewing = TVViewing(items: [TVItem(asset)], index: 0)
        case nil:
            break
        }
    }
}

/// The TV's places, the tab view's selection. A development build opens at one named by `-tvPlace`.
enum TVPlace: String, Hashable {
    case library, albums, memories, search, favorites, people, places, archive, lockedFolder, settings
}
