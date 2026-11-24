// The Mac's photo grid: AppKit's collection view with a layout of its own (PhotoGridLayout), as the iPhone's grid is
// UIKit's (ios/Verso/Grid/TimelineCollection.swift), rather than SwiftUI's lazy grid, which guesses the height of the
// rows it has not drawn. The layout knows every tile's place (PhotoGridGeometry), so the date scroller, the arrow keys
// and Back from the viewer land exactly in a library of any size, the grid follows the viewer's photo behind it, and
// the place holds as Info opens or the window resizes. The tiles are drawn in layers (PhotoGridTileView) and show the
// picture already in memory from their first frame. The grid works out itself what a click, a drag or a key is on:
// selecting (a click, Shift and Command, a rubber band from the space between photos), opening with a double click or
// Return, Quick Look with Space, menus, and dragging originals out as promised files (OriginalFilePromise). Every page
// of photos has it (AssetGridView). ARCHITECTURE.md, "The photo grid on the Mac".

import AppKit
import SwiftUI

/// What the grid asks of its page.
struct PhotoGridActions {
    /// ⌫ (false) or ⌘⌫ (true) on these photos.
    var delete: ([String], Bool) -> Void
    /// Space: Quick Look of the selection.
    var quickLook: () -> Void
    /// A photo's menu, made in SwiftUI, for these photos (the selection, or the photo alone).
    var menu: (AssetItem) -> AnyView
    /// The size a pinch settled on, to keep (`GridMetrics.steps`).
    var setSize: (Double) -> Void
}

/// Where the grid is on its page: the bars over it, and its top left in the viewer's space.
struct PhotoGridPlacement: Equatable {
    var insets: EdgeInsets
    var origin: CGPoint
}

/// The grid's handle for its page: where the grid is and how it lays its rows out, for the date scroller and the
/// viewer's flight, and moving it, as SwiftUI's ScrollViewProxy moves a scroll view.
@MainActor @Observable final class PhotoGridScroller {
    @ObservationIgnored fileprivate weak var controller: PhotoGridController?
    /// Photos a row, and a row's height with the space below it, as the grid lays them out.
    private(set) var columns = 1
    private(set) var pitch = 0.0
    /// The grid's top left in the viewer's space (`ViewerCellFrames.space`).
    @ObservationIgnored var origin: CGPoint = .zero

    fileprivate func publish(_ geometry: PhotoGridGeometry) {
        if columns != geometry.columns { columns = geometry.columns }
        if abs(pitch - Double(geometry.pitch)) > 0.0001 { pitch = Double(geometry.pitch) }
    }

    /// Puts a place, in points down the months, at the top of the view below the bars.
    func scrollTo(monthsY: Double) { controller?.scrollTo(monthsY: CGFloat(monthsY)) }

    /// Scrolls only as far as needed to show a photo, as Finder and Photos scroll with the arrow keys.
    func reveal(_ id: String) { controller?.reveal(id) }

    /// Puts a photo in the middle of the view, unless it is in view; false when the grid has no place for it.
    @discardableResult
    func center(_ id: String) -> Bool { controller?.center(id) ?? false }

    /// Keeps the viewer's photo in view behind it, so closing it flies back into its tile.
    func follow(_ id: String) { _ = controller?.center(id) }

    /// The keys go to the grid again (the viewer has closed).
    func takeFocus() { controller?.takeFocus() }
}

struct PhotoGridCollection: NSViewRepresentable {
    let model: AssetGridModel
    let pipeline: ImagePipeline
    let client: ImmichClient
    /// The tiles' least side (`GridMetrics.steps`): a new one zooms the grid to it about the middle of the view.
    let size: Double
    let look: PhotoGridTileLook
    /// Read so the grid draws again as the selection changes.
    let selection: Set<String>
    /// Above the photos, scrolling with them.
    var header: AnyView?
    /// The page's bars over the grid, which the photos run on under and rest clear of.
    let insets: EdgeInsets
    let scroller: PhotoGridScroller
    let railPosition: TimelineRailPosition
    var cellFrames: ViewerCellFrames?
    let actions: PhotoGridActions

    func makeCoordinator() -> PhotoGridController { PhotoGridController() }

    func makeNSView(context: Context) -> PhotoGridContainerView {
        let view = context.coordinator.makeView()
        context.coordinator.update(self, environment: context.environment)
        return view
    }

    func updateNSView(_ view: PhotoGridContainerView, context: Context) {
        context.coordinator.update(self, environment: context.environment)
    }

    static func dismantleNSView(_ view: PhotoGridContainerView, coordinator: PhotoGridController) {
        coordinator.dismantle()
    }
}

/// The grid's view on the page: its scroll view, and over it, while a pinch is under way, the picture of the size
/// shown (`PhotoGridPicture`).
final class PhotoGridContainerView: NSView {
    override var isFlipped: Bool { true }
}

/// The grid's scroll view, which keeps the place as its width changes (Info opening, the window resizing), and
/// doesn't scroll while a pinch holds the grid.
final class PhotoGridScrollView: NSScrollView {
    fileprivate weak var controller: PhotoGridController?

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanges = abs(newSize.width - frame.width) > 0.5
        if widthChanges { controller?.abandonZoom() }
        let anchor = widthChanges ? controller?.middleAnchor() : nil
        super.setFrameSize(newSize)
        controller?.resized(keeping: anchor)
    }

    override func scrollWheel(with event: NSEvent) {
        if controller?.isZooming == true { return }
        super.scrollWheel(with: event)
    }
}

/// Everything the grid knows and does: the collection view's data, where things are, scrolling, and what the mouse
/// and the keys do.
@MainActor final class PhotoGridController: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate {
    private var parent: PhotoGridCollection?
    private var environment = EnvironmentValues()
    let layout = PhotoGridLayout()
    private let container = PhotoGridContainerView()
    private let scrollView = PhotoGridScrollView()
    private let clipView = PhotoGridClipView()
    private let collectionView = PhotoGridCollectionView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
    private let dragSource = PhotoGridDragSource()
    private let pinch = PhotoGridPinch()
    /// The picture of the size shown over the grid while a pinch is under way, made at the first.
    private var picture: PhotoGridPicture?
    /// The size the grid shows at rest, and the one its page asks for, which it zooms to.
    private(set) var shownSize: Double = 0
    /// The page changed the months while a pinch held the grid: they are laid out once it is over.
    private var reshapeWaits = false
    /// Geometries at other sizes for a pinch, at the width and months they were worked out for.
    private var sizedGeometries: [Double: PhotoGridGeometry] = [:]
    /// The months as the collection view was last given them, by ID: its sections are these.
    private var shownSections: [String] = []
    private var shownLook = PhotoGridTileLook()
    private var measuredPageHeader: CGFloat?
    private var insetsApplied = false
    /// The width the grid was last laid out at.
    private var laidOutWidth: CGFloat = 0
    /// Scrolls asked for before the grid had a width to lay out at.
    private var pending: [() -> Void] = []
    /// The months whose photos were last said to be in view.
    private var reportedSections: [String]?
    private var reportScheduled = false
    private var press: Press?
    private var band: PhotoGridBand?
    private var autoscroll: Timer?

    private var model: AssetGridModel? { parent?.model }
    private var geometry: PhotoGridGeometry { layout.geometry }
    private var clip: NSRect { scrollView.contentView.bounds }
    private var isAtTop: Bool { clip.minY <= -layout.topInset + 0.5 }
    /// A pinch holds the grid.
    fileprivate var isZooming: Bool { pinch.isActive }

    func makeView() -> PhotoGridContainerView {
        scrollView.contentView = clipView
        scrollView.minMagnification = 0.05
        scrollView.maxMagnification = 20
        scrollView.frame = container.bounds
        scrollView.autoresizingMask = [.width, .height]
        container.addSubview(scrollView)
        pinch.stage = self
        pinch.view = container
        collectionView.collectionViewLayout = layout
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.controller = self
        collectionView.isSelectable = false
        collectionView.backgroundColors = [.clear]
        collectionView.register(PhotoGridTileItem.self, forItemWithIdentifier: PhotoGridTileItem.identifier)
        collectionView.register(PhotoGridMonthHeader.self, forSupplementaryViewOfKind: PhotoGridLayout.monthHeaderKind,
                                withIdentifier: PhotoGridMonthHeader.identifier)
        collectionView.register(PhotoGridPageHeader.self, forSupplementaryViewOfKind: PhotoGridLayout.pageHeaderKind,
                                withIdentifier: PhotoGridPageHeader.identifier)
        scrollView.controller = self
        scrollView.documentView = collectionView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(clipScrolled(_:)), name: NSView.boundsDidChangeNotification,
                                               object: scrollView.contentView)
        return container
    }

    func dismantle() {
        NotificationCenter.default.removeObserver(self)
        pinch.abandon()
        endBand()
        if let cellFrames = parent?.cellFrames { cellFrames.locate = nil }
    }

    // MARK: Following SwiftUI

    func update(_ parent: PhotoGridCollection, environment: EnvironmentValues) {
        let reshaped = parent.look.fit != shownLook.fit
        let restyled = parent.look != shownLook
        shownLook = parent.look
        self.parent = parent
        self.environment = environment
        parent.scroller.controller = self
        parent.cellFrames?.locate = { [weak self] id in self?.frameOnPage(of: id) }
        applyInsets(parent.insets)

        if shownSize == 0 {
            shownSize = parent.size
            layout.inputs.size = parent.size
        }
        reshape()
        refreshTiles(restyled: restyled, animated: reshaped)
        refreshPageHeader()
        followSize()
        scheduleReport()
    }

    /// The model's months laid out, if they changed: the photo at the top of the view stays where it is (months loading,
    /// photos deleted). Not while a pinch holds the grid, which lays them out once it is over.
    private func reshape() {
        guard let parent else { return }
        guard !pinch.isActive else {
            reshapeWaits = true
            return
        }
        reshapeWaits = false
        let model = parent.model
        let sections = model.sections
        var inputs = layout.inputs
        inputs.counts = sections.map(model.shownCount)
        inputs.headers = sections.map { model.showsSectionHeaders && $0.title != nil }
        let hasHeader = parent.header != nil
        if hasHeader != layout.hasPageHeader {
            layout.hasPageHeader = hasHeader
            if !hasHeader { measuredPageHeader = nil }
        }
        // A guess until the header has drawn itself.
        inputs.pageHeader = hasHeader ? measuredPageHeader ?? 44 : 0
        let ids = sections.map(\.id)
        guard inputs != layout.inputs || ids != shownSections else { return }
        let anchor = keptPlace(at: CGPoint(x: 0, y: layout.topInset))
        layout.inputs = inputs
        shownSections = ids
        reportedSections = nil
        sizedGeometries = [:]
        collectionView.reloadData()
        settle()
        restore(anchor)
        model.columns = geometry.columns
    }

    /// The size the page asks for (⌘+ and ⌘−, the toolbar's − and +): the grid zooms to it about the middle of the
    /// view, as a pinch lets go, or takes it at once where it shows as many photos a row.
    private func followSize() {
        guard let wanted = parent?.size, !pinch.isActive else { return }
        if let settled = pinch.settledSize {
            // The page has yet to take the size a pinch settled on.
            if wanted == settled { pinch.shows(size: settled) }
            return
        }
        guard wanted != shownSize else { return }
        if geometry.width >= 1, container.window != nil,
           abs(pitch(forSize: wanted) - pitch(forSize: shownSize)) > 0.5 {
            // Once SwiftUI's update is over: the motion lays out views of its own.
            Task { @MainActor [weak self] in
                guard let self, parent?.size == wanted, wanted != shownSize, !pinch.isActive else { return }
                let middle = CGPoint(x: clipView.frame.width / 2,
                                     y: layout.topInset + (clipView.frame.height - layout.topInset) / 2)
                if !pinch.zoom(to: wanted, about: middle) { take(wanted) }
            }
            return
        }
        take(wanted)
    }

    /// A size taken at once, the first photo in view staying where it is.
    private func take(_ size: Double) {
        let anchor = keptPlace(at: CGPoint(x: 0, y: layout.topInset))
        shownSize = size
        layout.inputs.size = size
        settle()
        restore(anchor)
        model?.columns = geometry.columns
        scheduleReport()
    }

    /// The bars over the grid as the scroll view's insets: the photos stay where they are, at the top if they were.
    private func applyInsets(_ insets: EdgeInsets) {
        let top = max(0, insets.top)
        guard !insetsApplied || abs(top - layout.topInset) > 0.5 else { return }
        let atTop = !insetsApplied || isAtTop
        insetsApplied = true
        layout.topInset = top
        scrollView.contentInsets = NSEdgeInsets(top: top, left: 0, bottom: 0, right: 0)
        if atTop { scroll(toClipY: -top) }
    }

    /// The tiles in view drawn again: all of them for a new look, else those whose photo changed (a month loaded, a
    /// favorite), and the selection.
    private func refreshTiles(restyled: Bool, animated: Bool) {
        guard let parent else { return }
        let selection = parent.model.selection
        for indexPath in collectionView.indexPathsForVisibleItems() {
            guard let item = collectionView.item(at: indexPath) as? PhotoGridTileItem else { continue }
            let asset = asset(at: PhotoGridGeometry.Place(section: indexPath.section, item: indexPath.item))
            let selected = asset.map { selection.contains($0.id) } ?? false
            if !restyled, item.tile.asset == asset {
                item.tile.setSelected(selected)
            } else {
                item.tile.show(asset, look: shownLook, selected: selected, pipeline: parent.pipeline, animated: animated)
            }
        }
    }

    private func refreshPageHeader() {
        guard layout.hasPageHeader,
              let view = collectionView.supplementaryView(forElementKind: PhotoGridLayout.pageHeaderKind,
                                                          at: IndexPath(item: 0, section: 0)) as? PhotoGridPageHeader else { return }
        showPageHeader(in: view)
    }

    private func showPageHeader(in view: PhotoGridPageHeader) {
        guard let header = parent?.header else { return }
        view.show(header, environment: environment) { [weak self] height in self?.pageHeaderMeasured(height) }
    }

    /// The page's header drew itself at a new height: the layout makes room for it, the photos staying where they are,
    /// at the top if they were.
    private func pageHeaderMeasured(_ height: CGFloat) {
        guard layout.hasPageHeader, height > 0, abs(height - layout.inputs.pageHeader) > 0.5 else { return }
        guard !pinch.isActive else {
            // Laid out once the pinch is over.
            measuredPageHeader = height
            reshapeWaits = true
            return
        }
        let atTop = isAtTop
        let change = height - layout.inputs.pageHeader
        let top = clip.minY
        measuredPageHeader = height
        layout.inputs.pageHeader = height
        sizedGeometries = [:]
        settle()
        scroll(toClipY: atTop ? -layout.topInset : top + change)
        scheduleReport()
    }

    // MARK: The collection view's data

    /// The model's photo at a tile, while the model's months are those the collection view was given.
    private func asset(at place: PhotoGridGeometry.Place) -> AssetItem? {
        guard let model, shownSections.indices.contains(place.section), model.sections.indices.contains(place.section),
              model.sections[place.section].id == shownSections[place.section] else { return nil }
        return model.asset(place.section, place.item)
    }

    /// The grid's own layout, or the picture's while a pinch is under way: the controller tells both collection views
    /// their months.
    private func gridLayout(_ collectionView: NSCollectionView) -> PhotoGridLayout {
        collectionView.collectionViewLayout as? PhotoGridLayout ?? layout
    }

    func numberOfSections(in collectionView: NSCollectionView) -> Int { gridLayout(collectionView).inputs.counts.count }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        let counts = gridLayout(collectionView).inputs.counts
        return counts.indices.contains(section) ? counts[section] : 0
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: PhotoGridTileItem.identifier, for: indexPath) as! PhotoGridTileItem
        guard let parent else { return item }
        let asset = asset(at: PhotoGridGeometry.Place(section: indexPath.section, item: indexPath.item))
        item.tile.show(asset, look: shownLook, selected: asset.map { parent.model.selection.contains($0.id) } ?? false,
                       pipeline: parent.pipeline)
        // A month's photos load as its tiles come into view.
        if collectionView === self.collectionView, shownSections.indices.contains(indexPath.section),
           parent.model.sections.indices.contains(indexPath.section),
           parent.model.sections[indexPath.section].id == shownSections[indexPath.section] {
            parent.model.cellAppeared(section: indexPath.section, item: indexPath.item)
        }
        return item
    }

    func collectionView(_ collectionView: NSCollectionView, viewForSupplementaryElementOfKind kind: NSCollectionView.SupplementaryElementKind,
                        at indexPath: IndexPath) -> NSView {
        if kind == PhotoGridLayout.pageHeaderKind {
            let view = collectionView.makeSupplementaryView(ofKind: kind, withIdentifier: PhotoGridPageHeader.identifier,
                                                            for: indexPath) as! PhotoGridPageHeader
            showPageHeader(in: view)
            return view
        }
        let view = collectionView.makeSupplementaryView(ofKind: kind, withIdentifier: PhotoGridMonthHeader.identifier,
                                                        for: indexPath) as! PhotoGridMonthHeader
        let sections = model?.sections ?? []
        view.show(title: sections.indices.contains(indexPath.section) ? sections[indexPath.section].title ?? "" : "")
        return view
    }

    func collectionView(_ collectionView: NSCollectionView, didEndDisplaying item: NSCollectionViewItem,
                        forRepresentedObjectAt indexPath: IndexPath) {
        (item as? PhotoGridTileItem)?.tile.stopLoading()
    }

    // MARK: Where things are

    /// The layout at the scroll view's width now, the collection view as tall as its content.
    private func settle() {
        // The clip view's frame: its bounds are magnified while a pinch is under way.
        let shown = clipView.frame
        laidOutWidth = shown.width
        layout.invalidateLayout()
        let size = NSSize(width: shown.width, height: max(geometry.contentHeight, shown.height - layout.topInset))
        if collectionView.frame.size != size { collectionView.setFrameSize(size) }
    }

    /// A photo's square on the page, for the viewer's flight; nil where the grid has no place for it.
    private func frameOnPage(of id: String) -> CGRect? {
        guard let place = place(of: id), let parent else { return nil }
        let origin = parent.scroller.origin
        return geometry.tileFrame(place).offsetBy(dx: origin.x - clip.minX, dy: origin.y - clip.minY)
    }

    private func place(of id: String) -> PhotoGridGeometry.Place? {
        guard let order = model?.order(of: id), layout.inputs.counts.indices.contains(order.section),
              shownSections[order.section] == model?.sections[order.section].id,
              order.item < layout.inputs.counts[order.section] else { return nil }
        return PhotoGridGeometry.Place(section: order.section, item: order.item)
    }

    /// The place to keep through a change of the grid: the photo at a point of the view (from its top), how far down it
    /// the point is, and whether the grid was at its top, where it stays.
    fileprivate struct Anchor {
        let id: String?
        let section: String
        let item: Int
        let fraction: CGFloat
        let viewY: CGFloat
        let atTop: Bool
    }

    private func keptPlace(at point: CGPoint) -> Anchor? {
        let geometry = geometry
        guard geometry.width > 0 else { return nil }
        let contentPoint = CGPoint(x: point.x, y: clip.minY + point.y)
        guard let place = geometry.nearestPlace(to: contentPoint), shownSections.indices.contains(place.section) else {
            return isAtTop ? Anchor(id: nil, section: "", item: 0, fraction: 0, viewY: 0, atTop: true) : nil
        }
        let frame = geometry.tileFrame(place)
        let fraction = min(max((contentPoint.y - frame.minY) / max(1, frame.height), 0), 1)
        return Anchor(id: asset(at: place)?.id, section: shownSections[place.section], item: place.item, fraction: fraction,
                      viewY: point.y, atTop: isAtTop)
    }

    /// The photo in the middle of the view, kept there as the width changes; the top, where the grid is at it.
    fileprivate func middleAnchor() -> Anchor? {
        keptPlace(at: CGPoint(x: clip.width / 2, y: layout.topInset + (clip.height - layout.topInset) / 2))
    }

    private func restore(_ anchor: Anchor?) {
        guard let anchor else { return }
        if anchor.atTop {
            scroll(toClipY: -layout.topInset)
            return
        }
        var place = anchor.id.flatMap { self.place(of: $0) }
        if place == nil, let section = shownSections.firstIndex(of: anchor.section), layout.inputs.counts[section] > 0 {
            place = PhotoGridGeometry.Place(section: section, item: min(anchor.item, layout.inputs.counts[section] - 1))
        }
        guard let place else { return }
        let frame = geometry.tileFrame(place)
        scroll(toClipY: frame.minY + anchor.fraction * frame.height - anchor.viewY)
    }

    /// The scroll view's width changed: the grid lays out at the new one, keeping its place.
    fileprivate func resized(keeping anchor: Anchor?) {
        scrollView.tile()
        let width = clip.width
        guard width >= 1 else { return }
        if abs(width - laidOutWidth) > 0.5 || collectionView.frame.width != width {
            settle()
            restore(anchor)
            model?.columns = geometry.columns
        }
        if !pending.isEmpty {
            let actions = pending
            pending = []
            actions.forEach { $0() }
        }
        scheduleReport()
    }

    private func whenLaidOut(_ action: @escaping () -> Void) {
        if geometry.width >= 1 { action() } else { pending.append(action) }
    }

    // MARK: Scrolling

    private func scroll(toClipY y: CGFloat) {
        let clipView = scrollView.contentView
        let lowest = -layout.topInset
        let highest = max(lowest, geometry.contentHeight - clipView.bounds.height)
        let target = min(max(y, lowest), highest)
        // Across too: a pinch moves the view sideways on its way.
        guard abs(target - clipView.bounds.minY) > 0.01 || abs(clipView.bounds.minX) > 0.01 else { return }
        clipView.scroll(to: NSPoint(x: 0, y: target))
        scrollView.reflectScrolledClipView(clipView)
    }

    fileprivate func scrollTo(monthsY: CGFloat) {
        whenLaidOut { [weak self] in
            guard let self else { return }
            scroll(toClipY: geometry.monthsTop + monthsY - layout.topInset)
        }
    }

    /// Only as far as needed: below the bars and below the month's header, which stays at the top over its photos.
    fileprivate func reveal(_ id: String) {
        whenLaidOut { [weak self] in
            guard let self, let place = place(of: id) else { return }
            let frame = geometry.tileFrame(place)
            let header = geometry.sections[place.section].header
            let top = clip.minY + layout.topInset + header
            if frame.minY < top {
                scroll(toClipY: frame.minY - layout.topInset - header)
            } else if frame.maxY > clip.maxY {
                scroll(toClipY: frame.maxY - clip.height)
            }
        }
    }

    fileprivate func center(_ id: String) -> Bool {
        guard model?.order(of: id) != nil else { return false }
        whenLaidOut { [weak self] in
            guard let self, let place = place(of: id) else { return }
            let frame = geometry.tileFrame(place)
            let visibleTop = clip.minY + layout.topInset
            if frame.minY >= visibleTop, frame.maxY <= clip.maxY { return }
            scroll(toClipY: frame.midY - layout.topInset - (clip.height - layout.topInset) / 2)
        }
        return true
    }

    fileprivate func takeFocus() {
        Task { @MainActor [weak self] in
            guard let self, let window = collectionView.window, !(window.firstResponder is NSText) else { return }
            window.makeFirstResponder(collectionView)
        }
    }

    @objc private func clipScrolled(_ notification: Notification) {
        scheduleReport()
    }

    /// Reports once the layout pass at hand is over: what the reports change is observed, and changing it while
    /// SwiftUI or AppKit lays the page out made AppKit's layout loop before (`startMotion` in AssetGridView).
    private func scheduleReport() {
        guard !reportScheduled else { return }
        reportScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            reportScheduled = false
            reportPosition()
        }
    }

    /// Tells the date scroller where the grid is and how it lays its rows out, the window's title the months in view,
    /// and the page whether its header names it.
    private func reportPosition() {
        // A pinch magnifies the grid on its way: it reports once at rest.
        guard let parent, geometry.width > 0, !pinch.isActive else { return }
        let geometry = geometry
        parent.scroller.publish(geometry)
        let top = clip.minY + layout.topInset
        let offset = Double(top - geometry.monthsTop)
        if parent.railPosition.offset != offset { parent.railPosition.offset = offset }
        let months = geometry.sections(from: top, to: clip.maxY).map { range in
            range.filter { geometry.sections[$0].count > 0 && shownSections.indices.contains($0) }.map { shownSections[$0] }
        } ?? []
        if months != reportedSections {
            reportedSections = months
            parent.model.showing(sections: months)
        }
        if layout.hasPageHeader {
            // As SwiftUI said it: a quarter of the header in view.
            let header = geometry.pageHeader
            let shown = max(0, min(header, clip.maxY) - max(0, top))
            let inView = header > 0 && shown >= header * 0.25
            if parent.model.headerInView != inView { parent.model.headerInView = inView }
        }
    }

    // MARK: The mouse

    private enum Press {
        /// On a photo: a click selects it, unless it was selected already and nothing is held, when the click selects it
        /// alone on the way up, so the selection can be dragged.
        case photo(id: String, place: PhotoGridGeometry.Place, start: NSPoint, selectsOnRelease: Bool)
        /// Between photos or on a header: a rubber band selects what it touches.
        case space(start: NSPoint, base: Set<String>, mode: BandMode, banding: Bool)
        case dragging
    }

    private enum BandMode {
        case replace, add, toggle
    }

    fileprivate func mouseDown(_ event: NSEvent) {
        guard let model, !pinch.isActive else { return }
        collectionView.window?.makeFirstResponder(collectionView)
        let point = collectionView.convert(event.locationInWindow, from: nil)
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.control), let menu = menu(at: point) {
            press = nil
            NSMenu.popUpContextMenu(menu, with: event, for: collectionView)
            return
        }
        if let place = geometry.place(at: point), let asset = asset(at: place) {
            if event.clickCount >= 2 {
                press = nil
                model.open(asset.id)
                return
            }
            let held = flags.contains(.command) || flags.contains(.shift)
            if !held, model.selection.contains(asset.id) {
                press = .photo(id: asset.id, place: place, start: point, selectsOnRelease: true)
            } else {
                model.click(asset.id)
                refreshSelection()
                press = .photo(id: asset.id, place: place, start: point, selectsOnRelease: false)
            }
        } else {
            let mode: BandMode = flags.contains(.command) ? .toggle : flags.contains(.shift) ? .add : .replace
            press = .space(start: point, base: model.selection, mode: mode, banding: false)
        }
    }

    fileprivate func mouseDragged(_ event: NSEvent) {
        let point = collectionView.convert(event.locationInWindow, from: nil)
        switch press {
        case .photo(_, let place, let start, _):
            guard hypot(point.x - start.x, point.y - start.y) > 3 else { return }
            press = .dragging
            beginDrag(from: place, event: event)
        case .space(let start, let base, let mode, _):
            press = .space(start: start, base: base, mode: mode, banding: true)
            stretchBand(to: point)
            startAutoscroll()
        default:
            break
        }
    }

    fileprivate func mouseUp(_ event: NSEvent) {
        switch press {
        case .photo(let id, _, _, true):
            model?.click(id)
            refreshSelection()
        case .space(_, _, .replace, false):
            // Clicking the space between photos clears the selection, as in Photos.
            model?.selection = []
            refreshSelection()
        case .space(_, _, _, true):
            endBand()
        default:
            break
        }
        press = nil
    }

    private func refreshSelection() {
        guard let selection = model?.selection else { return }
        for item in collectionView.visibleItems() {
            guard let tile = (item as? PhotoGridTileItem)?.tile else { continue }
            tile.setSelected(tile.asset.map { selection.contains($0.id) } ?? false)
        }
    }

    // MARK: The rubber band

    /// The band from where the press began to `point`, both in the content, and the photos it touches selected.
    private func stretchBand(to point: NSPoint) {
        guard case .space(let start, let base, let mode, _) = press, let model else { return }
        let rect = NSRect(x: min(start.x, point.x), y: min(start.y, point.y), width: abs(point.x - start.x), height: abs(point.y - start.y))
        let view = band ?? {
            let view = PhotoGridBand()
            collectionView.addSubview(view)
            band = view
            return view
        }()
        view.frame = rect
        let touched = Set(geometry.places(touching: rect).compactMap { asset(at: $0)?.id })
        let selection: Set<String> = switch mode {
        case .replace: touched
        case .add: base.union(touched)
        case .toggle: base.symmetricDifference(touched)
        }
        if selection != model.selection {
            model.selection = selection
            refreshSelection()
        }
    }

    /// While the band is held beyond the top or the foot of the view, the grid scrolls on under it, the faster the
    /// further.
    private func startAutoscroll() {
        guard autoscroll == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.autoscrollTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        autoscroll = timer
    }

    private func autoscrollTick() {
        guard case .space(_, _, _, true) = press, let window = collectionView.window else { return }
        let point = collectionView.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        let top = clip.minY + layout.topInset
        let distance = point.y < top ? point.y - top : point.y > clip.maxY ? point.y - clip.maxY : 0
        guard distance != 0 else { return }
        let step = (distance > 0 ? 1 : -1) * min(60, abs(distance) / 3 + 4)
        scroll(toClipY: clip.minY + step)
        stretchBand(to: collectionView.convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    private func endBand() {
        autoscroll?.invalidate()
        autoscroll = nil
        band?.removeFromSuperview()
        band = nil
    }

    // MARK: Dragging out

    /// The photos dragged out as their originals, promised (OriginalFilePromise): the selection in the grid's order when
    /// the photo is in it, else the photo alone, as Photos drags.
    private func beginDrag(from place: PhotoGridGeometry.Place, event: NSEvent) {
        guard let model, let parent, let dragged = asset(at: place) else { return }
        let ids = model.selection.contains(dragged.id) ? model.macDragSelection : [dragged.id]
        let drag = OriginalDrag(ids: ids, client: parent.client)
        drag.start()
        // The tiles in view, each at its place with its picture; the others gather at the dragged one.
        var shown: [String: (frame: NSRect, image: NSImage?)] = [:]
        for item in collectionView.visibleItems() {
            guard let tile = (item as? PhotoGridTileItem)?.tile, let id = tile.asset?.id else { continue }
            shown[id] = (item.view.frame, tile.image.map { NSImage(cgImage: $0, size: item.view.frame.size) })
        }
        let start: (frame: NSRect, image: NSImage?) = shown[dragged.id] ?? (geometry.tileFrame(place), nil)
        let lockedFolder = model.source == .locked
        var promises: [OriginalFilePromise] = []
        let items = ids.enumerated().map { position, id in
            let promise = OriginalFilePromise(id: id, file: drag.file(at: position), client: parent.client,
                                              albumIDs: lockedFolder ? nil : [id])
            promises.append(promise)
            let item = NSDraggingItem(pasteboardWriter: promise)
            let place: (frame: NSRect, image: NSImage?) = shown[id] ?? (start.frame, nil)
            item.setDraggingFrame(place.frame, contents: place.image ?? (id == dragged.id ? start.image : nil))
            return item
        }
        // Kept until the next drag: a receiver may ask for the files after the drag has ended.
        dragSource.promises = promises
        _ = collectionView.beginDraggingSession(with: items, event: event, source: dragSource)
    }

    // MARK: Menus

    fileprivate func menu(at point: NSPoint) -> NSMenu? {
        guard let parent, let place = geometry.place(at: point), let asset = asset(at: place) else { return nil }
        return NSHostingMenu(rootView: parent.actions.menu(asset).environment(\.self, environment))
    }

    // MARK: Keys

    /// The grid is hidden behind an open photo, whose keys they are.
    fileprivate var isCovered: Bool { model?.viewerID != nil }

    /// The grid's keys: Space, Return, ⌫ and ⌘⌫, the arrows (with Shift), Esc and ".".
    fileprivate func keyDown(_ event: NSEvent) -> Bool {
        guard let model, let parent, model.viewerID == nil, !pinch.isActive else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let ids = Array(model.selection)
        switch event.keyCode {
        case 49: // Space
            guard !ids.isEmpty, flags.isDisjoint(with: [.command, .control, .option]) else { return false }
            parent.actions.quickLook()
        case 36, 76: // Return, Enter
            guard let first = model.selectedItems.first else { return false }
            model.open(first.id)
        case 51, 117: // ⌫, ⌦
            guard !ids.isEmpty, flags.isDisjoint(with: [.shift, .option, .control]) else { return false }
            parent.actions.delete(ids, flags.contains(.command))
        case 123, 124, 125, 126:
            // Command with an arrow is left to the menus and the system.
            guard !flags.contains(.command) else { return false }
            let direction: AssetGridModel.Move = switch event.keyCode {
            case 123: .left
            case 124: .right
            case 126: .up
            default: .down
            }
            let extending = flags.contains(.shift)
            Task { await model.move(direction, extending: extending) }
        case 53: // Esc
            model.selection = []
        default:
            guard event.characters == ".", !ids.isEmpty else { return false }
            Task { await model.toggleFavorite(ids) }
        }
        return true
    }

    /// The Edit menu's Delete, whose key ⌫ is.
    fileprivate func deleteSelection() {
        guard let model, let parent, !model.selection.isEmpty else { return }
        parent.actions.delete(Array(model.selection), false)
    }

    // MARK: Pinching

    /// A pinch on the trackpad, at the point of the view under the pointer (PhotoGridPinch).
    fileprivate func magnify(_ event: NSEvent) {
        guard geometry.width >= 1, model?.viewerID == nil else { return }
        pinch.magnify(event, at: container.convert(event.locationInWindow, from: nil))
    }

    /// The width changes under a pinch: it lets go of the grid.
    fileprivate func abandonZoom() {
        pinch.abandon()
    }
}

extension PhotoGridController: PhotoGridZoomStage {
    /// The grid at another size, at its width now, with its months.
    private func geometry(forSize size: Double) -> PhotoGridGeometry {
        if size == layout.inputs.size { return geometry }
        let width = clipView.frame.width
        if let known = sizedGeometries[size], known.width == width { return known }
        var inputs = layout.inputs
        inputs.size = size
        let sized = PhotoGridGeometry(width: width, inputs: inputs)
        sizedGeometries[size] = sized
        return sized
    }

    func size(beyond size: Double, step: Int) -> Double? {
        let steps = GridMetrics.steps
        guard let start = steps.indices.min(by: { abs(steps[$0] - size) < abs(steps[$1] - size) }) else { return nil }
        let columns = geometry(forSize: size).columns
        var index = start + step
        while steps.indices.contains(index) {
            if geometry(forSize: steps[index]).columns != columns { return steps[index] }
            index += step
        }
        return nil
    }

    func pitch(forSize size: Double) -> CGFloat { geometry(forSize: size).pitch }

    func anchor(at point: CGPoint) -> (place: PhotoGridGeometry.Place, fraction: CGFloat)? {
        let shown = geometry(forSize: shownSize)
        guard point.y >= shown.monthsTop, let place = shown.nearestPlace(to: point) else { return nil }
        let frame = shown.tileFrame(place)
        return (place, min(max((point.y - frame.minY) / max(1, frame.height), 0), 1))
    }

    func frame(of place: PhotoGridGeometry.Place, forSize size: Double) -> CGRect {
        geometry(forSize: size).tileFrame(place)
    }

    func contentHeight(forSize size: Double) -> CGFloat { geometry(forSize: size).contentHeight }

    var offset: CGFloat { clip.minY }
    var viewHeight: CGFloat { clipView.frame.height }
    var topInset: CGFloat { layout.topInset }

    func setOut(toward size: Double, _ transition: GridZoomTransition, keepingPicture: Bool) {
        endBand()
        press = nil
        if !keepingPicture { takePicture(offset: transition.fromOffset) }
        // The grid at the next size under the picture, its headers where they rest there.
        layout.frozenTop = transition.toOffset + layout.topInset
        layout.inputs.size = size
        clipView.movesFreely = true
        settle()
        show(transition)
    }

    /// The picture of the grid as it shows at rest, over the grid while the pinch is under way.
    private func takePicture(offset: CGFloat) {
        let picture = self.picture ?? {
            let picture = PhotoGridPicture(source: self)
            picture.scrollView.frame = container.bounds
            picture.scrollView.autoresizingMask = [.width, .height]
            container.addSubview(picture.scrollView, positioned: .above, relativeTo: scrollView)
            self.picture = picture
            return picture
        }()
        var inputs = layout.inputs
        inputs.size = shownSize
        picture.take(inputs, hasPageHeader: layout.hasPageHeader, width: clipView.frame.width, topInset: layout.topInset,
                     offset: offset, viewHeight: clipView.frame.height)
    }

    func show(_ transition: GridZoomTransition) {
        let next = transition.nextMagnified
        scrollView.magnification = next.magnification
        clipView.setBoundsOrigin(next.origin)
        scrollView.reflectScrolledClipView(clipView)
        picture?.place(transition.pictureMagnified, alpha: 1 - min(max(transition.progress, 0), 1))
    }

    func arrive(at size: Double, _ transition: GridZoomTransition) {
        rest(at: size, offset: transition.toOffset)
        shownSize = size
        parent?.actions.setSize(size)
    }

    func goBack(to size: Double, _ transition: GridZoomTransition) {
        rest(at: size, offset: transition.fromOffset)
    }

    /// The grid at a size, unmagnified, the view's top at `offset`, and the picture gone.
    private func rest(at size: Double, offset: CGFloat) {
        layout.frozenTop = nil
        layout.inputs.size = size
        scrollView.magnification = 1
        clipView.movesFreely = false
        settle()
        scroll(toClipY: offset)
        picture?.drop()
        model?.columns = geometry.columns
    }

    func zoomEnded() {
        if reshapeWaits { reshape() }
        refreshTiles(restyled: false, animated: false)
        scheduleReport()
        // A size the page asked for meanwhile (⌘+ or ⌘−).
        Task { @MainActor [weak self] in self?.followSize() }
    }
}

/// The collection view, which tells the grid what the mouse and the keys do, rather than selecting by itself.
final class PhotoGridCollectionView: NSCollectionView {
    fileprivate weak var controller: PhotoGridController?

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) { controller?.mouseDown(event) }
    override func mouseDragged(with event: NSEvent) { controller?.mouseDragged(event) }
    override func mouseUp(with event: NSEvent) { controller?.mouseUp(event) }

    override func menu(for event: NSEvent) -> NSMenu? {
        controller?.menu(at: convert(event.locationInWindow, from: nil))
    }

    override func keyDown(with event: NSEvent) {
        if controller?.keyDown(event) == true { return }
        // Behind an open photo, up to the page, whose viewer takes them.
        if controller?.isCovered == true { nextResponder?.keyDown(with: event) } else { super.keyDown(with: event) }
    }

    /// The Edit menu's Delete.
    @objc func delete(_ sender: Any?) {
        controller?.deleteSelection()
    }

    override func magnify(with event: NSEvent) {
        controller?.magnify(event)
    }
}

/// What the grid's drags out are: copies of the originals.
@MainActor private final class PhotoGridDragSource: NSObject, NSDraggingSource {
    var promises: [OriginalFilePromise] = []

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }
}

/// The rubber band, as Finder draws one.
private final class PhotoGridBand: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.zPosition = 100
        layer?.borderWidth = 1
        needsDisplay = true
    }

    required init?(coder: NSCoder) { nil }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.secondaryLabelColor.withAlphaComponent(0.15).cgColor
        layer?.borderColor = NSColor.secondaryLabelColor.withAlphaComponent(0.5).cgColor
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A month's header (`SectionHeader`): its name on glass at the leading edge.
final class PhotoGridMonthHeader: NSView, NSCollectionViewElement {
    static let identifier = NSUserInterfaceItemIdentifier("PhotoGridMonthHeader")
    private var host: NSHostingView<SectionHeader>?
    private var title: String?

    func show(title: String) {
        guard title != self.title else { return }
        self.title = title
        if let host {
            host.rootView = SectionHeader(title: title)
        } else {
            let host = NSHostingView(rootView: SectionHeader(title: title))
            host.sizingOptions = []
            host.frame = bounds
            host.autoresizingMask = [.width, .height]
            addSubview(host)
            self.host = host
        }
    }

    /// Clicks on a header go to the grid.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The page's header above the months (an album's details), as tall as it draws itself at the grid's width, which it
/// tells the layout as it changes, its details loading.
final class PhotoGridPageHeader: NSView, NSCollectionViewElement {
    static let identifier = NSUserInterfaceItemIdentifier("PhotoGridPageHeader")
    private var host: NSHostingView<AnyView>?

    func show(_ header: AnyView, environment: EnvironmentValues, measured: @escaping @MainActor (CGFloat) -> Void) {
        let content = AnyView(
            header
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                    // Not inside the layout pass the measuring happens in.
                    Task { @MainActor in measured(height) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .environment(\.self, environment)
        )
        if let host {
            host.rootView = content
        } else {
            let host = NSHostingView(rootView: content)
            host.sizingOptions = []
            host.frame = bounds
            host.autoresizingMask = [.width, .height]
            addSubview(host)
            self.host = host
        }
    }
}
