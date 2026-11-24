// What the tab bar holds besides Library, first, and Collections, last: pages of the person's choosing, up to two on
// an iPhone, Albums alone by default (the maintainer's choice), and up to three on an iPad, whose bar at the top has
// room for one more, Albums and People by default; or Map, Memories, Shared Links and the Archive (ROADMAP.md, M10).
// Kept on this device; Collections leaves out what the bar holds.

import UIKit

enum TabBarChoice: String, CaseIterable, Identifiable, Hashable {
    case albums, people, places, memories, sharedLinks, archive

    var id: Self { self }

    /// How many the bar holds between Library and Collections: the iPhone shows four tabs beside Search, and a fifth
    /// goes into the system's More tab (on iOS 27.2), which Verso never shows; the iPad's bar at the top has room for
    /// one more.
    @MainActor static var most: Int { isPad ? 3 : 2 }
    @MainActor static var defaults: [TabBarChoice] { isPad ? [.albums, .people] : [.albums] }

    @MainActor private static var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }
    /// The `@AppStorage` key the choice is kept under, as the raw values joined with commas.
    static let storageKey = "tabBarChoices"

    var title: String {
        switch self {
        case .albums: "Albums"
        case .people: "People"
        case .places: "Map"
        case .memories: "Memories"
        case .sharedLinks: "Shared Links"
        case .archive: "Archive"
        }
    }

    var systemImage: String {
        switch self {
        case .albums: "rectangle.stack"
        case .people: "person.crop.square"
        case .places: "map"
        case .memories: "sparkles.rectangle.stack"
        case .sharedLinks: "link"
        case .archive: "archivebox"
        }
    }

    /// The route of the page, for a link to it where the bar does not hold it.
    var route: Route {
        switch self {
        case .albums: .albums
        case .people: .people
        case .places: .places
        case .memories: .memories()
        case .sharedLinks: .sharedLinks
        case .archive: .photos(.archive, title: String(localized: "Archive"))
        }
    }

    /// What is kept for a bar of Library and Collections alone, apart from nothing kept, which means the defaults.
    private static let noneChosen = "none"

    /// The choice kept under `storageKey`; the defaults when nothing is kept.
    @MainActor static func decode(_ stored: String) -> [TabBarChoice] {
        guard !stored.isEmpty else { return defaults }
        guard stored != noneChosen else { return [] }
        var seen = Set<TabBarChoice>()
        let choices = stored.split(separator: ",").compactMap { TabBarChoice(rawValue: String($0)) }.filter { seen.insert($0).inserted }
        return Array(choices.prefix(most))
    }

    @MainActor static func encode(_ choices: [TabBarChoice]) -> String {
        choices.isEmpty ? noneChosen : choices.prefix(most).map(\.rawValue).joined(separator: ",")
    }
}
