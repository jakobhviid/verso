import SwiftUI
import VersoCore

// What a grid of photos shows on the TV: all of them, the favorites, the videos, or the favorite videos, from a Filter
// menu beside the page's title (the Library's All Photos, Favorites, the Archive, an album, a person, the Locked
// Folder). Favorites narrow the timeline itself, month by month (`isFavorite`); videos, which a timeline cannot narrow
// to, come from a search for them where the page's photos are (its visibility, its person), newest first. An album has
// no search, so its menu offers favorites alone.

/// A grid's filter.
struct TVFilter: Hashable {
    var favorites = false
    var videos = false

    var isOn: Bool { favorites || videos }
}

extension TimelineQuery {
    /// The timeline with the filter's favorites.
    func filtered(_ filter: TVFilter) -> TimelineQuery {
        var query = self
        if filter.favorites { query.isFavorite = true }
        return query
    }

    /// Whether its photos can be searched for, as the videos filter does: not an album's, which a search cannot name.
    var searchable: Bool { albumId == nil }

    /// The search for its videos, with the filter's favorites, newest first.
    func videos(_ filter: TVFilter, page: Int) -> AdvancedSearchRequest {
        var search = AdvancedSearchRequest(size: 100)
        search.type = "VIDEO"
        search.order = "desc"
        search.page = page
        search.visibility = visibility
        search.personIds = personId.map { [$0] }
        if filter.favorites || isFavorite == true { search.isFavorite = true }
        return search
    }
}

/// The Filter menu: Favorites and, where the page's photos can be searched, Videos, each ticked when on.
struct TVFilterMenu: View {
    @Binding var filter: TVFilter
    var offersVideos = true

    var body: some View {
        Menu {
            Toggle("Favorites", systemImage: "heart", isOn: $filter.favorites)
            if offersVideos { Toggle("Videos", systemImage: "video", isOn: $filter.videos) }
        } label: {
            Label(filter.isOn ? String(localized: "Filtered") : String(localized: "Filter"),
                  systemImage: filter.isOn ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                .labelStyle(.titleAndIcon)
        }
        // As tall as the segmented control beside it, not stretched to the title's height.
        .fixedSize()
    }
}

/// The albums to add a photo to, as Albums shows them (the shared core's arrangement: by year, the newest first, each
/// year's albums by their most recent photo), each a row with its name and count; choosing one adds the photo.
struct TVAlbumPicker: View {
    let choose: (Album) -> Void
    @Environment(TVModel.self) private var tv
    @Environment(\.dismiss) private var dismiss
    @State private var albums: [Album]?
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            Group {
                if let albums {
                    if albums.isEmpty {
                        TVNotice(title: "No Albums", systemImage: "rectangle.stack")
                    } else {
                        List {
                            ForEach(AlbumsOptions().groups(albums, userID: nil)) { group in
                                Section {
                                    ForEach(group.albums) { album in
                                        Button {
                                            choose(album)
                                            dismiss()
                                        } label: {
                                            LabeledContent(album.albumName, value: itemCount(album.assetCount))
                                        }
                                    }
                                } header: {
                                    if let header = group.header { Text(Self.title(header)) }
                                }
                            }
                        }
                    }
                } else if let failure {
                    TVNotice(title: "Can't Load Albums", systemImage: "rectangle.stack", message: failure)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Add to Album")
        }
        .task {
            do { albums = try await tv.root.client?.albums() ?? [] }
            catch { failure = error.localizedDescription }
        }
    }

    private static func title(_ header: AlbumsGroup.Header) -> String {
        switch header {
        case .year(let year): String(year)
        case .unknownYear: String(localized: "Unknown Year")
        case .mine: String(localized: "My Albums")
        case .owner(let name): name
        }
    }
}
