// The one menu of photo actions on iOS, wherever a photo is acted on: a long press on a tile, the "..." in the
// selection's bar, and the viewer's "..." (ROADMAP.md, M10). It is built from Photos' own long-press menu on iOS 26, in
// its order: a row of three quick actions along the top (Copy, Save to Photos, Hide), the common pair (Share,
// Favorite), the submenus, which open in place as iOS 26's submenus in a context menu do (Add To, Move To, Adjust Info),
// what only this page offers (Show in All Photos or Show in Archive, Use as Album Cover, Stack, Remove from Album), and
// Delete alone, in red, at the bottom. Where a photo lives goes by the photo, not the page: an archived photo in an
// album or a search has Show in Archive and Move To the Library, the others Show in All Photos and Move To the Archive,
// as Photos' Move To offers the other library; a selection of both is offered both, and each photo moves only where it
// is not already.
//
// Each action shows once, and one that does not apply is left out rather than dimmed: someone else's photo has no
// Hide, Move To, Adjust Info, Favorite or Delete; Recently Deleted has Restore and Delete Permanently alone; a photo
// still on its way from the phone has Copy, Share, Favorite and Delete. Where the page has an action in a bar of its own
// beside the menu (the viewer's Share, Favorite and Delete; the selection bar's Share, Add To, Favorite and Delete), the
// menu leaves it to the bar.
//
// The menu decides nothing itself: the page says what applies to its photos (PhotoActionsContext, made by
// PhotoActionsRules for a grid and for the viewer alike) and does what is chosen (PhotoAction, GridActions.perform for
// a grid).

import SwiftUI

/// Where the menu shows, which says what the page's own bar offers beside it.
enum PhotoActionsPlace {
    /// A long press on a tile: every action.
    case tile
    /// The "..." in the selection's bar, beside its Share, Add To, Favorite and Delete.
    case selectionBar
    /// The viewer's "...", beside its bottom bar's Share, Favorite and Delete.
    case viewer
}

/// Where photos live in the library, as Move To moves them.
enum PhotoHome {
    case library, archive
}

/// What can be chosen in the menu.
enum PhotoAction {
    /// The originals on the pasteboard.
    case copy
    /// The originals into the phone's photo library.
    case saveToPhotos
    /// Into Immich's Locked Folder, Photos' Hidden, and back out of it.
    case hide, unhide
    case share
    case favorite(Bool)
    /// Add To: an album of one's own that is not shared, or one shared with people.
    case addToAlbum(shared: Bool)
    /// Add To: a new album with the photos, which a shared one then opens the sharing of.
    case newAlbum(shared: Bool)
    case tag
    case move(PhotoHome)
    case adjustDate, adjustLocation, adjustDescription
    /// One to five stars, or none.
    case rate(Int?)
    case showInAllPhotos, showInArchive, useAsAlbumCover, stack
    /// Out of the album, link or memory the page shows.
    case removeFromPage
    case delete, restore
}

/// Add To's choices, each where it applies.
struct PhotoAddTo {
    /// The account's own albums that are not shared.
    var albums = false
    /// Albums shared with people that the account may add to: its own, and others' where it is an editor.
    var sharedAlbums = false
    /// New Album and New Shared Album.
    var newAlbums = false
    var tags = false

    var any: Bool { albums || sharedAlbums || newAlbums || tags }
}

/// What the menu offers for the photos, as the page finds it: each true where the action applies to every photo it
/// takes.
struct PhotoActionsContext {
    var place: PhotoActionsPlace
    /// How many photos the actions take.
    var count = 1
    /// Recently Deleted: Restore and Delete Permanently alone.
    var restore = false
    var copy = false
    var saveToPhotos = false
    var hide = false
    var unhide = false
    var share = false
    var favorite = false
    /// They are all favourites already: Unfavorite.
    var allFavorite = false
    var addTo = PhotoAddTo()
    /// Move To, and where the photos all live now, which it does not offer: nil inside the Locked Folder, which they
    /// move out of, and for photos that live in both, each of which moves only where it is not already.
    var moveTo = false
    var home: PhotoHome?
    var adjustDate = false
    var adjustLocation = false
    var adjustDescription = false
    /// The stars, where the account has ratings on, and the photo's own when they are known.
    var rating = false
    var currentRating: Int?
    var showInAllPhotos = false
    /// The Archive at the photo, for an archived photo shown on another page.
    var showInArchive = false
    var albumCover = false
    var stack = false
    /// "Remove from Album", "Remove from Link" or "Remove from Memory", where the page lets the account.
    var removal: String?
    /// "Delete", "Delete Permanently" or "Delete from iPhone", where the photos may be deleted.
    var delete: String?

    /// Whether the menu has anything to offer here.
    var isEmpty: Bool {
        !(showsRestore || quickCount > 0 || showsShare || showsFavorite || showsAddTo || moveTo || showsAdjustInfo
            || showInAllPhotos || showInArchive || albumCover || stack || removal != nil || showsDelete)
    }

    // MARK: What shows here

    /// Restore and Delete Permanently are the bottom bar's in the viewer and the selection's bar.
    var showsRestore: Bool { restore && place == .tile }
    var showsShare: Bool { share && place == .tile }
    var showsFavorite: Bool { favorite && place == .tile }
    var showsAddTo: Bool { addTo.any && place != .selectionBar }
    var showsDelete: Bool { delete != nil && place == .tile }
    var showsAdjustInfo: Bool { adjustDate || adjustLocation || adjustDescription || rating }
    var quickCount: Int { [copy, saveToPhotos, hide || unhide].filter { $0 }.count }
}

/// The menu's items, for a context menu or a Menu's content. `pageItems` are what only the page around it offers
/// beyond the shared ones, such as the viewer's Start Slideshow; they go with the page's section.
struct PhotoActionsMenu<PageItems: View>: View {
    let context: PhotoActionsContext
    let perform: (PhotoAction) -> Void
    @ViewBuilder var pageItems: () -> PageItems

    init(context: PhotoActionsContext, perform: @escaping (PhotoAction) -> Void,
         @ViewBuilder pageItems: @escaping () -> PageItems) {
        self.context = context
        self.perform = perform
        self.pageItems = pageItems
    }

    var body: some View {
        if context.showsRestore {
            Button("Restore", systemImage: "arrow.uturn.backward") { perform(.restore) }
        }
        quickActions
        if context.showsShare || context.showsFavorite {
            Section {
                if context.showsShare {
                    Button("Share", systemImage: "square.and.arrow.up") { perform(.share) }
                }
                if context.showsFavorite {
                    Button(context.allFavorite ? "Unfavorite" : "Favorite",
                           systemImage: context.allFavorite ? "heart.slash" : "heart") {
                        perform(.favorite(!context.allFavorite))
                    }
                }
            }
        }
        if context.showsAddTo || context.moveTo || context.showsAdjustInfo {
            Section {
                if context.showsAddTo {
                    Menu {
                        PhotoAddToItems(addTo: context.addTo, perform: perform)
                    } label: {
                        Label("Add To", systemImage: "rectangle.stack.badge.plus")
                    }
                }
                if context.moveTo { moveToMenu }
                if context.showsAdjustInfo { adjustInfoMenu }
            }
        }
        Section {
            if context.showInAllPhotos {
                Button("Show in All Photos", systemImage: "photo.on.rectangle") { perform(.showInAllPhotos) }
            }
            if context.showInArchive {
                Button("Show in Archive", systemImage: "archivebox") { perform(.showInArchive) }
            }
            if context.albumCover {
                Button("Use as Album Cover", systemImage: "photo.badge.checkmark") { perform(.useAsAlbumCover) }
            }
            if context.stack {
                Button("Stack", systemImage: "square.stack.3d.up") { perform(.stack) }
            }
            pageItems()
            if let removal = context.removal {
                Button(removal, systemImage: "rectangle.stack.badge.minus", role: .destructive) { perform(.removeFromPage) }
            }
        }
        if context.showsDelete, let title = context.delete {
            Section {
                Button(title, systemImage: "trash", role: .destructive) { perform(.delete) }
            }
        }
    }

    // MARK: The parts

    /// Copy, Save to Photos and Hide in a row along the top, as Photos has Copy, Duplicate and Hide; one alone is a
    /// plain row.
    @ViewBuilder private var quickActions: some View {
        if context.quickCount > 1 {
            ControlGroup { quickButtons }
        } else if context.quickCount == 1 {
            Section { quickButtons }
        }
    }

    @ViewBuilder private var quickButtons: some View {
        if context.copy {
            Button("Copy", systemImage: "doc.on.doc") { perform(.copy) }
        }
        if context.saveToPhotos {
            Button("Save to Photos", systemImage: "square.and.arrow.down") { perform(.saveToPhotos) }
        }
        if context.hide {
            Button("Hide", systemImage: "eye.slash") { perform(.hide) }
        } else if context.unhide {
            Button("Unhide", systemImage: "eye") { perform(.unhide) }
        }
    }

    /// Where the photos can go, as Photos' Move To offers the other library: the Archive for photos in the Library,
    /// the Library for archived ones, and both for a mix or out of the Locked Folder, each moving only the photos not
    /// already there.
    private var moveToMenu: some View {
        Menu {
            if context.home != .library {
                Button("Library", systemImage: "photo.on.rectangle") { perform(.move(.library)) }
            }
            if context.home != .archive {
                Button("Archive", systemImage: "archivebox") { perform(.move(.archive)) }
            }
        } label: {
            Label("Move To", systemImage: "folder")
        }
    }

    private var adjustInfoMenu: some View {
        Menu {
            if context.adjustDate {
                Button("Adjust Date & Time", systemImage: "calendar") { perform(.adjustDate) }
            }
            if context.adjustLocation {
                Button("Adjust Location", systemImage: "mappin.and.ellipse") { perform(.adjustLocation) }
            }
            if context.adjustDescription {
                Button("Adjust Description", systemImage: "text.alignleft") { perform(.adjustDescription) }
            }
            if context.rating { ratingMenu }
        } label: {
            Label("Adjust Info", systemImage: "info.circle")
        }
    }

    /// The stars, one to five, and none; the photo's own ticked when it is known.
    private var ratingMenu: some View {
        Menu {
            ForEach(1...5, id: \.self) { stars in
                Toggle(isOn: Binding(get: { context.currentRating == stars }, set: { on in if on { perform(.rate(stars)) } })) {
                    Text(verbatim: String(repeating: "★", count: stars) + String(repeating: "☆", count: 5 - stars))
                }
                .accessibilityLabel(stars == 1 ? Text("1 Star") : Text("\(stars) Stars"))
            }
            Toggle(isOn: Binding(get: { context.currentRating == 0 }, set: { on in if on { perform(.rate(nil)) } })) {
                Text("No Rating")
            }
        } label: {
            Label("Rating", systemImage: "star")
        }
    }
}

extension PhotoActionsMenu where PageItems == EmptyView {
    init(context: PhotoActionsContext, perform: @escaping (PhotoAction) -> Void) {
        self.init(context: context, perform: perform) { EmptyView() }
    }
}

/// Add To's items: the albums to add to, new ones, and tags. The menu's Add To and the selection bar's hold them.
struct PhotoAddToItems: View {
    let addTo: PhotoAddTo
    let perform: (PhotoAction) -> Void

    var body: some View {
        if addTo.albums || addTo.sharedAlbums {
            Section {
                if addTo.albums {
                    Button("Album…", systemImage: "rectangle.stack") { perform(.addToAlbum(shared: false)) }
                }
                if addTo.sharedAlbums {
                    Button("Shared Album…", systemImage: "rectangle.stack.badge.person.crop") {
                        perform(.addToAlbum(shared: true))
                    }
                }
            }
        }
        if addTo.newAlbums {
            Section {
                Button("New Album…", systemImage: "plus.rectangle.on.rectangle") { perform(.newAlbum(shared: false)) }
                Button("New Shared Album…", systemImage: "person.2.crop.square.stack") { perform(.newAlbum(shared: true)) }
            }
        }
        if addTo.tags {
            Section {
                Button("Tag…", systemImage: "tag") { perform(.tag) }
            }
        }
    }
}
