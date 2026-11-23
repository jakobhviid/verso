// What Collections on iOS makes of the sidebar's layout (ROADMAP.md, M10): the shared SidebarLayout, saved where the
// Mac's Edit Sidebar saves it, gives the sections, their order, what is hidden and what is collapsed; this file gives
// each link its title, its symbol and its page, as the Mac's sidebar names them, whether this account has it, and the
// blocks the page shows: a block of cards for Albums, People, Places and Memories, and each section's other links as
// rows. The Mac keeps these facts in its sidebar's views, which iOS does not compile.

import SwiftUI

/// Where SidebarLayout is saved, the key the Mac's sidebar keeps it under.
let collectionsLayoutKey = "sidebarLayout"

extension SidebarGroup {
    /// The section's name, the Mac sidebar's own.
    var collectionsTitle: LocalizedStringResource {
        switch self {
        case .photos: "Photos"
        case .explore: "Explore"
        case .collections: "Collections"
        case .sharing: "Sharing"
        case .utilities: "Utilities"
        case .myAlbums: "My Albums"
        case .sharedAlbums: "Shared Albums"
        }
    }
}

extension SidebarSection {
    /// A built-in section's name, or the name given to a section of one's own.
    var collectionsLabel: Text {
        if let group = SidebarGroup(rawValue: id) { Text(group.collectionsTitle) } else { Text(verbatim: name ?? "") }
    }
}

extension SidebarLink {
    var collectionsTitle: LocalizedStringResource {
        switch self {
        case .search: "Search"
        case .library: "Library"
        case .favorites: "Favorites"
        case .videos: "Videos"
        case .map: "Map"
        case .places: "Places"
        case .memories: "Memories"
        case .tags: "Tags"
        case .folders: "Folders"
        case .albums: "Albums"
        case .people: "People"
        case .sharedLinks: "Shared Links"
        case .partners: "Partner Sharing"
        case .duplicates: "Duplicates"
        case .largeFiles: "Large Files"
        case .geolocation: "Assign Location"
        case .archive: "Archive"
        case .trash: "Recently Deleted"
        case .locked: "Locked Folder"
        }
    }

    var collectionsSymbol: String {
        switch self {
        case .search: "magnifyingglass"
        case .library: "photo.on.rectangle"
        case .favorites: "heart"
        case .videos: "video"
        case .map: "map"
        case .places: "map"
        case .memories: "sparkles.rectangle.stack"
        case .tags: "tag"
        case .folders: "folder"
        case .albums: "rectangle.stack"
        case .people: "person.crop.square"
        case .sharedLinks: "link"
        case .partners: "person.2"
        case .duplicates: "square.on.square"
        case .largeFiles: "externaldrive"
        case .geolocation: "mappin.and.ellipse"
        case .archive: "archivebox"
        case .trash: "trash"
        case .locked: "lock"
        }
    }

    /// Library and Search are tabs of their own on iOS, Favorites and Videos are the Library's filters, and Assign
    /// Location needs the Mac's map to place photos on, so Collections leaves them out; the layout keeps their places
    /// for the Mac.
    var inCollections: Bool {
        switch self {
        case .search, .library, .favorites, .videos, .geolocation: false
        default: true
        }
    }

    /// The page the link opens; nil for those Collections leaves out, and for Partner Sharing, whose partners are
    /// links of their own.
    var collectionsRoute: Route? {
        switch self {
        case .albums: .albums
        case .people: .people
        case .places, .map: .places
        case .memories: .memories()
        case .sharedLinks: .sharedLinks
        case .tags: .collections(.tags)
        case .folders: .collections(.folders)
        case .duplicates: .collections(.duplicates)
        case .locked: .collections(.lockedFolder)
        case .archive: .photos(.archive, title: String(localized: collectionsTitle))
        case .trash: .photos(.trash, title: String(localized: collectionsTitle))
        case .largeFiles: .photos(.largeFiles, title: String(localized: collectionsTitle))
        case .search, .library, .favorites, .videos, .geolocation, .partners: nil
        }
    }
}

extension TabBarChoice {
    /// The sidebar's links for the page, which leave Collections while the tab bar holds it.
    var sidebarLinks: [SidebarLink] {
        switch self {
        case .albums: [.albums]
        case .people: [.people]
        case .places: [.places, .map]
        case .memories: [.memories]
        case .sharedLinks: [.sharedLinks]
        case .archive: [.archive]
        }
    }
}

/// One row of a section's grouped box, in the order the layout lists its links.
enum CollectionsEntry: Identifiable, Hashable {
    /// A link to a page.
    case link(SidebarLink)
    /// A partner who shares their photos, where the layout puts Partner Sharing.
    case partner(id: String, name: String)

    var id: String {
        switch self {
        case .link(let link): "link:" + link.rawValue
        case .partner(let id, _): "partner:" + id
        }
    }
}

/// One block of the Collections page, in the layout's order.
enum CollectionsBlock: Identifiable {
    /// Albums, People, Places or Memories: a header that opens the page, and cards of what it holds.
    case cards(SidebarLink)
    /// A section's other links, as rows in a grouped box under the section's name, where its first row is.
    case rows(SidebarSection, [CollectionsEntry])

    var id: String {
        switch self {
        case .cards(let link): "cards:" + link.rawValue
        case .rows(let section, _): "rows:" + section.id
        }
    }
}

extension LibrarySession {
    /// Whether this account and server have the link's page, as the Mac's sidebar decides. The Locked Folder takes a
    /// session sign-in, which an API key is not.
    func collectionsHas(_ link: SidebarLink) -> Bool {
        switch link {
        case .people: features.facialRecognition
        case .map: features.map
        case .memories: services.explorePreferences?.memories?.enabled == true
        case .tags: services.explorePreferences?.tags?.enabled == true
        case .folders: services.explorePreferences?.folders?.enabled == true
        case .sharedLinks: sharing.linksAvailable
        case .partners: sharing.partnersAvailable
        case .duplicates: features.duplicateDetection == true
        case .trash: features.trash
        case .locked: client.exploreSupportsLockedFolder
        default: true
        }
    }

    /// The key a hidden album or partner is kept under, the Mac sidebar's: per server and user.
    func collectionsItemKey(_ item: String) -> String {
        client.serverURL.absoluteString + "|" + (user?.id ?? "") + "|" + item
    }

    /// The links Collections lists in a section, shown or hidden: those this account has and the tab bar does not hold,
    /// in the layout's order.
    func collectionsLinks(in sectionID: String, layout: SidebarLayout, tabBar: [TabBarChoice]) -> [SidebarLink] {
        let inTabBar = Set(tabBar.flatMap(\.sidebarLinks))
        return layout.links(in: sectionID).filter { $0.inCollections && collectionsHas($0) && !inTabBar.contains($0) }
    }

    /// The albums the Albums block shows, without those hidden from the sidebar: the account's own, then those shared
    /// with it, each in its sidebar section's order (the newest photo first unless changed), as the Albums page puts
    /// the account's own first.
    func collectionsAlbums(layout: SidebarLayout) -> [Album] {
        [SidebarGroup.myAlbums, .sharedAlbums].flatMap { group in
            let shared = group == .sharedAlbums
            let shown = albums.filter { $0.shared == shared && !layout.isDynamicItemHidden(collectionsItemKey("album:" + $0.id)) }
            let sortBy = layout.albumSorting(in: group.rawValue).flatMap(AlbumsSortBy.init(rawValue:)) ?? .mostRecentPhoto
            return sortBy.sidebar(shown, limit: nil)
        }
    }

    /// The blocks Collections shows, in the layout's order: hidden sections and links left out, and sections with
    /// nothing to show. Albums, People, Places and Memories are blocks of their own; Map and Places are one, Places,
    /// where the first of them is. A section's other links are one box of rows, where the first of them is.
    func collectionsBlocks(layout: SidebarLayout, tabBar: [TabBarChoice]) -> [CollectionsBlock] {
        var placesShown = false
        var blocks: [CollectionsBlock] = []
        for section in layout.sections where !section.hidden {
            var rows: [CollectionsEntry] = []
            var rowsPosition: Int?
            for link in collectionsLinks(in: section.id, layout: layout, tabBar: tabBar) where !layout.isHidden(link) {
                var entries: [CollectionsEntry] = []
                switch link {
                case .places, .map:
                    if !placesShown { blocks.append(.cards(.places)) }
                    placesShown = true
                case .albums, .people, .memories:
                    blocks.append(.cards(link))
                case .partners:
                    entries = sharing.receivedPartners
                        .filter { !layout.isDynamicItemHidden(collectionsItemKey("partner:" + $0.id)) }
                        .map { CollectionsEntry.partner(id: $0.id, name: $0.name) }
                default:
                    entries = [.link(link)]
                }
                if !entries.isEmpty, rowsPosition == nil { rowsPosition = blocks.count }
                rows += entries
            }
            if let rowsPosition { blocks.insert(.rows(section, rows), at: rowsPosition) }
        }
        return blocks
    }
}
