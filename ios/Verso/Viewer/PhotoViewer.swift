// The photo viewer on iOS, as Photos has it: the grid's photos full screen, swiped through left and right in the grid's
// order (ViewerPager), shown in place over the grid, the photo flying out of its tile and back, or dragged down back
// into it (ViewerHost), and pinched to zoom. A tap hides every control, leaving the photo on black. The controls are
// glass, in bars of the viewer's own where the system's would be, so they fade where they stand as it opens, closes and
// is tapped (the system's slide, and take no touch while they do): at the top Back, the place over the day and time in
// one capsule, and More; under Back a
// Live Photo's LIVE badge, and under More a stacked photo's badge, which opens its stack (ViewerStackSheet); above the
// bottom bar a filmstrip of the photos beside it; along the bottom Share, then Favorite, Info and Edit together, then
// Delete, or Restore and Delete Permanently in Recently Deleted. Edit turns and crops the picture
// (ViewerPictureEditor). A swipe up or Info slides the photo up with its details beneath (ViewerDetails). More is the
// menu of photo actions a long press on a tile shows (PhotoActionsMenu), for the photo shown, with Start Slideshow;
// what the bar holds it leaves to the bar. Deleting, archiving or hiding a photo shows the next one, through the
// grid's model, so the grids change with it.

import SwiftUI
import UIKit

struct PhotoViewer: View {
    let session: LibrarySession
    /// The grid it opened from, whose photos it pages through.
    let model: AssetGridModel
    /// The host it is shown in, which closes it.
    let host: ViewerHost
    @State private var state: ViewerState
    @State private var confirmingDelete = false
    @State private var copying = false
    /// The originals going into the phone's photo library (Save to Photos), and the last time they arrived.
    @State private var saving = false
    @State private var saved = 0
    /// Add To's albums and tags, from the menu of photo actions.
    @State private var actionSheet: PhotoActionSheet?
    /// The photo in the share sheet.
    @State private var sharing: GridAssetIDs?
    @State private var actionError: String?
    /// Look Up Place Names with Apple Maps, from the account's sheet: off, places are named from Immich's data alone.
    @AppStorage(ViewerPlaceNames.appleMapsKey) private var looksUpPlaceNames = false
    @Environment(LibraryChrome.self) private var chrome: LibraryChrome?
    @Environment(\.pushRoute) private var pushRoute

    /// The state says which photo it opens on and whether the grid shows the model's photos last to first
    /// (ViewerState.readsBackwards); the host shares it, for the photo's flight and its drag.
    init(state: ViewerState, host: ViewerHost) {
        session = state.session
        model = state.model
        self.host = host
        _state = State(initialValue: state)
    }

    var body: some View {
        @Bindable var state = state
        let titles = titles
        NavigationStack(path: $state.detailsPath) {
            ZStack {
                ViewerStage(state: state, modelRevision: modelRevision)
                controls(titles)
            }
            // For UI tests, which ask whether a viewer shows.
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("Viewer")
            .navigationTitle(titles.title)
            .navigationBarTitleDisplayMode(.inline)
            // The bars are the viewer's own (`controls`); the pages its details open have the system's.
            .toolbar(.hidden, for: .navigationBar)
            // The stage draws the backdrop, which fades in and out with the viewer.
            .containerBackground(.clear, for: .navigation)
            .statusBarHidden(state.isOpen && (!state.chromeVisible || state.detailsActive))
            .persistentSystemOverlays(state.chromeVisible ? .automatic : .hidden)
            .navigationDestination(for: ViewerDetailsRoute.self) { route in destination(route) }
            .sheet(item: $state.presented) { presentation in
                ViewerPresentationSheet(state: state, presentation: presentation)
            }
            .sheet(item: $actionSheet) { sheet in
                PhotoActionSheetView(session: session, sheet: sheet) { _ in }
            }
            .shareSheet(item: $sharing) { request in shareContent(request.ids) }
            .sensoryFeedback(.success, trigger: saved)
            .fullScreenCover(item: $state.editing) { asset in
                ViewerPictureEditor(session: session, asset: asset)
            }
            .fullScreenCover(isPresented: $state.slideshowShown) {
                ViewerSlideshow(state: state) { item in
                    state.slideshowShown = false
                    if let item { state.jump(to: item) }
                }
            }
            // A viewer opened from the details' pages (a person's photos, say) shows over this one.
            .alert("Something Went Wrong", isPresented: errorShown) {
                Button("OK") {}
            } message: {
                Text(model.lastError ?? actionError ?? "")
            }
            .alert("Can't Change the Album", isPresented: albumErrorShown) {
                Button("OK") {}
            } message: {
                Text(session.albumActions.error ?? "")
            }
        }
        .viewerHost()
        .onAppear(perform: start)
        .onDisappear { state.stop() }
        .task(id: "\(state.currentID)|\(session.metadata.revision)|\(state.detailsAttempt)") {
            await state.loadDetails()
        }
        .task(id: placeKey) {
            if looksUpPlaceNames { await state.lookUpPlaceName() }
        }
        .task(id: state.currentID) { await state.loadRatingsPreference() }
        // A video's title in Now Playing is the capsule's, kept as its place is found.
        .onChange(of: [state.currentID, titles.title], initial: true) { _, named in
            guard state.currentItem?.isVideo == true else { return }
            state.video.nameForNowPlaying(named[1], itemID: named[0])
        }
    }

    private func start() {
        let host = host
        state.start(close: { host.close() })
        // Where the viewer opened from a tab's page, the details' people, albums and tags open on that tab's stack,
        // as a link there does, once the viewer has closed into its tile; the Locked Folder keeps them inside the
        // viewer.
        if chrome != nil, session.lockedFolder == nil {
            let push = pushRoute
            state.openInTab = { route in
                host.close { push(route) }
            }
        }
    }

    // MARK: Title

    /// As Photos titles a photo: its place over the day and time; with no place, the day over the time. The place is
    /// Immich's most precise name for it, its city, else its state or country, as the Mac's details name it; with Look
    /// Up Place Names with Apple Maps on, the point of interest Apple's maps name there comes first.
    private var titles: (title: String, subtitle: String) {
        guard let item = state.currentItem else { return ("", "") }
        let details = state.currentDetails
        let exif = details?.exifInfo
        let named = looksUpPlaceNames ? details.flatMap { state.placeName(for: $0) } : nil
        let place = [named, exif?.city, exif?.state, exif?.country, item.city].compactMap { $0 }.first { !$0.isEmpty }
        guard let date = details.flatMap({ ImmichDate.parse($0.localDateTime) }) ?? item.date else { return (place ?? "", "") }
        let day = ViewerDays.name(date)
        if let place { return (place, day + " " + ImmichDate.time(date)) }
        return (day, ImmichDate.time(date))
    }

    /// The shown photo and its coordinates, so the place is asked for again once they are known or changed, or once
    /// Apple's names are switched on.
    private var placeKey: String {
        let exif = state.currentDetails?.exifInfo
        return "\(state.currentID)|\(exif?.latitude ?? 0)|\(exif?.longitude ?? 0)|\(looksUpPlaceNames)"
    }

    /// Changes as the model's months load or change, for the pager to ask for the neighbours again.
    private var modelRevision: Int {
        var hasher = Hasher()
        for section in model.sections {
            hasher.combine(section.id)
            hasher.combine(section.count)
            hasher.combine(section.assets == nil)
        }
        return hasher.finalize()
    }

    // MARK: Controls

    private var currentIDs: [String] { [state.currentID] }

    /// The controls, in Photos' places: the top bar, the LIVE badge under Back and the stack's badge under More, the
    /// filmstrip above the bottom bar (for a video, its bar: ViewerVideoBar), and the bottom bar. They show while the viewer is open and the controls are, and
    /// none while a drag down or a pinch takes the photo away; with the details up, the bottom bar alone. Fading in, they take
    /// touches from its first moment.
    private func controls(_ titles: (title: String, subtitle: String)) -> some View {
        let shown = state.isOpen && state.chromeVisible && state.closeDrag == nil && state.closePinch == nil
        let topShown = shown && !state.detailsActive
        return VStack(spacing: 0) {
            topBar(titles)
                .opacity(topShown ? 1 : 0)
                .allowsHitTesting(topShown)
            HStack(alignment: .top, spacing: 0) {
                if topShown, let item = state.currentItem, item.livePhotoVideoID != nil {
                    ViewerLiveBadge(state: state, item: item)
                        .transition(.opacity)
                }
                Spacer(minLength: 0)
                if topShown, let count = state.stackCount, count > 1 {
                    ViewerStackBadge(count: count) { state.showStack() }
                        .disabled(state.currentDetails?.stack == nil)
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, 16)
            // Where they were under the system's bar, which reached 10 points below its buttons.
            .padding(.top, 18)
            .overlay(alignment: .top) {
                if topShown, let notice = state.liveNotice {
                    ViewerLiveNotice(state: state, notice: notice)
                        .padding(.top, 8)
                        .transition(.opacity)
                }
            }
            Spacer(minLength: 0)
            if topShown, state.currentItem?.isVideo == true {
                // Its ends line up with the bottom bar's, 28 points from the edges.
                ViewerVideoBar(video: state.video) { state.fadeChromeForVideo() }
                    .padding(.horizontal, 28)
                    .padding(.bottom, 12)
                    .transition(.opacity)
            } else if topShown, model.totalCount > 1 {
                ViewerFilmstrip(state: state)
                    .padding(.bottom, 10)
                    .transition(.opacity)
            }
            bottomBar
                .opacity(shown ? 1 : 0)
                .allowsHitTesting(shown)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// Back, the place and day in their capsule, and More, where the system's bar has them: glass circles of 44 points,
    /// 20 from the edges, at the top of the safe area (as the system's bar has them on an iPhone 17 Pro Max).
    private func topBar(_ titles: (title: String, subtitle: String)) -> some View {
        HStack(spacing: 8) {
            Button("Back", systemImage: "chevron.backward") { host.close() }
                .modifier(ViewerBarCircle(size: 44))
            Spacer(minLength: 0)
            ViewerTitleCapsule(title: titles.title, subtitle: titles.subtitle) { state.toggleDetails() }
            Spacer(minLength: 0)
            moreMenu
                .modifier(ViewerBarCircle(size: 44))
        }
        .padding(.horizontal, 20)
        .frame(height: 44)
    }

    /// Share, then Favorite, Info and Edit in one capsule, then Delete, where the system's bottom bar has them: circles
    /// of 48 points, 28 from the edges, their foot 6 points into the bottom safe area; in Recently Deleted, Restore, Info
    /// and Delete Permanently.
    private var bottomBar: some View {
        HStack(spacing: 0) {
            if model.source == .trash {
                restoreButton.modifier(ViewerBarCircle(size: 48))
                Spacer(minLength: 0)
                infoButton.modifier(ViewerBarCircle(size: 48))
                Spacer(minLength: 0)
                deleteButton.modifier(ViewerBarCircle(size: 48))
            } else {
                shareButton.modifier(ViewerBarCircle(size: 48))
                Spacer(minLength: 0)
                HStack(spacing: 0) {
                    favoriteButton.modifier(ViewerBarItem(width: 55, height: 48))
                    infoButton.modifier(ViewerBarItem(width: 56, height: 48))
                    editButton.modifier(ViewerBarItem(width: 55, height: 48))
                }
                .glassEffect(.regular.interactive(), in: .capsule)
                Spacer(minLength: 0)
                deleteButton.modifier(ViewerBarCircle(size: 48))
            }
        }
        .padding(.horizontal, 28)
        .frame(height: 48)
        .padding(.bottom, -6)
    }

    /// The share sheet for the photo shown, as a grid's (ShareSheet.swift): its original downloads only once an app in
    /// the sheet takes it, and Create Link… and Add to Link… are beside the apps where they apply.
    private var shareButton: some View {
        Button("Share", systemImage: "square.and.arrow.up") { sharing = GridAssetIDs(ids: [state.currentID]) }
            .disabled(state.currentItem == nil)
    }

    /// What Share shares of the photo shown: as the grid decides it, the original under its own name and in its own
    /// format once the photo's details have loaded.
    private func shareContent(_ ids: [String]) -> ShareContent {
        var content = PhotoActionsRules(model: model, session: session, chrome: chrome).shareContent(ids)
        if let item = state.currentItem, ids == [item.id], let details = state.currentDetails {
            let original = ViewerOriginal(item: item, details: details, client: session.client)
            content.originals = [ShareOriginal(id: item.id, isVideo: item.isVideo, name: original.name, type: original.type)]
        }
        return content
    }

    private var favoriteButton: some View {
        let favorite = state.currentItem?.isFavorite == true
        return Button(favorite ? "Unfavorite" : "Favorite", systemImage: favorite ? "heart.fill" : "heart") {
            // In Favorites, unfavoriting takes the photo out of the grid, and the next one shows.
            leave { id in await model.setFavorite([id], !favorite) }
        }
        .contentTransition(.symbolEffect(.replace))
        .disabled(!model.canMutate(currentIDs))
    }

    private var infoButton: some View {
        Button("Info", systemImage: state.showsDetails ? "info.circle.fill" : "info.circle") {
            state.toggleDetails()
        }
    }

    /// Photos' Edit: the editor that turns and crops the picture, for the photos Immich can edit.
    private var editButton: some View {
        Button("Edit", systemImage: "slider.horizontal.3") { state.edit() }
            .disabled(!state.canEditPicture)
    }

    private var deleteButton: some View {
        Button(deletesPermanently ? "Delete Permanently" : "Delete", systemImage: "trash") { confirmingDelete = true }
            .disabled(!model.canDelete(currentIDs))
            .confirmationDialog(deleteActionTitle, isPresented: $confirmingDelete, titleVisibility: .hidden) {
                Button(deleteActionTitle, role: .destructive) {
                    let permanently = deletesPermanently
                    leave { id in await model.delete([id], permanently: permanently) }
                }
            } message: {
                Text(deleteMessage)
            }
    }

    private var restoreButton: some View {
        Button("Restore", systemImage: "arrow.uturn.backward") {
            leave { id in await model.restore([id]) }
        }
        .disabled(!model.canDelete(currentIDs))
    }

    // MARK: More

    /// More: the menu of photo actions every place shares (PhotoActionsMenu), for the photo shown, with the slideshow
    /// among the page's own; Share, Favorite and Delete are the bar's.
    private var moreMenu: some View {
        Menu {
            PhotoActionsMenu(context: actionsContext, perform: perform) {
                Button("Start Slideshow", systemImage: "play.rectangle") { state.slideshowShown = true }
                    .disabled(state.currentItem == nil)
            }
        } label: {
            if copying || saving {
                ProgressView()
            } else {
                Label("More", systemImage: "ellipsis")
            }
        }
    }

    /// What the menu offers for the photo shown, by the grid's rules: Remove from Album alone of the page's removals,
    /// and the photo's own rating ticked.
    private var actionsContext: PhotoActionsContext {
        var context = PhotoActionsRules(model: model, session: session, chrome: chrome)
            .context(for: [state.currentID], place: .viewer, ratingsEnabled: state.ratingsEnabled)
        if model.source.albumID.map(canEditAlbum) != true { context.removal = nil }
        context.currentRating = state.currentDetails?.exifInfo?.rating ?? 0
        if copying || saving {
            context.copy = false
            context.saveToPhotos = false
        }
        return context
    }

    private func perform(_ action: PhotoAction) {
        let id = state.currentID
        switch action {
        case .copy: copyCurrent()
        case .saveToPhotos: saveCurrent()
        case .hide: leave { id in await model.moveToLockedFolder([id]) }
        case .unhide: leave { id in await model.removeFromLockedFolder([id]) }
        case .move(let home):
            let model = model
            leave { id in
                if model.source == .locked {
                    await model.removeFromLockedFolder([id], archiving: home == .archive)
                } else {
                    await model.setArchived([id], home == .archive)
                }
            }
        case .addToAlbum(let shared): actionSheet = PhotoActionSheet(kind: .addToAlbum(shared: shared), ids: [id])
        case .newAlbum(let shared): actionSheet = PhotoActionSheet(kind: .newAlbum(shared: shared), ids: [id])
        case .tag: actionSheet = PhotoActionSheet(kind: .tag, ids: [id])
        case .adjustDate: if let details = state.currentDetails { state.present(.date(details)) }
        case .adjustLocation: if let details = state.currentDetails { state.present(.location(details)) }
        case .adjustDescription: state.editCaption()
        case .rate(let stars): rate(stars)
        case .showInAllPhotos: showInLibrary()
        case .showInArchive: showInArchive()
        case .useAsAlbumCover: useAsAlbumCover(id)
        case .removeFromPage: if let albumID = model.source.albumID { removeFromAlbum(albumID) }
        // The viewer's bar holds them; the menu leaves them to it.
        case .share, .favorite, .delete, .restore, .stack: break
        }
    }

    /// The shown photo's stars, as the details' stars set them.
    private func rate(_ stars: Int?) {
        let id = state.currentID
        let update = stars.map { MetadataUpdate(ids: [id], rating: $0) } ?? MetadataUpdate(ids: [id], clearRating: true)
        let session = session
        Task { _ = await session.metadata.update(update, session: session) }
    }

    /// The album the grid shows, with the shown photo as its cover.
    private func useAsAlbumCover(_ id: String) {
        guard let albumID = model.source.albumID else { return }
        let session = session
        session.albumActions.perform(session: session, albumID: albumID, reloadTimeline: false) {
            _ = try await session.client.updateAlbum(albumID, AlbumUpdate(albumThumbnailAssetId: id))
        }
    }

    // MARK: Actions

    /// Locked items skip Recently Deleted, as in Immich, and a server without a trash deletes at once.
    private var deletesPermanently: Bool {
        model.source == .trash || model.source == .locked || !session.features.trash
    }

    private var deleteActionTitle: String {
        if deletesPermanently { return String(localized: "Delete Permanently") }
        return state.currentItem?.isVideo == true ? String(localized: "Delete Video") : String(localized: "Delete Photo")
    }

    private var deleteMessage: String {
        let isVideo = state.currentItem?.isVideo == true
        if deletesPermanently {
            return isVideo ? String(localized: "This video will be deleted permanently. This can't be undone.")
                : String(localized: "This photo will be deleted permanently. This can't be undone.")
        }
        return isVideo ? String(localized: "This video will be moved to Recently Deleted.")
            : String(localized: "This photo will be moved to Recently Deleted.")
    }

    /// Runs an action on the shown photo that may take it out of the grid; the next photo then shows.
    private func leave(_ action: @escaping @MainActor (String) async -> Void) {
        let state = state
        Task { await state.performLeaving(action) }
    }

    /// The shown photo's original into the phone's photo library, as the grid's Save to Photos.
    private func saveCurrent() {
        let id = state.currentID
        let session = session
        saving = true
        Task {
            do {
                _ = try await PhotoActionWork.saveToPhotos([id], phone: 0, session: session)
                saved += 1
            } catch where !error.isCancellation {
                session.handle(error)
                actionError = error.localizedDescription
            } catch {}
            saving = false
        }
    }

    private func copyCurrent() {
        guard let item = state.currentItem else { return }
        let original = ViewerOriginal(item: item, details: state.currentDetails, client: session.client)
        copying = true
        Task {
            do {
                try await original.copyToPasteboard()
            } catch where !error.isCancellation {
                session.handle(error)
                actionError = error.localizedDescription
            } catch {}
            copying = false
        }
    }

    /// The Library tab at its own page, scrolled to the photo, as the grid's Show in All Photos; the viewer closes.
    private func showInLibrary() {
        guard let chrome else { return }
        let id = state.currentID
        host.close()
        chrome.showInLibrary(id, from: model, session: session)
    }

    /// The Archive at the photo, as the grid's Show in Archive; the viewer closes.
    private func showInArchive() {
        guard let chrome else { return }
        let id = state.currentID
        host.close()
        chrome.showInArchive(id, from: model, session: session)
    }

    private func canEditAlbum(_ albumID: String) -> Bool {
        let userID = session.user?.id
        if let details = session.albumActions.details[albumID] { return details.canEdit(userID) }
        return session.albums.first { $0.id == albumID }?.canEdit(userID) == true
    }

    /// Takes the photo out of the album the grid shows, as the Mac's Remove from Album; it stays in the library.
    private func removeFromAlbum(_ albumID: String) {
        let session = session
        let model = model
        leave { id in
            do {
                try await model.removeFromAlbum([id])
            } catch {
                session.handle(error)
                session.albumActions.error = error.localizedDescription
            }
            session.invalidateAlbumGrid(albumID)
            await session.reloadAlbums()
        }
    }

    // MARK: Pages inside the viewer

    @ViewBuilder
    private func destination(_ route: ViewerDetailsRoute) -> some View {
        switch route {
        case .person(let id, let name):
            AssetGridPage(session: session, source: .person(id), title: name.isEmpty ? String(localized: "Unnamed Person") : name)
        case .album(let album):
            AlbumPage(session: session, album: album)
        case .tag(let id, let name):
            AssetGridPage(session: session, source: .explore(.tag(id)), title: name)
        case .place(let latitude, let longitude, let title):
            ViewerPlaceMap(latitude: latitude, longitude: longitude, title: title)
        }
    }

    // MARK: Alerts

    private var errorShown: Binding<Bool> {
        Binding(get: { model.lastError != nil || actionError != nil },
                set: { shown in
                    if !shown {
                        model.lastError = nil
                        actionError = nil
                    }
                })
    }

    private var albumErrorShown: Binding<Bool> {
        Binding(get: { session.albumActions.error != nil },
                set: { shown in if !shown { session.albumActions.error = nil } })
    }
}
