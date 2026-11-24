import Foundation

/// Grid pages: view options become server filters and survive in the page's saved settings.
@main struct GridArrangementChecks {
    static func main() throws {
        let library = TimelineQuery(withPartners: true)

        // The defaults ask the server for exactly what the page asked for before.
        let plain = GridArrangement().applied(to: library)
        precondition(plain == library)
        precondition(plain.parameters["order"] == .some(nil) && plain.parameters["orderBy"] == .some(nil))

        // Favorites drop partners' photos, which the server refuses together with a favorites filter.
        let favorites = GridArrangement(show: .favorites).applied(to: library)
        precondition(favorites.isFavorite == true && favorites.withPartners == nil)

        // The account's own photos: the timeline without partners', the page's other options kept.
        let mine = GridArrangement(sortBy: .dateAdded, owner: .mine).applied(to: library)
        precondition(mine.withPartners == nil && mine.isFavorite == nil && mine.orderBy == "createdAt")
        precondition(GridArrangement(owner: .mine).isFiltered && !GridArrangement(owner: .mine).searchesTimeline)

        // Oldest first and Date Added, the latter only on servers that support it.
        let added = GridArrangement(sortBy: .dateAdded, order: .oldestFirst)
        precondition(added.applied(to: library).parameters["orderBy"] == "createdAt")
        precondition(added.applied(to: library).parameters["order"] == "asc")

        // Sections: Date Taken uses the photo's own clock, Date Added the upload time in UTC.
        let taken = "2026-01-01T00:30:00.000Z", uploaded = "2025-12-31T23:30:00.000Z"
        precondition(GridArrangement().month(localDateTime: taken, createdAt: uploaded) == "2026-01")
        precondition(added.month(localDateTime: taken, createdAt: uploaded) == "2025-12")
        precondition(added.month(localDateTime: taken, createdAt: nil) == nil)

        // Saved settings, per page, with the API's names.
        let defaults = UserDefaults(suiteName: "GridArrangementChecks")!
        defaults.removePersistentDomain(forName: "GridArrangementChecks")
        precondition(GridArrangement(page: .library, defaults: defaults) == GridArrangement())
        defaults.set("Favorites", forKey: "grid.library.show")
        defaults.set("createdAt", forKey: "grid.library.sortBy")
        defaults.set("asc", forKey: "grid.library.order")
        precondition(GridArrangement(page: .library, defaults: defaults) == GridArrangement(show: .favorites, sortBy: .dateAdded, order: .oldestFirst))
        precondition(GridArrangement(page: .archive, defaults: defaults) == GridArrangement())
        // Only the Library reads whose photos it shows; the Mac never saves it, so its Library shows partners' as before.
        defaults.set("Mine", forKey: "grid.library.owner")
        defaults.set("Mine", forKey: "grid.person.owner")
        precondition(GridArrangement(page: .library, defaults: defaults).owner == .mine)
        precondition(GridArrangement(page: .person, defaults: defaults).owner == .anyone)
        defaults.removeObject(forKey: "grid.library.owner")
        precondition(GridArrangement(page: .library, defaults: defaults).owner == .anyone)
        // Pages without a favorites filter ignore a saved one.
        defaults.set("Favorites", forKey: "grid.favorites.show")
        defaults.set("Favorites", forKey: "grid.partner.show")
        precondition(!GridArrangement(page: .favorites, defaults: defaults).isFiltered)
        precondition(!GridArrangement(page: .partner, defaults: defaults).isFiltered)
        defaults.set("Nonsense", forKey: "grid.tag.order")
        precondition(GridArrangement(page: .tag, defaults: defaults).order == .newestFirst)

        // Videos: favorites and order through the search API, no Date Added.
        defaults.set("Favorites", forKey: "grid.videos.show")
        defaults.set("createdAt", forKey: "grid.videos.sortBy")
        defaults.set("asc", forKey: "grid.videos.order")
        defaults.set("VIDEO", forKey: "grid.videos.mediaType")
        let videos = GridArrangement(page: .videos, defaults: defaults)
        precondition(videos == GridArrangement(show: .favorites, order: .oldestFirst))
        precondition(videos.isFavorite == true && videos.assetType == nil)

        // Large Files: photos or videos and favorites, always largest first.
        defaults.set("IMAGE", forKey: "grid.largeFiles.mediaType")
        defaults.set("asc", forKey: "grid.largeFiles.order")
        let large = GridArrangement(page: .largeFiles, defaults: defaults)
        precondition(large == GridArrangement(mediaType: .photos) && large.isFiltered && large.assetType == "IMAGE" && large.isFavorite == nil)
        precondition(GridArrangement().assetType == nil && GridArrangement().isFavorite == nil)
        precondition(GridMediaType(rawValue: "VIDEO") == .videos)

        // Timeline pages: photos or videos only through search, without Date Added; not for partners.
        defaults.set("VIDEO", forKey: "grid.library.mediaType")
        defaults.set("VIDEO", forKey: "grid.locked.mediaType")
        defaults.set("VIDEO", forKey: "grid.partner.mediaType")
        let libraryVideos = GridArrangement(page: .library, defaults: defaults)
        precondition(libraryVideos.mediaType == .videos && libraryVideos.searchesTimeline && libraryVideos.isFiltered)
        precondition(!libraryVideos.sortsByDateAdded && GridArrangement(sortBy: .dateAdded).sortsByDateAdded)
        precondition(libraryVideos.month(localDateTime: "2026-01-01T00:30:00.000Z", createdAt: "2025-12-31T23:30:00.000Z") == "2026-01")
        precondition(GridArrangement(page: .locked, defaults: defaults).searchesTimeline)
        precondition(!GridArrangement(page: .partner, defaults: defaults).searchesTimeline)
        precondition([GridPage.library, .favorites, .archive, .person, .tag, .locked, .largeFiles].allSatisfy(\.offersMediaTypeFilter))
        precondition(!GridPage.videos.offersMediaTypeFilter && !GridPage.partner.offersMediaTypeFilter)

        // Assign Location: starts with only the items the map leaves out, stays on the timeline API.
        let located = GridArrangement(page: .geolocation, defaults: defaults)
        precondition(located == GridArrangement(location: .missing) && located.hidesLocated && located.isFiltered)
        defaults.set("All", forKey: "grid.geolocation.location")
        defaults.set("Favorites", forKey: "grid.geolocation.show")
        defaults.set("VIDEO", forKey: "grid.geolocation.mediaType")
        defaults.set("asc", forKey: "grid.geolocation.order")
        let everything = GridArrangement(page: .geolocation, defaults: defaults)
        precondition(everything == GridArrangement(order: .oldestFirst) && !everything.hidesLocated && !everything.searchesTimeline)
        // Other pages ignore a saved location filter.
        defaults.set("Missing", forKey: "grid.library.location")
        precondition(!GridArrangement(page: .library, defaults: defaults).hidesLocated)
        precondition(GridPage.geolocation.defaultLocation == .missing && GridPage.library.defaultLocation == .all)
        defaults.removePersistentDomain(forName: "GridArrangementChecks")
        print("Grid view options checks passed.")
    }
}
