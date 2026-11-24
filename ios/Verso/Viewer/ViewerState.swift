// The photo viewer's state on iOS: the photo it shows, its glass controls shown or hidden, its details pulled up under
// it or not (and how far a finger has pulled them), the photo's details from the server, and the way to the photos
// beside it, in the grid's order, read from the grid's model (AssetGridModel) as its months load. The pager
// (ViewerPager) shows the pages; this decides which photo is where. A photo's place is named from Immich's own data;
// Apple's maps are asked for a landmark's name only once the person has switched that on (ViewerPlaceNames).

import MapKit
import SwiftUI

/// A sheet over the viewer: editing the date or the place, or the photo's stack.
enum ViewerPresentation: Identifiable {
    case date(AssetResponse)
    case location(AssetResponse)
    /// The stack the shown photo is in, by its id.
    case stack(String)

    var id: String {
        switch self {
        case .date(let asset): "date|" + asset.id
        case .location(let asset): "location|" + asset.id
        case .stack(let id): "stack|" + id
        }
    }
}

/// The account sheet's Look Up Place Names with Apple Maps, kept on this device and off until switched on. Off, a
/// photo's place is named from Immich's own data alone (its city, state and country, as on the Mac), and nothing is
/// sent to Apple; on, the title names the landmark or street Apple's maps find at the photo's coordinates, as Photos
/// does, which sends those coordinates to Apple.
enum ViewerPlaceNames {
    static let appleMapsKey = "viewer.lookUpPlaceNames"

    static var looksUpWithAppleMaps: Bool { UserDefaults.standard.bool(forKey: appleMapsKey) }
}

@MainActor @Observable
final class ViewerState {
    let session: LibrarySession
    let model: AssetGridModel
    /// The grid shows the model's photos last to first: the timeline's months and photos come newest first, and the
    /// grid has the newest at the bottom, as Photos has. The photo to the right is then the one before it in the model.
    let readsBackwards: Bool
    /// The photo shown.
    private(set) var currentID: String
    /// The glass controls, which a tap hides and shows.
    var chromeVisible = true
    /// The video playing, which its page hands over, and the video bar shows (ViewerVideo.swift).
    let video = ViewerVideoPlayback()
    /// The fade of the chrome a moment after Play, called off by any other change to it.
    @ObservationIgnored private var chromeFade: Task<Void, Never>?
    /// The viewer is in, shown in place over its grid (ViewerHost): its backdrop and controls show, fading in as it
    /// opens and out as it closes, while `flight` carries the photo between its tile and its place.
    var isOpen = false
    /// The photo's flight out of its tile or back into it: a picture of it stands in for its page until it lands.
    var flight: ViewerFlight?
    /// A finger dragging the photo down to close the viewer: how far it has moved, in points.
    private(set) var closeDrag: CGSize?
    /// A pinch taking the photo below its fitted size to close the viewer: its scale, while it does.
    private(set) var closePinch: CGFloat?
    /// The details are up under the photo, scrolled there or brought by Info; the stage scrolls to them, or back to
    /// the photo alone, as this changes (ViewerStage).
    private(set) var showsDetails = false
    /// The details are shown, being scrolled, or going away: what they show loads, and the swipe down that closes the
    /// viewer waits.
    private(set) var detailsActive = false
    /// The shown photo is zoomed in.
    private(set) var isZoomed = false
    /// Add to Album, a new album, an edit of the date or place, or the stack, over the viewer.
    var presented: ViewerPresentation?
    /// The photo in the editor (Edit in the bottom bar), which turns and crops it.
    var editing: AssetResponse?
    /// The slideshow, from More, from the shown photo on.
    var slideshowShown = false
    /// Whether Live Photos move as a swipe brings them: one switch for all of them, any Live Photo's LIVE badge, kept on
    /// this device. Off, they stay still while swiping and still play whole while pressed, as Photos' Live Photos do
    /// with the system's Auto-Play Video Previews off.
    private(set) var livePhotosMove = !UserDefaults.standard.bool(forKey: ViewerState.livePhotosStillKey)
    static let livePhotosStillKey = "viewer.livePhotosStill"
    /// The switch just changed: a short notice says so, as the Camera's LIVE and LIVE OFF do.
    private(set) var liveNotice: LiveNotice?
    /// The Live Photo whose motion is still loading for a play the person asked for: its badge shows it waiting.
    var liveLoading: String?
    /// Live Photos whose motion could not be read: their badge says they cannot play.
    var liveUnavailable: Set<String> = []
    /// Adjust Info's Description: the photo whose caption field takes the keyboard once the details show.
    var captionFocusID: String?
    /// The shown photo's details from the server, as the Mac's inspector keeps them: only the requested photo's
    /// answer is taken.
    var inspector = AssetInspectorState()
    /// Counts Try Again in the details, so they load again.
    var detailsAttempt = 0
    /// The names Apple's maps give the photos' places, by their coordinates: a point of interest or a street, for
    /// the title, with Look Up Place Names with Apple Maps on.
    private(set) var placeNames: [String: String] = [:]
    /// Whether the account has ratings on in Immich, as read when the viewer opened.
    private var ratingsPreference: Bool?
    /// The pages the details opened inside the viewer, where the tab's own stack cannot be reached.
    var detailsPath: [ViewerDetailsRoute] = []

    /// The shown photo as last seen in the model, for while the model reads its months again after a change.
    @ObservationIgnored private var lastItem: AssetItem?
    /// The month the shown photo was last found in, to load it again after the model has read itself again.
    @ObservationIgnored private var lastSectionID: String?
    /// The pager's way to show another photo: the photo, the direction it comes from (1 from the right), and whether
    /// it slides in.
    @ObservationIgnored var showPage: ((AssetItem, Int, Bool) -> Void)?
    /// The pager's way to play the shown Live Photo.
    @ObservationIgnored var playLivePhoto: (() -> Void)?
    /// The pager's way to stop the shown Live Photo playing, and to load its motion, switched on again.
    @ObservationIgnored var stopLivePhoto: (() -> Void)?
    @ObservationIgnored var loadLivePhoto: (() -> Void)?
    /// The pager's way to find where the shown photo's picture is in its window, as it is drawn.
    @ObservationIgnored var pictureFrame: (() -> CGRect?)?
    /// The pager's way to ready the shown page for its flight into its tile (true) or back from a drag let go (false).
    @ObservationIgnored var closingZoom: ((Bool) -> Void)?
    /// Closes the viewer, back into the grid.
    @ObservationIgnored private var close: () -> Void = {}
    /// The session's way to close a viewer before this one showed (a viewer opened from this one's details), given
    /// back when this one goes.
    @ObservationIgnored private var previousCloseViewer: (() -> Void)?
    @ObservationIgnored private var prefetchTask: Task<Void, Never>?
    @ObservationIgnored private var relocateTask: Task<Void, Never>?
    /// The photo an action is taking out of the grid, which is not looked for again when the model lets it go.
    @ObservationIgnored private var leavingID: String?
    /// Places already asked of Apple's maps, by their coordinates, named or not, so paging back asks no more.
    @ObservationIgnored private var placesAsked: Set<String> = []
    /// Opens a page on the stack of the tab the viewer was opened from, closing the viewer, where it can be reached.
    @ObservationIgnored var openInTab: ((Route) -> Void)?

    /// The scroll to the details and back, as Info, the title or a tap on the photo brings them or sends them away.
    static let detailsAnimation = Animation.spring(duration: 0.42, bounce: 0.12)

    init(session: LibrarySession, model: AssetGridModel, startID: String, readsBackwards: Bool) {
        self.session = session
        self.model = model
        self.readsBackwards = readsBackwards
        currentID = startID
        video.ended = { [weak self] in self?.videoEnded() }
    }

    /// The shown photo, from the model, or as last seen while the model has not loaded it again.
    var currentItem: AssetItem? {
        if let item = model.item(currentID) { return item }
        return lastItem?.id == currentID ? lastItem : nil
    }

    /// The shown photo's details, once they are its own.
    var currentDetails: AssetResponse? {
        guard let asset = inspector.asset, asset.id == currentID else { return nil }
        return asset
    }

    // MARK: Showing and leaving

    /// The viewer shows: the grid's model knows which photo is open, as on the Mac, and a photo removed from the
    /// grids elsewhere (moved to the Locked Folder, say) makes way for its neighbour.
    func start(close: @escaping () -> Void) {
        self.close = close
        if let item = model.item(currentID) { lastItem = item }
        model.viewerID = currentID
        if previousCloseViewer == nil { previousCloseViewer = session.closeViewer }
        session.closeViewer = { [weak self] in self?.currentPhotoLeaving() }
        prefetchNeighbours()
        // Originals downloaded for copying, from earlier, which the system has taken its copies of.
        Task.detached { MacTransferCache.prune() }
    }

    /// The viewer has gone: the grid scrolls to the photo it closed on, and a video it played leaves Now Playing.
    func stop() {
        video.end()
        session.closeViewer = previousCloseViewer ?? {}
        previousCloseViewer = nil
        prefetchTask?.cancel()
        relocateTask?.cancel()
        if model.viewerID == currentID {
            model.viewerScrollTarget = currentID
            model.viewerID = nil
        }
    }

    /// The pager has settled on a photo, by a swipe or by being sent there.
    func settle(on item: AssetItem) {
        lastItem = item
        guard item.id != currentID else { return }
        currentID = item.id
        model.viewerID = item.id
        prefetchNeighbours()
    }

    /// Goes straight to a photo, as a tap in the filmstrip or the end of a slideshow does.
    func jump(to item: AssetItem) {
        guard item.id != currentID else { return }
        var step = 1
        if let target = model.order(of: item.id), let shown = model.order(of: currentID) {
            let later = (target.section, target.item) > (shown.section, shown.item)
            step = later != readsBackwards ? 1 : -1
        }
        showPage?(item, step, false)
    }

    /// The shown photo fitted to a screen of `size`, as its page draws it before it is zoomed.
    func fittedFrame(in size: CGSize) -> CGRect {
        let ratio = CGFloat(max(currentItem?.ratio ?? 1, 0.01))
        var fitted = CGSize(width: size.width, height: size.width / ratio)
        if fitted.height > size.height { fitted = CGSize(width: size.height * ratio, height: size.height) }
        return CGRect(x: (size.width - fitted.width) / 2, y: (size.height - fitted.height) / 2,
                      width: fitted.width, height: fitted.height)
    }

    /// Where the shown photo is drawn on a screen of `size`, for its flight home: where a drag has taken it, else as its
    /// page draws it (zoomed in, say), else fitted.
    func drawnFrame(in size: CGSize) -> CGRect {
        let fitted = fittedFrame(in: size)
        if closePinch != nil, let drawn = pictureFrame?() { return drawn }
        if let closeDrag {
            let scale = Self.closeDragScale(closeDrag, height: size.height)
            return CGRect(x: size.width / 2 + (fitted.minX - size.width / 2) * scale + closeDrag.width,
                          y: size.height / 2 + (fitted.minY - size.height / 2) * scale + closeDrag.height,
                          width: fitted.width * scale, height: fitted.height * scale)
        }
        if let drawn = pictureFrame?(), drawn.width >= fitted.width * 0.9 || drawn.height >= fitted.height * 0.9 {
            return drawn
        }
        return fitted
    }

    // MARK: A drag down closes

    /// The photo shrinks as a finger drags it down, to 0.65 of its size half a screen down, as Photos' does.
    static func closeDragScale(_ drag: CGSize, height: CGFloat) -> CGFloat {
        1 - 0.35 * min(1, max(0, drag.height) / max(height * 0.5, 1))
    }

    /// The backdrop fades as the photo is dragged down, the grid showing through, gone a third of a screen down.
    static func closeDragBackdrop(_ drag: CGSize, height: CGFloat) -> Double {
        Double(1 - min(1, max(0, drag.height) / max(height * 0.35, 1)))
    }

    // MARK: A pinch closes

    /// A pinch that ends below this, of the photo's fitted size, closes the viewer, as on the Mac.
    static let pinchCloseScale: CGFloat = 0.8

    /// The backdrop fades as a pinch shrinks the photo, gone at half its size, as the Mac's does.
    static func pinchBackdrop(_ scale: CGFloat?) -> Double {
        guard let scale else { return 1 }
        return Double(min(1, max(0, (scale - 0.5) / 0.5)))
    }

    /// A pinch takes the photo below its fitted size, as Photos' and the Mac's do: the controls go, what plays stops,
    /// and the grid shows through as it shrinks.
    func pinchToClose(_ scale: CGFloat) {
        if closePinch == nil {
            closingZoom?(true)
            withAnimation(.easeOut(duration: 0.15)) { closePinch = scale }
        } else {
            closePinch = scale
        }
    }

    /// The pinch lets go: below `pinchCloseScale` the viewer closes into the tile from there; else the photo grows back,
    /// which its page does, and the controls come back. Says whether it closes.
    func endPinchToClose(_ scale: CGFloat) -> Bool {
        guard closePinch != nil else { return false }
        if scale < Self.pinchCloseScale {
            close()
            return true
        }
        withAnimation(.easeOut(duration: 0.3)) { closePinch = nil }
        closingZoom?(false)
        return false
    }

    // MARK: A drag down closes

    /// The finger moves the photo, down from where it lies, to close the viewer: the controls go, and what plays stops.
    func dragToClose(_ translation: CGSize) {
        if closeDrag == nil {
            closingZoom?(true)
            withAnimation(.easeOut(duration: 0.15)) { closeDrag = translation }
        } else {
            closeDrag = translation
        }
    }

    /// The finger lets go: the viewer closes into the tile from where the photo is when it went far enough down or was
    /// flicked down, else the photo springs back.
    func endDragToClose(_ translation: CGSize, velocity: CGPoint) {
        guard closeDrag != nil else { return }
        if (translation.height > 90 && velocity.y > -200) || velocity.y > 600 {
            closeDrag = translation
            close()
        } else {
            withAnimation(.spring(duration: 0.3, bounce: 0.15)) { closeDrag = nil }
            closingZoom?(false)
        }
    }

    /// Whether a drag may close the viewer into its tile: not while the details are up, the photo is zoomed in or a
    /// page the details opened shows, whose drags are theirs, and not sideways, which pages.
    func allowsDragToClose(velocity: CGVector) -> Bool {
        guard !detailsActive, !isZoomed, detailsPath.isEmpty else { return false }
        return abs(velocity.dy) >= abs(velocity.dx)
    }

    func toggleChrome() {
        chromeFade?.cancel()
        withAnimation(.easeInOut(duration: 0.2)) { chromeVisible.toggle() }
    }

    /// Play pressed in the video bar: the chrome fades a moment after, while the video plays, as in Photos.
    func fadeChromeForVideo() {
        chromeFade?.cancel()
        chromeFade = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard let self, !Task.isCancelled, video.isPlaying, video.scrubbing == nil, chromeVisible else { return }
            withAnimation(.easeInOut(duration: 0.3)) { chromeVisible = false }
        }
    }

    /// The video played to its end: the chrome comes back, with Play.
    func videoEnded() {
        chromeFade?.cancel()
        guard !chromeVisible else { return }
        withAnimation(.easeInOut(duration: 0.2)) { chromeVisible = true }
    }

    /// A tap on the photo: with the details up it brings the photo back, else it hides or shows the controls.
    func photoTapped() {
        if showsDetails { hideDetails() } else { toggleChrome() }
    }

    /// Zooming into a photo hides the controls, as in Photos, and brings it back from its details to look at.
    func zoomChanged(_ zoomed: Bool) {
        isZoomed = zoomed
        guard zoomed else { return }
        hideDetails()
        guard chromeVisible else { return }
        withAnimation(.easeInOut(duration: 0.2)) { chromeVisible = false }
    }

    /// A sheet over the viewer.
    func present(_ presentation: ViewerPresentation) {
        presented = presentation
    }

    /// Whether the shown photo's picture can be turned and cropped here, as the Mac decides (MetadataMenuItems):
    /// one's own still photo of known size, not a Live Photo, a panorama or a GIF, outside the trash, on an Immich
    /// with edits.
    var canEditPicture: Bool {
        guard let asset = currentDetails, inspector.canEdit(currentID), !asset.isTrashed,
              session.version?.supportsMetadataEdits == true, !session.metadata.unavailableEdits,
              model.canMutate([currentID]) else { return false }
        return asset.canEditMetadataImage(userID: session.user?.id)
    }

    /// Edit in the bottom bar: the editor over the viewer.
    func edit() {
        guard canEditPicture, let asset = currentDetails else { return }
        editing = asset
    }

    // MARK: Ratings and stacks

    /// Whether the account has ratings on in Immich's preferences, as the Mac shows its stars only then: as read
    /// when the viewer opened, since another app may have changed it, and until then as the session read it.
    var ratingsEnabled: Bool {
        ratingsPreference ?? session.preferences?.ratings?.enabled ?? false
    }

    /// Reads the account's ratings preference, as the Mac's details read it; a failed read is tried again at the next
    /// photo.
    func loadRatingsPreference() async {
        guard ratingsPreference == nil else { return }
        let client = session.client
        guard let preferences = try? await client.metadataPreferences(), !Task.isCancelled else { return }
        ratingsPreference = preferences.ratings?.enabled ?? false
    }

    /// How many photos the shown photo's stack holds: from its details once they are its own, else from the grid.
    var stackCount: Int? {
        if let details = currentDetails { return details.stack.map(\.assetCount) }
        return currentItem?.stackCount
    }

    /// The stack's badge: its photos and actions in a sheet.
    func showStack() {
        guard let stack = currentDetails?.stack else { return }
        presented = .stack(stack.id)
    }

    /// The stack changed (a cover set, a photo taken out, unstacked): the details read the stack again. When the shown
    /// photo was the stack's cover, which stands for the stack in the grid, the new cover shows in its place.
    func stackChanged(previousCover: String, newCover: AssetResponse?) {
        detailsAttempt += 1
        guard let newCover, newCover.id != previousCover, currentID == previousCover else { return }
        showPage?(AssetItem(newCover), 1, false)
    }

    // MARK: The details

    func showDetails() {
        guard !showsDetails else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            detailsActive = true
            showsDetails = true
            chromeVisible = true
        }
    }

    func hideDetails() {
        guard showsDetails else { return }
        showsDetails = false
    }

    func toggleDetails() {
        if showsDetails { hideDetails() } else { showDetails() }
    }

    /// Adjust Info's Description: the details come up with the caption field ready to type in.
    func editCaption() {
        captionFocusID = currentID
        showDetails()
    }

    /// The stage has scrolled away from the photo alone: the details are made, and the controls that go with the
    /// details up (the top bar, the Live badge, the filmstrip) fade as it starts.
    func detailsScrolled(_ offset: CGFloat) {
        guard offset > 0.5, !detailsActive else { return }
        withAnimation(.easeOut(duration: 0.2)) { detailsActive = true }
    }

    /// The stage's scroll has come to rest: at the photo alone, what the details show stops loading and the controls
    /// come back; at the details, or past them, they are up.
    func detailsSettled(at offset: CGFloat, rest: CGFloat) {
        if offset <= 0.5 {
            showsDetails = false
            if detailsActive { withAnimation(.easeIn(duration: 0.2)) { detailsActive = false } }
        } else if offset >= rest - 1, !showsDetails {
            showsDetails = true
            chromeVisible = true
        }
    }

    /// Opens what the details lead to: a person, an album or a tag on the tab's own stack, closing the viewer, where
    /// it can be reached; else, and for the map, inside the viewer.
    func open(_ route: ViewerDetailsRoute) {
        if let openInTab, let tabRoute = Self.tabRoute(for: route) {
            openInTab(tabRoute)
        } else {
            detailsPath.append(route)
        }
    }

    private static func tabRoute(for route: ViewerDetailsRoute) -> Route? {
        switch route {
        case .person(let id, let name):
            // The person's page reads the rest of them as it opens.
            .person(Person(id: id, name: name, isHidden: false, isFavorite: nil, birthDate: nil))
        case .album(let album): .album(album)
        case .tag(let id, let name): .photos(.explore(.tag(id)), title: name)
        case .place: nil
        }
    }

    // MARK: Live Photos

    /// A swipe plays a Live Photo's glimpse: the switch is on, and the system's Reduce Motion and Auto-Play Video
    /// Previews agree.
    var glimpsesPlay: Bool { livePhotosMove && Self.systemLetsLivePhotosMove }

    static var systemLetsLivePhotosMove: Bool {
        !UIAccessibility.isReduceMotionEnabled && UIAccessibility.isVideoAutoplayEnabled
    }

    /// The LIVE badge, one switch for all Live Photos: it plays nothing, a Live Photo moving stops, and a notice says
    /// which way it went.
    func toggleLivePhotos() {
        livePhotosMove.toggle()
        UserDefaults.standard.set(!livePhotosMove, forKey: Self.livePhotosStillKey)
        if livePhotosMove { loadLivePhoto?() } else { stopLivePhoto?() }
        withAnimation(.easeOut(duration: 0.2)) { liveNotice = LiveNotice(on: livePhotosMove) }
    }

    /// The notice goes, unless the switch changed again meanwhile.
    func dismissLiveNotice(_ notice: LiveNotice) {
        guard liveNotice == notice else { return }
        withAnimation(.easeIn(duration: 0.3)) { liveNotice = nil }
    }

    // MARK: The photos beside the shown one

    /// The photo beside one, if its month has loaded: `step` 1 is the one to the right, the next, and -1 the one to the
    /// left. A month not loaded yet starts loading, and the pager asks again once it has.
    func neighbour(of id: String, step: Int) -> AssetItem? {
        guard let position = model.order(of: id) else { return nil }
        let delta = readsBackwards ? -step : step
        let sections = model.sections
        var sectionIndex = position.section
        var itemIndex = position.item + delta
        while sections.indices.contains(sectionIndex) {
            guard let assets = sections[sectionIndex].assets else {
                model.ensureLoaded(sectionIndex)
                return nil
            }
            if itemIndex < 0 {
                sectionIndex -= 1
                guard sections.indices.contains(sectionIndex) else { return nil }
                guard let previous = sections[sectionIndex].assets else {
                    model.ensureLoaded(sectionIndex)
                    return nil
                }
                itemIndex = previous.count - 1
                continue
            }
            if itemIndex >= assets.count {
                sectionIndex += 1
                itemIndex = 0
                continue
            }
            return assets[itemIndex]
        }
        return nil
    }

    /// The photo after one in the viewer's order, its month loaded if need be: the slideshow's next.
    func nextPhoto(after id: String) async -> AssetItem? {
        await model.neighbor(of: id, delta: readsBackwards ? -1 : 1)
    }

    /// The loaded photos around one, left to right as the viewer pages, up to `radius` on each side, for the
    /// filmstrip. Only what the model holds: the pager loads the months beside the shown photo.
    func photos(around id: String, radius: Int) -> [AssetItem] {
        guard let position = model.order(of: id), let centre = model.asset(position.section, position.item) else {
            return currentItem.map { [$0] } ?? []
        }
        let before = loadedPhotos(from: position, step: -1, count: radius)
        let after = loadedPhotos(from: position, step: 1, count: radius)
        let inModelOrder = before.reversed() + [centre] + after
        return readsBackwards ? inModelOrder.reversed() : inModelOrder
    }

    /// Up to `count` loaded photos from a position in the model's order, `step` 1 onwards and -1 back, stopping at a
    /// month not loaded.
    private func loadedPhotos(from position: (section: Int, item: Int), step: Int, count: Int) -> [AssetItem] {
        let sections = model.sections
        var found: [AssetItem] = []
        var sectionIndex = position.section
        var itemIndex = position.item + step
        while found.count < count, sections.indices.contains(sectionIndex), let assets = sections[sectionIndex].assets {
            if itemIndex < 0 {
                sectionIndex -= 1
                itemIndex = sections.indices.contains(sectionIndex) ? (sections[sectionIndex].assets?.count ?? 0) - 1 : -1
                continue
            }
            if itemIndex >= assets.count {
                sectionIndex += 1
                itemIndex = 0
                continue
            }
            found.append(assets[itemIndex])
            itemIndex += step
        }
        return found
    }

    /// The months beside the shown photo load, and the next pages of a search, and the neighbours' previews come
    /// ahead, so a swipe shows them at once.
    private func prefetchNeighbours() {
        prefetchTask?.cancel()
        let id = currentID
        if let position = model.order(of: id) {
            lastSectionID = model.sections[position.section].id
            model.cellAppeared(section: position.section, item: position.item)
            if position.item < 30 { model.ensureLoaded(position.section - 1) }
        }
        let model = model
        let pipeline = session.pipeline
        let readsBackwards = readsBackwards
        prefetchTask = Task {
            for step in [1, -1] {
                guard !Task.isCancelled else { return }
                guard let next = await model.neighbor(of: id, delta: readsBackwards ? -step : step),
                      !Task.isCancelled else { continue }
                _ = await pipeline.thumbnail(next.id, size: .preview)
            }
        }
    }

    /// The model has read itself again (after a date was changed, say) and has not found the shown photo yet: its
    /// month loads again, or the pages of a search up to it, as on the Mac when a photo is revealed.
    func relocateCurrent() {
        guard relocateTask == nil, currentID != leavingID, model.order(of: currentID) == nil, model.state == .loaded
        else { return }
        let id = currentID
        if let lastSectionID, let index = model.sections.firstIndex(where: { $0.id == lastSectionID }),
           model.sections[index].assets == nil {
            model.ensureLoaded(index)
        }
        let known = currentDetails
        let client = session.client
        relocateTask = Task { [weak self] in
            var asset = known
            if asset == nil { asset = try? await client.asset(id) }
            guard let self else { return }
            if let asset, !Task.isCancelled { try? await model.loadForReveal(asset) }
            relocateTask = nil
        }
    }

    // MARK: Changes that take the photo away

    /// Does something to the shown photo that may take it out of this grid (deleting, archiving, restoring): when it
    /// has gone, the next photo shows, or the one before when it was the last, and the viewer closes when none is left.
    func performLeaving(_ action: @MainActor (String) async -> Void) async {
        let id = currentID
        let next = neighbour(of: id, step: 1)
        let previous = next == nil ? neighbour(of: id, step: -1) : nil
        leavingID = id
        await action(id)
        if leavingID == id { leavingID = nil }
        guard currentID == id, model.item(id) == nil else { return }
        if let next, model.item(next.id) != nil {
            showPage?(next, 1, true)
        } else if let previous, model.item(previous.id) != nil {
            showPage?(previous, -1, true)
        } else {
            close()
        }
    }

    /// The shown photo is being removed from the grids elsewhere (LibrarySession.removeFromGrids), before the model
    /// lets it go: its neighbour shows instead, or the viewer closes.
    private func currentPhotoLeaving() {
        if let next = neighbour(of: currentID, step: 1) {
            showPage?(next, 1, true)
        } else if let previous = neighbour(of: currentID, step: -1) {
            showPage?(previous, -1, true)
        } else {
            close()
        }
    }

    // MARK: Details

    /// Loads the shown photo's details and albums, for the title, the details and sharing.
    func loadDetails() async {
        let client = session.client
        await AssetInspectorState.load(currentID,
                                       asset: { try await client.asset($0) },
                                       albums: { (try? await client.albums(containing: $0)) ?? [] },
                                       update: { change in change(&inspector) })
    }

    /// The name Apple's maps gave a photo's place, once asked, while Look Up Place Names with Apple Maps is on.
    func placeName(for asset: AssetResponse) -> String? {
        guard ViewerPlaceNames.looksUpWithAppleMaps else { return nil }
        return Self.placeKey(asset).flatMap { placeNames[$0] }
    }

    /// Asks Apple's maps what is at the shown photo's place, once it has shown for a moment, for the title's point of
    /// interest or street, as Photos names a photo's place. Only with Look Up Place Names with Apple Maps on, which
    /// sends the coordinates to Apple, and never in the Locked Folder, whose places stay on the phone.
    func lookUpPlaceName() async {
        guard ViewerPlaceNames.looksUpWithAppleMaps, session.lockedFolder == nil, let asset = currentDetails,
              let key = Self.placeKey(asset), !placesAsked.contains(key), let latitude = asset.exifInfo?.latitude,
              let longitude = asset.exifInfo?.longitude else { return }
        // Paging past a photo asks nothing.
        try? await Task.sleep(for: .milliseconds(600))
        guard !Task.isCancelled, ViewerPlaceNames.looksUpWithAppleMaps, !placesAsked.contains(key),
              let request = MKReverseGeocodingRequest(location: CLLocation(latitude: latitude, longitude: longitude))
        else { return }
        guard let places = try? await request.mapItems, !Task.isCancelled else { return }
        placesAsked.insert(key)
        let city = asset.exifInfo?.city
        if let name = places.first?.name, !name.isEmpty, name != city { placeNames[key] = name }
    }

    /// A place's coordinates to about ten metres, by which its name is kept.
    private static func placeKey(_ asset: AssetResponse) -> String? {
        guard let latitude = asset.exifInfo?.latitude, let longitude = asset.exifInfo?.longitude else { return nil }
        return String(format: "%.4f,%.4f", latitude, longitude)
    }
}
