// The photo grid on iOS, for every page of photos: square tiles two points apart, edge to edge, flowing in rows with no
// break between months, as Photos' library does. A timeline has its newest photos at the end its page says
// (GridNewestEnd): at the bottom, as Photos' library, by default, where it reads the model backwards (AssetGridModel
// keeps its months newest first, as the server sends them) and opens at the bottom; or at the top, in the model's
// order, where it opens. A page with a header, search results and the like keep the model's order from the top.
//
// The rows are worked out from the months' photo counts (TimelineLayout), once for each change of the model, so a month
// not loaded yet holds its place, its photos load as its tiles come into view (AssetGridModel.cellAppeared), and no
// work walks every photo of a large library as it scrolls. A pinch goes through the zoom levels, every count a row from
// three (GridZoom, GridPinch). While selecting, a sideways drag across the tiles selects them, as in Photos, and one up
// or down scrolls; down or up the edge of the view the grid scrolls on under a selecting finger. The sideways drag is a
// UIKit pan beside the collection view's own (TimelineCollection): a SwiftUI drag gesture anywhere on the photos keeps
// the scroll view from scrolling at all. The date scroller sits on the trailing edge of a long timeline.
//
// The Library's own timeline also shows the phone's new photos on their way to Immich among Immich's (`phone`, from
// BackupCenter), placed by TimelinePhoneMerge and drawn from the phone (BackupPhoneTile) with their marks. One that
// arrived stays until the model has Immich's photo for it, which then takes its place in the same pass, showing the
// phone's picture until Immich's thumbnail comes (GridTile's stand-in), so nothing jumps or blinks.
//
// The grid lands at the end it opens at (a timeline's newest photos, at either end): as it first shows, which is also
// whenever what it shows is replaced (its page is a new one), and whenever its page asks (`landingRequests`, a tap on
// the Library's or the Archive's tab, the sort changed); it stays there as its months load, until the person moves it
// or a photo is asked for (Show in All Photos, a month's photo picked in Months, the viewer's photo). The photos run on
// under the bars with the soft scroll edge effect at the top. The grid tells its page (GridPageState) the days of the
// photos in view, whether it is at the end it opens at, and when the person has scrolled it away from there, for the
// line under the page's title and the tab bar.

import SwiftUI

struct TimelineGrid: View {
    let model: AssetGridModel
    let pipeline: ImagePipeline
    let actions: GridActions
    var header: AnyView?
    /// The model's months read backwards: the newest photo last, as Photos' library, or the oldest where the model has
    /// them oldest first.
    let reversed: Bool
    /// The grid opens at its bottom, where a timeline's newest photos are with Newest at the Bottom; else at its top.
    let opensAtBottom: Bool
    /// Changes when the page asks the grid to go to the end it opens at.
    var landingRequests = 0
    /// The phone's new photos on their way to Immich, on the Library's own timeline; none elsewhere.
    var phone: [BackupLibraryTile] = []
    /// They go among Immich's photos by when each was taken; else (the timeline ordered by date added) at the newest
    /// end.
    var phoneByDate = true
    /// Immich's photos that just arrived from the phone, by asset, with their local identifiers (BackupLibraryTile).
    var standIns: [String: String] = [:]
    /// Where the phone's own tiles zoom from as they open PhoneViewer (SwiftUI's zoom); Immich's photos fly out of
    /// their tile (ViewerHost), found through each tile's anchor.
    var phoneZoom: Namespace.ID?

    @AppStorage(GridZoom.storageKey) private var zoomLevel = GridZoom.defaultLevel
    @AppStorage(GridTile.aspectRatioKey) private var fitsWhole = false
    @AppStorage(DateScroller.shownKey) private var showsDateScroller = true
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var layoutCache = TimelineLayoutCache()
    @State private var scroll = GridScrollState()
    @State private var scroller = GridScroller()
    /// The safe area the grid runs on under, its bars and the page's title among them.
    @State private var safeArea = EdgeInsets()
    @State private var gridWidth: CGFloat = 0
    /// The grid's height, whose shorter side with its width sets an iPad's counts a row (GridZoom).
    @State private var gridHeight: CGFloat = 0
    @State private var dragSelection: GridDragSelection?
    @State private var autoScroll: Task<Void, Never>?
    /// The grid goes to the end it opens at as its photos are laid out, until the person moves it or a photo is asked for.
    @State private var landing = true
    /// Until when a scroll the grid was not asked for (iOS's own, on a tap on the tab) gives way to landing.
    @State private var landingWindow = Date.distantPast
    /// A scroll animation of the grid's own is under way.
    @State private var animatingOwnScroll = false

    private let spacing: CGFloat = 2

    var body: some View {
        // Read here so the grid draws again when the months change; their layout is worked out once for each change.
        let _ = model.sections
        let _ = model.arrangement
        ZStack {
            if model.totalCount == 0 && (phone.isEmpty || model.state != .loaded) {
                emptyState
            } else if gridWidth > 0 {
                grid(width: gridWidth)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
            gridWidth = size.width
            gridHeight = size.height
        }
    }

    // MARK: Empty

    @ViewBuilder
    private var emptyState: some View {
        if let header {
            ScrollView {
                VStack(spacing: 0) {
                    header
                    emptyContent
                        .frame(minHeight: 320)
                }
            }
            .refreshable { [model] in await model.reload() }
        } else {
            emptyContent
        }
    }

    @ViewBuilder
    private var emptyContent: some View {
        switch model.state {
        case .idle, .loading:
            VStack(spacing: 12) {
                ProgressView()
                if model.searchResultsLoaded > 0 {
                    Text("Loaded \(model.searchResultsLoaded) search results")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded:
            emptyMessage
        case .failed(let message):
            ContentUnavailableView {
                Label("Can't Load Photos", systemImage: "wifi.exclamationmark")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { Task { await model.reload() } }
            }
        }
    }

    /// Why a page has no photos, in its own words, as the Mac says it.
    private var emptyMessage: some View {
        let (title, symbol): (String, String) = switch model.source {
        case .favorites: ("No Favorites", "heart")
        case .videos: ("No Videos", "video")
        case .archive: ("Archive Is Empty", "archivebox")
        case .trash: ("No Recently Deleted Items", "trash")
        case .locked: ("Locked Folder Is Empty", "lock")
        case .search, .filteredSearch: ("No Results", "magnifyingglass")
        case .partner: ("No Partner Photos", "person.2")
        case .largeFiles: ("No Large Files", "externaldrive")
        case .geolocation: ("No Photos to Locate", "mappin.and.ellipse")
        case .album: ("No Photos", "rectangle.stack")
        case .sharedLink: ("No Photos", "link")
        default: ("No Photos", "photo.on.rectangle")
        }
        return ContentUnavailableView(title, systemImage: symbol)
    }

    // MARK: Grid

    /// The photos on their way as the merge places them: each one's date and month, as Immich files it.
    private var phoneMerge: [TimelinePhoneMerge.Phone] {
        phone.enumerated().map { index, tile in
            let date = (phoneByDate ? tile.photo.created : tile.photo.added ?? tile.photo.created) ?? .now
            // A timeline by date added files a photo by when Immich got it, in UTC.
            let month = TimelinePhoneMerge.month(of: date, in: phoneByDate ? .current : .gmt)
            return TimelinePhoneMerge.Phone(index: index, date: date, month: month)
        }
    }

    /// The ID a tile has in the selection: Immich's asset's, or the photo on its way's.
    private func gridID(_ place: TilePlace) -> String? {
        if let index = place.phone { return phone.indices.contains(index) ? phone[index].photo.gridID : nil }
        return model.asset(place.section, place.item)?.id
    }

    private func grid(width: CGFloat) -> some View {
        let layout = layoutCache.layout(for: model, reversed: reversed, phone: phoneMerge, phoneByDate: phoneByDate)
        let columns = GridZoom.columns(level: zoomLevel, width: width, height: gridHeight,
                                       regular: horizontalSizeClass == .regular)
        let metrics = GridTileMetrics(columns: columns, width: width, spacing: spacing)
        let rowCount = layout.rowCount(columns: columns)
        let isSelecting = actions.state.isSelecting
        // A grid of months; the date scroller shows only where they have dates (not search results and the like).
        let isTimeline = model.showsSectionHeaders && layout.months.count >= 3
        // Changes as months and pages of photos load, so the days in view are said once their photos are known.
        let loadedPhotos = model.sections.reduce(0) { $0 + ($1.assets?.count ?? 0) }
        // What the tiles show beyond what they read from the model as they draw: a change draws the tiles in view again.
        var look = Hasher()
        look.combine(fitsWhole)
        look.combine(standIns)
        look.combine(phone.map(\.photo.gridID))
        look.combine(phone.map { $0.arrivedAsset != nil })
        let lookKey = look.finalize()
        let pipeline = pipeline, actions = actions, model = model, phone = phone, standIns = standIns
        let fitsWhole = fitsWhole, phoneZoom = phoneZoom
        return TimelineCollection(
            tileCount: layout.tileCount, metrics: metrics, contentKey: lookKey, layoutKey: layoutCache.revision,
            header: header,
            tile: { index in
                AnyView(TimelineTile(model: model, layout: layout, index: index, metrics: metrics, actions: actions,
                                     pipeline: pipeline, fitsWhole: fitsWhole, phone: phone, standIns: standIns,
                                     phoneZoom: phoneZoom))
            },
            insets: safeArea,
            anchoredAtBottom: opensAtBottom,
            // While a drag selects, the photos stay under the finger; the edge of the view scrolls them instead.
            isScrollEnabled: dragSelection?.start == nil,
            scroller: scroller,
            onScroll: { viewport in
                scroll.viewport = viewport
                reportOpeningEnd(viewport)
                reportVisibleMonths(layout: layout, metrics: metrics, rowCount: rowCount)
            },
            onPhase: { phase in
                scroll.isScrolling = phase.isScrolling
                followScrollPhase(phase, rowCount: rowCount)
            },
            sidewaysEnabled: isSelecting,
            onSidewaysDrag: { event in sidewaysDrag(event, layout: layout, metrics: metrics, rowCount: rowCount) },
            zoom: zoom(width: width),
            refresh: { [model] in await model.reload() },
            keys: isSelecting ? selectionKeys : nil
        )
        // The photos run on under the bars, which the collection view's insets keep them clear of at rest.
        .ignoresSafeArea(.container, edges: .vertical)
        .onGeometryChange(for: EdgeInsets.self) { $0.safeAreaInsets } action: { safeArea = $0 }
        .onChange(of: loadedPhotos) {
            reportVisibleDates(layout: layout, metrics: metrics, rowCount: rowCount)
        }
        .overlay {
            DateScroller(layout: layout, scroll: scroll, metrics: metrics, rowCount: rowCount, scroller: scroller,
                         bars: safeArea, shown: isTimeline && showsDateScroller) {
                landing = false
            }
        }
        .onAppear { scrollToTarget(layout: layout, metrics: metrics, rowCount: rowCount) }
        .onChange(of: model.viewerScrollTarget) {
            scrollToTarget(layout: layout, metrics: metrics, rowCount: rowCount)
        }
        // A photo opened stays where it is behind the viewer, whatever loads.
        .onChange(of: actions.state.opened) { _, opened in
            if opened != nil { landing = false }
        }
        .onChange(of: actions.state.openedPhone) { _, opened in
            if opened != nil { landing = false }
        }
        // The photo open in the viewer stays in view behind it, so closing it flies back into its tile.
        .onChange(of: model.viewerID) { _, id in
            guard let id, actions.state.opened != nil else { return }
            actions.state.shownInViewer = id
            follow(id, layout: layout, metrics: metrics, rowCount: rowCount)
        }
        .onChange(of: isSelecting) { _, selecting in
            if !selecting { endDragSelection() }
        }
        // Rows come and go as months load and the zoom changes: while landing, the grid stays at its end.
        .onChange(of: rowCount) {
            if landing { goToOpeningEnd(rowCount: rowCount, animated: false) }
        }
        .onChange(of: landingRequests) {
            landing = true
            landingWindow = .now.addingTimeInterval(1)
            goToOpeningEnd(rowCount: rowCount, animated: true)
        }
    }

    /// Photos' zoom levels at this width, for the grid's pinch, which leaves the grid where it is rather than landing.
    private func zoom(width: CGFloat) -> TimelineZoom {
        let regular = horizontalSizeClass == .regular
        let spacing = spacing
        let height = gridHeight
        return TimelineZoom(
            level: GridZoom.clamped(zoomLevel, width: width, height: height, regular: regular),
            metrics: { level in
                guard GridZoom.levels(width: width, height: height, regular: regular).contains(level) else { return nil }
                return GridTileMetrics(columns: GridZoom.columns(level: level, width: width, height: height,
                                                                 regular: regular),
                                       width: width, spacing: spacing)
            },
            actions: GridZoomActions(began: { landing = false }, changed: { level in zoomLevel = level }))
    }

    /// A selection's keys (GridKeys): Favorite and Delete where they apply to the photos selected, and Cancel.
    private var selectionKeys: GridKeys {
        let ids = model.selection.sorted()
        var keys = GridKeys(cancel: { [actions] in actions.endSelecting() })
        guard !ids.isEmpty, actions.source != .trash else {
            if !ids.isEmpty, actions.canDelete(ids) {
                keys.delete = GridKeys.Action(title: String(localized: "Delete Permanently")) { [actions] in
                    actions.requestDelete(ids)
                }
            }
            return keys
        }
        let context = actions.context(for: ids, place: .selectionBar)
        if context.favorite {
            keys.favorite = GridKeys.Action(title: context.allFavorite ? String(localized: "Unfavorite")
                                                : String(localized: "Favorite")) { [actions] in
                actions.favorite(ids, !context.allFavorite)
            }
        }
        if actions.canDelete(ids) {
            keys.delete = GridKeys.Action(title: actions.deletesPermanently ? String(localized: "Delete Permanently")
                                              : String(localized: "Delete")) { [actions] in
                actions.requestDelete(ids)
            }
        }
        return keys
    }

    // MARK: Landing

    /// Goes to the end the grid opens at: its last row at the bottom of the view, or its top, header and all, at the top.
    private func goToOpeningEnd(rowCount: Int, animated: Bool) {
        guard rowCount > 0 else { return }
        if animated { animatingOwnScroll = true }
        if opensAtBottom {
            scroller.scrollTo(row: rowCount - 1, anchor: .bottom, animated: animated)
        } else {
            scroller.scrollTo(y: 0, animated: animated)
        }
    }

    /// The person's scroll takes the grid from landing, and so does a scroll animation the grid did not start (a tap on
    /// the status bar), except just after the page asked it to land: iOS scrolls to the top on a tap on the tab shown,
    /// which the grid turns into its own way to its end. As the person lets go, the page hears whether they took the
    /// grid some way from the end it opens at: back in time on a timeline, down a page that reads down.
    private func followScrollPhase(_ phase: ScrollPhase, rowCount: Int) {
        if phase != .interacting, let start = scroll.awayStart {
            scroll.awayStart = nil
            let away = opensAtBottom ? start - scroll.viewport.offset : scroll.viewport.offset - start
            if away > 60 { actions.state.awayScrolls += 1 }
        }
        switch phase {
        case .interacting:
            landing = false
            scroll.awayStart = scroll.viewport.offset
        case .animating where !animatingOwnScroll:
            if landing, Date.now < landingWindow {
                goToOpeningEnd(rowCount: rowCount, animated: true)
            } else {
                landing = false
            }
        case .idle:
            animatingOwnScroll = false
            let distance = opensAtBottom ? scroll.viewport.distanceFromBottom : scroll.viewport.visibleTop
            if landing, Date.now < landingWindow, distance > 1 {
                goToOpeningEnd(rowCount: rowCount, animated: true)
            }
        default:
            break
        }
    }

    // MARK: Where things are

    /// The rows in view, from the scroll position and the rows' fixed height.
    private func visibleRows(_ viewport: GridViewport, metrics: GridTileMetrics, rowCount: Int) -> ClosedRange<Int>? {
        guard rowCount > 0 else { return nil }
        let top = viewport.visibleTop - scroller.headerHeight
        let bottom = top + viewport.visibleHeight
        let first = min(max(Int(floor(top / metrics.pitch)), 0), rowCount - 1)
        let last = min(max(Int(floor(max(top, bottom - 1) / metrics.pitch)), first), rowCount - 1)
        return first...last
    }

    /// The tile at a point of the rows (the content's coordinates below the header, which scroll with the photos).
    private func tileIndex(at point: CGPoint, layout: TimelineLayout, metrics: GridTileMetrics) -> Int? {
        guard point.y >= 0, layout.tileCount > 0 else { return nil }
        let row = Int(point.y / metrics.pitch)
        let column = min(max(Int(point.x / (metrics.side + metrics.spacing)), 0), metrics.columns - 1)
        let index = row * metrics.columns + column
        return index < layout.tileCount ? index : layout.tileCount - 1
    }

    /// The months of the photos in view, told to the model, and their days, told to the page, when the rows in view
    /// change.
    private func reportVisibleMonths(layout: TimelineLayout, metrics: GridTileMetrics, rowCount: Int) {
        guard let rows = visibleRows(scroll.viewport, metrics: metrics, rowCount: rowCount), rows != scroll.reportedRows else { return }
        scroll.reportedRows = rows
        reportVisibleDates(layout: layout, metrics: metrics, rowCount: rowCount)
        let firstTile = rows.lowerBound * metrics.columns
        let lastTile = min(layout.tileCount - 1, rows.upperBound * metrics.columns + metrics.columns - 1)
        guard let first = layout.monthIndex(ofTile: firstTile), let last = layout.monthIndex(ofTile: lastTile) else { return }
        model.showing(sections: layout.months[min(first, last)...max(first, last)].map(\.id))
    }

    /// The days from the earliest to the latest photo in view, of those loaded, as Photos says them under its title.
    private func reportVisibleDates(layout: TimelineLayout, metrics: GridTileMetrics, rowCount: Int) {
        guard let rows = visibleRows(scroll.viewport, metrics: metrics, rowCount: rowCount) else { return }
        let firstTile = rows.lowerBound * metrics.columns
        let lastTile = min(layout.tileCount - 1, rows.upperBound * metrics.columns + metrics.columns - 1)
        var earliest: Date?
        var latest: Date?
        if firstTile <= lastTile {
            for index in firstTile...lastTile {
                guard let place = layout.place(ofTile: index) else { continue }
                let phoneDate = place.phone.flatMap { phone.indices.contains($0) ? phone[$0].photo.created : nil }
                guard let date = phoneDate ?? model.asset(place.section, place.item)?.date else { continue }
                earliest = min(earliest ?? date, date)
                latest = max(latest ?? date, date)
            }
        }
        let text = earliest.flatMap { first in latest.map { GridDates.range(from: first, to: $0) } }
        if actions.state.visibleDates != text { actions.state.visibleDates = text }
    }

    /// Whether the grid is at the end it opens at, with some give, so the line under the title and the tab bar do not
    /// flicker between the two at the edge.
    private func reportOpeningEnd(_ viewport: GridViewport) {
        guard viewport.containerHeight > 0 else { return }
        let distance = opensAtBottom ? viewport.distanceFromBottom : viewport.visibleTop
        let wasAtEnd = actions.state.atOpeningEnd
        let atEnd = distance < (wasAtEnd ? 48 : 12)
        if atEnd != wasAtEnd { actions.state.atOpeningEnd = atEnd }
    }

    /// Goes to the photo the model asks the grid to show: Months' photos open All Photos at them, Show in All Photos
    /// finds one, and the viewer leaves the photo it closed on. A photo already in view stays where it is, so the grid
    /// does not move under a photo the viewer has just zoomed back into.
    private func scrollToTarget(layout: TimelineLayout, metrics: GridTileMetrics, rowCount: Int) {
        guard let id = model.viewerScrollTarget, let order = model.order(of: id),
              let index = layout.tileIndex(section: order.section, item: order.item) else { return }
        model.viewerScrollTarget = nil
        landing = false
        let row = index / metrics.columns
        if scroll.viewport.visibleHeight > 0, let rows = visibleRows(scroll.viewport, metrics: metrics, rowCount: rowCount),
           rows.contains(row) { return }
        // Once the collection view has the rows of this update.
        Task { @MainActor in
            await Task.yield()
            scroller.scrollTo(row: row, anchor: .center)
        }
    }

    private func follow(_ id: String, layout: TimelineLayout, metrics: GridTileMetrics, rowCount: Int) {
        guard let order = model.order(of: id), let index = layout.tileIndex(section: order.section, item: order.item) else { return }
        let row = index / metrics.columns
        if let rows = visibleRows(scroll.viewport, metrics: metrics, rowCount: rowCount), rows.contains(row) { return }
        scroller.scrollTo(row: row, anchor: .center)
    }

    // MARK: Drag to select

    /// While selecting, a drag that starts sideways on a tile selects every photo from it to the one under the finger,
    /// or deselects them when it started on a selected one, as in Photos; one that starts up or down scrolls.
    private func sidewaysDrag(_ event: GridSidewaysDrag.Event, layout: TimelineLayout, metrics: GridTileMetrics,
                              rowCount: Int) {
        switch event {
        case .began(let start, let location):
            guard let selection = startDragSelection(at: start, layout: layout, metrics: metrics) else { return }
            dragSelection = selection
            continueDragSelection(at: location, layout: layout, metrics: metrics, rowCount: rowCount)
        case .moved(let location):
            guard dragSelection?.start != nil else { return }
            continueDragSelection(at: location, layout: layout, metrics: metrics, rowCount: rowCount)
        case .ended:
            endDragSelection()
        }
    }

    /// A drag selecting from the photo at `location`, or nil where there is none. It deselects when it starts on a
    /// photo selected already.
    private func startDragSelection(at location: CGPoint, layout: TimelineLayout, metrics: GridTileMetrics) -> GridDragSelection? {
        guard let start = tileIndex(at: location, layout: layout, metrics: metrics),
              let place = layout.place(ofTile: start), let id = gridID(place) else { return nil }
        let selecting = actions.state.isSelecting
        let base = selecting ? model.selection : []
        return GridDragSelection(start: start, selects: !(selecting && base.contains(id)), base: base, current: start)
    }

    /// The finger of a selecting drag moved: the photos from the first to the one under it are selected, and the grid
    /// scrolls on while the finger rests at its top or bottom edge.
    private func continueDragSelection(at location: CGPoint, layout: TimelineLayout, metrics: GridTileMetrics,
                                       rowCount: Int) {
        if let index = tileIndex(at: location, layout: layout, metrics: metrics) {
            dragSelection?.current = index
        }
        // Where the finger is in the view, for scrolling on at its top and bottom edges.
        let viewport = scroll.viewport
        let fingerY = location.y + scroller.headerHeight - viewport.offset
        dragSelection?.finger = CGPoint(x: location.x, y: fingerY)
        let edgeZone: CGFloat = 70
        let topEdge = viewport.insetTop + edgeZone
        let bottomEdge = viewport.boundsHeight - viewport.insetBottom - edgeZone
        if fingerY < topEdge {
            dragSelection?.edge = -1
            dragSelection?.depth = min(1, (topEdge - fingerY) / edgeZone)
        } else if fingerY > bottomEdge {
            dragSelection?.edge = 1
            dragSelection?.depth = min(1, (fingerY - bottomEdge) / edgeZone)
        } else {
            dragSelection?.edge = 0
        }
        applyDragSelection(layout: layout)
        if dragSelection?.edge != 0, autoScroll == nil {
            startAutoScroll(layout: layout, metrics: metrics, rowCount: rowCount)
        }
    }

    private func applyDragSelection(layout: TimelineLayout) {
        guard let drag = dragSelection, let start = drag.start else { return }
        var ids = Set<String>()
        for index in min(start, drag.current)...max(start, drag.current) {
            if let place = layout.place(ofTile: index), let id = gridID(place) {
                ids.insert(id)
            }
        }
        let selection = drag.selects ? drag.base.union(ids) : drag.base.subtracting(ids)
        if selection != model.selection { model.selection = selection }
    }

    /// Scrolls a row at a time while the finger rests at the top or bottom edge, faster the nearer the edge, and
    /// selects on as the photos pass under it.
    private func startAutoScroll(layout: TimelineLayout, metrics: GridTileMetrics, rowCount: Int) {
        autoScroll = Task { @MainActor in
            while !Task.isCancelled, let drag = dragSelection, drag.start != nil, drag.edge != 0 {
                guard let rows = visibleRows(scroll.viewport, metrics: metrics, rowCount: rowCount) else { break }
                let target = drag.edge < 0 ? rows.lowerBound - 1 : rows.upperBound + 1
                guard target >= 0, target < rowCount else { break }
                scroller.scrollTo(row: target, anchor: drag.edge < 0 ? .top : .bottom)
                let pause = 140 - Int(100 * drag.depth)
                try? await Task.sleep(for: .milliseconds(pause))
                guard let finger = dragSelection?.finger else { break }
                let rowsY = scroll.viewport.offset + finger.y - scroller.headerHeight
                if let index = tileIndex(at: CGPoint(x: finger.x, y: rowsY), layout: layout, metrics: metrics) {
                    dragSelection?.current = index
                    applyDragSelection(layout: layout)
                }
            }
            autoScroll = nil
        }
    }

    private func endDragSelection() {
        autoScroll?.cancel()
        autoScroll = nil
        dragSelection = nil
    }
}

/// One tile of the grid, by its place in the layout: Immich's photo, or one on its way from the phone. Its own view, in
/// its cell, so it redraws when its photo or its selection change, not with the whole grid.
struct TimelineTile: View {
    let model: AssetGridModel
    let layout: TimelineLayout
    let index: Int
    let metrics: GridTileMetrics
    let actions: GridActions
    let pipeline: ImagePipeline
    let fitsWhole: Bool
    let phone: [BackupLibraryTile]
    /// Immich's photos that just arrived from the phone, by asset, with their local identifiers: they show the phone's
    /// picture until their thumbnail comes.
    let standIns: [String: String]
    let phoneZoom: Namespace.ID?

    var body: some View {
        if let place = layout.place(ofTile: index) {
            if let phoneIndex = place.phone {
                if phone.indices.contains(phoneIndex) { phoneTile(phone[phoneIndex]) }
            } else {
                tile(place, standIns: standIns)
            }
        }
    }

    /// A photo on its way, from the phone, with its mark; one that arrived has none, while Immich's takes its place.
    private func phoneTile(_ tile: BackupLibraryTile) -> some View {
        let id = tile.photo.gridID
        let isSelecting = actions.state.isSelecting
        let mark = tile.arrivedAsset == nil ? BackupCenter.shared.mark(tile.photo) : nil
        return BackupPhoneTile(photo: tile.photo, mark: mark, side: metrics.side, isSelected: model.selection.contains(id),
                               isSelecting: isSelecting, fitsWhole: fitsWhole)
            .modifier(PhoneZoomSource(id: id, namespace: phoneZoom))
            .onTapGesture { openPhone(tile) }
            .contextMenu {
                PhoneTileMenu(actions: actions, photo: tile.photo)
            } preview: {
                BackupPhoneTile(photo: tile.photo, mark: nil, side: 340, fitsWhole: true)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(BackupPhoneTileLabel.text(tile.photo, mark: mark))
            .accessibilityAddTraits(isSelecting && model.selection.contains(id) ? [.isButton, .isSelected] : .isButton)
            .accessibilityIdentifier("Phone Tile")
    }

    /// A tap opens the photo on its way from the phone, or while selecting adds it to the selection or takes it out.
    private func openPhone(_ tile: BackupLibraryTile) {
        let id = tile.photo.gridID
        if actions.state.isSelecting {
            if model.selection.contains(id) { model.selection.remove(id) } else { model.selection.insert(id) }
        } else {
            actions.state.shownPhone = id
            actions.state.openedPhone = OpenedAsset(id: id)
        }
    }

    @ViewBuilder
    private func tile(_ place: TilePlace, standIns: [String: String]) -> some View {
        let asset = model.asset(place.section, place.item)
        let isSelecting = actions.state.isSelecting
        let square = GridTile(asset: asset, pipeline: pipeline, side: metrics.side,
                              isSelected: asset.map { model.selection.contains($0.id) } ?? false, isSelecting: isSelecting,
                              fitsWhole: fitsWhole, revision: actions.session.metadata.imageRevision,
                              standIn: asset.flatMap { standIns[$0.id] })
            .onAppear { model.cellAppeared(section: place.section, item: place.item) }
        if let asset {
            square
                // Where the viewer's zoom starts and ends for this photo.
                .background(ViewerZoomAnchor(id: asset.id, sources: actions.state.zoomSources))
                .onTapGesture { open(asset) }
                // Dragged out to another app, the photo is its original, downloaded once the app takes it, as on the
                // Mac; the long press's menu goes as the drag begins.
                .draggable(OriginalTransfer(id: asset.id, isVideo: asset.isVideo, client: actions.session.client))
                .contextMenu {
                    GridTileMenu(actions: actions, asset: asset)
                } preview: {
                    GridTilePreview(asset: asset, pipeline: pipeline)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilityLabel(asset))
                .accessibilityAddTraits(isSelecting && model.selection.contains(asset.id) ? [.isButton, .isSelected] : .isButton)
                // For UI tests, which find a given photo by its Immich identifier; VoiceOver does not read it.
                .accessibilityIdentifier("photo-" + asset.id)
        } else {
            square
                .accessibilityHidden(true)
        }
    }

    /// A tap opens the photo, or while selecting adds it to the selection or takes it out.
    private func open(_ asset: AssetItem) {
        if actions.state.isSelecting {
            if model.selection.contains(asset.id) { model.selection.remove(asset.id) } else { model.selection.insert(asset.id) }
        } else {
            model.viewerID = asset.id
            actions.state.shownInViewer = asset.id
            actions.state.opened = OpenedAsset(id: asset.id)
        }
    }

    private func accessibilityLabel(_ asset: AssetItem) -> String {
        let kind = asset.isVideo ? "Video" : "Photo"
        let date = asset.date.map { ImmichDate.day($0) }
        let favorite = asset.isFavorite ? ", Favorite" : ""
        return date.map { "\(kind), \($0)\(favorite)" } ?? kind + favorite
    }
}

/// Where the grid's scroll view is, in its content's coordinates (the header's top is 0), as ScrollGeometry gives it:
/// UIKit's offset, the insets' top at the top of the content, and the container the part of the view between the bars,
/// the view running on under the bars by the insets.
struct GridViewport: Equatable {
    var offset: CGFloat = 0
    var insetTop: CGFloat = 0
    var insetBottom: CGFloat = 0
    /// The height of the view between the bars.
    var containerHeight: CGFloat = 0
    var contentHeight: CGFloat = 0

    /// The content at the top of the view, below the bars.
    var visibleTop: CGFloat { offset + insetTop }
    /// How far the content goes on below the bottom of the view, above the bars.
    var distanceFromBottom: CGFloat { contentHeight - visibleTop - containerHeight }
    var visibleHeight: CGFloat { max(0, containerHeight) }
    /// The whole view, the parts under the bars too.
    var boundsHeight: CGFloat { containerHeight + insetTop + insetBottom }
}

/// The scroll position, apart from the grid, so scrolling redraws only what follows it (the date scroller).
@MainActor @Observable final class GridScrollState {
    var viewport = GridViewport()
    var isScrolling = false
    /// Where the person's scroll began, while their finger is on the grid.
    @ObservationIgnored var awayStart: CGFloat?
    /// The rows whose months the model was last told are in view.
    @ObservationIgnored var reportedRows: ClosedRange<Int>?
}

/// A drag selecting photos: the tile it started on, whether it selects or deselects, the selection before it, and the
/// tile under the finger. A drag found to be a scroll has no start.
private struct GridDragSelection {
    var start: Int?
    var selects = true
    var base: Set<String> = []
    var current = 0
    /// The finger in the view's coordinates.
    var finger: CGPoint?
    /// The view's edge the finger rests at, -1 the top and 1 the bottom, and how far into it, from 0 to 1.
    var edge = 0
    var depth: CGFloat = 0
}

/// The days of photos as Photos says them under a title: "Nov 15, 2026", or "Nov 15 - 19, 2026" for several. A photo's
/// date is its own clock's, kept as UTC (ImmichDate), so it is written in UTC.
enum GridDates {
    private static let utc = TimeZone(identifier: "UTC")!

    static func range(from first: Date, to last: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        guard first < last, !calendar.isDate(first, inSameDayAs: last) else {
            return first.formatted(Date.FormatStyle(timeZone: utc).month(.abbreviated).day().year())
        }
        return (first..<last).formatted(Date.IntervalFormatStyle(timeZone: utc).month(.abbreviated).day().year())
    }
}

/// While selecting, a drag that starts sideways on the photos (the collection view's pan, TimelineCollection), in the
/// rows' coordinates: where it began and where the finger is.
enum GridSidewaysDrag {
    enum Event {
        case began(start: CGPoint, location: CGPoint)
        case moved(CGPoint)
        case ended
    }
}

/// A phone tile as the source of PhoneViewer's zoom, where the page gives one.
private struct PhoneZoomSource: ViewModifier {
    let id: String
    let namespace: Namespace.ID?

    func body(content: Content) -> some View {
        if let namespace {
            content.matchedTransitionSource(id: id, in: namespace)
        } else {
            content
        }
    }
}
