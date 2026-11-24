// The Library's View Options on iOS, as Photos' Library filter menu (ROADMAP.md, M10): the sort, Added or Captured; one
// filter, in Photos' order (All Items, Favorites, Shared with You, Captured by Me, Not in an Album, or Photos or Videos
// alone); Library View, Mine or Mine and Partners', where the account has partners, with the one in use under its
// name; and the View Options submenu every grid has (GridOptionsMenu). Photos' Edited is left out: Immich keeps whether
// a photo is edited, but neither its timeline nor its search filters by it.
//
// Each filter is what Immich does well for it:
// - Favorites, Captured by Me, Photos and Videos are the Library's own view options, kept under the Mac's keys
//   (GridArrangement), so the Library's grid reads them as the Mac's does: favourites on the timeline, the account's
//   own photos as the timeline without partners' (GridArrangement.owner, which the Mac does not offer), photos or
//   videos alone through search, which leaves out partners' photos and cannot order by the date added.
// - Shared with You is a partner's timeline (GridSource.partner), one partner's or, with several, the one chosen.
// - Not in an Album is a search for them (SearchQuery.notInAlbum) through a grid of the Library's own
//   (LibraryChrome.notInAlbumModel), as the window keeps one search grid for Search's results. A search's photos come
//   as one run without months (AssetGridModel), the newest at the Library's newest end, without the date scroller.
// Library View is Immich's own setting, "Show in timeline", for each partner who shares with the account (the same as
// in Immich's web app), so Mine takes every partner out of the account's timeline and Mine and Partners' puts them back.
// Captured by Me shows the account's own photos whatever Library View says.
//
// The filter is kept on this device, as the Library's sort is, and Show in All Photos puts it back to All Items. A
// filter, the sort and Library View each take the Library to its newest photos (LibraryTabView). The View Options
// submenu has Newest at the Bottom or at the Top, the setting every timeline shares (GridNewestEnd).

import SwiftUI

/// What the Library shows: every photo, or one kind.
enum LibraryFilter: Hashable {
    case all, favorites, photos, videos, notInAlbum
    /// The account's own photos, without partners'.
    case capturedByMe
    /// One partner's photos.
    case sharedWithYou(partnerID: String)

    /// The photos the filter shows.
    var source: GridSource {
        switch self {
        case .all, .favorites, .capturedByMe, .photos, .videos: .library
        case .notInAlbum: .filteredSearch(Self.notInAlbumQuery)
        case .sharedWithYou(let partnerID): .partner(partnerID)
        }
    }

    /// Whether the Library's months are what it shows, for Years and Months.
    var showsWholeLibrary: Bool { self == .all }

    /// Whether the photos can be ordered by the date they were added: the timeline's can, a search's cannot.
    var ordersByDateAdded: Bool {
        switch self {
        case .all, .favorites, .capturedByMe, .sharedWithYou: true
        case .photos, .videos, .notInAlbum: false
        }
    }

    static var notInAlbumQuery: SearchQuery {
        var query = SearchQuery()
        query.notInAlbum = true
        return query
    }
}

/// The Library's filter as it is kept: the Library's own view options (GridPage.library) for Favorites, Captured by Me,
/// Photos and Videos, read by its grid's model, and a key of iOS's own for the filters that show other photos.
struct LibraryFilterSetting: DynamicProperty {
    static let otherKey = "library.filter"
    private static let notInAlbum = "notInAlbum"
    private static let partnerPrefix = "partner:"

    @AppStorage(GridPage.library.key("show")) private var show = GridShow.all
    @AppStorage(GridPage.library.key("mediaType")) private var mediaType = GridMediaType.all
    @AppStorage(GridPage.library.key("owner")) private var owner = GridOwner.anyone
    @AppStorage(LibraryFilterSetting.otherKey) private var other = ""

    var filter: LibraryFilter {
        get {
            if other == Self.notInAlbum { return .notInAlbum }
            if other.hasPrefix(Self.partnerPrefix) { return .sharedWithYou(partnerID: String(other.dropFirst(Self.partnerPrefix.count))) }
            if show == .favorites { return .favorites }
            if owner == .mine { return .capturedByMe }
            switch mediaType {
            case .photos: return .photos
            case .videos: return .videos
            case .all: return .all
            }
        }
        nonmutating set {
            let kept = Self.kept(newValue)
            show = kept.show
            mediaType = kept.mediaType
            owner = kept.owner
            other = kept.other
        }
    }

    /// Every photo again, as Show in All Photos asks, from outside a view.
    static func showAll(defaults: UserDefaults = .standard) {
        let kept = kept(.all)
        defaults.set(kept.show.rawValue, forKey: GridPage.library.key("show"))
        defaults.set(kept.mediaType.rawValue, forKey: GridPage.library.key("mediaType"))
        defaults.set(kept.owner.rawValue, forKey: GridPage.library.key("owner"))
        defaults.set(kept.other, forKey: otherKey)
    }

    private static func kept(_ filter: LibraryFilter)
        -> (show: GridShow, mediaType: GridMediaType, owner: GridOwner, other: String) {
        switch filter {
        case .all: (.all, .all, .anyone, "")
        case .favorites: (.favorites, .all, .anyone, "")
        case .capturedByMe: (.all, .all, .mine, "")
        case .photos: (.all, .photos, .anyone, "")
        case .videos: (.all, .videos, .anyone, "")
        case .notInAlbum: (.all, .all, .anyone, notInAlbum)
        case .sharedWithYou(let partnerID): (.all, .all, .anyone, partnerPrefix + partnerID)
        }
    }
}

/// Library View: the account's photos alone, or with those of the partners who share with it.
enum LibraryViewChoice: Hashable {
    case mine, withPartners

    var title: String {
        switch self {
        case .mine: String(localized: "Mine")
        case .withPartners: String(localized: "Mine and Partners'")
        }
    }
}

struct LibraryOptionsMenu: View {
    let session: LibrarySession
    /// The partners who share their photos with the account.
    let partners: [SharingPartner]
    @Binding var filter: LibraryFilter
    @AppStorage(GridPage.library.key("sortBy")) private var sortBy = GridSortBy.dateTaken
    @Environment(LibraryChrome.self) private var chrome: LibraryChrome?

    var body: some View {
        Menu {
            GridSortControl(sortBy: sortBinding, dateAddedAvailable: filter.ordersByDateAdded)
            Section("Filter:") {
                toggle("All Items", systemImage: "square.grid.3x3", .all)
                toggle("Favorites", systemImage: "heart", .favorites)
                sharedWithYou
                toggle("Captured by Me", systemImage: "person.fill.viewfinder", .capturedByMe)
                toggle("Not in an Album", systemImage: "rectangle.stack.badge.minus", .notInAlbum)
                Menu("Media Types", systemImage: "photo.on.rectangle.angled") {
                    toggle("Photos", systemImage: "photo", .photos)
                    toggle("Videos", systemImage: "video", .videos)
                }
            }
            if !partners.isEmpty {
                Section {
                    Menu {
                        Picker("Library View", selection: libraryView) {
                            Text(LibraryViewChoice.mine.title).tag(LibraryViewChoice.mine)
                            Text(LibraryViewChoice.withPartners.title).tag(LibraryViewChoice.withPartners)
                        }
                        .pickerStyle(.inline)
                    } label: {
                        // The one in use under the name, as Photos says "Both Libraries" there.
                        Text("Library View")
                        Text(libraryView.wrappedValue.title)
                        Image(systemName: "photo.stack")
                    }
                }
            }
            GridViewOptionsSubmenu(offersDateScroller: filter != .notInAlbum, offersNewestEnd: true)
        } label: {
            GridOptionsLabel()
        }
        .gridOptionsTint(filter != .all)
    }

    /// Shared with You: the partner's photos, or with several partners one of them, by name.
    @ViewBuilder
    private var sharedWithYou: some View {
        if partners.count == 1, let partner = partners.first {
            toggle("Shared with You", systemImage: "shared.with.you", .sharedWithYou(partnerID: partner.id))
        } else if partners.count > 1 {
            Menu("Shared with You", systemImage: "shared.with.you") {
                ForEach(partners) { partner in
                    toggle(partner.name.isEmpty ? partner.email : partner.name, systemImage: "person",
                           .sharedWithYou(partnerID: partner.id))
                }
            }
        }
    }

    private func toggle(_ title: String, systemImage: String, _ option: LibraryFilter) -> some View {
        GridFilterToggle(title: title, systemImage: systemImage, isOn: filter == option) { filter = option }
    }

    /// The Library's sort, which a partner's photos shown under Shared with You follow too.
    private var sortBinding: Binding<GridSortBy> {
        Binding(get: { sortBy }, set: { sort in
            UserDefaults.standard.set(sort.rawValue, forKey: GridPage.partner.key("sortBy"))
            sortBy = sort
        })
    }

    /// Mine while no partner is in the account's timeline; choosing changes each partner's "Show in timeline" on the
    /// server, and the Library reads its months again.
    private var libraryView: Binding<LibraryViewChoice> {
        Binding(get: {
            partners.contains { $0.inTimeline == true } ? .withPartners : .mine
        }, set: { choice in
            let inTimeline = choice == .withPartners
            let changing = partners.filter { ($0.inTimeline == true) != inTimeline }
            guard !changing.isEmpty else { return }
            let session = session
            Task {
                let done = await session.sharing.perform {
                    for partner in changing {
                        try await session.client.updateSharingPartner(partner.id, inTimeline: inTimeline)
                    }
                }
                if done {
                    session.invalidateGrids()
                    // The Library shows other photos: it goes to its newest, as for a filter.
                    chrome?.landLibrary()
                } else if let error = session.sharing.error {
                    session.gridModel(for: .library).lastError = error
                }
            }
        })
    }
}
