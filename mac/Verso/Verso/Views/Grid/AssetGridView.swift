import SwiftUI
import VersoCore

enum GridMetrics {
    static let defaultSize = 150.0
    /// Square photos (false) or the Aspect Ratio grid (true), as Photos' toggle.
    static let aspectRatioKey = "gridAspectRatio"
    static let steps: [Double] = [56, 72, 96, 120, 150, 190, 240, 320, 420]

    static func zoomIn(_ size: Double) -> Double { steps.first { $0 > size + 1 } ?? steps.last! }
    static func zoomOut(_ size: Double) -> Double { steps.last { $0 < size - 1 } ?? steps.first! }
}

/// Resolves the grid model for a source and hosts the grid, the viewer, toolbar and inspector.
struct AssetGridContainer<Header: View>: View {
    @Environment(LibrarySession.self) private var session
    let source: GridSource
    let title: Text
    let header: Header
    /// The header scrolls away with the photos, as an album's or a person's title does, instead of staying above them.
    var headerScrolls = false

    init(source: GridSource, title: Text, headerScrolls: Bool = false, @ViewBuilder header: () -> Header) {
        self.source = source
        self.title = title
        self.headerScrolls = headerScrolls
        self.header = header()
    }

    var body: some View {
        AssetGridHost(model: session.gridModel(for: source), title: title, header: header, headerScrolls: headerScrolls)
            .id(source)
    }
}

extension AssetGridContainer where Header == EmptyView {
    init(source: GridSource, title: Text) {
        self.init(source: source, title: title) { EmptyView() }
    }
}

struct AssetGridHost<Header: View>: View {
    @Environment(LibrarySession.self) private var session
    @Bindable var model: AssetGridModel
    let title: Text
    let header: Header
    var headerScrolls = false

    @Environment(\.gridPageControls) private var pageControls
    @AppStorage("showInspector") private var showInspector = false
    /// Follows `showInspector`, which menu commands also change, so the panel slides in and out as Photos' Info does.
    @State private var inspectorShown = UserDefaults.standard.bool(forKey: "showInspector")
    @AppStorage("gridThumbnailSize") private var thumbnailSize = GridMetrics.defaultSize
    @AppStorage(GridMetrics.aspectRatioKey) private var aspectRatio = false
    @AppStorage(TimelineRail.shownKey) private var showsDateScroller = true
    @AppStorage(HDRPhotos.enabledKey) private var showHDR = true
    @State private var pendingDelete: [String]?
    @State private var pendingRemoval: [String]?
    @State private var photoZoom: PhotoZoomRequest?
    @State private var showingFaceList = false
    @State private var photoFaces = PhotoFaces()
    @AppStorage(PhotoFaces.shownKey) private var faceNamesShown = false
    @State private var tagRequest: ExploreTagRequest?
    @State private var playLive = false
    @State private var utilities = AssetsUtilities()
    @AppStorage("library.mode") private var libraryMode = LibraryMode.all
    /// The month Months opens at, after a year card.
    @State private var overviewStart: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var cellFrames = ViewerCellFrames()
    /// The open photo's zoom out of its square, back in, or slide to the next one.
    @State private var motion: ViewerMotion?
    /// The photo the viewer last moved to, or nil for the grid: one update behind `model.viewerID` when it changes.
    @State private var settledID: String?
    @State private var hostSize: CGSize = .zero
    /// The scale a pinch left the photo at as it closed.
    @State private var pinchedScale: Double?
    /// A pinch is shrinking the photo: the grid shows through behind it.
    @State private var revealsGrid = false
    /// The open photo's zoom, for the toolbar's slider.
    @State private var photoScale = 1.0
    /// The photo's place, opened out over it from the map below it.
    @State private var expandedMap: PhotoPlace?
    @State private var slider = ViewerSlider()
    /// The open photo's neighbours, for a swipe to uncover: those of photo `id`, so a photo the viewer has just moved to
    /// never uses its predecessor's.
    @State private var neighbors: (id: String?, previous: String?, next: String?) = (nil, nil, nil)
    /// The pointer is over the page, for the open photo's side arrows.
    @State private var pointerOverViewer = false

    /// Library's Years or Months instead of the grid.
    private var overview: LibraryMode? {
        model.source == .library && libraryMode != .all ? libraryMode : nil
    }

    private var viewerItem: AssetItem? {
        model.viewerID.flatMap { id in model.item(id) ?? (session.metadata.viewerSnapshot?.id == id ? session.metadata.viewerSnapshot : nil) }
    }

    private var inspectedID: String? {
        model.viewerID ?? (model.selection.count == 1 ? model.selection.first : nil)
    }

    var body: some View {
        ZStack {
            Group {
                if let overview {
                    LibraryOverviewView(model: model, mode: overview, startMonth: overviewStart, openYear: { year in
                        overviewStart = year.months.first
                        withAnimation(.smooth(duration: 0.35)) { libraryMode = .months }
                    }, openPhoto: { id in
                        model.selection = [id]
                        model.viewerScrollTarget = id
                        withAnimation(.smooth(duration: 0.35)) { libraryMode = .all }
                    })
                } else {
                    AssetGridView(model: model, onDelete: requestDelete, onTags: { ids, removing in
                        guard model.canMutate(ids) else { return }
                        tagRequest = ExploreTagRequest(ids: ids, removing: removing)
                    }, onRemove: requestRemoval, scrollHeader: headerScrolls ? AnyView(header) : nil, cellFrames: cellFrames)
                }
            }
            // Switching between Years, Months and All Photos replaces the view with a transition, as in Photos.
            .id(overview ?? .all)
            .transition(.blurReplace)
            // Behind a photo flying out of it or back in, or pinched smaller, the grid shows, dimmed.
            .opacity(model.viewerID == nil || shownMotion?.isFlight == true || revealsGrid ? 1 : 0)
            .allowsHitTesting(model.viewerID == nil)
            if let motion = shownMotion, case .flight(_, _, let opening, let dim) = motion.kind {
                Color(nsColor: .windowBackgroundColor)
                    .opacity(opening ? (motion.done ? 1 : 0) : (motion.done ? 0 : dim))
                    .allowsHitTesting(false)
            }
            if let item = viewerItem {
                photoViewer(item)
                    .id("\(item.id)-\(session.metadata.imageRevision)") // Metadata
                    // While a motion runs, pictures of the photos stand in for it.
                    .opacity(shownMotion == nil ? 1 : 0)
                    .transition(shownMotion == nil ? AnyTransition.opacity : .identity)
            }
            if let motion = shownMotion { motionLayer(motion) }
            if viewerItem != nil { ViewerSlideLayer(slider: slider).allowsHitTesting(false) }
            if let place = expandedMap {
                ExpandedPhotoMap(place: place).transition(.opacity)
            }
        }
        .coordinateSpace(.named(ViewerCellFrames.space))
        .background(ViewerPointerTracking { pointerOverViewer = $0 })
        .onGeometryChange(for: CGSize.self) { $0.size } action: { hostSize = $0 }
        // Without a motion (Reduce Motion, or a square off screen), the photo cross-fades. Stepping swaps it under the
        // slide without animating: nothing in SwiftUI animates while the slide's layers move.
        .animation(shownMotion == nil && !(isStepping && !reduceMotion) ? .easeOut(duration: 0.18) : nil, value: model.viewerID)
        .task(id: model.viewerID) {
            guard let id = model.viewerID else { neighbors = (nil, nil, nil); return }
            let previous = await model.neighbor(of: id, delta: -1)?.id
            let next = await model.neighbor(of: id, delta: 1)?.id
            if model.viewerID == id { neighbors = (id, previous, next) }
        }
        .onChange(of: model.viewerID) { old, new in
            revealsGrid = false
            if let old, let new { slide(from: old, to: new) }
            expandedMap = nil
            startMotion(from: old, to: new)
            // The HDR photos kept for sliding, here or in the full-screen viewer, which closes through this too.
            if new == nil { session.pipeline.releaseHDR() }
        }
        .onChange(of: showHDR) { _, shown in if !shown { session.pipeline.releaseHDR() } }
        .onAppear { settledID = model.viewerID }
        .modifier(MetadataHost(model: model)) // Metadata
        .navigationTitle(viewerItem?.date.map { Text(ImmichDate.day($0)) } ?? (headerNamesPage ? Text(verbatim: "") : title))
        .navigationSubtitle(headerNamesPage && viewerItem == nil ? "" : subtitle)
        // An open photo's title is in the middle of the toolbar, as in Photos (`photoTitle`).
        .toolbar(removing: viewerItem == nil ? nil : .title)
        // An open photo has its own Back, to the photos; the page's Back returns with them.
        .navigationBarBackButtonHidden(model.viewerID != nil)
        .toolbar(id: "assetGrid") { toolbar }
        .sheet(item: $tagRequest) { request in
            ExploreTagPicker(tags: session.exploreTags, removing: request.removing) { tag in
                do {
                    try await session.client.exploreTagAssets(request.ids, tag: tag.id, remove: request.removing)
                } catch {
                    session.handle(error)
                    session.invalidateGrids()
                    await model.reload()
                    throw error
                }
                session.invalidateGrids()
                await model.reload()
            }
        }
        .sharingPresentation() // Sharing
        .modifier(AssetsGridUtilities(model: model, utilities: utilities))
        .gridHeader(header, shown: !headerScrolls)
        .inspector(isPresented: Binding(get: { inspectorShown }, set: { showInspector = $0 })) {
            AssetInspector(assetID: inspectedID, source: model.source)
                .inspectorColumnWidth(min: 260, ideal: 300, max: 420)
        }
        .task(id: session.macGridRevision) { await model.loadIfNeeded() }
        .gridViewOptionsReloader(model)
        .onChange(of: session.upload.revision) { Task { await model.reload(keepingUnchanged: true) } } // Upload
        .focusedSceneValue(\.gridModel, model)
        .focusedSceneValue(\.faceNamesAvailable, canShowFaces ? true : nil)
        .focusedSceneValue(\.photoZoom, viewerItem?.isVideo == false ? PhotoZoomAction(zoom: zoomPhoto) : nil)
        // The open photo's faces, while its face names are shown.
        .task(id: canShowFaces && faceNamesShown ? viewerItem?.id : nil) {
            if canShowFaces && faceNamesShown, let id = viewerItem?.id { await photoFaces.load(id, session: session) }
        }
        .modifier(PhotoFacesSheets(faces: photoFaces, assetID: canShowFaces ? viewerItem?.id : nil, showingList: $showingFaceList))
        .focusedSceneValue(\.libraryMode, model.source == .library ? $libraryMode.animation(.smooth(duration: 0.35)) : nil)
        .selectAllTarget(model, enabled: overview == nil)
        .confirmationDialog(deleteTitle, isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible) {
            Button(model.source == .trash || model.source == .locked ? "Delete Permanently" : "Delete", role: .destructive) {
                let ids = pendingDelete ?? []
                Task { await model.delete(ids, permanently: deletesPermanently) }
            }
        } message: {
            Text(deletesPermanently
                 ? "This can't be undone."
                 : "Items are moved to Recently Deleted.")
        }
        // Photos undoes a removal with ⌘Z; without undo, ⌫ asks first. An alert, not a destructive confirmation, so
        // Return accepts, as in Photos, and ⌫ then Return works without the pointer.
        .alert(removalTitle, isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } })) {
            Button(model.source.linkID != nil ? "Remove from Link" : model.source.memoryID != nil ? "Remove from Memory" : "Remove from Album") {
                let ids = pendingRemoval ?? []
                if model.source.linkID != nil {
                    Task { await model.removeFromLink(ids) }
                    return
                }
                if model.source.memoryID != nil {
                    Task { await model.removeFromMemory(ids) }
                    return
                }
                guard let id = model.source.albumID else { return }
                session.albumActions.perform(session: session, albumID: id) { try await model.removeFromAlbum(ids) }
            }
            .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The photos remain in your library.")
        }
        .alert("Something Went Wrong", isPresented: Binding(get: { model.lastError != nil }, set: { if !$0 { model.lastError = nil } })) {
            Button("OK") {}
        } message: {
            Text(model.lastError ?? "")
        }
        .onChange(of: model.viewerID) { _, id in
            playLive = false
            if id == nil { showInspector = false }
        }
        .onDisappear { showInspector = false }
        .onChange(of: showInspector) { _, shown in
            guard inspectorShown != shown else { return }
            withAnimation(.smooth(duration: 0.3)) { inspectorShown = shown }
        }
        .modifier(ViewerIntegration(model: model))
    }

    /// The page's header shows its name while it is in view, so the toolbar leaves it out until it scrolls away.
    private var headerNamesPage: Bool { headerScrolls && model.headerInView && model.viewerID == nil && overview == nil }

    private var subtitle: String {
        if let item = viewerItem { return item.date.map(ImmichDate.time) ?? "" }
        let count = model.totalCount
        guard model.state == .loaded, count > 0 else { return "" }
        if model.checkingLocations, model.selection.isEmpty { return String(localized: "Looking for items without a location…") }
        if !model.selection.isEmpty { return String(localized: "\(model.selection.count) of \(count) selected") }
        return model.visibleMonths ?? String(localized: "\(count) items")
    }

    /// Locked items skip Recently Deleted, as in Immich.
    private var deletesPermanently: Bool {
        model.source == .trash || model.source == .locked || !session.features.trash
    }

    private var deleteTitle: String {
        let n = pendingDelete?.count ?? 0
        return model.source == .trash || model.source == .locked
            ? String(localized: "Permanently delete \(n) items?")
            : String(localized: "Delete \(n) items?")
    }

    private func requestDelete(_ ids: [String]) {
        guard model.canDelete(ids) else { return }
        pendingDelete = ids
    }

    /// From one photo to another, in the update before `startMotion` has run.
    private var isStepping: Bool {
        settledID != nil && model.viewerID != nil && settledID != model.viewerID
    }

    /// The motion running, or the one about to start: for the update in which `model.viewerID` changes, before
    /// `startMotion` runs, so the first frame already shows its start.
    private var shownMotion: ViewerMotion? {
        motion ?? (model.viewerID != settledID ? makeMotion(from: settledID, to: model.viewerID, generation: 0) : nil)
    }

    private func makeMotion(from old: String?, to new: String?, generation: Int) -> ViewerMotion? {
        guard !reduceMotion, old != new else { return nil }
        let bounds = CGRect(origin: .zero, size: hostSize)
        switch (old, new) {
        case (nil, let id?):
            guard let flight = flight(of: id, in: bounds) else { return nil }
            return ViewerMotion(id: id, kind: .flight(from: flight.square, to: flight.fit, opening: true, dim: 0),
                                generation: generation)
        case (let id?, nil):
            guard let flight = flight(of: id, in: bounds) else { return nil }
            let from = pinchedScale.map { ViewerMotionLayout.scaled(flight.fit, by: $0) } ?? flight.fit
            let dim = pinchedScale.map(ViewerMotionLayout.backdrop(forPinch:)) ?? 1
            return ViewerMotion(id: id, kind: .flight(from: from, to: flight.square, opening: false, dim: dim), generation: generation)
        default:
            return nil
        }
    }

    /// A photo's grid square, as the grid shows it (cropped, or whole in Aspect Ratio), and its place in the viewer.
    private func flight(of id: String, in bounds: CGRect) -> (square: CGRect, fit: CGRect)? {
        guard let cell = cellFrames.frame(of: id), ViewerMotionLayout.isShown(cell, in: bounds),
              let item = model.item(id), cachedImage(id) != nil else { return nil }
        let square = aspectRatio ? ViewerMotionLayout.fitted(item.ratio, in: cell) : cell
        return (square, ViewerMotionLayout.fitted(item.ratio, in: bounds))
    }

    private func startMotion(from old: String?, to new: String?) {
        let generation = (motion?.generation ?? 0) + 1
        let next = makeMotion(from: old, to: new, generation: generation)
        // A photo closing into a square off screen fades instead; the grid scrolls to the selected photo as it shows
        // again: the one that closed, unless a face below a photo chose another (`showSelected`). The grid follows the
        // open photo behind it, so its square is in view as it closes.
        if let old, new == nil, next == nil {
            model.viewerScrollTarget = model.selection.count == 1 ? model.selection.first : old
        }
        settledID = new
        pinchedScale = nil
        motion = next
        guard let next else { return }
        // After the start has been drawn, so there's something to move from.
        Task { @MainActor in
            guard motion?.generation == generation else { return }
            withAnimation(.smooth(duration: next.isFlight ? 0.35 : 0.3)) {
                motion?.done = true
            } completion: {
                if motion?.generation == generation { motion = nil }
            }
        }
    }

    private func cachedImage(_ id: String) -> CGImage? {
        session.pipeline.cachedThumbnail(id, size: .preview) ?? session.pipeline.cachedThumbnail(id, size: .thumbnail)
    }

    /// A photo to slide as the viewer shows it: its HDR version while that's in memory, otherwise its preview.
    private func slidePicture(_ id: String) -> CGImage? {
        (showHDR ? session.pipeline.cachedHDR(id) : nil) ?? cachedImage(id)
    }

    private func photoViewer(_ item: AssetItem) -> AssetViewer {
        var viewer = AssetViewer(model: model, item: item, playLive: $playLive, onDelete: requestDelete,
                                 onTags: requestTags, onRemove: requestRemoval, zoomRequest: photoZoom, onZoom: zoomPhoto,
                                 faces: faceNamesShown ? photoFaces.boxes(for: item.id) : [])
        viewer.onPinchClose = pinchClose
        viewer.onPinchChange = { revealsGrid = $0 }
        viewer.onScaleChange = { photoScale = $0 }
        viewer.onExpandMap = expandMap
        viewer.closeOverlay = closeExpandedMap
        viewer.showsSideArrows = pointerOverViewer
        if !reduceMotion {
            viewer.onSwipeDrag = swipeDrag
            viewer.onSwipeEnd = swipeEnd
        }
        return viewer
    }

    private func requestTags(_ ids: [String], removing: Bool) {
        guard model.canMutate(ids) else { return }
        tagRequest = ExploreTagRequest(ids: ids, removing: removing)
    }

    private func pinchClose(_ scale: Double) {
        pinchedScale = scale
        model.viewerID = nil
    }

    private func expandMap(_ place: PhotoPlace) {
        withAnimation(.easeOut(duration: 0.2)) { expandedMap = place }
    }

    /// Esc and Back close the opened-out map before the photo.
    private func closeExpandedMap() -> Bool {
        guard expandedMap != nil else { return false }
        withAnimation(.easeOut(duration: 0.2)) { expandedMap = nil }
        return true
    }

    /// The flying copy of the photo.
    @ViewBuilder private func motionLayer(_ motion: ViewerMotion) -> some View {
        switch motion.kind {
        case .flight(let from, let to, _, _):
            if let image = cachedImage(motion.id) {
                let rect = motion.done ? to : from
                // Filling the rect, so a square crop opens out to the whole photo.
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFill()
                    .frame(width: rect.width, height: rect.height)
                    .clipped()
                    .position(x: rect.midX, y: rect.midY)
                    .allowsHitTesting(false)
            }
        }
    }

    /// Stepping slides pictures of the two photos in Core Animation (`ViewerSlider`), while the photo underneath is
    /// swapped without animating; a Live Photo's motion slides over its picture, so its glimpse shows as the step brings
    /// it.
    private func slide(from old: String, to new: String) {
        guard !reduceMotion, expandedMap == nil, let a = model.order(of: old), let b = model.order(of: new),
              let outgoing = slidePicture(old), let incoming = slidePicture(new) else { return }
        slider.slide(from: outgoing, outgoingMotion: liveMotion(old, making: false)?.slideLayer,
                     to: incoming, incomingMotion: liveMotion(new, making: true)?.slideLayer,
                     direction: ViewerMotionLayout.direction(from: a, to: b), toID: new)
    }

    /// A photo's Live Photo motion in the window's viewer (`LivePhotos`): the one made ahead, or, where `making` and
    /// glimpses play, a new one, which the viewer then takes.
    private func liveMotion(_ id: String?, making: Bool) -> LivePhotoMotion? {
        guard let id else { return nil }
        let place = LivePhotos.place(model, presentation: false)
        guard making, LivePhotos.glimpsesPlay(reduceMotion: reduceMotion), let item = model.item(id) else {
            return LivePhotos.existingMotion(of: id, place: place)
        }
        return LivePhotos.motion(for: item, place: place, session: session)
    }

    /// The open photo's neighbours, once looked up for it.
    private var openNeighbors: (previous: String?, next: String?)? {
        guard let id = model.viewerID, neighbors.id == id else { return nil }
        return (neighbors.previous, neighbors.next)
    }

    /// A swipe's neighbour on the side of `delta`, as the slide's layers show it.
    private func slideNeighbour(_ delta: Int) -> ViewerSlideNeighbour {
        guard let openNeighbors else { return .pending }
        guard let id = delta > 0 ? openNeighbors.next : openNeighbors.previous else { return .end }
        return slidePicture(id).map { .picture($0, motion: liveMotion(id, making: true)?.slideLayer) } ?? .pending
    }

    /// The photos follow a trackpad swipe: the open one, and the neighbour it uncovers, whose Live Photo moves once it
    /// is 65% across, as the iPhone's does.
    private func swipeDrag(_ width: CGFloat) {
        guard let id = model.viewerID, let current = slidePicture(id) else { return }
        let across = slider.drag(width, current: current, currentMotion: liveMotion(id, making: false)?.slideLayer,
                                 previous: slideNeighbour(-1), next: slideNeighbour(1))
        guard across >= ViewerSlider.glimpseAcross, LivePhotos.glimpsesPlay(reduceMotion: reduceMotion),
              let incoming = width > 0 ? openNeighbors?.previous : openNeighbors?.next else { return }
        liveMotion(incoming, making: true)?.glimpse()
    }

    /// The swipe ended: far enough, it moves to that photo, finishing the step on the layers when its picture was
    /// showing and at once when it wasn't; otherwise back. Before the open photo's neighbours are known, it looks the
    /// neighbour up, as the keys do. A neighbour whose Live Photo began moving stops unless the swipe goes to it.
    private func swipeEnd(_ direction: Int?) {
        for (side, neighbour) in [(-1, openNeighbors?.previous), (1, openNeighbors?.next)] where side != direction {
            liveMotion(neighbour, making: false)?.withdrawGlimpse()
        }
        guard let id = model.viewerID, let direction else {
            slider.endDrag(direction: nil, toID: nil)
            return
        }
        if let openNeighbors {
            step(to: direction > 0 ? openNeighbors.next : openNeighbors.previous, direction: direction)
        } else {
            Task {
                let target = await model.neighbor(of: id, delta: direction)?.id
                step(to: model.viewerID == id ? target : nil, direction: direction)
            }
        }
    }

    private func step(to target: String?, direction: Int) {
        guard let target else {
            slider.endDrag(direction: nil, toID: nil)
            return
        }
        slider.endDrag(direction: direction, toID: target)
        model.viewerID = target
        model.selection = [target]
    }

    /// Face names and Manage Faces, for an open photo, as Photos has them.
    private var canShowFaces: Bool {
        viewerItem?.isVideo == false && session.features.facialRecognition && photoFaces.supported
    }

    private var removalTitle: String {
        model.source.linkID != nil
            ? String(localized: "Remove \(pendingRemoval?.count ?? 0) items from the link?")
            : model.source.memoryID != nil
            ? String(localized: "Remove \(pendingRemoval?.count ?? 0) items from the memory?")
            : String(localized: "Remove \(pendingRemoval?.count ?? 0) items from the album?")
    }

    private func requestRemoval(_ ids: [String]) {
        if model.source.linkID != nil || model.source.memoryID != nil {
            // The links listed and the memories are the account's own, which it may change.
            pendingRemoval = ids
            return
        }
        guard let id = model.source.albumID, session.albumActions.details[id]?.canEdit(session.user?.id) == true else { return }
        pendingRemoval = ids
    }

    /// Photos' toggle between square photos and whole photos in their own shape.
    private var aspectRatioButton: some View {
        Button { aspectRatio.toggle() } label: {
            Label(aspectRatio ? "Show Square Photos" : "Show Aspect Ratio", systemImage: "rectangle.arrowtriangle.2.inward")
        }
        .help(aspectRatio ? "Show Square Photos" : "Show Aspect Ratio")
    }

    private func photoTitle(_ item: AssetItem) -> some CustomizableToolbarContent {
        ToolbarItem(id: "photoTitle", placement: .principal) {
            VStack(spacing: 1) {
                Text(item.date.map(ImmichDate.day) ?? "").font(.headline)
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
            .lineLimit(1)
            // A steady width, so the toolbar doesn't lay itself out again for every date.
            .frame(width: 280)
        }
        .customizationBehavior(.disabled)
    }

    private var photoZoomSlider: some CustomizableToolbarContent {
        ToolbarItem(id: "photoZoom", placement: .navigation) {
            PhotoZoomSlider(scale: photoScale) { zoomPhoto(.to($0)) }
                .disabled(viewerItem?.isVideo != false)
        }
    }

    private func zoomPhoto(_ zoom: PhotoZoomRequest.Zoom) {
        photoZoom = PhotoZoomRequest(zoom: zoom, generation: (photoZoom?.generation ?? 0) + 1)
    }

    private var zoomOutButton: some View {
        Button { thumbnailSize = GridMetrics.zoomOut(thumbnailSize) } label: { Label("Zoom Out", systemImage: "minus") }
    }

    private var zoomInButton: some View {
        Button { thumbnailSize = GridMetrics.zoomIn(thumbnailSize) } label: { Label("Zoom In", systemImage: "plus") }
    }

    /// Grouped as Photos groups its toolbar: the grid's size, then its shape and what it shows, then what to do with
    /// the selection. Customize Toolbar… rearranges it; Delete is there to add, and otherwise ⌘⌫ and the context menu.
    /// Every toolbar in the window must be customizable, or none of it is.
    @ToolbarContentBuilder
    private var toolbar: some CustomizableToolbarContent {
        let ids = model.viewerID.map { [$0] } ?? Array(model.selection)
        let items = ids.compactMap(model.item)
        // Years and Months show the library, not photos to act on. Their items stay, disabled, rather than come and
        // go: the toolbar keeps its layout, and the Years, Months and All Photos control stays under the pointer.
        let grid = overview == nil

        if model.viewerID != nil {
            if let item = viewerItem {
                // Plain text in the middle, as Photos' title is, not in a capsule.
                if #available(macOS 26, *) {
                    photoTitle(item).sharedBackgroundVisibility(.hidden)
                } else {
                    photoTitle(item)
                }
            }
            ToolbarItem(id: "back", placement: .navigation) {
                Button { if !closeExpandedMap() { model.viewerID = nil } } label: { Label("Back", systemImage: "chevron.backward") }
                    .help(expandedMap == nil ? "Back to grid" : "Back to photo")
            }
            // Over the opened-out map, the photo's zoom and faces would act on the photo hidden under it.
            // The photo's items stay from one photo to the next, dimmed where they don't apply (a video has no zoom
            // or faces, most photos aren't Live), so stepping doesn't change the toolbar's layout. Over the opened-out
            // map they go: they would act on the photo hidden under it.
            if expandedMap == nil {
                // Photos' zoom slider, beside Back; it draws its own capsule, apart from Back's.
                if #available(macOS 26, *) {
                    photoZoomSlider.sharedBackgroundVisibility(.hidden)
                } else {
                    photoZoomSlider
                }
                if session.features.facialRecognition && photoFaces.supported {
                    if #available(macOS 26, *) { ToolbarSpacer(.fixed) }
                    PeopleFaceToolbarItems(showingList: $showingFaceList, isEnabled: canShowFaces)
                }
                ToolbarItem(id: "live") {
                    Toggle(isOn: $playLive) { Label("Live", systemImage: "livephoto") }
                        .help("Play Live Photo")
                        .disabled(viewerItem?.livePhotoVideoID == nil)
                }
            }
        } else {
            // Two buttons rather than a ControlGroup, which share a capsule all the same: a ControlGroup came up empty
            // on some pages, and on macOS 15 it was part of an endless toolbar layout loop on pushed pages. On every
            // page the first items on the right, in a box of their own
            // (DESIGN.md, "The toolbar's places"); the page's mode in the middle.
            if model.source == .library {
                // The Library's zoom sits left of Years, Months and All Photos, as Photos has it.
                ToolbarItem(id: "libraryZoomOut", placement: .principal) { zoomOutButton.disabled(!grid) }
                ToolbarItem(id: "libraryZoomIn", placement: .principal) { zoomInButton.disabled(!grid) }
                ToolbarItem(id: "libraryMode", placement: .principal) {
                    ToolbarModePicker(selection: $libraryMode.animation(.smooth(duration: 0.35)), options: LibraryMode.allCases) { $0.title }
                }
            } else {
                ToolbarItem(id: "zoomOut") { zoomOutButton.disabled(!grid) }
                ToolbarItem(id: "zoomIn") { zoomInButton.disabled(!grid) }
            }
            if #available(macOS 26, *) { ToolbarSpacer(.fixed) }
            if let pageControls {
                ToolbarItem(id: "pageControls") { pageControls.view }
                if #available(macOS 26, *) { ToolbarSpacer(.fixed) }
            }
            if model.source == .geolocation {
                // The page's main action, right after the zoom, in a box of its own.
                ToolbarItem(id: "assignLocationPage") { assignLocationButton(ids).disabled(!grid) }
                    .customizationBehavior(.disabled)
                if #available(macOS 26, *) { ToolbarSpacer(.fixed) }
            }
            ToolbarItem(id: "aspectRatio") { aspectRatioButton.disabled(!grid) }
            if model.showsSectionHeaders {
                // The date scroller beside the grid: a calendar with a timeline at its trailing edge.
                ToolbarItem(id: "dateScroller") {
                    Toggle(isOn: $showsDateScroller) { Label("Date Scroller", systemImage: "calendar.day.timeline.trailing") }
                        .help(showsDateScroller ? "Hide Date Scroller" : "Show Date Scroller")
                        .disabled(!grid)
                }
            }
            if let page = model.source.gridPage {
                ToolbarItem(id: "viewOptions") {
                    GridViewOptions(page: page)
                        .menuIndicator(.hidden)
                        .disabled(!grid)
                }
            }
            if AssetsUtilitiesMenu.hasItems(for: model.source) {
                ToolbarItem(id: "utilities") { AssetsUtilitiesMenu(model: model, utilities: utilities).disabled(!grid) }
            }
        }
        if #available(macOS 26, *) { ToolbarSpacer(.fixed) }

        ToolbarItem(id: "info") {
            Button { showInspector.toggle() } label: { Label("Info", systemImage: "info.circle") }
                .help("Show Info (⌘I)")
        }
        if model.source != .locked {
            // The selection's: dimmed with nothing selected, as in Photos. Sharing an album is in its Album menu.
            ToolbarItem(id: "share") { // Sharing
                SharingMenu(assetIDs: ids, allowPublicLinks: model.canMutate(ids))
                    .menuIndicator(.hidden)
                    .disabled(!grid)
            }
        }
        if model.source == .trash {
            ToolbarItem(id: "restore") {
                Button { Task { await model.restore(ids) } } label: { Label("Restore", systemImage: "arrow.uturn.backward") }
                    .disabled(!model.canDelete(ids))
                    .help("Restore")
            }
        } else if !model.source.isPartner {
            ToolbarItem(id: "favorite") {
                let allFavorite = !items.isEmpty && items.allSatisfy(\.isFavorite)
                Button { Task { await model.toggleFavorite(ids) } } label: {
                    Label("Favorite", systemImage: allFavorite ? "heart.fill" : "heart")
                }
                .disabled(!grid || !model.canMutate(ids))
                .help(allFavorite ? "Unfavorite" : "Favorite")
            }
            ToolbarItem(id: "rotate") { rotateButton(ids).disabled(!grid) }
        }
        if model.source != .geolocation, AssetsUtilitiesMenu.supportsLocation(model.source) {
            ToolbarItem(id: "assignLocation", showsByDefault: false) { assignLocationButton(ids).disabled(!grid) }
        }
        ToolbarItem(id: "download") {
            Button {
                Exporter.exportOriginals(ids, session: session)
            } label: {
                Label("Download", systemImage: "arrow.down.to.line")
            }
            .disabled(!grid || ids.isEmpty)
            .help("Export Unmodified Original…")
        }
        if !model.source.isPartner {
            // Recently Deleted keeps its button: there it deletes for good.
            ToolbarItem(id: model.source == .trash ? "deletePermanently" : "delete", showsByDefault: model.source == .trash) {
                Button { requestDelete(ids) } label: { Label("Delete", systemImage: "trash") }
                    .disabled(!grid || !model.canDelete(ids))
                    .help("Delete")
            }
        }
        SearchToolbarItem()
    }

    /// Assign Location… for the selection, as in the Image menu and the More menu.
    /// A toolbar button is named with a plain verb, as the Mac's are; the ellipsis that says a sheet asks for more is
    /// the menu item's and the help's (DESIGN.md, "Type and words").
    private func assignLocationButton(_ ids: [String]) -> some View {
        Button { session.metadata.present(.location, ids: ids.sorted()) } label: {
            Label("Assign Location", systemImage: "mappin.and.ellipse")
        }
        .disabled(ids.isEmpty || !model.canMutate(ids))
        .help("Assign a location to the photos selected…")
    }

    /// Photos' Rotate: to the left, or to the right with Option.
    private func rotateButton(_ ids: [String]) -> some View {
        let id = ids.count == 1 ? ids.first : nil
        let canRotate = id.map { session.metadata.imageEligibility[$0] == true } == true
            && !session.metadata.unavailableEdits && session.version?.supportsMetadataEdits == true && model.canMutate(ids)
        return Button {
            guard let id else { return }
            let clockwise = NSEvent.modifierFlags.contains(.option)
            Task { await session.metadata.rotate(id, clockwise: clockwise, session: session) }
        } label: {
            Label("Rotate", systemImage: "rotate.left")
        }
        .disabled(!canRotate)
        .help("Rotate left, or right with Option")
    }
}

struct AssetGridView: View {
    @Environment(LibrarySession.self) private var session
    @Bindable var model: AssetGridModel
    let onDelete: ([String]) -> Void
    let onTags: ([String], Bool) -> Void
    /// ⌫ in an album: takes the photos out of it.
    var onRemove: ([String]) -> Void = { _ in }
    /// Above the photos, scrolling with them.
    var scrollHeader: AnyView?
    /// A quieter message for a page whose header already holds what there is, such as a folder of subfolders.
    @Environment(\.gridEmptyNote) private var emptyNote
    @Environment(\.gridEmptyAddPhotos) private var emptyAddPhotos
    /// Where the squares are, for an open photo to fly out of and back into.
    var cellFrames: ViewerCellFrames?

    @AppStorage("gridThumbnailSize") private var thumbnailSize = GridMetrics.defaultSize
    /// Whole photos in their own shape, rather than cropped to squares, as Photos' Aspect Ratio grid.
    @AppStorage(GridMetrics.aspectRatioKey) private var aspectRatio = false
    @State private var emptyHeaderHeight: CGFloat = 0
    @AppStorage(TimelineRail.shownKey) private var showsDateScroller = true
    @State private var railPosition = TimelineRailPosition()
    @State private var gridScroller = PhotoGridScroller()
    /// The bars over the grid.
    @State private var gridInsets = EdgeInsets()

    var body: some View {
        Group {
            // Months a filter emptied still count as empty (Assign Location).
            if model.sections.allSatisfy({ model.shownCount($0) == 0 }) {
                if let scrollHeader {
                    // The header stays at the top and scrolls when it is taller than the window (a folder with many
                    // subfolders); the message fills the space left below it.
                    ScrollView {
                        VStack(spacing: 0) {
                            scrollHeader
                                .onScrollVisibilityChange(threshold: 0.25) { model.headerInView = $0 }
                                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { emptyHeaderHeight = $0 }
                            emptyContent.containerRelativeFrame(.vertical) { height, _ in max(160, height - emptyHeaderHeight) }
                        }
                    }
                } else {
                    emptyContent
                }
            } else {
                grid
            }
        }
    }

    /// Loading, a failure or why there are no photos, filling the space it is given.
    private var emptyContent: some View {
        Group {
                switch model.state {
                case .idle, .loading:
                    VStack(spacing: 12) {
                        ProgressView().controlSize(.large)
                        if model.searchResultsLoaded > 0 {
                            Text("Loaded \(model.searchResultsLoaded) search results")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                case .failed(let message):
                    ContentUnavailableView {
                        Label("Couldn't Load Photos", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(message)
                    } actions: {
                        Button("Try Again") { Task { await model.reload() } }
                    }
                case .loaded where model.checkingLocations:
                    VStack(spacing: 12) {
                        ProgressView().controlSize(.large)
                        Text("Looking for items without a location…").font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                case .loaded where model.uncheckedLocationMonths > 0:
                    // Months that failed weren't checked, so this can't say every item has a location.
                    ContentUnavailableView {
                        Label("Couldn't Check Every Month", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text("\(model.uncheckedLocationMonths) months couldn't be loaded, so items without a location may be missing.")
                    } actions: {
                        Button("Try Again") { model.retryLocationCheck() }
                    }
                case .loaded:
                    if let page = model.source.gridPage, model.arrangement?.hidesLocated == true {
                        ContentUnavailableView {
                            Label("All Items Have a Location", systemImage: "mappin.circle")
                        } description: {
                            Text("Every photo and video you own has GPS coordinates, so it shows on the map.")
                        } actions: {
                            Button("Show All Items") { page.showAllItems() }
                        }
                    } else if let page = model.source.gridPage, model.arrangement?.isFiltered == true {
                        ContentUnavailableView {
                            Label("No Matching Photos", systemImage: "line.3.horizontal.decrease.circle")
                        } description: {
                            Text("No photos match the selected view options.")
                        } actions: {
                            Button("Show All Items") { page.showAllItems() }
                        }
                    } else {
                        emptyState
                    }
                }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var emptyState: some View {
        if let note = emptyNote {
            Text(note).foregroundStyle(.secondary).padding()
        } else if let emptyAddPhotos, model.source.removesInsteadOfDeleting {
            ContentUnavailableView {
                Label("No Photos", systemImage: "photo.on.rectangle")
            } description: {
                Text(model.source.linkID != nil ? "This link shares no photos yet." : "This album has no photos yet.")
            } actions: {
                Button("Add Photos…", action: emptyAddPhotos.perform)
            }
        } else {
            defaultEmptyState
        }
    }

    private var defaultEmptyState: some View {
        let (title, symbol): (LocalizedStringKey, String) = switch model.source {
        case .favorites: ("No Favorites", "heart")
        case .videos: ("No Videos", "video")
        case .archive: ("Archive Is Empty", "archivebox")
        case .trash: ("No Recently Deleted Items", "trash")
        case .locked: ("Locked Folder Is Empty", "lock")
        case .search, .filteredSearch: ("No Results", "magnifyingglass")
        case .partner: ("No Partner Photos", "person.2")
        case .largeFiles: ("No Large Files", "externaldrive")
        case .geolocation: ("No Photos to Locate", "mappin.and.ellipse")
        case .explore(.folder): ("No Photos", "folder")
        case .explore: ("No Photos to Explore", "globe")
        default: ("No Photos", "photo.on.rectangle")
        }
        return ContentUnavailableView(title, systemImage: symbol)
    }

    private var thumbnailRequestSize: ImmichClient.ThumbnailSize {
        thumbnailSize * 2 > 320 ? .preview : .thumbnail
    }

    /// The photos in AppKit's collection view (`PhotoGridCollection`), which knows every tile's place: the date
    /// scroller, the arrow keys and Back from the viewer land exactly, and it follows the viewer's photo behind it.
    private var grid: some View {
        PhotoGridCollection(
            model: model, pipeline: session.pipeline, client: session.client, size: thumbnailSize,
            look: PhotoGridTileLook(size: thumbnailRequestSize, fit: aspectRatio, revision: session.metadata.imageRevision,
                                    showsFileSize: model.source == .largeFiles, showsLocation: model.source == .geolocation),
            selection: model.selection, header: scrollHeader, insets: gridInsets, scroller: gridScroller,
            railPosition: railPosition, cellFrames: cellFrames,
            actions: PhotoGridActions(
                delete: { ids, command in delete(ids, command: command) },
                quickLook: quickLook,
                menu: { asset in AnyView(contextMenu(for: asset)) },
                setSize: { size in thumbnailSize = size }))
        // The photos run on under the bars, which the scroll view's insets keep them clear of at rest.
        .ignoresSafeArea(.container, edges: .top)
        .onGeometryChange(for: PhotoGridPlacement.self) { proxy in
            PhotoGridPlacement(insets: proxy.safeAreaInsets, origin: proxy.frame(in: .named(ViewerCellFrames.space)).origin)
        } action: { placement in
            gridInsets = placement.insets
            gridScroller.origin = placement.origin
        }
        .safeAreaInset(edge: .trailing, spacing: 0) {
            if let months = railMonths, gridScroller.pitch > 0 {
                // Where everything is on it from the grid's own rows, and a click or a drag lands to the point.
                TimelineRail(sections: months, columns: gridScroller.columns, rowHeight: gridScroller.pitch,
                             position: railPosition, scrollTo: { gridScroller.scrollTo(monthsY: $0) })
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { uncheckedMonthsBanner }
        .onAppear { centerViewerTarget() }
        .onChange(of: model.viewerScrollTarget) { centerViewerTarget() }
        .onChange(of: model.keyboardScrollTarget) { _, id in
            guard let id else { return }
            gridScroller.reveal(id)
            model.keyboardScrollTarget = nil
        }
        // The photo open in the viewer stays in view behind it, so closing it flies back into its tile; closed, the keys
        // are the grid's again.
        .onChange(of: model.viewerID) { _, id in
            if let id { gridScroller.follow(id) } else { gridScroller.takeFocus() }
        }
        .onChange(of: model.selection) {
            MacQuickLook.shared.follow(model.macOrderedSelection, ahead: model.quickLookAhead)
        }
        .fastWheelScrolling()
    }

    private func centerViewerTarget() {
        guard let id = model.viewerScrollTarget, gridScroller.center(id) else { return }
        model.viewerScrollTarget = nil
    }

    /// Assign Location: the list leaves out months whose check failed.
    @ViewBuilder
    private var uncheckedMonthsBanner: some View {
        if model.uncheckedLocationMonths > 0 {
            HStack {
                Label("\(model.uncheckedLocationMonths) months couldn't be loaded, so items without a location may be missing.",
                      systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Try Again") { model.retryLocationCheck() }
            }
            .font(.callout)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(.bar)
        }
    }

    private func quickLook() {
        MacQuickLook.shared.toggle(model.macOrderedSelection, ahead: model.quickLookAhead, session: session,
                                   onError: { model.lastError = $0 }, onArrow: quickLookArrow)
    }

    /// The months the date scroller shows: a timeline's, as months with headers, and enough of them to scroll through.
    private var railMonths: [GridSection]? {
        guard showsDateScroller, model.showsSectionHeaders else { return nil }
        let months = model.sections.filter { model.shownCount($0) > 0 }
        guard months.count >= 3, monthsAreDated(buckets: months.map(\.id)) else { return nil }
        return months
    }

    /// As in Photos: ⌘⌫ deletes; ⌫ takes the photos out of an album, and deletes them elsewhere.
    private func delete(_ ids: [String], command: Bool) {
        guard !ids.isEmpty else { return }
        if command || !model.source.removesInsteadOfDeleting { onDelete(ids) } else { onRemove(ids) }
    }

    @ViewBuilder
    private func contextMenu(for asset: AssetItem) -> some View {
        let ids = model.selection.contains(asset.id) ? Array(model.selection) : [asset.id]
        Button("Open") { model.open(asset.id) }
        AssetActionsMenu(model: model, asset: asset, ids: ids, onDelete: onDelete, onTags: onTags)
    }
}

extension AssetGridView {
    /// Quick Look: an arrow key pressed in the panel moves the grid, which the panel then follows.
    private func quickLookArrow(_ event: NSEvent) -> Bool {
        let direction: AssetGridModel.Move
        switch event.keyCode {
        case 123: direction = .left
        case 124: direction = .right
        case 125: direction = .down
        case 126: direction = .up
        default: return false
        }
        let extending = event.modifierFlags.contains(.shift)
        Task { await model.move(direction, extending: extending) }
        return true
    }
}

struct SectionHeader: View {
    /// Albums: a chevron for groups that collapse.
    enum Disclosure { case expanded, collapsed }

    let title: String
    var disclosure: Disclosure?
    /// Albums and Places: how many items the group holds.
    var count: Int?

    var body: some View {
        HStack {
            HStack(spacing: 6) {
                if let disclosure {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(disclosure == .expanded ? 90 : 0))
                        .foregroundStyle(.secondary)
                }
                Text(title)
                if let count { Text(count, format: .number).foregroundStyle(.secondary).monospacedDigit() }
            }
                .font(.headline)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .adaptiveGlass(in: .capsule)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
}

struct ThumbnailCell: View {
    @Environment(LibrarySession.self) private var session
    let asset: AssetItem?
    let isSelected: Bool
    let size: ImmichClient.ThumbnailSize

    @State private var image: CGImage?
    @State private var placeholder: CGImage?
    @State private var imageID: String?
    @State private var failed = false
    @State private var isVisible = false

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay { picture }
            .contentShape(Rectangle())
            .onScrollVisibilityChange(threshold: 0.01) { isVisible = $0 }
            .task(id: TaskKey(id: asset?.id, size: size, revision: session.metadata.imageRevision, visible: isVisible)) { await load() }
    }

    /// The photo with its badges and selection, cropped to its square.
    private var picture: some View {
        Rectangle()
            .fill(.quaternary.opacity(0.5))
            .overlay {
                if let image {
                    Image(decorative: image, scale: 1).resizable().scaledToFill()
                } else if let placeholder {
                    Image(decorative: placeholder, scale: 1).resizable().scaledToFill()
                } else if failed {
                    Image(systemName: asset?.isVideo == true ? "video.slash" : "photo")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                }
            }
            .overlay(alignment: .bottom) { badges }
            .clipped()
            .overlay {
                if isSelected {
                    // A frame and a tint.
                    Rectangle().strokeBorder(Color.accentColor, lineWidth: 3)
                    Color.accentColor.opacity(0.12)
                }
            }
    }

    private struct TaskKey: Equatable { let id: String?; let size: ImmichClient.ThumbnailSize; let revision: Int; let visible: Bool }

    private func load() async {
        failed = false
        if imageID != asset?.id {
            image = nil
            placeholder = nil
            imageID = asset?.id
        }
        guard isVisible, !Task.isCancelled, let id = asset?.id else { return }
        let pipeline = session.pipeline
        if let cached = pipeline.cachedThumbnail(id, size: size) { image = cached; return }
        image = pipeline.cachedThumbnail(id, size: .thumbnail) ?? pipeline.cachedThumbnail(id, size: .preview) ?? image
        if image == nil, let hash = asset?.thumbhash {
            placeholder = ThumbHash.cachedImage(base64: hash)
            if placeholder == nil {
                let decoded = await ThumbHash.placeholder(base64: hash)
                guard !Task.isCancelled else { return }
                placeholder = decoded
            }
        }
        let loaded = await pipeline.gridThumbnail(id, size: size)
        guard !Task.isCancelled else { return }
        // Fades in over its placeholder when it arrives; from the cache it is just there.
        if let loaded { withAnimation(.easeOut(duration: 0.2)) { image = loaded; placeholder = nil } }
        else if !Task.isCancelled && image == nil { failed = true }
    }

    @ViewBuilder
    private var badges: some View {
        if let asset, asset.isFavorite || asset.isVideo || asset.livePhotoVideoID != nil || asset.stackCount != nil {
            HStack(spacing: 4) {
                if asset.isFavorite {
                    // On a dark plate, so it shows on snow and sky too.
                    Image(systemName: "heart.fill")
                        .padding(3)
                        .background(.black.opacity(0.45), in: .rect(cornerRadius: 4))
                }
                Spacer(minLength: 0)
                if let count = asset.stackCount {
                    Label("\(count)", systemImage: "square.stack.3d.up.fill").labelStyle(.titleAndIcon)
                }
                if asset.livePhotoVideoID != nil { Image(systemName: "livephoto") }
                if asset.isVideo {
                    Text(asset.durationMS.map(Duration.formatMilliseconds) ?? "")
                        .monospacedDigit()
                    Image(systemName: "video.fill")
                }
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.6), radius: 2)
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .background(alignment: .bottom) {
                LinearGradient(colors: [.clear, .black.opacity(0.35)], startPoint: .top, endPoint: .bottom)
            }
        }
    }
}

/// Shared by the grid and the opened photo; callers choose the target IDs.
struct AssetActionsMenu: View {
    @Environment(LibrarySession.self) private var session
    let model: AssetGridModel
    let asset: AssetItem
    let ids: [String]
    let onDelete: ([String]) -> Void
    let onTags: ([String], Bool) -> Void

    var body: some View {
        if model.source != .locked {
            ViewerContextMenu(model: model, asset: asset)
            if model.source != .trash { // Crosslink and the widget, in Show In
                CrosslinkMenuItems(item: ids.count <= 1 ? .asset(asset.id, model.source.crosslinkContext) : nil, widgetIDs: ids)
            }
        }
        Divider()
        if model.source == .locked {
            // Like Immich: no albums, sharing, tags or archive for locked items.
            Button(asset.isFavorite ? "Unfavorite" : "Favorite") { Task { await model.setFavorite(ids, !asset.isFavorite) } }
            AssetsContextMenu(model: model, ids: [asset.id] + ids.filter { $0 != asset.id })
            MetadataMenuItems(ids: ids, canEditImage: !asset.isVideo && asset.livePhotoVideoID == nil).disabled(session.metadata.busy) // Metadata
            AssetsExportMenu(ids: ids)
            Divider()
            Button("Remove from Locked Folder") { Task { await model.removeFromLockedFolder(ids) } }
            Button("Delete Permanently…", role: .destructive) { onDelete(ids) }
        } else if !model.canMutate(ids), model.source != .trash {
            SharingMenuItems(assetIDs: ids, allowPublicLinks: false)
            AssetsExportMenu(ids: ids)
        } else if model.source == .trash {
            Button("Restore") { Task { await model.restore(ids) } }.disabled(!model.canDelete(ids))
            Button("Delete Permanently…", role: .destructive) { onDelete(ids) }.disabled(!model.canDelete(ids))
        } else {
            AlbumSelectionMenu(session: session, model: model, ids: ids) // Albums
            Button(asset.isFavorite ? "Unfavorite" : "Favorite") { Task { await model.setFavorite(ids, !asset.isFavorite) } }
            SharingMenu(assetIDs: ids) // Sharing
            AssetsContextMenu(model: model, ids: [asset.id] + ids.filter { $0 != asset.id })
            MetadataMenuItems(ids: ids, canEditImage: !asset.isVideo && asset.livePhotoVideoID == nil).disabled(session.metadata.busy) // Metadata
            ExploreAssetActions(ids: ids, model: model, onTags: { onTags(ids, $0) }) // Explore
            AssetsExportMenu(ids: ids)
            Divider()
            if model.source == .archive {
                Button("Unarchive") { Task { await model.setArchived(ids, false) } }
            } else {
                Button(String(localized: "Archive Selected Photos")) { Task { await model.setArchived(ids, true) } }
            }
            Button("Delete…", role: .destructive) { onDelete(ids) }
        }
    }
}
