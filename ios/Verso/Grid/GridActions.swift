// What a photo grid does with the photos chosen: the menu of photo actions (PhotoActionsMenu) on a long press on a
// tile (a long press that goes on into a drag selects instead, TimelineGrid) and in the selection's bar, which holds
// Share, Add To, Favorite, "..." with the menu, and Delete, as Photos' bar does. The grid says what applies to its
// photos (PhotoActionsRules, which the viewer uses too) and does what is chosen (`perform`), with the Mac's actions
// (mac/Verso/Verso/Views/Grid/AssetGridView.swift, AssetActionsMenu) where they fit a phone: Recently Deleted
// restores, the Locked Folder keeps its photos apart, someone else's photos can be copied, saved, shared and, where
// Immich allows it, added to albums. Whether a photo is archived goes by the photo (AssetItem.archived(on:)), as an
// archived photo also shows in albums, Favorites, people, places and searches: it has Show in Archive and Move To the
// Library, the others Show in All Photos and Move To the Archive.
//
// The Library's photos on their way to Immich (from the phone, BackupWaitingPhoto) are in a selection by IDs of their
// own beside Immich's. Copy and Share take the phone's copy, Favorite sets it in Photos, and Delete deletes it from the
// phone, which iOS asks about; Immich's actions show once a photo has arrived, and in a selection with Immich's photos
// they leave it out and say so (a notice at the foot of the grid).

import SwiftUI

/// One page's grid state that its views share: whether it is selecting, the photo open in the viewer, the sheets and
/// questions the actions bring up, and where the grid is, for the line under the page's title.
@MainActor @Observable final class GridPageState {
    var isSelecting = false
    /// The days of the photos in view ("Nov 15 - 19, 2026"), as the line under the title says them while the grid
    /// scrolls; nil before any photo in view has loaded.
    var visibleDates: String?
    /// Whether the grid is at the end it opens at: a timeline's newest photos, at the bottom or the top
    /// (GridNewestEnd), or the top of a page that reads down.
    var atOpeningEnd = true
    /// Counts the person's scrolls away from the end the grid opens at, as they let go, for the tab bar, which has shrunk
    /// on them by then.
    var awayScrolls = 0
    /// The photo the viewer opened on, from the tap on its tile until the viewer has closed.
    var opened: OpenedAsset?
    /// The photo the viewer shows, whose tile it closes into.
    var shownInViewer: String?
    /// The tiles' anchors, which the viewer's zoom starts from and ends in.
    @ObservationIgnored let zoomSources = ViewerZoomSources()
    var pendingDelete: GridAssetIDs?
    /// Photos to take out of the album, link or memory the page shows, once asked.
    var pendingRemoval: GridAssetIDs?
    var sharing: GridAssetIDs?
    /// A sheet the menu's actions opened: Add To's albums or tags, a new album, or an editor of the photos' details.
    var actionSheet: PhotoActionSheet?
    /// A photo on its way to Immich open from the phone (PhoneViewer), by its grid ID, and the one it shows now, whose
    /// tile it closes into.
    var openedPhone: OpenedAsset?
    var shownPhone: String?
    /// A word at the foot of the grid, such as the photos on their way an action left out, or Save to Photos' answer.
    private(set) var notice: String?
    /// The notice stays until another takes its place, while the action it tells of goes on ("Saving to Photos…").
    private(set) var noticeHolds = false
    /// Whether the account has ratings on in Immich, read as the page first shows, as the viewer reads it as it opens.
    var ratingsEnabled: Bool?

    /// Says something at the grid's foot for a few seconds, or until the next word where it `holds`.
    func say(_ words: String, holds: Bool = false) {
        notice = words
        noticeHolds = holds
    }

    func clearNotice() {
        notice = nil
        noticeHolds = false
    }

    /// Reads the account's ratings preference once, as the Mac's details read it; a failed read leaves the session's.
    func loadRatingsPreference(_ session: LibrarySession) async {
        guard ratingsEnabled == nil, let preferences = try? await session.client.metadataPreferences() else { return }
        ratingsEnabled = preferences.ratings?.enabled ?? false
    }
}

/// Photos an action is for, as a sheet or a question takes them.
struct GridAssetIDs: Identifiable {
    let id = UUID()
    let ids: [String]
}

/// What applies to a page's photos, for the menu of photo actions wherever it shows: a grid's long press and selection
/// bar (GridActions), and the viewer's "...", which builds its context here too. It decides by each photo where it can
/// (its owner, whether it is archived) and by the page where only the page knows (an album's owner, Recently Deleted).
@MainActor struct PhotoActionsRules {
    let model: AssetGridModel
    let session: LibrarySession
    let chrome: LibraryChrome?

    var source: GridSource { model.source }

    /// Recently Deleted and the Locked Folder delete for good, as does a server without a trash, as in Immich.
    var deletesPermanently: Bool {
        source == .trash || source == .locked || !session.features.trash
    }

    /// Immich's photos among `ids`, and the photos on their way, by their local identifiers.
    func split(_ ids: [String]) -> (immich: [String], phone: [String]) {
        var immich: [String] = []
        var phone: [String] = []
        for id in ids {
            if let localID = BackupWaitingPhoto.localID(gridID: id) { phone.append(localID) } else { immich.append(id) }
        }
        return (immich, phone)
    }

    /// Whether the photos can be deleted: Immich's by the account, those on their way from the phone.
    func canDelete(_ ids: [String]) -> Bool {
        let (immich, phone) = split(ids)
        return immich.isEmpty ? !phone.isEmpty : model.canDelete(immich)
    }

    // MARK: What applies

    /// What the menu offers for these photos here (PhotoActionsMenu), each action where it applies to them all; the
    /// stars where the account has ratings on, as the page or the viewer last read it.
    func context(for ids: [String], place: PhotoActionsPlace, ratingsEnabled: Bool?) -> PhotoActionsContext {
        var context = PhotoActionsContext(place: place, count: ids.count)
        let (immich, phone) = split(ids)
        guard !ids.isEmpty else { return context }
        if source == .trash {
            let deletable = model.canDelete(immich)
            context.restore = deletable
            context.delete = deletable ? String(localized: "Delete Permanently") : nil
            return context
        }
        context.copy = true
        context.share = true
        // On their way from the phone: Copy, Share, Favorite in Photos, and Delete from the phone.
        if immich.isEmpty {
            let photos = BackupCenter.shared.libraryTiles.map(\.photo).filter { phone.contains($0.localID) }
            context.favorite = true
            context.allFavorite = !photos.isEmpty && photos.allSatisfy(\.favorite)
            context.delete = String(localized: "Delete from \(UIDevice.current.localizedModel)")
            return context
        }
        let items = immich.compactMap(model.item)
        let owned = model.canMutate(immich)
        let locked = source == .locked
        let one = ids.count == 1
        let archived = items.filter { $0.archived(on: source) }.count
        context.saveToPhotos = true
        context.favorite = owned
        context.allFavorite = !items.isEmpty && items.allSatisfy(\.isFavorite)
        context.hide = owned && !locked && session.lockedFolder == nil && session.client.exploreSupportsLockedFolder
        context.unhide = owned && locked
        context.addTo = addTo(items, count: immich.count, owned: owned)
        context.moveTo = owned
        // Where they all live, which Move To does not offer; nothing inside the Locked Folder, nor for some of each.
        if !locked, !items.isEmpty {
            context.home = archived == items.count ? .archive : archived == 0 ? .library : nil
        }
        context.adjustDate = owned
        context.adjustLocation = owned
        context.adjustDescription = owned && one
        context.rating = owned && one && (ratingsEnabled ?? session.preferences?.ratings?.enabled ?? false)
        context.showInAllPhotos = owned && one && archived == 0 && canShowInLibrary
        context.showInArchive = owned && one && archived == 1 && canShowInArchive
        context.albumCover = one && canChangeAlbumCover
        context.stack = owned && immich.count > 1 && !locked
        context.removal = canRemove ? removalTitle : nil
        if canDelete(ids) {
            context.delete = deletesPermanently ? String(localized: "Delete Permanently") : String(localized: "Delete")
        }
        return context
    }

    /// Add To's choices: Immich lets the account add its own photos and its partners' to albums, and tag its own.
    private func addTo(_ items: [AssetItem], count: Int, owned: Bool) -> PhotoAddTo {
        guard source != .locked, session.lockedFolder == nil, count > 0, items.count == count else { return PhotoAddTo() }
        let userID = session.user?.id
        let partners = Set(session.sharing.receivedPartners.map(\.id))
        let allowed = owned || source.isPartner
            || items.allSatisfy { item in item.ownerId == userID || item.ownerId.map(partners.contains) == true }
        guard allowed else { return PhotoAddTo() }
        var addTo = PhotoAddTo()
        // An album whose owner the list leaves out counts as the account's own, as the albums page counts it.
        addTo.albums = session.albums.contains { !$0.shared && ($0.albumOwner.map { $0.id == userID } ?? true) }
        addTo.sharedAlbums = session.albums.contains { $0.shared && $0.canEdit(userID) }
        addTo.newAlbums = true
        addTo.tags = owned && session.exploreTagsEnabled
        return addTo
    }

    /// What taking photos out of the page is called: an album's, a link's or a memory's.
    var removalTitle: String? {
        if source.albumID != nil { return String(localized: "Remove from Album") }
        if source.linkID != nil { return String(localized: "Remove from Link") }
        if source.memoryID != nil { return String(localized: "Remove from Memory") }
        return nil
    }

    /// Photos come out of an album the account owns or may edit, as in Immich, and out of its links and memories.
    private var canRemove: Bool {
        guard let albumID = source.albumID else { return removalTitle != nil }
        let userID = session.user?.id
        if let details = session.albumActions.details[albumID] { return details.canEdit(userID) }
        return session.albums.first { $0.id == albumID }?.canEdit(userID) == true
    }

    /// An album's owner may change its cover, as in Immich.
    var canChangeAlbumCover: Bool {
        guard let albumID = source.albumID, let userID = session.user?.id else { return false }
        if let details = session.albumActions.details[albumID] { return details.isOwner(userID) }
        return session.albums.first { $0.id == albumID }?.albumOwner?.id == userID
    }

    /// Show in All Photos, for a photo that is not archived, from any page but the Library's own, Recently Deleted's
    /// and the Locked Folder's.
    var canShowInLibrary: Bool {
        chrome != nil && source != .library && source != .trash && source != .locked && session.lockedFolder == nil
    }

    /// Show in Archive, for an archived photo, from any page but the Archive's own, Recently Deleted's and the Locked
    /// Folder's.
    var canShowInArchive: Bool {
        chrome != nil && source != .archive && source != .trash && source != .locked && session.lockedFolder == nil
    }
}

/// The actions on a page's photos, for its toolbar and menus.
@MainActor struct GridActions {
    let model: AssetGridModel
    let session: LibrarySession
    let state: GridPageState
    let chrome: LibraryChrome?

    var source: GridSource { model.source }

    /// What applies to the page's photos, which the viewer shares.
    var rules: PhotoActionsRules { PhotoActionsRules(model: model, session: session, chrome: chrome) }
    var deletesPermanently: Bool { rules.deletesPermanently }
    var removalTitle: String? { rules.removalTitle }
    func split(_ ids: [String]) -> (immich: [String], phone: [String]) { rules.split(ids) }
    func canDelete(_ ids: [String]) -> Bool { rules.canDelete(ids) }

    /// What the menu offers for these photos here, with the ratings preference the page read.
    func context(for ids: [String], place: PhotoActionsPlace) -> PhotoActionsContext {
        rules.context(for: ids, place: place, ratingsEnabled: state.ratingsEnabled)
    }

    func endSelecting() {
        state.isSelecting = false
        model.selection = []
    }

    /// The photos a long press on a tile acts on: the selection when the tile is one of the photos selected, else the
    /// tile's photo.
    func pressed(_ id: String) -> [String] {
        state.isSelecting && model.selection.contains(id) ? model.selection.sorted() : [id]
    }

    /// Immich's photos among `ids`; the photos on their way an action of Immich's leaves out are said at the grid's
    /// foot.
    private func immichOnly(_ ids: [String]) -> [String] {
        let (immich, phone) = split(ids)
        if !phone.isEmpty {
            state.say(phone.count == 1 ? String(localized: "1 photo on its way to Immich was left out")
                : String(localized: "\(phone.count) photos on their way to Immich were left out"))
        }
        return immich
    }

    /// Whether Immich's actions can take the photos, those on their way left out.
    func canMutate(_ ids: [String]) -> Bool { model.canMutate(split(ids).immich) }

    // MARK: Doing it

    /// Does what was chosen in the menu for these photos.
    func perform(_ action: PhotoAction, on ids: [String]) {
        switch action {
        case .copy: copy(ids)
        case .saveToPhotos: saveToPhotos(ids)
        case .hide: moveToLockedFolder(ids)
        case .unhide: removeFromLockedFolder(ids)
        case .share: share(ids)
        case .favorite(let value): favorite(ids, value)
        case .addToAlbum(let shared): present(.addToAlbum(shared: shared), immichOnly(ids))
        case .newAlbum(let shared): present(.newAlbum(shared: shared), immichOnly(ids))
        case .tag: present(.tag, immichOnly(ids))
        case .move(let home): move(ids, to: home)
        case .adjustDate: present(.date, earliestFirst(immichOnly(ids)))
        case .adjustLocation: present(.location, immichOnly(ids))
        case .adjustDescription: present(.description, immichOnly(ids))
        case .rate(let stars): rate(immichOnly(ids), stars)
        case .showInAllPhotos: if let id = ids.first { showInLibrary(id) }
        case .showInArchive: if let id = ids.first { showInArchive(id) }
        case .useAsAlbumCover: if let id = ids.first { useAsAlbumCover(id) }
        case .stack: stack(ids)
        case .removeFromPage: requestRemoval(immichOnly(ids))
        case .delete: requestDelete(ids)
        case .restore: restore(ids)
        }
    }

    private func present(_ kind: PhotoActionSheet.Kind, _ ids: [String]) {
        guard !ids.isEmpty else { return }
        state.actionSheet = PhotoActionSheet(kind: kind, ids: ids)
    }

    /// Immich's photos by when they were taken, the earliest first, for Adjust Date & Time, which shows that one.
    private func earliestFirst(_ ids: [String]) -> [String] {
        ids.sorted { (model.item($0)?.date ?? .distantFuture) < (model.item($1)?.date ?? .distantFuture) }
    }

    func share(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        state.sharing = GridAssetIDs(ids: ids)
    }

    /// The originals on the pasteboard, said at the grid's foot while they download and once they are there.
    func copy(_ ids: [String]) {
        let (immich, phone) = split(ids)
        guard !ids.isEmpty else { return }
        let state = state
        let model = model
        let session = session
        state.say(ids.count == 1 ? String(localized: "Copying…") : String(localized: "Copying \(ids.count) Items…"), holds: true)
        Task {
            do {
                try await PhotoActionWork.copy(immich, phone: phone, client: session.client)
                state.say(ids.count == 1 ? String(localized: "Copied") : String(localized: "Copied \(ids.count) Items"))
            } catch {
                state.clearNotice()
                guard !error.isCancellation else { return }
                session.handle(error)
                model.lastError = error.localizedDescription
            }
        }
    }

    /// The originals into the phone's photo library, with one word when it is done.
    func saveToPhotos(_ ids: [String]) {
        let (immich, phone) = split(ids)
        guard !ids.isEmpty else { return }
        let state = state
        let model = model
        let session = session
        state.say(String(localized: "Saving to Photos…"), holds: true)
        Task {
            do {
                let saved = try await PhotoActionWork.saveToPhotos(immich, phone: phone.count, session: session)
                state.say(saved.words)
            } catch {
                state.clearNotice()
                guard !error.isCancellation else { return }
                session.handle(error)
                model.lastError = error.localizedDescription
            }
        }
    }

    /// Favourites in Immich, or in Photos for photos on their way, which their upload carries to Immich.
    func favorite(_ ids: [String], _ value: Bool) {
        let (immich, phone) = split(ids)
        if immich.isEmpty {
            Task { _ = await BackupCenter.shared.setFavorite(phone, value) }
            return
        }
        setFavorite(ids, value)
    }

    func setFavorite(_ ids: [String], _ value: Bool) {
        let ids = immichOnly(ids)
        Task { await model.setFavorite(ids, value) }
    }

    func setArchived(_ ids: [String], _ archived: Bool) {
        let ids = immichOnly(ids)
        endSelecting()
        Task { await model.setArchived(ids, archived) }
    }

    /// Move To: the library or the archive, from where each photo lives, the Locked Folder included; those already
    /// there stay as they are.
    func move(_ ids: [String], to home: PhotoHome) {
        let archiving = home == .archive
        if source == .locked {
            endSelecting()
            Task { await model.removeFromLockedFolder(ids, archiving: archiving) }
            return
        }
        let moving = split(ids).immich.filter { model.item($0)?.archived(on: source) != archiving }
        guard !moving.isEmpty else { return }
        setArchived(moving, archiving)
    }

    /// One to five stars, or none, as the viewer's details set them.
    func rate(_ ids: [String], _ stars: Int?) {
        guard !ids.isEmpty else { return }
        let session = session
        let model = model
        let update = stars.map { MetadataUpdate(ids: ids, rating: $0) } ?? MetadataUpdate(ids: ids, clearRating: true)
        Task {
            if !(await session.metadata.update(update, session: session)), let error = session.metadata.error {
                model.lastError = error
                session.metadata.error = nil
            }
        }
    }

    /// Asks before deleting Immich's photos; photos on their way alone go straight to iOS's own question.
    func requestDelete(_ ids: [String]) {
        let (immich, phone) = split(ids)
        if immich.isEmpty {
            guard !phone.isEmpty else { return }
            delete(ids)
            return
        }
        guard model.canDelete(immich) else { return }
        state.pendingDelete = GridAssetIDs(ids: ids)
    }

    /// Immich's photos deleted there, and photos on their way deleted from the phone, which iOS asks about.
    func delete(_ ids: [String]) {
        endSelecting()
        let (immich, phone) = split(ids)
        let permanently = deletesPermanently
        if !immich.isEmpty { Task { await model.delete(immich, permanently: permanently) } }
        if !phone.isEmpty { Task { _ = await BackupCenter.shared.deleteFromPhone(phone) } }
    }

    func restore(_ ids: [String]) {
        endSelecting()
        Task { await model.restore(ids) }
    }

    /// Hide, Photos' word: into Immich's Locked Folder, which the notice names, as Collections does.
    func moveToLockedFolder(_ ids: [String]) {
        let ids = immichOnly(ids)
        endSelecting()
        let state = state
        let model = model
        Task {
            guard await model.moveToLockedFolder(ids) else { return }
            state.say(ids.count == 1 ? String(localized: "Hidden in the Locked Folder")
                      : String(localized: "\(ids.count) Items Hidden in the Locked Folder"))
        }
    }

    func removeFromLockedFolder(_ ids: [String]) {
        endSelecting()
        Task { await model.removeFromLockedFolder(ids) }
    }

    func requestRemoval(_ ids: [String]) {
        guard !ids.isEmpty, removalTitle != nil else { return }
        state.pendingRemoval = GridAssetIDs(ids: ids)
    }

    func remove(_ ids: [String]) {
        endSelecting()
        if source.linkID != nil {
            Task { await model.removeFromLink(ids) }
        } else if source.memoryID != nil {
            Task { await model.removeFromMemory(ids) }
        } else if let albumID = source.albumID {
            let model = model
            session.albumActions.perform(session: session, albumID: albumID) { try await model.removeFromAlbum(ids) }
        }
    }

    func useAsAlbumCover(_ id: String) {
        guard let albumID = source.albumID else { return }
        let session = session
        endSelecting()
        session.albumActions.perform(session: session, albumID: albumID, reloadTimeline: false) {
            _ = try await session.client.updateAlbum(albumID, AlbumUpdate(albumThumbnailAssetId: id))
        }
    }

    func stack(_ ids: [String]) {
        let ids = immichOnly(ids)
        guard ids.count > 1, model.canMutate(ids) else { return }
        endSelecting()
        let model = model
        let session = session
        Task {
            do {
                _ = try await session.client.assetsCreateStack(ids)
                session.invalidateGrids()
                await model.reload()
            } catch {
                session.handle(error)
                model.lastError = error.localizedDescription
            }
        }
    }

    func showInLibrary(_ id: String) {
        endSelecting()
        chrome?.showInLibrary(id, from: model, session: session)
    }

    func showInArchive(_ id: String) {
        endSelecting()
        chrome?.showInArchive(id, from: model, session: session)
    }
}

/// The selection's bar along the bottom of the window while selecting, in the glass of iOS's own bars, as Photos has
/// it: Share, then Add To, Favorite and "..." with the menu of photo actions, then Delete; Restore and Delete in
/// Recently Deleted.
struct GridSelectionToolbar: ToolbarContent {
    let actions: GridActions

    var body: some ToolbarContent {
        let model = actions.model
        let ids = model.selection.sorted()
        if actions.source == .trash {
            ToolbarItem(placement: .bottomBar) {
                Button("Restore", systemImage: "arrow.uturn.backward") { actions.restore(ids) }
                    .disabled(!model.canDelete(ids))
            }
            ToolbarSpacer(.flexible, placement: .bottomBar)
            ToolbarItem(placement: .bottomBar) {
                Button("Delete", systemImage: "trash", role: .destructive) { actions.requestDelete(ids) }
                    .disabled(!model.canDelete(ids))
            }
        } else {
            let context = actions.context(for: ids, place: .selectionBar)
            ToolbarItem(placement: .bottomBar) {
                Button("Share", systemImage: "square.and.arrow.up") { actions.share(ids) }
                    .disabled(ids.isEmpty)
            }
            ToolbarSpacer(.flexible, placement: .bottomBar)
            ToolbarItemGroup(placement: .bottomBar) {
                if actions.source != .locked {
                    Menu {
                        PhotoAddToItems(addTo: context.addTo) { actions.perform($0, on: ids) }
                    } label: {
                        Label("Add To", systemImage: "rectangle.stack.badge.plus")
                    }
                    .menuOrder(.fixed)
                    .disabled(!context.addTo.any)
                }
                Button(context.allFavorite ? "Unfavorite" : "Favorite",
                       systemImage: context.allFavorite ? "heart.fill" : "heart") {
                    actions.favorite(ids, !context.allFavorite)
                }
                .disabled(!context.favorite)
                Menu {
                    PhotoActionsMenu(context: context) { actions.perform($0, on: ids) }
                } label: {
                    Label("More", systemImage: "ellipsis")
                }
                // In the menu's own order, the quick actions on top, as a long press shows it, rather than nearest the bar.
                .menuOrder(.fixed)
                .disabled(context.isEmpty)
            }
            ToolbarSpacer(.flexible, placement: .bottomBar)
            ToolbarItem(placement: .bottomBar) {
                Button("Delete", systemImage: "trash", role: .destructive) { actions.requestDelete(ids) }
                    .disabled(!actions.canDelete(ids))
            }
        }
    }
}

/// The long press's menu on a tile: the menu of photo actions for that photo, or for the selection when it is one of
/// the photos selected.
struct GridTileMenu: View {
    let actions: GridActions
    let asset: AssetItem

    var body: some View {
        let ids = actions.pressed(asset.id)
        PhotoActionsMenu(context: actions.context(for: ids, place: .tile)) { actions.perform($0, on: ids) }
    }
}

/// The long press's menu on a photo on its way to Immich: Copy, Share, Favorite and Delete from the phone, which iOS
/// asks about; for the selection when it is one of the photos selected, where Immich's actions take the rest.
struct PhoneTileMenu: View {
    let actions: GridActions
    let photo: BackupWaitingPhoto

    var body: some View {
        let ids = actions.pressed(photo.gridID)
        PhotoActionsMenu(context: actions.context(for: ids, place: .tile)) { actions.perform($0, on: ids) }
    }
}

/// The sheets the menu's actions open over a grid, and what the menu reads as the page first shows: the account's
/// ratings and tags preferences.
struct PhotoActionsPresentation: ViewModifier {
    let session: LibrarySession
    let actions: GridActions

    func body(content: Content) -> some View {
        @Bindable var state = actions.state
        content
            .sheet(item: $state.actionSheet) { sheet in
                PhotoActionSheetView(session: session, sheet: sheet) { words in
                    actions.endSelecting()
                    if let words { state.say(words) }
                }
            }
            .task {
                await state.loadRatingsPreference(session)
                await session.loadExploreTags()
            }
    }
}

extension GridActions {
    /// "3 Photos Selected", as Photos counts a selection; "Select Items" before the first.
    var selectionTitle: String {
        let model = model
        let count = model.selection.count
        guard count > 0 else { return "Select Items" }
        let phone = Set(split(Array(model.selection)).phone)
        let phoneVideos = BackupCenter.shared.libraryTiles.filter { phone.contains($0.photo.localID) && $0.photo.isVideo }.count
        let videos = model.selectedItems.filter(\.isVideo).count + phoneVideos
        if videos == 0 { return count == 1 ? "1 Photo Selected" : "\(count) Photos Selected" }
        if videos == count { return count == 1 ? "1 Video Selected" : "\(count) Videos Selected" }
        return "\(count) Items Selected"
    }

    /// The delete question's title, as the Mac asks it.
    func deleteTitle(_ count: Int) -> String {
        let noun = count == 1 ? "Item" : "\(count) Items"
        return deletesPermanently ? "Permanently Delete \(noun)?" : "Delete \(noun)?"
    }

    /// The delete question's message; photos on their way among them are deleted from the phone, which iOS asks
    /// about after.
    func deleteMessage(_ ids: [String]) -> String {
        let immich = deletesPermanently ? "This can't be undone." : "Items are moved to Recently Deleted."
        let phone = split(ids).phone.count
        guard phone > 0 else { return immich }
        return immich + " " + (phone == 1 ? "The photo on its way to Immich is deleted from this \(DeviceWords.model)."
            : "The \(phone) photos on their way to Immich are deleted from this \(DeviceWords.model).")
    }
}
