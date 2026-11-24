import Foundation
import VersoCore

// The sidebar as Edit Sidebar arranges it, on the Mac and in Collections on iOS: its sections in order, which link sits
// in which, what is hidden and collapsed, and how many albums an album section lists. The shared core works it out
// (`sidebarArrangement`, `sidebarEdited`), as on Linux, and keeps it in the form this app has always kept it in; the
// app names its built-in sections and links, and what each shows.

enum SidebarGroup: String, CaseIterable {
    case photos, explore, collections, sharing, utilities, myAlbums, sharedAlbums
}

enum SidebarLink: String, CaseIterable {
    case search, library, favorites, videos
    case map, places, memories, tags, folders
    case albums, people
    case sharedLinks, partners
    case duplicates, largeFiles, geolocation, archive, trash, locked

    var defaultGroup: SidebarGroup {
        switch self {
        case .search, .library, .favorites, .videos: .photos
        case .map, .places, .memories, .tags, .folders: .explore
        case .albums, .people: .collections
        case .sharedLinks, .partners: .sharing
        default: .utilities
        }
    }
}

/// A section of the sidebar, as the core has it (`id`, `name`, `hidden`, `isCollapsed`, `isCustom`, `listsAlbums`).
typealias SidebarSection = VersoCore.SidebarSection

struct SidebarLayout {
    /// The built-in sections, each with its links where they start; My Albums and Shared Albums list albums.
    static let defaults = SidebarGroup.allCases.map { group in
        SidebarDefault(section: group.rawValue, pages: SidebarLink.allCases.filter { $0.defaultGroup == group }.map(\.rawValue))
    }

    private var arrangement: SidebarArrangement

    init(stored: String = "") {
        arrangement = sidebarArrangement(stored: stored, defaults: Self.defaults)
    }

    /// What the settings keep.
    var stored: String { arrangement.stored }
    var sections: [SidebarSection] { arrangement.sections }

    func links(in group: SidebarGroup) -> [SidebarLink] { links(in: group.rawValue) }

    func links(in sectionID: String) -> [SidebarLink] {
        (sections.first { $0.id == sectionID }?.pages ?? []).compactMap(SidebarLink.init(rawValue:))
    }

    func isHidden(_ link: SidebarLink) -> Bool { arrangement.hiddenPages.contains(link.rawValue) }
    mutating func setHidden(_ hidden: Bool, link: SidebarLink) { edit(.hidePage(page: link.rawValue, hidden: hidden)) }
    func isDynamicItemHidden(_ key: String) -> Bool { arrangement.hiddenItems.contains(key) }
    mutating func setDynamicItemHidden(_ hidden: Bool, key: String) { edit(.hideItem(key: key, hidden: hidden)) }
    /// How many albums an album section lists, or nil to list all of them: five until changed.
    func albumLimit(in sectionID: String) -> Int? {
        guard let section = sections.first(where: { $0.id == sectionID }) else { return 5 }
        return section.albumLimit.map { Int($0) }
    }
    mutating func setAlbumLimit(_ limit: Int?, in sectionID: String) {
        edit(.albumLimit(section: sectionID, limit: limit.map { UInt32(clamping: $0) }))
    }
    /// The album sort an album section uses, by its code, so the layout stays independent of the albums page.
    func albumSorting(in sectionID: String) -> String? { sections.first { $0.id == sectionID }?.albumSortBy }
    mutating func setAlbumSorting(_ sortBy: String?, in sectionID: String) { edit(.albumSortBy(section: sectionID, sortBy: sortBy)) }
    mutating func setSectionHidden(_ hidden: Bool, id: String) { edit(.hideSection(id: id, hidden: hidden)) }
    mutating func setSectionCollapsed(_ collapsed: Bool, id: String) { edit(.collapseSection(id: id, collapsed: collapsed)) }

    @discardableResult
    mutating func addSection(named name: String) -> String? { edit(.addSection(name: name)).added }

    mutating func renameSection(id: String, to name: String) { edit(.renameSection(id: id, name: name)) }

    /// Its links go back to the sections they started in.
    mutating func removeSection(id: String) { edit(.removeSection(id: id)) }

    mutating func shiftSection(id: String, by offset: Int) { edit(.shiftSection(id: id, by: Int32(clamping: offset))) }

    @discardableResult
    mutating func move(_ link: SidebarLink, to group: SidebarGroup, relativeTo target: SidebarLink? = nil, after: Bool = false) -> Bool {
        move(link, to: group.rawValue, relativeTo: target, after: after)
    }

    @discardableResult
    mutating func move(_ link: SidebarLink, to sectionID: String, relativeTo target: SidebarLink? = nil, after: Bool = false) -> Bool {
        edit(.movePage(page: link.rawValue, section: sectionID, target: target?.rawValue, after: after)).changed
    }

    /// Moves a link to where a list drop landed among the rows a section shows: before the row at `index`, or after the
    /// last row. Hidden rows in between keep their place.
    @discardableResult
    mutating func move(_ link: SidebarLink, to sectionID: String, at index: Int, among shown: [SidebarLink]) -> Bool {
        edit(.dropPage(page: link.rawValue, section: sectionID, index: UInt32(clamping: index), shown: shown.map(\.rawValue))).changed
    }

    @discardableResult
    private mutating func edit(_ change: SidebarEdit) -> SidebarEdited {
        let edited = sidebarEdited(stored: arrangement.stored, defaults: Self.defaults, edit: change)
        arrangement = edited.arrangement
        return edited
    }
}
