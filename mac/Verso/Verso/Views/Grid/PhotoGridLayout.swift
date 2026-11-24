import AppKit

/// The Mac's photo grid's layout of its own: every tile, month header and the page's header exactly where
/// `PhotoGridGeometry` puts it, worked out for what is asked and never stored for every tile. A month's header stays at
/// the top of the view while its photos scroll under it, until the next month's pushes it away. Its sections are the
/// model's months, one to one, so an index path is the model's section and item. ARCHITECTURE.md, "The photo grid on
/// the Mac".
final class PhotoGridLayout: NSCollectionViewLayout {
    /// The page's header above the months (an album's details), at index path 0, 0.
    static let pageHeaderKind = "PhotoGridPageHeader"
    static let monthHeaderKind = NSCollectionView.elementKindSectionHeader

    /// What the grid is laid out from; a change lays it out anew.
    var inputs = PhotoGridGeometry.Inputs.empty {
        didSet { if inputs != oldValue { invalidateLayout() } }
    }
    /// Whether the page has a header above the months, for which `inputs.pageHeader` is room.
    var hasPageHeader = false
    /// How far below the scroll view's top the photos rest: the toolbar and the bars over them, which a month's header
    /// stays below.
    var topInset: CGFloat = 0 {
        didSet { if topInset != oldValue { invalidateLayout() } }
    }

    /// While a pinch is under way (PhotoGridPinch), the height of the content the months' headers stay below: where the
    /// top of the view is at rest at the level shown or the next, however the view is magnified meanwhile.
    var frozenTop: CGFloat? {
        didSet { if frozenTop != oldValue { invalidateLayout() } }
    }
    /// The picture of the level shown, while a pinch is under way: the width of the grid it is a picture of, and only
    /// what touches this rectangle of the content, the view as the pinch began.
    var fixedWidth: CGFloat?
    var limit: CGRect?

    private var cached = PhotoGridGeometry.empty

    /// The grid's places at the width it is shown at now.
    var geometry: PhotoGridGeometry {
        let width = shownWidth
        if cached.width != width || cachedInputs != inputs {
            cached = PhotoGridGeometry(width: width, inputs: inputs)
            cachedInputs = inputs
        }
        return cached
    }

    private var cachedInputs = PhotoGridGeometry.Inputs.empty

    /// The width of the part of the scroll view the photos show in, as it is on the screen: a pinch magnifies it.
    private var shownWidth: CGFloat {
        if let fixedWidth { return fixedWidth }
        guard let collectionView else { return 0 }
        return collectionView.enclosingScrollView?.contentView.frame.width ?? collectionView.bounds.width
    }

    /// The top of the view below the bars, in the content.
    private var visibleTop: CGFloat {
        frozenTop ?? (collectionView?.enclosingScrollView?.contentView.bounds.minY ?? 0) + topInset
    }

    override var collectionViewContentSize: NSSize {
        let geometry = geometry
        return NSSize(width: geometry.width, height: geometry.contentHeight)
    }

    override func layoutAttributesForElements(in asked: NSRect) -> [NSCollectionViewLayoutAttributes] {
        let geometry = geometry
        var found: [NSCollectionViewLayoutAttributes] = []
        let rect = limit.map { asked.intersection($0) } ?? asked
        // Nothing until the grid has a width: a tile a point wide would have the collection view make hundreds.
        guard geometry.width >= 1, !rect.isNull, !rect.isEmpty else { return found }
        if hasPageHeader, geometry.pageHeader > 0, rect.minY < geometry.pageHeader,
           let header = pageHeaderAttributes(geometry) {
            found.append(header)
        }
        guard let sections = geometry.sections(from: rect.minY, to: rect.maxY) else { return found }
        let pinned = visibleTop
        for section in sections {
            if let header = headerAttributes(section, geometry: geometry, visibleTop: pinned), header.frame.intersects(rect) {
                found.append(header)
            }
            for item in geometry.items(inSection: section, from: rect.minY, to: rect.maxY) {
                found.append(tileAttributes(PhotoGridGeometry.Place(section: section, item: item), geometry: geometry))
            }
        }
        // The header of a month whose top is above the rectangle, staying at the top of the view over its photos.
        if let first = sections.first, first > 0, let section = geometry.section(atContentY: pinned), section < first,
           let header = headerAttributes(section, geometry: geometry, visibleTop: pinned), header.frame.intersects(rect) {
            found.append(header)
        }
        return found
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
        let geometry = geometry
        guard geometry.sections.indices.contains(indexPath.section),
              indexPath.item < geometry.sections[indexPath.section].count else { return nil }
        return tileAttributes(PhotoGridGeometry.Place(section: indexPath.section, item: indexPath.item), geometry: geometry)
    }

    override func layoutAttributesForSupplementaryView(ofKind elementKind: NSCollectionView.SupplementaryElementKind,
                                                       at indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
        let geometry = geometry
        if elementKind == Self.pageHeaderKind { return hasPageHeader ? pageHeaderAttributes(geometry) : nil }
        guard elementKind == Self.monthHeaderKind else { return nil }
        return headerAttributes(indexPath.section, geometry: geometry, visibleTop: visibleTop)
    }

    private func tileAttributes(_ place: PhotoGridGeometry.Place, geometry: PhotoGridGeometry) -> NSCollectionViewLayoutAttributes {
        let attributes = NSCollectionViewLayoutAttributes(forItemWith: IndexPath(item: place.item, section: place.section))
        attributes.frame = geometry.tileFrame(place)
        return attributes
    }

    /// A month's header: at its place, or at the top of the view while its month's photos pass under it, until its
    /// month's end pushes it up.
    private func headerAttributes(_ section: Int, geometry: PhotoGridGeometry, visibleTop: CGFloat) -> NSCollectionViewLayoutAttributes? {
        guard var frame = geometry.headerFrame(section) else { return nil }
        frame.origin.y = max(frame.minY, min(visibleTop, geometry.sectionBottom(section) - frame.height))
        let attributes = NSCollectionViewLayoutAttributes(forSupplementaryViewOfKind: Self.monthHeaderKind,
                                                          with: IndexPath(item: 0, section: section))
        attributes.frame = frame
        attributes.zIndex = 10
        return attributes
    }

    private func pageHeaderAttributes(_ geometry: PhotoGridGeometry) -> NSCollectionViewLayoutAttributes? {
        guard geometry.pageHeader > 0 else { return nil }
        let attributes = NSCollectionViewLayoutAttributes(forSupplementaryViewOfKind: Self.pageHeaderKind,
                                                          with: IndexPath(item: 0, section: 0))
        attributes.frame = CGRect(x: 0, y: 0, width: geometry.width, height: geometry.pageHeader)
        attributes.zIndex = 5
        return attributes
    }

    // MARK: Scrolling

    /// A new width lays the grid out anew; a scroll moves only the months' headers at the top of the view.
    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool {
        true
    }

    override func invalidationContext(forBoundsChange newBounds: NSRect) -> NSCollectionViewLayoutInvalidationContext {
        let context = super.invalidationContext(forBoundsChange: newBounds)
        guard abs(shownWidth - cached.width) < 0.5 else { return context }
        let headers = NSCollectionViewLayoutInvalidationContext()
        // A pinch magnifies the view: the headers stay where they rest.
        guard frozenTop == nil else { return headers }
        let geometry = geometry
        guard let section = geometry.section(atContentY: newBounds.minY + topInset) else { return headers }
        // The header at the top, the one pushing it away and the one it leaves.
        let near = max(0, section - 1)...min(geometry.sections.count - 1, section + 1)
        let paths = Set(near.filter { geometry.sections[$0].header > 0 }.map { IndexPath(item: 0, section: $0) })
        if !paths.isEmpty { headers.invalidateSupplementaryElements(ofKind: Self.monthHeaderKind, at: paths) }
        return headers
    }
}
