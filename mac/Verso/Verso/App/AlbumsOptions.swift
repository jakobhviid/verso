import Foundation
import VersoCore

// Albums: the Immich web app's album view settings (web/src/lib/utils/album-utils.ts and AlbumsList.svelte). The shared
// core filters, groups and sorts the albums and keeps which groups are collapsed (`albumsSections`, `albumsSorted`,
// `albumsSidebar`, `albumsCollapsed`), as on Linux, by the same codes; the order of titles and owners' names is the
// person's language's, which only the app knows.

enum AlbumsSortOrder: String, CaseIterable, Identifiable {
    case ascending = "asc", descending = "desc"
    var id: Self { self }
    var title: LocalizedStringResource { self == .ascending ? "Ascending" : "Descending" }
}

enum AlbumsFilter: String, CaseIterable, Identifiable {
    case all = "All", owned = "Owned", shared = "Shared"
    var id: Self { self }
    var title: LocalizedStringResource {
        switch self {
        case .all: "All Albums"
        case .owned: "My Albums"
        case .shared: "Shared Albums"
        }
    }
}

enum AlbumsGroupBy: String, CaseIterable, Identifiable {
    case none = "None", year = "Year", owner = "Owner"
    var id: Self { self }
    var title: LocalizedStringResource {
        switch self {
        case .none: "No Grouping"
        case .year: "Year"
        case .owner: "Owner"
        }
    }
    /// The group order the grouping takes when chosen: the newest year first, owners A to Z.
    var defaultOrder: AlbumsSortOrder { AlbumsSortOrder(rawValue: albumsGroupOrderByDefault(groupBy: rawValue)) ?? .descending }
}

enum AlbumsSortBy: String, CaseIterable, Identifiable {
    case title = "Title", itemCount = "ItemCount", dateModified = "DateModified", dateCreated = "DateCreated"
    case mostRecentPhoto = "MostRecentPhoto", oldestPhoto = "OldestPhoto"
    var id: Self { self }
    var title: LocalizedStringResource {
        switch self {
        case .title: "Title"
        case .itemCount: "Item Count"
        case .dateModified: "Date Modified"
        case .dateCreated: "Date Created"
        case .mostRecentPhoto: "Most Recent Photo"
        case .oldestPhoto: "Oldest Photo"
        }
    }
    /// The album order the key takes when chosen: titles A to Z, counts and dates largest and newest first.
    var defaultOrder: AlbumsSortOrder { AlbumsSortOrder(rawValue: albumsSortOrderByDefault(sortBy: rawValue)) ?? .descending }

    /// A sidebar album section: the first albums in this key's own order, or all of them without a limit.
    func sidebar(_ albums: [Album], limit: Int?) -> [Album] {
        albumsSidebar(albums: albums.map(AlbumFacts.init), sortBy: rawValue, limit: limit.map { UInt32(clamping: $0) },
                      names: AlbumsOptions.names(albums)).map { albums[Int($0)] }
    }
}

/// Immich's Cover and List views.
enum AlbumsViewMode: String, CaseIterable, Identifiable {
    case cover = "Cover", list = "List"
    var id: Self { self }
    var title: LocalizedStringResource { self == .cover ? "Covers" : "List" }
}

struct AlbumsGroup: Identifiable {
    enum Header: Hashable {
        case year(Int), unknownYear, mine, owner(String)
    }
    let id: String
    let header: Header?
    var albums: [Album]
}

extension AlbumsOptions {
    init(filter: AlbumsFilter = .all, groupBy: AlbumsGroupBy = .year, groupOrder: AlbumsSortOrder = .descending,
         sortBy: AlbumsSortBy = .mostRecentPhoto, sortOrder: AlbumsSortOrder = .descending) {
        self.init(filter: filter.rawValue, groupBy: groupBy.rawValue, groupOrder: groupOrder.rawValue, sortBy: sortBy.rawValue,
                  sortOrder: sortOrder.rawValue)
    }

    /// Immich turns year groups off while sorting by album dates, which say nothing about the photos' years.
    func allows(_ option: AlbumsGroupBy) -> Bool { albumsAllowsGrouping(options: self, groupBy: option.rawValue) }

    var effectiveGroupBy: AlbumsGroupBy { AlbumsGroupBy(rawValue: albumsGrouping(options: self)) ?? .none }

    /// The albums shown, filtered, grouped (years by the newest photo, or the oldest when sorting by it; the account's
    /// own first among owners in ascending order), and sorted within each group.
    func groups(_ albums: [Album], userID: String?) -> [AlbumsGroup] {
        albumsSections(albums: albums.map(AlbumFacts.init), options: self, userId: userID, names: Self.names(albums)).map { section in
            let header: AlbumsGroup.Header? = switch section.header {
            case .year(let year)?: .year(Int(year))
            case .unknownYear?: .unknownYear
            case .mine?: .mine
            case .owner(let name)?: .owner(name)
            case nil: nil
            }
            return AlbumsGroup(id: section.id, header: header, albums: section.albums.map { albums[Int($0)] })
        }
    }

    /// The albums in the chosen order, whatever the filter and grouping; albums without the date go last.
    func sorted(_ albums: [Album]) -> [Album] {
        albumsSorted(albums: albums.map(AlbumFacts.init), options: self, names: Self.names(albums)).map { albums[Int($0)] }
    }

    /// Each title's and owner's name by its place in the order of the person's language, as `localizedCompare` sorts
    /// them; names alike in it share one.
    fileprivate static func names(_ albums: [Album]) -> [String: UInt32] {
        nameOrder(albums.flatMap { [$0.albumName, $0.albumOwner?.name ?? ""] }) { $0.localizedCompare($1) }
    }
}

extension AlbumFacts {
    /// What the core reads of an album. Its photos' dates are their own wall-clock days, sent at UTC midnight.
    init(_ album: Album) {
        let date = { (value: String?) in value.flatMap(ImmichDate.parse) }
        self.init(title: album.albumName, ownerId: album.albumOwner?.id, ownerName: album.albumOwner?.name ?? "", shared: album.shared,
                  assetCount: UInt64(clamping: album.assetCount), createdAt: date(album.createdAt), updatedAt: date(album.updatedAt),
                  startDate: date(album.startDate), endDate: date(album.endDate))
    }
}
