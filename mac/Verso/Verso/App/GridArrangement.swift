import Foundation
import VersoCore

// Grid pages: view options in the style of Apple Photos. Immich's web app has none for these pages, so
// they stay with what the server filters and orders: the timeline API (GET /timeline/buckets) and, for
// Videos and Large Files, the search API. The shared core reads each page's options, decides which a page offers and
// what they mean (`gridOptions`, `gridFacts`), and makes the query a timeline page reads with them (`gridQuery`, which
// AssetGridModel asks), as on Linux; it keeps them by Linux's codes, reading the spelling this app kept before
// (Immich's names) too.

/// The grid pages with view options. Each saves its own settings.
enum GridPage: String {
    case library, favorites, archive, partner, person, tag, locked
    case videos, largeFiles, geolocation

    /// A Favorites filter adds nothing on Favorites, and partners' favorites are their own.
    /// Assign Location filters by location instead.
    var offersFavoritesFilter: Bool { offers.favorites }
    /// Photos or videos only. Timeline pages switch to the search API for it, which can't search a partner's library.
    /// Assign Location stays on the timeline API, whose coordinates its location filter needs.
    var offersMediaTypeFilter: Bool { offers.mediaType }
    /// Assign Location: only the items the map leaves out, those without GPS coordinates.
    var offersLocationFilter: Bool { offers.location }
    /// The page is for finding items without a location, so it starts with only those.
    var defaultLocation: GridLocation { GridLocation(rawValue: offers.defaultLocation) ?? .all }
    /// Date Added orders the timeline only; search has no upload-date order.
    var offersSortBy: Bool { offers.sortBy }
    /// Large Files is always largest first.
    var offersOrder: Bool { offers.order }
    /// The account's own photos alone, without partners' (Photos' Captured by Me): only the Library mixes partners'
    /// photos into the account's. Verso on iOS offers it; the Mac's view options do not.
    var offersOwnerFilter: Bool { offers.owner }

    func key(_ setting: String) -> String { "grid.\(rawValue).\(setting)" }

    private var offers: GridOffers { gridOffers(page: rawValue) }
}

/// A view option kept in the settings by its code: written as Linux writes it, and read in the spelling this app kept
/// before too (`gridOptionCode`), so `@AppStorage` finds what an earlier version kept.
protocol GridOption: CaseIterable, RawRepresentable where RawValue == String {
    /// The option's name in its settings key.
    static var option: String { get }
}

extension GridOption {
    /// The value kept by a code in either spelling.
    static func kept(_ code: String) -> Self? {
        gridOptionCode(option: option, code: code).flatMap { written in allCases.first { $0.rawValue == written } }
    }
}

enum GridShow: String, GridOption, Identifiable {
    case all, favorites
    static let option = "show"
    init?(rawValue: String) {
        guard let kept = Self.kept(rawValue) else { return nil }
        self = kept
    }
    var id: Self { self }
    var title: LocalizedStringResource { self == .all ? "All Items" : "Favorites" }
}

enum GridMediaType: String, GridOption, Identifiable {
    case all, photos, videos
    static let option = "mediaType"
    init?(rawValue: String) {
        guard let kept = Self.kept(rawValue) else { return nil }
        self = kept
    }
    var id: Self { self }
    var title: LocalizedStringResource {
        switch self {
        case .all: "Photos and Videos"
        case .photos: "Photos"
        case .videos: "Videos"
        }
    }
}

/// Whose photos a page shows: everyone's it asks for, or the account's own alone.
enum GridOwner: String, GridOption {
    case anyone, mine
    static let option = "owner"
    init?(rawValue: String) {
        guard let kept = Self.kept(rawValue) else { return nil }
        self = kept
    }
}

enum GridLocation: String, GridOption, Identifiable {
    case missing, all
    static let option = "location"
    init?(rawValue: String) {
        guard let kept = Self.kept(rawValue) else { return nil }
        self = kept
    }
    var id: Self { self }
    var title: LocalizedStringResource { self == .missing ? "Without Location" : "All Items" }
}

enum GridSortBy: String, GridOption, Identifiable {
    case dateTaken = "taken", dateAdded = "added"
    static let option = "sortBy"
    init?(rawValue: String) {
        guard let kept = Self.kept(rawValue) else { return nil }
        self = kept
    }
    var id: Self { self }
    var title: LocalizedStringResource { self == .dateTaken ? "Date Taken" : "Date Added" }
}

enum GridOrder: String, GridOption, Identifiable {
    // Immich's order values.
    case newestFirst = "desc", oldestFirst = "asc"
    static let option = "order"
    init?(rawValue: String) {
        guard let kept = Self.kept(rawValue) else { return nil }
        self = kept
    }
    var id: Self { self }
    var title: LocalizedStringResource { self == .newestFirst ? "Newest First" : "Oldest First" }
}

struct GridArrangement: Equatable {
    let show: GridShow
    let mediaType: GridMediaType
    let sortBy: GridSortBy
    let order: GridOrder
    let location: GridLocation
    let owner: GridOwner
    /// What the options mean, from the core.
    private let facts: GridFacts

    init(show: GridShow = .all, mediaType: GridMediaType = .all, sortBy: GridSortBy = .dateTaken, order: GridOrder = .newestFirst,
         location: GridLocation = .all, owner: GridOwner = .anyone) {
        self.show = show
        self.mediaType = mediaType
        self.sortBy = sortBy
        self.order = order
        self.location = location
        self.owner = owner
        facts = gridFacts(options: GridOptions(show: show.rawValue, mediaType: mediaType.rawValue, sortBy: sortBy.rawValue,
                                               order: order.rawValue, location: location.rawValue, owner: owner.rawValue))
    }

    /// The settings a page saved with `@AppStorage`, limited to the options it offers.
    init(page: GridPage, defaults: UserDefaults = .standard) {
        let kept = Dictionary(uniqueKeysWithValues: [GridShow.option, GridMediaType.option, GridSortBy.option, GridOrder.option,
                                                     GridLocation.option, GridOwner.option]
            .compactMap { option in defaults.string(forKey: page.key(option)).map { (option, $0) } })
        self.init(gridOptions(page: page.rawValue, kept: kept))
    }

    /// These options as a page offers them: those it does not offer at their defaults.
    init(page: GridPage, show: GridShow, mediaType: GridMediaType, location: GridLocation) {
        let kept = [GridShow.option: show.rawValue, GridMediaType.option: mediaType.rawValue, GridLocation.option: location.rawValue]
        self.init(gridOptions(page: page.rawValue, kept: kept))
    }

    private init(_ options: GridOptions) {
        self.init(show: GridShow(rawValue: options.show) ?? .all, mediaType: GridMediaType(rawValue: options.mediaType) ?? .all,
                  sortBy: GridSortBy(rawValue: options.sortBy) ?? .dateTaken, order: GridOrder(rawValue: options.order) ?? .newestFirst,
                  location: GridLocation(rawValue: options.location) ?? .all, owner: GridOwner(rawValue: options.owner) ?? .anyone)
    }

    var isFiltered: Bool { facts.isFiltered }

    /// Assign Location: the timeline API can't filter by location, so the grid drops located items itself.
    /// Like Immich's map, an item has a location when it has both a latitude and a longitude.
    var hidesLocated: Bool { facts.hidesLocated }

    /// The favorites filter for the search API, which leaves it out when not filtering.
    var isFavorite: Bool? { facts.favoritesOnly ? true : nil }

    /// The asset type for the search API (Immich's AssetType), if filtering by one.
    var assetType: String? { facts.assetType }

    /// Timeline pages show photos or videos only through the search API, since the timeline API has no
    /// type filter. Search groups into months by date taken and leaves out partners' photos.
    var searchesTimeline: Bool { facts.searchesTimeline }

    /// Sorting by Date Added, but not while searching, which has no upload-date order.
    var sortsByDateAdded: Bool { facts.sortsByDateAdded }

    /// The options as the core reads them.
    var options: GridOptions {
        GridOptions(show: show.rawValue, mediaType: mediaType.rawValue, sortBy: sortBy.rawValue, order: order.rawValue,
                    location: location.rawValue, owner: owner.rawValue)
    }

    /// The month an asset falls in, as the first seven characters of a bucket ID ("2026-11").
    /// Date Added buckets go by the upload time in UTC, Date Taken buckets by the photo's own clock.
    func month(localDateTime: String, createdAt: String?) -> Substring? {
        gridMonth(options: options, localDateTime: localDateTime, createdAt: createdAt.flatMap(ImmichDate.parse)).map { Substring($0) }
    }
}
