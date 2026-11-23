// The photo grid's scroll view on iOS: UIKit's collection view, as Photos' grid is, rather than SwiftUI's lazy stack.
// Its layout (TimelineCollectionLayout) places every tile exactly where TimelineLayout's arithmetic puts it, every row
// one height, so the content's height is known and a scroll to any photo lands on it, in a library of any size, where
// a lazy stack reckons the rows it has not drawn at an estimate and a scroll deep into a large library lands far from
// its photo. The tiles are the grid's own SwiftUI views (TimelineGrid's TimelineTile), in the cells
// (`UIHostingConfiguration`), with their menus, their anchors for the viewer and their loading as they appear; the
// page's header is a cell of its own above them, as tall as it draws itself. TimelineGrid keeps everything the grid
// knows and does (landing at its newest photos, what is in view, the viewer's photo, selecting) and moves the grid
// through GridScroller, as SwiftUI's ScrollViewProxy moves a lazy stack. ARCHITECTURE.md, "The photo grid
// on the iPhone".

import SwiftUI
import UIKit

/// Moves the grid, as SwiftUI's ScrollViewProxy moves a scroll view: to a row at an anchor, exactly, the layout
/// knowing each row's place.
@MainActor final class GridScroller {
    fileprivate weak var collectionView: UICollectionView?
    /// Told as the grid starts an animated scroll of its own, which ends as the scroll view says (`.idle`).
    fileprivate var startedAnimating: (() -> Void)?

    /// The height of the page's header above the tiles, as it last drew itself.
    var headerHeight: CGFloat {
        (collectionView?.collectionViewLayout as? TimelineCollectionLayout)?.headerHeight ?? 0
    }

    /// Puts `row`'s `anchor` on the same point of the view between the bars (`.top`, `.center`, `.bottom`), as
    /// ScrollViewProxy.scrollTo does, within what the content allows.
    func scrollTo(row: Int, anchor: UnitPoint, animated: Bool = false) {
        guard let view = collectionView, let layout = view.collectionViewLayout as? TimelineCollectionLayout,
              layout.transition == nil else { return }
        view.layoutIfNeeded()
        let insets = view.adjustedContentInset
        let visible = view.bounds.height - insets.top - insets.bottom
        let top = layout.rowTop(row)
        let target = top + anchor.y * layout.metrics.side - anchor.y * visible - insets.top
        set(target, in: view, animated: animated)
    }

    /// Puts the content's `y` at the top of the view between the bars.
    func scrollTo(y: CGFloat, animated: Bool = false) {
        guard let view = collectionView, (view.collectionViewLayout as? TimelineCollectionLayout)?.transition == nil
        else { return }
        view.layoutIfNeeded()
        set(y - view.adjustedContentInset.top, in: view, animated: animated)
    }

    private func set(_ target: CGFloat, in view: UICollectionView, animated: Bool) {
        let insets = view.adjustedContentInset
        let lowest = -insets.top
        let highest = max(lowest, view.contentSize.height - view.bounds.height + insets.bottom)
        let offset = CGPoint(x: view.contentOffset.x, y: min(max(target, lowest), highest))
        guard abs(offset.y - view.contentOffset.y) > 0.5 else { return }
        if animated { startedAnimating?() }
        view.setContentOffset(offset, animated: animated)
    }
}

/// The grid's collection view, from SwiftUI.
struct TimelineCollection: UIViewRepresentable {
    /// The tiles, and what they look like: a change of `contentKey` draws the tiles in view again.
    let tileCount: Int
    let metrics: GridTileMetrics
    let contentKey: AnyHashable
    /// Changes when what each tile shows may have moved (the model's months, the phone's photos): every tile is asked
    /// for again.
    let layoutKey: AnyHashable
    let header: AnyView?
    let tile: (Int) -> AnyView
    /// The page's safe area, the bars over the grid and its title's among them, which the photos run on under but
    /// rest clear of: the view itself ignores it, so UIKit's own insets would leave out SwiftUI's bars.
    let insets: EdgeInsets
    /// A timeline whose newest photos are at the bottom keeps its bottom where it was as its content grows or shrinks.
    let anchoredAtBottom: Bool
    let isScrollEnabled: Bool
    let scroller: GridScroller
    let onScroll: (GridViewport) -> Void
    let onPhase: (ScrollPhase) -> Void
    /// While selecting, a drag that starts sideways, with its points in the rows' coordinates (the header's height
    /// taken off).
    let sidewaysEnabled: Bool
    let onSidewaysDrag: (GridSidewaysDrag.Event) -> Void
    /// The zoom levels a pinch goes between (GridPinch).
    let zoom: TimelineZoom
    let refresh: () async -> Void
    /// The keyboard's keys while selecting; none otherwise.
    var keys: GridKeys? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UICollectionView {
        let layout = TimelineCollectionLayout()
        let view = TimelineCollectionView(frame: .zero, collectionViewLayout: layout)
        view.backgroundColor = .clear
        view.contentInsetAdjustmentBehavior = .never
        view.alwaysBounceVertical = true
        view.showsHorizontalScrollIndicator = false
        // Photos' grid has none; the date scroller says where the grid is.
        view.showsVerticalScrollIndicator = false
        view.topEdgeEffect.style = .soft
        view.register(TimelineTileCell.self, forCellWithReuseIdentifier: TimelineTileCell.identifier)
        view.register(TimelineHeaderCell.self, forCellWithReuseIdentifier: TimelineHeaderCell.identifier)
        let coordinator = context.coordinator
        coordinator.parent = self
        view.dataSource = coordinator
        view.delegate = coordinator
        let refresh = UIRefreshControl()
        refresh.addTarget(coordinator, action: #selector(Coordinator.refreshed(_:)), for: .valueChanged)
        view.refreshControl = refresh
        let sideways = UIPanGestureRecognizer(target: coordinator, action: #selector(Coordinator.dragged(_:)))
        sideways.maximumNumberOfTouches = 1
        sideways.delegate = coordinator
        view.addGestureRecognizer(sideways)
        coordinator.sideways = sideways
        coordinator.pinch.attach(to: view)
        coordinator.pinch.actions = zoom.actions
        coordinator.pinch.scrollEnabled = isScrollEnabled
        coordinator.applied = (metrics, layoutKey, contentKey)
        layout.levelMetrics = zoom.metrics
        layout.configure(level: zoom.level, metrics: metrics, tileCount: tileCount, hasHeader: header != nil)
        layout.drawnSide = metrics.side
        scroller.collectionView = view
        scroller.startedAnimating = { [weak coordinator] in coordinator?.parent?.onPhase(.animating) }
        view.anchoredAtBottom = anchoredAtBottom
        apply(insets, to: view)
        return view
    }

    func updateUIView(_ view: UICollectionView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        scroller.collectionView = view
        let pinch = coordinator.pinch
        pinch.actions = zoom.actions
        pinch.shows(level: zoom.level)
        pinch.scrollEnabled = isScrollEnabled
        view.isScrollEnabled = isScrollEnabled && !pinch.isActive
        coordinator.sideways?.isEnabled = sidewaysEnabled
        (view as? TimelineCollectionView)?.anchoredAtBottom = anchoredAtBottom
        (view as? TimelineCollectionView)?.keys = keys
        apply(insets, to: view)
        guard let layout = view.collectionViewLayout as? TimelineCollectionLayout,
              let applied = coordinator.applied else { return }
        // A new count, size or header lays the grid out anew, but for the level a pinch settled on, at which the grid
        // is already. A new layout of as many tiles (a month's photos loaded), a new look, or the tiles drawn at
        // another size draw the tiles in view again, the others drawing as they come into view.
        layout.levelMetrics = zoom.metrics
        let levelMetrics = pinch.settledLevel == nil ? metrics : layout.metrics
        let level = pinch.settledLevel ?? zoom.level
        let reshaped = layout.tileCount != tileCount || layout.hasHeader != (header != nil) || layout.metrics != levelMetrics
        let resized = applied.metrics != metrics
        let redrawn = resized || applied.layoutKey != layoutKey || applied.contentKey != contentKey
        coordinator.applied = (metrics, layoutKey, contentKey)
        layout.drawnSide = metrics.side
        if reshaped {
            pinch.abandon()
            // A timeline anchored at its bottom keeps it, as a lazy stack does with `.sizeChanges`.
            let fromBottom = anchoredAtBottom ? distanceFromBottom(view) : nil
            layout.configure(level: level, metrics: levelMetrics, tileCount: tileCount, hasHeader: header != nil)
            view.reloadData()
            view.layoutIfNeeded()
            if let fromBottom { keep(fromBottom, in: view) }
        } else if redrawn {
            view.reconfigureItems(at: view.indexPathsForVisibleItems)
            // The rows in view told again, at the level the tiles are now drawn at.
            if resized { coordinator.scrollViewDidScroll(view) }
        } else if let header, let cell = view.cellForItem(at: IndexPath(item: 0, section: 0)) as? TimelineHeaderCell {
            cell.show(header) { [weak coordinator, weak view] height in
                if let view { coordinator?.headerMeasured(height, in: view) }
            }
        }
    }

    /// The safe area as the view's insets, the photos staying where they are: at the top, or as far from the bottom of
    /// a grid anchored there.
    private func apply(_ insets: EdgeInsets, to view: UICollectionView) {
        let new = UIEdgeInsets(top: insets.top, left: 0, bottom: insets.bottom, right: 0)
        let old = view.contentInset
        guard abs(new.top - old.top) > 0.5 || abs(new.bottom - old.bottom) > 0.5 else { return }
        let atTop = view.contentOffset.y <= -old.top + 0.5
        let fromBottom = anchoredAtBottom ? distanceFromBottom(view) : nil
        view.contentInset = new
        view.verticalScrollIndicatorInsets = new
        if let fromBottom {
            keep(fromBottom, in: view)
        } else if atTop {
            view.contentOffset.y = -new.top
        }
    }

    private func distanceFromBottom(_ view: UICollectionView) -> CGFloat {
        view.contentSize.height + view.adjustedContentInset.bottom - view.contentOffset.y - view.bounds.height
    }

    private func keep(_ fromBottom: CGFloat, in view: UICollectionView) {
        let insets = view.adjustedContentInset
        let y = view.contentSize.height + insets.bottom - view.bounds.height - fromBottom
        view.contentOffset.y = max(-insets.top, y)
    }

    final class Coordinator: NSObject, UICollectionViewDataSource, UICollectionViewDelegate, UIGestureRecognizerDelegate {
        var parent: TimelineCollection?
        var sideways: UIPanGestureRecognizer?
        let pinch = GridPinch()
        /// What the tiles in view were last drawn for.
        var applied: (metrics: GridTileMetrics, layoutKey: AnyHashable, contentKey: AnyHashable)?

        func numberOfSections(in collectionView: UICollectionView) -> Int { 2 }

        func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
            guard let parent else { return 0 }
            return section == TimelineCollectionLayout.headerSection ? (parent.header == nil ? 0 : 1) : parent.tileCount
        }

        func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
            if indexPath.section == TimelineCollectionLayout.headerSection {
                let cell = collectionView.dequeueReusableCell(withReuseIdentifier: TimelineHeaderCell.identifier,
                                                              for: indexPath) as! TimelineHeaderCell
                if let header = parent?.header {
                    cell.show(header) { [weak self, weak collectionView] height in
                        if let collectionView { self?.headerMeasured(height, in: collectionView) }
                    }
                }
                return cell
            }
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: TimelineTileCell.identifier,
                                                          for: indexPath) as! TimelineTileCell
            if let parent {
                let index = indexPath.item
                cell.contentConfiguration = UIHostingConfiguration { parent.tile(index) }.margins(.all, 0)
            }
            return cell
        }

        /// The header drew itself at a new height: the layout makes room for it, the photos staying where they are, at
        /// the top, as far from the bottom of a grid anchored there, or under the bars where the grid was scrolled.
        func headerMeasured(_ height: CGFloat, in view: UICollectionView) {
            guard let layout = view.collectionViewLayout as? TimelineCollectionLayout, layout.hasHeader,
                  abs(height - layout.headerHeight) > 0.5 else { return }
            let insets = view.adjustedContentInset
            let atTop = view.contentOffset.y <= -insets.top + 0.5
            let anchored = (view as? TimelineCollectionView)?.anchoredAtBottom == true
            let fromBottom = view.contentSize.height + insets.bottom - view.contentOffset.y - view.bounds.height
            let change = height - layout.headerHeight
            layout.setHeaderHeight(height)
            view.layoutIfNeeded()
            if anchored {
                view.contentOffset.y = max(-insets.top, view.contentSize.height + insets.bottom - view.bounds.height - fromBottom)
            } else if !atTop {
                view.contentOffset.y += change
            }
        }

        // MARK: Scrolling, as ScrollGeometry and ScrollPhase said it

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard let parent else { return }
            let insets = scrollView.adjustedContentInset
            parent.onScroll(GridViewport(offset: scrollView.contentOffset.y, insetTop: insets.top,
                                         insetBottom: insets.bottom,
                                         containerHeight: scrollView.bounds.height - insets.top - insets.bottom,
                                         contentHeight: scrollView.contentSize.height))
        }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            parent?.onPhase(.interacting)
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            parent?.onPhase(decelerate ? .decelerating : .idle)
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            parent?.onPhase(.idle)
        }

        func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
            parent?.onPhase(.idle)
        }

        /// A tap on the status bar: a scroll animation the grid did not start.
        func scrollViewShouldScrollToTop(_ scrollView: UIScrollView) -> Bool {
            parent?.onPhase(.animating)
            return true
        }

        func scrollViewDidScrollToTop(_ scrollView: UIScrollView) {
            parent?.onPhase(.idle)
        }

        @objc func refreshed(_ control: UIRefreshControl) {
            guard let refresh = parent?.refresh else {
                control.endRefreshing()
                return
            }
            Task { @MainActor in
                await refresh()
                control.endRefreshing()
            }
        }

        // MARK: Selecting by a sideways drag

        @objc func dragged(_ recognizer: UIPanGestureRecognizer) {
            guard let view = recognizer.view as? UICollectionView,
                  let layout = view.collectionViewLayout as? TimelineCollectionLayout else { return }
            let point = recognizer.location(in: view)
            let location = CGPoint(x: point.x, y: point.y - layout.headerHeight)
            switch recognizer.state {
            case .began:
                let moved = recognizer.translation(in: view)
                parent?.onSidewaysDrag(.began(start: CGPoint(x: location.x - moved.x, y: location.y - moved.y),
                                              location: location))
            case .changed:
                parent?.onSidewaysDrag(.moved(location))
            case .ended, .cancelled, .failed:
                parent?.onSidewaysDrag(.ended)
            default:
                break
            }
        }

        /// It begins only when the finger first moves more across than up or down.
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard gestureRecognizer === sideways, let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
            let velocity = pan.velocity(in: pan.view)
            return abs(velocity.x) > abs(velocity.y)
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            gestureRecognizer === sideways
        }
    }
}

/// The collection view, which tells its window's view controller it is the page's scroll view, so the bars and the tab
/// bar follow its scrolling, as they follow a SwiftUI scroll view's; and which lands at its bottom the first time it has
/// content, where it is anchored there.
private final class TimelineCollectionView: UICollectionView {
    var anchoredAtBottom = false
    private var landedFirst = false
    /// The keys of a selection, which take the keyboard while it lasts (GridKeys).
    var keys: GridKeys? {
        didSet {
            if keys != nil { takeKeyboard() } else if oldValue != nil, isFirstResponder { resignFirstResponder() }
        }
    }

    override var canBecomeFirstResponder: Bool { keys != nil }

    /// Takes the keyboard, once the update in progress is over, unless a field is being typed in.
    private func takeKeyboard() {
        guard window != nil, !isFirstResponder else { return }
        Task { @MainActor [weak self] in
            guard let self, keys != nil, window != nil, !isFirstResponder,
                  !(UIResponder.firstResponder is UITextInput) else { return }
            becomeFirstResponder()
        }
    }

    override var keyCommands: [UIKeyCommand]? {
        guard let keys else { return [] }
        var commands: [UIKeyCommand] = []
        if let favorite = keys.favorite {
            commands.append(command(".", [], favorite.title, #selector(favoriteSelection)))
        }
        if let delete = keys.delete {
            commands.append(command(UIKeyCommand.inputDelete, .command, delete.title, #selector(deleteSelection)))
        }
        commands.append(command(UIKeyCommand.inputEscape, [], String(localized: "Cancel"), #selector(cancelSelecting)))
        return commands
    }

    private func command(_ input: String, _ modifiers: UIKeyModifierFlags, _ title: String,
                         _ action: Selector) -> UIKeyCommand {
        let command = UIKeyCommand(title: title, action: action, input: input, modifierFlags: modifiers)
        // Ahead of the system's own Esc.
        command.wantsPriorityOverSystemBehavior = true
        return command
    }

    @objc private func favoriteSelection() { keys?.favorite?.perform() }
    @objc private func deleteSelection() { keys?.delete?.perform() }
    @objc private func cancelSelecting() { keys?.cancel() }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        var responder: UIResponder? = self
        while let next = responder?.next {
            if let controller = next as? UIViewController {
                controller.setContentScrollView(self, for: .top)
                controller.setContentScrollView(self, for: .bottom)
                break
            }
            responder = next
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard !landedFirst, contentSize.height > 0, bounds.height > 0 else { return }
        landedFirst = true
        if anchoredAtBottom {
            contentOffset.y = max(-adjustedContentInset.top, contentSize.height + adjustedContentInset.bottom - bounds.height)
        }
    }
}

/// A tile's cell: always the layout's size, so it never measures its SwiftUI content.
private final class TimelineTileCell: UICollectionViewCell {
    static let identifier = "tile"

    override func preferredLayoutAttributesFitting(_ attributes: UICollectionViewLayoutAttributes)
        -> UICollectionViewLayoutAttributes {
        attributes
    }
}

/// The page's header above the tiles: as tall as it draws itself at the grid's width, which it tells the layout
/// (`measured`) as it changes, its details loading, rather than UIKit measuring the cell, which misses it growing.
private final class TimelineHeaderCell: UICollectionViewCell {
    static let identifier = "header"

    func show(_ header: AnyView, measured: @escaping @MainActor (CGFloat) -> Void) {
        contentConfiguration = UIHostingConfiguration {
            header
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                    // Not inside the layout pass the measuring happens in.
                    Task { @MainActor in measured(height) }
                }
                .frame(maxHeight: .infinity, alignment: .top)
        }
        .margins(.all, 0)
    }

    override func preferredLayoutAttributesFitting(_ attributes: UICollectionViewLayoutAttributes)
        -> UICollectionViewLayoutAttributes {
        attributes
    }
}

/// The photo grid's zoom levels, for its pinch: the level shown, each level's tiles (nil past the last either way), and
/// what to tell the grid.
struct TimelineZoom {
    let level: Int
    let metrics: (Int) -> GridTileMetrics?
    let actions: GridZoomActions
}

/// Where everything in the grid's collection view goes: the header at the top, as tall as it draws itself, then the
/// tiles in rows of `metrics.columns`, each row `metrics.pitch` below the last; worked out for what is asked, never
/// stored for every tile. While a pinch goes between two levels, each tile is on its way between its places at both.
final class TimelineCollectionLayout: UICollectionViewLayout, PinchZoomLayout {
    static let headerSection = 0
    static let tileSection = 1

    private(set) var metrics = GridTileMetrics(columns: 1, width: 1, spacing: 0)
    /// The zoom level `metrics` are, and each level's tiles.
    private(set) var level = 0
    var levelMetrics: (Int) -> GridTileMetrics? = { _ in nil }
    private(set) var tileCount = 0
    private(set) var hasHeader = false
    /// The header's height, as it last drew itself; a guess until it has.
    private(set) var headerHeight: CGFloat = 0

    func setHeaderHeight(_ height: CGFloat) {
        headerHeight = height
        invalidateLayout()
    }

    /// The side the tiles' views are drawn at: a tile shown at another size (on a pinch's way, or at a level the grid
    /// has not yet drawn its tiles at) keeps it, scaled, so its view is not drawn again on the way.
    var drawnSide: CGFloat = 1 {
        didSet { if drawnSide != oldValue { invalidateLayout() } }
    }
    var transition: GridZoomTransition? {
        didSet { invalidateLayout() }
    }

    func configure(level: Int, metrics: GridTileMetrics, tileCount: Int, hasHeader: Bool) {
        self.level = level
        self.metrics = metrics
        self.tileCount = tileCount
        if hasHeader != self.hasHeader { headerHeight = hasHeader ? 44 : 0 }
        self.hasHeader = hasHeader
        transition = nil
    }

    func zoomed(toLevel level: Int) {
        guard let metrics = levelMetrics(level) else { return }
        self.level = level
        self.metrics = metrics
        transition = nil
    }

    func pitch(atLevel level: Int) -> CGFloat? {
        level == self.level ? metrics.pitch : levelMetrics(level)?.pitch
    }

    func frame(of item: IndexPath, atLevel level: Int) -> CGRect {
        tileFrame(item.item, in: level == self.level ? metrics : levelMetrics(level) ?? metrics)
    }

    func contentHeight(atLevel level: Int) -> CGFloat {
        contentHeight(in: level == self.level ? metrics : levelMetrics(level) ?? metrics)
    }

    /// The level a pinch is on its way to.
    private var nextMetrics: GridTileMetrics? {
        transition.flatMap { levelMetrics($0.toLevel) }
    }

    private var rowCount: Int { rowCount(in: metrics) }

    private func rowCount(in metrics: GridTileMetrics) -> Int { (tileCount + metrics.columns - 1) / metrics.columns }

    /// The top of a row of tiles, in the content.
    func rowTop(_ row: Int) -> CGFloat { headerHeight + CGFloat(row) * metrics.pitch }

    /// Where a tile is at a level, in the content.
    func tileFrame(_ index: Int, in metrics: GridTileMetrics) -> CGRect {
        let row = index / metrics.columns
        let column = index % metrics.columns
        return CGRect(x: CGFloat(column) * metrics.pitch, y: headerHeight + CGFloat(row) * metrics.pitch,
                      width: metrics.side, height: metrics.side)
    }

    /// The content's height at a level.
    func contentHeight(in metrics: GridTileMetrics) -> CGFloat {
        let rows = rowCount(in: metrics)
        return headerHeight + (rows > 0 ? CGFloat(rows) * metrics.pitch - metrics.spacing : 0)
    }

    /// The tile at a point of the content, the nearest where the point is between tiles or past the last, and how far
    /// down it the point is (0 its top, 1 its bottom); none on the header.
    func anchor(at point: CGPoint) -> (item: IndexPath, fraction: CGFloat)? {
        guard tileCount > 0, point.y >= headerHeight else { return nil }
        let row = min(Int((point.y - headerHeight) / metrics.pitch), rowCount - 1)
        let column = min(max(Int(point.x / metrics.pitch), 0), metrics.columns - 1)
        let index = min(row * metrics.columns + column, tileCount - 1)
        let frame = tileFrame(index, in: metrics)
        return (IndexPath(item: index, section: Self.tileSection), min(max((point.y - frame.minY) / metrics.side, 0), 1))
    }

    override var collectionViewContentSize: CGSize {
        CGSize(width: collectionView?.bounds.width ?? 0, height: contentHeight(in: metrics))
    }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        var found: [UICollectionViewLayoutAttributes] = []
        if hasHeader, let header = headerAttributes(), header.frame.intersects(rect) { found.append(header) }
        guard tileCount > 0 else { return found }
        guard let transition, let next = nextMetrics else {
            guard let tiles = tiles(in: metrics, from: rect.minY, to: rect.maxY) else { return found }
            for index in tiles { found.append(tileAttributes(index)) }
            return found
        }
        // The next level's tiles that show in the rectangle, from where it is at the next level.
        let (top, bottom) = transition.nextContent(of: rect)
        guard let shown = tiles(in: next, from: top, to: bottom) else { return found }
        for index in shown {
            let frame = shownFrame(index)
            if frame.intersects(rect) { found.append(tileAttributes(index, shown: frame)) }
        }
        return found
    }

    /// The tiles of the rows between two heights of the content at a level.
    private func tiles(in metrics: GridTileMetrics, from top: CGFloat, to bottom: CGFloat) -> ClosedRange<Int>? {
        let rows = rowCount(in: metrics)
        guard rows > 0 else { return nil }
        let first = max(0, Int(floor((top - headerHeight) / metrics.pitch)))
        let last = min(rows - 1, Int(floor((bottom - headerHeight) / metrics.pitch)))
        guard first <= last else { return nil }
        return (first * metrics.columns)...min(tileCount - 1, last * metrics.columns + metrics.columns - 1)
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        if indexPath.section == Self.headerSection { return hasHeader ? headerAttributes() : nil }
        guard indexPath.item < tileCount else { return nil }
        return tileAttributes(indexPath.item)
    }

    /// Where a tile shows: its place, or on a pinch's way, its place at the next level where the grid shows it.
    private func shownFrame(_ index: Int) -> CGRect {
        guard let transition, let next = nextMetrics else { return tileFrame(index, in: metrics) }
        return transition.shown(nextContent: tileFrame(index, in: next))
    }

    /// A tile shown at `frame`, at the size its view was drawn at, scaled to the size it shows.
    private func tileAttributes(_ index: Int, shown: CGRect? = nil) -> UICollectionViewLayoutAttributes {
        let frame = shown ?? shownFrame(index)
        let attributes = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: index, section: Self.tileSection))
        attributes.size = CGSize(width: drawnSide, height: drawnSide)
        attributes.center = CGPoint(x: frame.midX, y: frame.midY)
        if abs(frame.width - drawnSide) > 0.01 {
            attributes.transform = CGAffineTransform(scaleX: frame.width / drawnSide, y: frame.width / drawnSide)
        }
        if transition != nil { attributes.zIndex = GridPinch.cellDepth }
        return attributes
    }

    private func headerAttributes() -> UICollectionViewLayoutAttributes? {
        let attributes = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: 0, section: Self.headerSection))
        // On a pinch's way, the header goes from its place to its place at the next level, at its own size, over the
        // tiles.
        let top = transition.map { $0.progress * ($0.fromOffset - $0.toOffset) } ?? 0
        attributes.frame = CGRect(x: 0, y: top, width: collectionView?.bounds.width ?? 0, height: max(1, headerHeight))
        if transition != nil { attributes.zIndex = GridPinch.headerDepth }
        return attributes
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        newBounds.width != collectionView?.bounds.width
    }
}

/// A selection's keys on a hardware keyboard, as the Mac's grid has them: "." favorites or unfavorites the photos
/// selected, ⌘⌫ deletes them (asking first, as the bar's Delete does) and Esc ends selecting, as Cancel does; ⌘A is
/// Select All's own (AssetGridPage). Each where it applies to the photos selected.
struct GridKeys {
    struct Action {
        let title: String
        let perform: @MainActor () -> Void
    }

    var favorite: Action?
    var delete: Action?
    let cancel: @MainActor () -> Void
}
