// Offline checks of the Mac's photo grid layout (PhotoGridGeometry, PhotoGridLayout): the arithmetic it shares with the
// date scroller, and the layout in a real NSCollectionView in a hidden window, scrolled deep into a large grid, its
// months' headers staying at the top, and laid out again at another width. Run by check.py ('photo-grid-layout'). No
// app launch, no network.
import AppKit

private final class Tile: NSCollectionViewItem {
    override func loadView() { view = NSView() }
}

private final class Header: NSView, NSCollectionViewElement {}

/// Months of photos, as the grid's controller gives them to the collection view.
@MainActor private final class Months: NSObject, NSCollectionViewDataSource {
    let counts: [Int]

    init(counts: [Int]) { self.counts = counts }

    func numberOfSections(in collectionView: NSCollectionView) -> Int { counts.count }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { counts[section] }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        collectionView.makeItem(withIdentifier: NSUserInterfaceItemIdentifier("tile"), for: indexPath)
    }

    func collectionView(_ collectionView: NSCollectionView, viewForSupplementaryElementOfKind kind: NSCollectionView.SupplementaryElementKind,
                        at indexPath: IndexPath) -> NSView {
        collectionView.makeSupplementaryView(ofKind: kind, withIdentifier: NSUserInterfaceItemIdentifier("header"), for: indexPath)
    }
}

private func close(_ first: CGFloat, _ second: CGFloat) -> Bool { abs(first - second) < 0.01 }

private func close(_ first: CGRect, _ second: CGRect) -> Bool {
    close(first.minX, second.minX) && close(first.minY, second.minY) && close(first.width, second.width) && close(first.height, second.height)
}

@main private struct PhotoGridLayoutChecks {
    typealias Place = PhotoGridGeometry.Place

    static func geometry() {
        // An adaptive grid's columns: as many tiles of the least side, with their spacing, as the width holds.
        precondition(PhotoGridGeometry.columns(width: 0, size: 150) == 1)
        precondition(PhotoGridGeometry.columns(width: 301, size: 150) == 1 && PhotoGridGeometry.columns(width: 302, size: 150) == 2)

        let counts = [8, 0, 4, 2, 6]
        let headers = [true, true, true, false, true]
        let grid = PhotoGridGeometry(width: 616, inputs: .init(size: 150, pageHeader: 120, counts: counts, headers: headers))
        precondition(grid.columns == 4 && close(grid.side, 152.5) && close(grid.pitch, 154.5), "\(grid.columns) \(grid.side)")

        // Each month takes its header and ceil(count / columns) rows, as the date scroller counts it (verso-core's
        // rail): an empty month none, a month without a title no header.
        var top: CGFloat = 0
        var tops: [CGFloat] = []
        for (count, header) in zip(counts, headers) {
            tops.append(top)
            top += (count > 0 && header ? 50 : 0) + CGFloat((count + 3) / 4) * grid.pitch
        }
        precondition(zip(grid.sections.map(\.top), tops).allSatisfy { close($0, $1) }, "\(grid.sections.map(\.top)) \(tops)")
        precondition(close(grid.monthsHeight, top) && close(grid.contentHeight, 120 + top + 20))

        // A tile's place: its month's top below the page's header, the month's header, then its row and column.
        let tile = grid.tileFrame(Place(section: 4, item: 5))
        precondition(close(tile, CGRect(x: grid.pitch, y: 120 + tops[4] + 50 + grid.pitch, width: 152.5, height: 152.5)), "\(tile)")
        precondition(close(grid.tileFrame(Place(section: 3, item: 1)).minY, 120 + tops[3]), "A month without a title has no header")
        precondition(close(grid.headerFrame(2)!, CGRect(x: 0, y: 120 + tops[2], width: 616, height: 50)))
        precondition(grid.headerFrame(1) == nil && grid.headerFrame(3) == nil)
        precondition(close(grid.sectionBottom(0), 120 + tops[2]))

        // A point is the tile it is on; none on a header, in the space between two tiles or past a month's last photo.
        precondition(grid.place(at: CGPoint(x: tile.midX, y: tile.midY)) == Place(section: 4, item: 5))
        precondition(grid.place(at: CGPoint(x: 10, y: 120 + tops[2] + 20)) == nil, "A header is no tile")
        precondition(grid.place(at: CGPoint(x: 153.5, y: tile.midY)) == nil, "The space between tiles is no tile")
        precondition(grid.place(at: CGPoint(x: 3 * grid.pitch + 10, y: 120 + tops[3] + 10)) == nil, "Past a month's last photo")
        precondition(grid.place(at: CGPoint(x: 10, y: 60)) == nil, "The page's header is no tile")
        // Nearest: in a header its month's first; in an empty month the next with photos; past the last, the last.
        precondition(grid.nearestPlace(to: CGPoint(x: 10, y: 120 + tops[2] + 20)) == Place(section: 2, item: 0))
        precondition(grid.nearestPlace(to: CGPoint(x: 3 * grid.pitch + 10, y: 120 + tops[3] + 10)) == Place(section: 3, item: 1))
        precondition(grid.nearestPlace(to: CGPoint(x: 10, y: 0)) == Place(section: 0, item: 0), "Above the months, the first")
        precondition(grid.section(atContentY: 120 + tops[2]) == 2, "An empty month takes no room: the next starts there")

        // The tiles a rectangle touches, in the grid's order: a rubber band from the space between two rows.
        let band = CGRect(x: grid.pitch + 10, y: 120 + tops[0] + 50 + 100, width: grid.pitch, height: grid.pitch)
        precondition(grid.places(touching: band) == [Place(section: 0, item: 1), Place(section: 0, item: 2),
                                                     Place(section: 0, item: 5), Place(section: 0, item: 6)],
                     "\(grid.places(touching: band))")
        precondition(grid.sections(from: 0, to: 100) == nil, "The page's header holds no months")
        precondition(grid.sections(from: 120 + tops[2] + 1, to: 120 + tops[4] + 1) == 2...4)
        print("Photo grid geometry checks passed")
    }

    @MainActor static func collectionView() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let counts = Array(repeating: 300, count: 40)
        let layout = PhotoGridLayout()
        layout.inputs = .init(size: 96, pageHeader: 0, counts: counts, headers: Array(repeating: true, count: counts.count))
        layout.topInset = 52
        let months = Months(counts: counts)
        let collection = NSCollectionView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        collection.collectionViewLayout = layout
        collection.dataSource = months
        collection.register(Tile.self, forItemWithIdentifier: NSUserInterfaceItemIdentifier("tile"))
        collection.register(Header.self, forSupplementaryViewOfKind: PhotoGridLayout.monthHeaderKind,
                            withIdentifier: NSUserInterfaceItemIdentifier("header"))
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        scroll.documentView = collection
        scroll.hasVerticalScroller = true
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 52, left: 0, bottom: 0, right: 0)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        window.contentView = scroll

        func settle() {
            collection.setFrameSize(NSSize(width: scroll.contentView.bounds.width, height: layout.geometry.contentHeight))
            layout.invalidateLayout()
            for _ in 0..<3 {
                scroll.layoutSubtreeIfNeeded()
                collection.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
        }

        func scrollTo(_ y: CGFloat) {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
            settle()
        }

        func header(_ section: Int) -> NSView? {
            collection.supplementaryView(forElementKind: PhotoGridLayout.monthHeaderKind, at: IndexPath(item: 0, section: section))
        }

        settle()
        let width = scroll.contentView.bounds.width
        precondition(close(layout.geometry.width, width), "The grid is as wide as the part of the scroll view it shows in")
        precondition(close(collection.collectionViewLayout!.collectionViewContentSize.height, layout.geometry.contentHeight))

        // Deep into the grid: the row of a month's 150th photo at the top below the bars and its month's header.
        let deep = Place(section: 35, item: 150)
        let frame = layout.geometry.tileFrame(deep)
        scrollTo(frame.minY - 52 - 50)
        guard let item = collection.item(at: IndexPath(item: deep.item, section: deep.section)) else {
            preconditionFailure("The tile scrolled to is laid out")
        }
        precondition(close(item.view.frame, frame), "The tile is where the arithmetic puts it: \(item.view.frame) \(frame)")
        let visibleTop = scroll.contentView.bounds.minY + 52
        precondition(close(visibleTop, frame.minY - 50), "Scrolled to the point")
        // Its month's header stays at the top of the view over its photos.
        guard let pinned = header(35) else { preconditionFailure("The month's header is shown") }
        precondition(close(pinned.frame.minY, visibleTop), "The header stays at the top: \(pinned.frame.minY) \(visibleTop)")
        precondition(header(34).map { $0.frame.maxY <= visibleTop + 0.01 } ?? true, "The month before's header has gone up")

        // Scrolling on moves it with the view; the month's end pushes it up as the next month comes.
        scrollTo(scroll.contentView.bounds.minY + 333)
        precondition(close(header(35)!.frame.minY, scroll.contentView.bounds.minY + 52), "The header follows the scroll")
        let end = layout.geometry.sectionBottom(35)
        scrollTo(end - 20 - 52)
        precondition(close(header(35)!.frame.minY, end - 50), "The next month pushes the header up: \(header(35)!.frame.minY) \(end - 50)")
        precondition(close(header(36)!.frame.minY, end), "The next month's header is at its place")

        // Another width lays the grid out anew: other columns, every tile where the arithmetic puts it.
        let columnsBefore = layout.geometry.columns
        scroll.setFrameSize(NSSize(width: 520, height: 600))
        settle()
        precondition(close(layout.geometry.width, scroll.contentView.bounds.width) && layout.geometry.columns < columnsBefore)
        let after = layout.geometry.tileFrame(deep)
        scrollTo(after.minY - 52 - 50)
        guard let moved = collection.item(at: IndexPath(item: deep.item, section: deep.section)) else {
            preconditionFailure("The tile is laid out at the new width")
        }
        precondition(close(moved.view.frame, after), "At the new width: \(moved.view.frame) \(after)")

        // A pinch's picture: a second collection view of the tiles in view, limited to the view as the pinch began, its
        // headers where they rest. Its tiles are there as soon as it is laid out, with no turn of the run loop, so it
        // shows in the frame the grid goes to the next size under it.
        let pictureLayout = PhotoGridLayout()
        pictureLayout.fixedWidth = layout.geometry.width
        pictureLayout.inputs = layout.inputs
        pictureLayout.topInset = 52
        let top = scroll.contentView.bounds.minY
        pictureLayout.frozenTop = top + 52
        pictureLayout.limit = CGRect(x: 0, y: top, width: layout.geometry.width, height: 600)
        let picture = NSCollectionView(frame: NSRect(x: 0, y: 0, width: 520, height: 600))
        picture.collectionViewLayout = pictureLayout
        picture.dataSource = months
        picture.register(Tile.self, forItemWithIdentifier: NSUserInterfaceItemIdentifier("tile"))
        picture.register(Header.self, forSupplementaryViewOfKind: PhotoGridLayout.monthHeaderKind,
                         withIdentifier: NSUserInterfaceItemIdentifier("header"))
        let pictureScroll = NSScrollView(frame: scroll.frame)
        pictureScroll.documentView = picture
        scroll.superview?.addSubview(pictureScroll)
        picture.setFrameSize(NSSize(width: layout.geometry.width, height: pictureLayout.geometry.contentHeight))
        picture.reloadData()
        pictureScroll.contentView.scroll(to: NSPoint(x: 0, y: top))
        pictureScroll.layoutSubtreeIfNeeded()
        picture.layoutSubtreeIfNeeded()
        guard let pictured = picture.item(at: IndexPath(item: deep.item, section: deep.section)) else {
            preconditionFailure("The picture's tiles are there once it is laid out")
        }
        precondition(close(pictured.view.frame, after), "The picture's tile is where the grid's is")
        let outside = picture.visibleItems().filter { !$0.view.frame.intersects(pictureLayout.limit!) }
        precondition(outside.isEmpty, "The picture holds only what was in view")
        precondition(picture.supplementaryView(forElementKind: PhotoGridLayout.monthHeaderKind,
                                               at: IndexPath(item: 0, section: deep.section)).map { close($0.frame.minY, top + 52) } == true,
                     "The picture's header rests below the bars")
        window.close()
        print("Photo grid collection view checks passed: deep scroll to the point, headers staying at the top and pushed up, another width")
    }

    /// A pinch shows each size through a scroll view's magnification, its clip view moved past the content's edges
    /// (PhotoGridPinch): a point of the content shows where the transition puts it, the next size's and the picture's.
    @MainActor static func magnified() {
        final class FreeClip: NSClipView {
            override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect { proposedBounds }
        }
        final class Content: NSView {
            override var isFlipped: Bool { true }
        }
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let clip = FreeClip()
        scroll.contentView = clip
        let content = Content(frame: NSRect(x: 0, y: 0, width: 800, height: 20_000))
        scroll.documentView = content
        scroll.minMagnification = 0.05
        scroll.maxMagnification = 20
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = scroll
        precondition(!scroll.allowsMagnification, "Magnified by the grid alone, never by the scroll view's own gestures")

        /// Where a point of the content shows, from the view's top left.
        func onScreen(_ point: CGPoint) -> CGPoint {
            let shown = scroll.convert(point, from: content)
            return CGPoint(x: shown.x, y: scroll.isFlipped ? shown.y : scroll.bounds.height - shown.y)
        }

        for (fromPitch, toPitch) in [(CGFloat(100), CGFloat(150)), (150, 100)] {
            for progress in [CGFloat(0), 0.3, 0.75, 1] {
                let transition = GridZoomTransition(fromLevel: 0, toLevel: 1, fromPitch: fromPitch, toPitch: toPitch, fromOffset: 1_200,
                                                    toOffset: 1_830, fromAnchor: CGPoint(x: 220, y: 260),
                                                    toAnchor: CGPoint(x: 330, y: 240), progress: progress)
                let next = transition.nextMagnified
                scroll.magnification = next.magnification
                clip.setBoundsOrigin(next.origin)
                scroll.reflectScrolledClipView(clip)
                precondition(close(scroll.magnification, next.magnification), "The scroll view magnifies as asked")
                for point in [CGPoint(x: 0, y: 1_830), CGPoint(x: 330, y: 2_070), CGPoint(x: 777, y: 2_400)] {
                    let expected = transition.shown(next: CGRect(x: point.x, y: point.y - 1_830, width: 0, height: 0)).origin
                    let shown = onScreen(point)
                    precondition(close(shown.x, expected.x) && close(shown.y, expected.y),
                                 "The next size shows where the transition puts it: \(shown) \(expected), progress \(progress)")
                }
                let picture = transition.pictureMagnified
                scroll.magnification = picture.magnification
                clip.setBoundsOrigin(picture.origin)
                scroll.reflectScrolledClipView(clip)
                for point in [CGPoint(x: 0, y: 1_200), CGPoint(x: 220, y: 1_460), CGPoint(x: 700, y: 1_700)] {
                    let old = CGPoint(x: point.x, y: point.y - 1_200)
                    let anchor = transition.anchor
                    let expected = CGPoint(x: anchor.x + transition.scale * (old.x - 220), y: anchor.y + transition.scale * (old.y - 260))
                    let shown = onScreen(point)
                    precondition(close(shown.x, expected.x) && close(shown.y, expected.y),
                                 "The picture shows where the transition puts it: \(shown) \(expected), progress \(progress)")
                }
            }
        }
        window.close()
        print("Photo grid pinch checks passed: the next size and the picture magnified where the transition puts them")
    }

    static func main() {
        geometry()
        MainActor.assumeIsolated {
            collectionView()
            magnified()
        }
    }
}
