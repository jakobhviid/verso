// A card page's grid on iOS (Albums, People, Memories, Places, a country's places, Shared Links): UIKit's collection
// view, as the photo grid is (TimelineCollection), with the page's SwiftUI cards in its cells, in rows of so many to a
// row at the page's card size (CardLadder), in sections with their headers. Every card on a page is one height at a
// size (its picture's shape and its lines of text), measured off the screen from a few of the page's own cards, so the
// layout knows where every card is at every size: a pinch zooms the cards as one grid through the sizes, as the photo
// grid's does (GridPinch), and View Options' Zoom Out and Zoom In make the same motion about the middle of the view. On
// the way the cells show the next size's cards, under a picture of the size shown.
//
// Above the cards a page may keep its search (`finder`), hidden at rest above the top and brought into view as the page
// is pulled down, as Mail's and Settings' search is: a pull that ends with it half in view settles it shown or hidden,
// whichever is nearer, and a pull further reads the page again (`refresh`). It fades as it goes under the bar, and
// stays while a search is under way; the content always has room to scroll it away. Under the cards a page may keep
// what it says when it has none, or the end of a list still loading (`footer`). ARCHITECTURE.md, "Pinching between
// sizes".

import SwiftUI
import UIKit

/// One of a card page's sections: its cards, and its header, if it has one.
struct CardGridSection {
    let id: String
    let count: Int
    var header: AnyView?
}

/// A card page's grid, under its bars and title, which it rests clear of.
struct CardGrid: View {
    let sections: [CardGridSection]
    /// A card at a card size: the cell draws the size it shows, which on a pinch's way is the next.
    let card: (_ section: Int, _ item: Int, _ size: Int) -> AnyView
    var finder: AnyView? = nil
    /// A search is under way: the search stays, whole, wherever it is.
    var searching = false
    var footer: AnyView? = nil
    let ladder: CardLadder
    @Binding var size: Int
    let regular: Bool
    /// Changes when what the cards show changes, though their number does not: the cards in view are drawn again.
    var contentKey: AnyHashable = 0
    /// Above the first section, where the page has no search.
    var top: CGFloat = 0
    var refresh: (() async -> Void)? = nil

    @State private var safeArea = EdgeInsets()

    var body: some View {
        CardCollection(sections: sections, card: card, finder: finder, searching: searching, footer: footer,
                       ladder: ladder, size: size, changed: { size = $0 }, regular: regular, insets: safeArea,
                       contentKey: contentKey, top: top, refresh: refresh)
            .ignoresSafeArea(.container, edges: .vertical)
            .onGeometryChange(for: EdgeInsets.self) { $0.safeAreaInsets } action: { safeArea = $0 }
    }
}

/// The page's margins and the room between the cards, which the ladder gives across.
private enum CardGridMargins {
    static let side: CGFloat = 16
    static let bottom: CGFloat = 24
    /// Between a section's last row and the next section's header.
    static let sectionGap: CGFloat = 8
}

/// A card size's grid at a width: so many cards to a row, each so wide and so tall.
struct CardGridMetrics: Equatable {
    let size: Int
    let columns: Int
    let cardWidth: CGFloat
    let cardHeight: CGFloat
    let columnSpacing: CGFloat
    let rowSpacing: CGFloat

    var pitch: CGFloat { cardWidth + columnSpacing }
}

private struct CardCollection: UIViewRepresentable {
    let sections: [CardGridSection]
    let card: (Int, Int, Int) -> AnyView
    let finder: AnyView?
    let searching: Bool
    let footer: AnyView?
    let ladder: CardLadder
    let size: Int
    let changed: (Int) -> Void
    let regular: Bool
    let insets: EdgeInsets
    let contentKey: AnyHashable
    let top: CGFloat
    let refresh: (() async -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UICollectionView {
        let layout = CardCollectionLayout()
        let view = CardCollectionView(frame: .zero, collectionViewLayout: layout)
        view.backgroundColor = .clear
        view.contentInsetAdjustmentBehavior = .never
        view.alwaysBounceVertical = true
        view.keyboardDismissMode = .onDrag
        view.topEdgeEffect.style = .soft
        view.register(CardCell.self, forCellWithReuseIdentifier: CardCell.identifier)
        view.register(MeasuredCell.self, forCellWithReuseIdentifier: MeasuredCell.identifier)
        let coordinator = context.coordinator
        coordinator.parent = self
        view.dataSource = coordinator
        view.delegate = coordinator
        if refresh != nil {
            let control = UIRefreshControl()
            control.addTarget(coordinator, action: #selector(Coordinator.refreshed(_:)), for: .valueChanged)
            view.refreshControl = control
        }
        coordinator.pinch.attach(to: view)
        coordinator.pinch.actions = GridZoomActions(changed: { [weak coordinator] level in coordinator?.settled(level) })
        layout.shownLevelChanged = { [weak view] in
            guard let view else { return }
            view.reconfigureItems(at: view.indexPathsForVisibleItems)
        }
        coordinator.view = view
        coordinator.apply(insets: insets)
        return view
    }

    func updateUIView(_ view: UICollectionView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        coordinator.apply(insets: insets)
        coordinator.update()
    }

    @MainActor final class Coordinator: NSObject, UICollectionViewDataSource, UICollectionViewDelegate {
        var parent: CardCollection?
        weak var view: UICollectionView?
        let pinch = GridPinch()
        private let sizer = CardSizer()
        /// The card sizes that change the page, from the largest cards to the smallest, one for each zoom level.
        private var sizes: [Int] = []
        /// Cards' heights by size and width, measured.
        private var heights: [String: CGFloat] = [:]
        private var headerHeights: [String: CGFloat] = [:]
        /// What the cells in view were drawn for.
        private var drawn: (sections: [String], counts: [Int], content: AnyHashable, width: CGFloat)?
        /// The person has scrolled the page: from then on its search stays where they leave it.
        private var touched = false

        private var layout: CardCollectionLayout? { view?.collectionViewLayout as? CardCollectionLayout }

        // MARK: Levels

        /// The width the cards share: the page's, less its margins.
        private var cardWidth: CGFloat { max(0, (view?.bounds.width ?? 0) - 2 * CardGridMargins.side) }

        /// A size's grid at the page's width, its cards' height measured from the page's own.
        func metrics(size: Int) -> CardGridMetrics? {
            guard let parent, let view, cardWidth > 0 else { return nil }
            let ladder = parent.ladder
            let columns = ladder.columns(size, width: cardWidth, regular: parent.regular)
            let spacing = ladder.spacing
            let width = (cardWidth - CGFloat(columns - 1) * spacing) / CGFloat(columns)
            let key = "\(size)-\(Int(width.rounded()))"
            let height: CGFloat
            if let known = heights[key] {
                height = known
            } else {
                height = measureCards(size: size, width: width, traits: view.traitCollection)
                heights[key] = height
            }
            return CardGridMetrics(size: size, columns: columns, cardWidth: width, cardHeight: height,
                                   columnSpacing: spacing, rowSpacing: spacing)
        }

        /// The tallest of a few of the page's cards, from each section, at a size and width.
        private func measureCards(size: Int, width: CGFloat, traits: UITraitCollection) -> CGFloat {
            guard let parent else { return width }
            var samples: [(Int, Int)] = []
            for (index, section) in parent.sections.enumerated() where section.count > 0 {
                for item in 0..<min(section.count, 4) { samples.append((index, item)) }
                if samples.count >= 12 { break }
            }
            let measured = samples.map { sizer.height(of: parent.card($0.0, $0.1, size), width: width, traits: traits) }
            let tallest = measured.max() ?? width
            // A card that would grow without end (a picture that fills what it is offered) is as tall as wide.
            return tallest.isFinite && tallest > 0 && tallest < width * 4 ? tallest : width
        }

        private func measureHeader(_ section: CardGridSection, width: CGFloat) -> CGFloat {
            guard let header = section.header, let view else { return 0 }
            let key = "\(section.id)-\(Int(width.rounded()))"
            if let known = headerHeights[key] { return known }
            let height = sizer.height(of: header, width: width, traits: view.traitCollection)
            headerHeights[key] = height
            return height
        }

        /// The sizes a pinch goes through at the page's width: of the sizes that look the same, the smallest.
        private func levelSizes() -> [Int] {
            guard let parent else { return [] }
            var found: [Int] = []
            var candidate = CardSize.sizes.upperBound
            while candidate >= CardSize.sizes.lowerBound {
                let smallest = parent.ladder.smallestAlike(candidate, width: cardWidth, regular: parent.regular)
                found.append(smallest)
                candidate = smallest - 1
            }
            return found
        }

        private func level(of size: Int) -> Int {
            guard let parent else { return 0 }
            let smallest = parent.ladder.smallestAlike(size, width: cardWidth, regular: parent.regular)
            return sizes.firstIndex(of: smallest) ?? 0
        }

        /// The pinch settled on a level: the page's size is its.
        func settled(_ level: Int) {
            guard sizes.indices.contains(level) else { return }
            parent?.changed(sizes[level])
        }

        // MARK: Updating

        /// The view was laid out at a width the grid was not: it lays itself out again, after this layout pass.
        func widthChanged(_ width: CGFloat) {
            guard width > 0, drawn?.width != width, !updateScheduled else { return }
            updateScheduled = true
            Task { @MainActor in
                self.updateScheduled = false
                self.update()
            }
        }

        private var updateScheduled = false

        func update() {
            guard let parent, let view, let layout, view.bounds.width > 0 else { return }
            sizes = levelSizes()
            layout.levelMetrics = { [weak self] level in
                guard let self, self.sizes.indices.contains(level) else { return nil }
                return self.metrics(size: self.sizes[level])
            }
            pinch.scrollEnabled = true
            let ids = parent.sections.map(\.id)
            let counts = parent.sections.map(\.count)
            let width = view.bounds.width
            let reshaped = drawn.map { $0.sections != ids || $0.counts != counts || $0.width != width } ?? true
            let redrawn = drawn.map { $0.content != parent.contentKey } ?? true
            // Every card is one height at a size, whatever its section holds: measured again for another width or
            // other sections.
            if drawn?.width != width || drawn?.sections != ids { heights = [:] }
            if drawn?.width != width { headerHeights = [:] }
            drawn = (ids, counts, parent.contentKey, width)
            let wanted = level(of: parent.size)
            pinch.shows(level: wanted)
            // While a pinch or a zoom is under way, the page's size is the one it is going to.
            if pinch.isActive { return }
            layout.visibleHeight = view.bounds.height - view.adjustedContentInset.top - view.adjustedContentInset.bottom
            let headerHeights = parent.sections.map { measureHeader($0, width: width - 2 * CardGridMargins.side) }
            let shape = CardCollectionLayout.Shape(counts: counts, headers: headerHeights, top: parent.top,
                                                   finder: parent.finder != nil, footer: parent.footer != nil)
            if !reshaped, !redrawn, layout.level != wanted, pinch.settledLevel == nil, view.window != nil,
               abs(layout.level - wanted) == 1, layout.shape == shape {
                // View Options' Zoom Out or Zoom In: the same motion as a pinch's, about the middle of the view.
                let insets = view.adjustedContentInset
                let middle = CGPoint(x: view.bounds.width / 2,
                                     y: insets.top + (view.bounds.height - insets.top - insets.bottom) / 2)
                if pinch.zoom(by: wanted - layout.level, about: middle) { return }
            }
            let level = pinch.settledLevel ?? wanted
            if reshaped || layout.shape != shape || layout.level != level || layout.metrics != layout.levelMetrics(level) {
                pinch.abandon()
                let fromTop = view.contentOffset.y + view.adjustedContentInset.top
                let before = layout.isConfigured ? layout.shape : nil
                layout.configure(shape: shape, level: level)
                if let before, before.finder == shape.finder, view.numberOfSections == before.counts.count + 2 {
                    // The cards and the foot anew, the search as it is: a search typed into keeps the keyboard as
                    // the albums it matches change.
                    UIView.performWithoutAnimation {
                        view.performBatchUpdates {
                            view.deleteSections(IndexSet(1...(before.counts.count + 1)))
                            view.insertSections(IndexSet(1...(shape.counts.count + 1)))
                        }
                    }
                } else {
                    view.reloadData()
                }
                view.layoutIfNeeded()
                if !touched { hideFinder() } else { view.contentOffset.y = fromTop - view.adjustedContentInset.top }
            } else if redrawn {
                view.reconfigureItems(at: view.indexPathsForVisibleItems)
            } else {
                showPageViews()
            }
            showFinder()
        }

        /// The search, the foot and the sections' headers in view as the page draws them now: what they show changes
        /// with the page (the search's choice, a folded section's chevron) while the cards stay as they are.
        private func showPageViews() {
            guard let parent, let view else { return }
            for indexPath in view.indexPathsForVisibleItems {
                guard let cell = view.cellForItem(at: indexPath) else { continue }
                if let cell = cell as? MeasuredCell {
                    let isFinder = indexPath.section == 0
                    if let content = isFinder ? parent.finder : parent.footer {
                        cell.show(content) { [weak self] height in self?.measured(height, finder: isFinder) }
                    }
                } else if indexPath.item == 0, parent.sections.indices.contains(indexPath.section - 1),
                          let header = parent.sections[indexPath.section - 1].header, let layout {
                    (cell as? CardCell)?.show(header, size: layout.drawnSize(of: indexPath))
                }
            }
        }

        func apply(insets: EdgeInsets) {
            guard let view else { return }
            let new = UIEdgeInsets(top: insets.top, left: 0, bottom: insets.bottom, right: 0)
            let old = view.contentInset
            guard abs(new.top - old.top) > 0.5 || abs(new.bottom - old.bottom) > 0.5 else { return }
            let fromTop = view.contentOffset.y + old.top
            view.contentInset = new
            view.verticalScrollIndicatorInsets = new
            layout?.visibleHeight = view.bounds.height - new.top - new.bottom
            view.contentOffset.y = fromTop - new.top
            if !touched { hideFinder() }
        }

        // MARK: The search above the top

        /// The search above the top of the view, while the person has not scrolled the page and is not searching.
        private func hideFinder() {
            guard let parent, let view, let layout, parent.finder != nil, !parent.searching, layout.finderHeight > 0
            else { return }
            view.layoutIfNeeded()
            view.contentOffset.y = layout.finderHeight - view.adjustedContentInset.top
        }

        /// Whole while in view, fading as the page scrolls it under the bar, whole while a search is under way.
        private func showFinder() {
            guard let parent, let view, let layout, parent.finder != nil,
                  let cell = view.cellForItem(at: CardCollectionLayout.finderItem) else { return }
            let scrolled = view.contentOffset.y + view.adjustedContentInset.top
            let height = layout.finderHeight
            cell.contentView.alpha = parent.searching || height <= 0 ? 1 : min(1, max(0, 1 - scrolled / height))
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            showFinder()
        }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            touched = true
        }

        /// A pull that ends with the search half in view settles it shown or hidden, whichever is nearer.
        func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint,
                                       targetContentOffset: UnsafeMutablePointer<CGPoint>) {
            guard let parent, let layout, parent.finder != nil, !parent.searching, layout.finderHeight > 0 else { return }
            let top = scrollView.adjustedContentInset.top
            let scrolled = targetContentOffset.pointee.y + top
            guard scrolled > 0, scrolled < layout.finderHeight else { return }
            targetContentOffset.pointee.y = (scrolled < layout.finderHeight / 2 ? 0 : layout.finderHeight) - top
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

        // MARK: Cells

        func numberOfSections(in collectionView: UICollectionView) -> Int {
            (parent?.sections.count ?? 0) + 2
        }

        func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
            guard let parent else { return 0 }
            if section == 0 { return parent.finder == nil ? 0 : 1 }
            if section == parent.sections.count + 1 { return parent.footer == nil ? 0 : 1 }
            let shown = parent.sections[section - 1]
            return (shown.header == nil ? 0 : 1) + shown.count
        }

        func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
            guard let parent, let layout else { return UICollectionViewCell() }
            if indexPath.section == 0 || indexPath.section == parent.sections.count + 1 {
                let cell = collectionView.dequeueReusableCell(withReuseIdentifier: MeasuredCell.identifier,
                                                              for: indexPath) as! MeasuredCell
                let isFinder = indexPath.section == 0
                if let content = isFinder ? parent.finder : parent.footer {
                    cell.show(content) { [weak self] height in self?.measured(height, finder: isFinder) }
                }
                return cell
            }
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: CardCell.identifier,
                                                          for: indexPath) as! CardCell
            let section = indexPath.section - 1
            let shown = parent.sections[section]
            let drawn = layout.drawnSize(of: indexPath)
            if let header = shown.header, indexPath.item == 0 {
                cell.show(header, size: drawn)
            } else {
                let item = indexPath.item - (shown.header == nil ? 0 : 1)
                // On a pinch's way, the next size's card (People's faces are drawn larger two to a row).
                let size = layout.shownMetrics?.size ?? parent.size
                cell.show(parent.card(section, item, size), size: drawn)
            }
            return cell
        }

        /// The search or the foot drew itself at a new height: the layout makes room for it, the cards staying where
        /// they are, or the search hidden while the person has not scrolled.
        private func measured(_ height: CGFloat, finder: Bool) {
            guard let view, let layout else { return }
            let old = finder ? layout.finderHeight : layout.footerHeight
            guard abs(height - old) > 0.5 else { return }
            let fromTop = view.contentOffset.y + view.adjustedContentInset.top
            if finder { layout.finderHeight = height } else { layout.footerHeight = height }
            view.layoutIfNeeded()
            if finder {
                if !touched { hideFinder() } else if fromTop >= old { view.contentOffset.y += height - old }
            }
        }
    }
}

/// The collection view, which tells its window's view controller it is the page's scroll view, so the bars follow its
/// scrolling.
private final class CardCollectionView: UICollectionView {
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
        (delegate as? CardCollection.Coordinator)?.update()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        (delegate as? CardCollection.Coordinator)?.widthChanged(bounds.width)
    }
}

/// A card's or a header's cell: always the layout's size, so it never measures its SwiftUI content.
private final class CardCell: UICollectionViewCell {
    static let identifier = "card"
    private var host: UIHostingController<AnyView>?

    /// The card at the cell's size, which the layout gives it, in a hosting controller of its own without a safe area:
    /// in a hosting configuration, a cell under the bars has its SwiftUI laid out in the cell less the bars (the top
    /// bars' height, or the tab bar's), so a card that keeps its shape shrank there and grew as it scrolled clear
    /// (Places' countries), and one of a fixed size sat off its place by half the bar.
    func show(_ content: AnyView, size: CGSize) {
        let root = AnyView(content.frame(width: size.width, height: size.height))
        if let host {
            host.rootView = root
            return
        }
        let host = UIHostingController(rootView: root)
        host.safeAreaRegions = []
        host.view.backgroundColor = .clear
        host.view.frame = contentView.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        contentView.addSubview(host.view)
        self.host = host
    }

    override func preferredLayoutAttributesFitting(_ attributes: UICollectionViewLayoutAttributes)
        -> UICollectionViewLayoutAttributes {
        attributes
    }
}

/// The search's or the foot's cell: as tall as it draws itself, which it tells the layout (`measured`).
private final class MeasuredCell: UICollectionViewCell {
    static let identifier = "measured"

    func show(_ content: AnyView, measured: @escaping @MainActor (CGFloat) -> Void) {
        contentConfiguration = UIHostingConfiguration {
            content
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

/// Measures a SwiftUI view's height at a width, off the screen, with the traits of the page it shows in.
@MainActor private final class CardSizer {
    private let controller = UIHostingController(rootView: AnyView(EmptyView()))

    func height(of view: AnyView, width: CGFloat, traits: UITraitCollection) -> CGFloat {
        controller.traitOverrides.preferredContentSizeCategory = traits.preferredContentSizeCategory
        controller.traitOverrides.horizontalSizeClass = traits.horizontalSizeClass
        controller.traitOverrides.displayScale = traits.displayScale
        controller.rootView = view
        return ceil(controller.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height)
    }
}

/// Where everything in a card page's collection view goes: the search at the top, then each section's header and its
/// cards in rows, then the foot, at the margins; worked out for what is asked from the sections' counts and the size's
/// one card height. While a pinch goes between two sizes, everything is at its place at the next where the grid shows
/// it (GridPinch).
final class CardCollectionLayout: UICollectionViewLayout, PinchZoomLayout {
    static let finderItem = IndexPath(item: 0, section: 0)

    /// What the page holds: each section's cards and header's height, and whether it has a search and a foot.
    struct Shape: Equatable {
        var counts: [Int] = []
        var headers: [CGFloat] = []
        var top: CGFloat = 0
        var finder = false
        var footer = false
    }

    private(set) var shape = Shape()
    private(set) var level = 0
    private(set) var metrics: CardGridMetrics?
    private(set) var isConfigured = false
    var levelMetrics: (Int) -> CardGridMetrics? = { _ in nil }
    var finderHeight: CGFloat = 0 { didSet { if finderHeight != oldValue { invalidateLayout() } } }
    var footerHeight: CGFloat = 0 { didSet { if footerHeight != oldValue { invalidateLayout() } } }
    /// The height of the view between the bars: the content is at least that and the search tall, so the search can
    /// always be scrolled away.
    var visibleHeight: CGFloat = 0 { didSet { if visibleHeight != oldValue { invalidateLayout() } } }
    /// Told when the cells are to show another size's cards: a pinch set out, or went back.
    var shownLevelChanged: (() -> Void)?

    var transition: GridZoomTransition? {
        didSet {
            invalidateLayout()
            if transition?.toLevel != oldValue?.toLevel { shownLevelChanged?() }
        }
    }

    /// The size the cells show: the next, on a pinch's way.
    var shownMetrics: CardGridMetrics? {
        transition.flatMap { levelMetrics($0.toLevel) } ?? metrics
    }

    func configure(shape: Shape, level: Int) {
        self.shape = shape
        self.level = level
        metrics = levelMetrics(level)
        isConfigured = metrics != nil
        transition = nil
        invalidateLayout()
    }

    // MARK: Where things are

    /// The tops of each section's header, first card row and foot, at a size.
    private struct Plan {
        var sections: [(header: CGFloat, cards: CGFloat)] = []
        var footer: CGFloat = 0
        var height: CGFloat = 0
    }

    private var plans: [Int: Plan] = [:]

    override func invalidateLayout() {
        plans = [:]
        super.invalidateLayout()
    }

    private func metrics(atLevel level: Int) -> CardGridMetrics? {
        level == self.level ? metrics : levelMetrics(level)
    }

    private func rows(_ count: Int, _ metrics: CardGridMetrics) -> Int { (count + metrics.columns - 1) / metrics.columns }

    private func cardsHeight(_ count: Int, _ metrics: CardGridMetrics) -> CGFloat {
        let rows = rows(count, metrics)
        return rows > 0 ? CGFloat(rows) * (metrics.cardHeight + metrics.rowSpacing) - metrics.rowSpacing : 0
    }

    private func plan(atLevel level: Int) -> Plan? {
        if let known = plans[level] { return known }
        guard let metrics = metrics(atLevel: level) else { return nil }
        var plan = Plan()
        var y = (shape.finder ? finderHeight : 0) + shape.top
        for (index, count) in shape.counts.enumerated() {
            let header = y
            y += shape.headers[index]
            plan.sections.append((header, y))
            y += cardsHeight(count, metrics)
            if count > 0 || shape.headers[index] > 0 { y += metrics.rowSpacing + CardGridMargins.sectionGap }
        }
        plan.footer = y
        y += shape.footer ? footerHeight : 0
        plan.height = max(y + CardGridMargins.bottom, visibleHeight + (shape.finder ? finderHeight : 0))
        plans[level] = plan
        return plan
    }

    func frame(of item: IndexPath, atLevel level: Int) -> CGRect {
        guard let plan = plan(atLevel: level), let metrics = metrics(atLevel: level) else { return .zero }
        let width = collectionView?.bounds.width ?? 0
        // The search and the foot are laid out before they have drawn themselves, a point tall, so they do.
        if item.section == 0 { return CGRect(x: 0, y: 0, width: width, height: max(1, finderHeight)) }
        let section = item.section - 1
        if section >= shape.counts.count {
            return CGRect(x: 0, y: plan.footer, width: width, height: max(1, footerHeight))
        }
        let hasHeader = shape.headers[section] > 0
        if hasHeader && item.item == 0 {
            return CGRect(x: CardGridMargins.side, y: plan.sections[section].header,
                          width: width - 2 * CardGridMargins.side, height: shape.headers[section])
        }
        let index = item.item - (hasHeader ? 1 : 0)
        let row = index / metrics.columns
        let column = index % metrics.columns
        return CGRect(x: CardGridMargins.side + CGFloat(column) * metrics.pitch,
                      y: plan.sections[section].cards + CGFloat(row) * (metrics.cardHeight + metrics.rowSpacing),
                      width: metrics.cardWidth, height: metrics.cardHeight)
    }

    func contentHeight(atLevel level: Int) -> CGFloat { plan(atLevel: level)?.height ?? 0 }

    /// The size an item's cell is drawn at: its size at the level shown, the next on a pinch's way.
    func drawnSize(of item: IndexPath) -> CGSize {
        frame(of: item, atLevel: transition?.toLevel ?? level).size
    }

    var restingTop: CGFloat { shape.finder ? finderHeight : 0 }

    func pitch(atLevel level: Int) -> CGFloat? { metrics(atLevel: level)?.pitch }

    func zoomed(toLevel level: Int) {
        guard let metrics = levelMetrics(level) else { return }
        self.level = level
        self.metrics = metrics
        transition = nil
    }

    func anchor(at point: CGPoint) -> (item: IndexPath, fraction: CGFloat)? {
        guard let plan = plan(atLevel: level), let metrics else { return nil }
        // The section the point is in, and its card row nearest the point.
        var nearest: (IndexPath, CGRect, CGFloat)?
        for (section, count) in shape.counts.enumerated() where count > 0 {
            let top = plan.sections[section].cards
            let rows = rows(count, metrics)
            let pitch = metrics.cardHeight + metrics.rowSpacing
            let row = min(max(Int((point.y - top) / pitch), 0), rows - 1)
            let column = min(max(Int((point.x - CardGridMargins.side) / metrics.pitch), 0), metrics.columns - 1)
            let index = min(row * metrics.columns + column, count - 1)
            let item = IndexPath(item: index + (shape.headers[section] > 0 ? 1 : 0), section: section + 1)
            let frame = frame(of: item, atLevel: level)
            let distance = max(frame.minY - point.y, 0, point.y - frame.maxY)
            if nearest == nil || distance < nearest!.2 { nearest = (item, frame, distance) }
        }
        guard let (item, frame, _) = nearest else { return nil }
        return (item, min(max((point.y - frame.minY) / max(frame.height, 1), 0), 1))
    }

    // MARK: UICollectionViewLayout

    override var collectionViewContentSize: CGSize {
        CGSize(width: collectionView?.bounds.width ?? 0, height: contentHeight(atLevel: level))
    }

    /// Every item, in order, by section: the search, each section's header and cards, the foot.
    private func items(in rect: CGRect, atLevel level: Int) -> [IndexPath] {
        guard let plan = plan(atLevel: level), let metrics = metrics(atLevel: level) else { return [] }
        var found: [IndexPath] = []
        if shape.finder, rect.minY < max(1, finderHeight) { found.append(Self.finderItem) }
        for (section, count) in shape.counts.enumerated() {
            let headerTop = plan.sections[section].header
            let cardsTop = plan.sections[section].cards
            let bottom = cardsTop + cardsHeight(count, metrics)
            guard bottom >= rect.minY, headerTop <= rect.maxY else { continue }
            let hasHeader = shape.headers[section] > 0
            if hasHeader, cardsTop >= rect.minY, headerTop <= rect.maxY {
                found.append(IndexPath(item: 0, section: section + 1))
            }
            guard count > 0 else { continue }
            let pitch = metrics.cardHeight + metrics.rowSpacing
            let first = max(0, Int(floor((rect.minY - cardsTop) / pitch)))
            let last = min(rows(count, metrics) - 1, Int(floor((rect.maxY - cardsTop) / pitch)))
            guard first <= last else { continue }
            for index in (first * metrics.columns)...min(count - 1, last * metrics.columns + metrics.columns - 1) {
                found.append(IndexPath(item: index + (hasHeader ? 1 : 0), section: section + 1))
            }
        }
        if shape.footer, plan.footer <= rect.maxY {
            found.append(IndexPath(item: 0, section: shape.counts.count + 1))
        }
        return found
    }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        guard let transition else {
            return items(in: rect, atLevel: level).map { attributes(for: $0) }
        }
        // The next size's items that show in the rectangle, from where it is at the next size.
        let (top, bottom) = transition.nextContent(of: rect)
        let next = CGRect(x: rect.minX, y: top, width: rect.width, height: bottom - top)
        return items(in: next, atLevel: transition.toLevel).compactMap { item in
            let shown = attributes(for: item)
            return shown.frame.intersects(rect) ? shown : nil
        }
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        attributes(for: indexPath)
    }

    /// An item at its place, or on a pinch's way at its place at the next size, drawn at that size and scaled to the
    /// size it shows at.
    private func attributes(for item: IndexPath) -> UICollectionViewLayoutAttributes {
        let attributes = UICollectionViewLayoutAttributes(forCellWith: item)
        guard let transition else {
            attributes.frame = frame(of: item, atLevel: level)
            return attributes
        }
        let natural = frame(of: item, atLevel: transition.toLevel)
        let shown = transition.shown(nextContent: natural)
        attributes.size = natural.size
        attributes.center = CGPoint(x: shown.midX, y: shown.midY)
        if natural.width > 0 {
            let scale = shown.width / natural.width
            attributes.transform = CGAffineTransform(scaleX: scale, y: scale)
        }
        attributes.zIndex = isCard(item) ? GridPinch.cellDepth : GridPinch.headerDepth
        return attributes
    }

    private func isCard(_ item: IndexPath) -> Bool {
        let section = item.section - 1
        guard shape.counts.indices.contains(section) else { return false }
        return !(shape.headers[section] > 0 && item.item == 0)
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        newBounds.width != collectionView?.bounds.width
    }
}
