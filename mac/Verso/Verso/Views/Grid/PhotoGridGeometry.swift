import CoreGraphics
import Foundation

/// Where everything in the Mac's photo grid goes (`PhotoGridLayout`), worked out from the months' photo counts alone:
/// the page's header at the top (an album's details), then each month's header and its rows of square tiles, two points
/// apart, each month starting a row of its own. A row is laid out as the iPhone's is (`GridTileMetrics`, which both apps
/// compile); the months' headers, and a month starting a row, are the Mac's own: the iPhone's months flow on in shared
/// rows without headers (`TimelineLayout`). It is the date scroller's arithmetic in verso-core (`rail`), so a place
/// on the scroller is a place in the grid to the point: a month takes its header and `ceil(count / columns)` rows, each
/// row a tile's side and the space below it, whether its photos have loaded or not. Nothing here walks the photos
/// themselves, so a library of any size lays out in the time its months take. ARCHITECTURE.md, "The photo grid on the
/// Mac".
struct PhotoGridGeometry: Equatable {
    /// The space between two tiles, across and down.
    static let spacing: CGFloat = 2
    /// A month's header above its rows (`SectionHeader` in it), as the date scroller counts it.
    static let headerHeight: CGFloat = 50
    /// Below the last month.
    static let bottomPadding: CGFloat = 20

    /// A tile, by its month's index and its index there: the model's own section and item.
    struct Place: Hashable {
        let section: Int
        let item: Int
    }

    /// What the grid is laid out from.
    struct Inputs: Equatable {
        /// The tiles' least side: the grid's zoom (`GridMetrics.steps`).
        var size: Double
        /// The page's header above the months, as tall as it last drew itself; 0 without one.
        var pageHeader: CGFloat
        /// How many photos each month shows, in the grid's order.
        var counts: [Int]
        /// Whether each month has a header (a timeline's months; not search results).
        var headers: [Bool]

        static let empty = Inputs(size: 150, pageHeader: 0, counts: [], headers: [])
    }

    /// One month's room.
    struct Section: Equatable {
        /// Its top, in points down the months (below the page's header).
        let top: CGFloat
        /// Its header's height: none for a month without photos or without a title.
        let header: CGFloat
        let count: Int
        let rows: Int
    }

    let width: CGFloat
    /// A row's tiles: how many, their side, and the row's height with the space below it.
    let metrics: GridTileMetrics
    let pageHeader: CGFloat
    let sections: [Section]
    /// The months' height, the page's header and the padding below them left out.
    let monthsHeight: CGFloat

    var columns: Int { metrics.columns }
    /// A tile's side.
    var side: CGFloat { metrics.side }
    /// From one row's top to the next.
    var pitch: CGFloat { metrics.pitch }
    var contentHeight: CGFloat { pageHeader + monthsHeight + Self.bottomPadding }
    /// Where the months start, in points down the content.
    var monthsTop: CGFloat { pageHeader }

    /// As many tiles of the least side `size`, with their spacing, as the width holds, as an adaptive grid fits them.
    static func columns(width: CGFloat, size: Double) -> Int {
        max(1, Int((width + spacing) / (CGFloat(size) + spacing)))
    }

    init(width: CGFloat, inputs: Inputs) {
        let width = max(0, width)
        let metrics = GridTileMetrics(columns: Self.columns(width: width, size: inputs.size), width: width, spacing: Self.spacing)
        let columns = metrics.columns
        let pitch = metrics.pitch
        self.width = width
        self.metrics = metrics
        pageHeader = max(0, inputs.pageHeader)
        var sections: [Section] = []
        sections.reserveCapacity(inputs.counts.count)
        var top: CGFloat = 0
        for (index, count) in inputs.counts.enumerated() {
            let count = max(0, count)
            let rows = (count + columns - 1) / columns
            let header = count > 0 && inputs.headers.indices.contains(index) && inputs.headers[index] ? Self.headerHeight : 0
            sections.append(Section(top: top, header: header, count: count, rows: rows))
            top += header + CGFloat(rows) * pitch
        }
        self.sections = sections
        monthsHeight = top
    }

    static let empty = PhotoGridGeometry(width: 0, inputs: .empty)

    // MARK: Places

    /// A month's top in the content.
    func sectionTop(_ section: Int) -> CGFloat { pageHeader + sections[section].top }

    /// Where a month's rows end in the content, the space below its last row included.
    func sectionBottom(_ section: Int) -> CGFloat {
        let room = sections[section]
        return sectionTop(section) + room.header + CGFloat(room.rows) * pitch
    }

    /// A month's header where it sits among the photos; nil for a month without one.
    func headerFrame(_ section: Int) -> CGRect? {
        guard sections.indices.contains(section), sections[section].header > 0 else { return nil }
        return CGRect(x: 0, y: sectionTop(section), width: width, height: sections[section].header)
    }

    /// The top of a row of a month's tiles in the content.
    func rowTop(section: Int, row: Int) -> CGFloat {
        sectionTop(section) + sections[section].header + CGFloat(row) * pitch
    }

    /// Where a tile is in the content.
    func tileFrame(_ place: Place) -> CGRect {
        let row = place.item / columns
        let column = place.item % columns
        return CGRect(x: CGFloat(column) * pitch, y: rowTop(section: place.section, row: row), width: side, height: side)
    }

    /// The month at a height of the content: the last one that starts at or above it; nil above the months or
    /// without any.
    func section(atContentY y: CGFloat) -> Int? {
        let monthsY = y - pageHeader
        guard !sections.isEmpty, monthsY >= 0 else { return nil }
        var low = 0
        var high = sections.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if sections[middle].top <= monthsY { low = middle } else { high = middle - 1 }
        }
        return low
    }

    /// The months with room between two heights of the content.
    func sections(from top: CGFloat, to bottom: CGFloat) -> ClosedRange<Int>? {
        guard !sections.isEmpty, bottom >= pageHeader, top <= pageHeader + monthsHeight else { return nil }
        let first = section(atContentY: max(top, pageHeader)) ?? 0
        let last = section(atContentY: min(bottom, pageHeader + monthsHeight)) ?? first
        return first...max(first, last)
    }

    /// A month's tiles in the rows between two heights of the content, whole rows.
    func items(inSection section: Int, from top: CGFloat, to bottom: CGFloat) -> Range<Int> {
        let room = sections[section]
        guard room.rows > 0 else { return 0..<0 }
        let rowsTop = sectionTop(section) + room.header
        let first = max(0, Int(floor((top - rowsTop) / pitch)))
        let last = min(room.rows - 1, Int(floor((bottom - rowsTop) / pitch)))
        guard first <= last else { return 0..<0 }
        return (first * columns)..<min(room.count, (last + 1) * columns)
    }

    /// Every tile that a rectangle of the content touches, in the grid's order.
    func places(touching rect: CGRect) -> [Place] {
        guard let sections = sections(from: rect.minY, to: rect.maxY), columns > 0 else { return [] }
        let firstColumn = max(0, Int(floor(rect.minX / pitch)))
        let lastColumn = min(columns - 1, Int(floor(rect.maxX / pitch)))
        guard firstColumn <= lastColumn else { return [] }
        var places: [Place] = []
        for section in sections {
            for item in items(inSection: section, from: rect.minY, to: rect.maxY) {
                let column = item % columns
                guard column >= firstColumn, column <= lastColumn else { continue }
                let place = Place(section: section, item: item)
                if tileFrame(place).intersects(rect) { places.append(place) }
            }
        }
        return places
    }

    /// The tile at a point of the content; none on a header, in the space between tiles or past a month's last photo.
    func place(at point: CGPoint) -> Place? {
        guard point.x >= 0, point.x < width, let section = section(atContentY: point.y) else { return nil }
        let room = sections[section]
        let rowsTop = sectionTop(section) + room.header
        guard point.y >= rowsTop, room.rows > 0 else { return nil }
        let row = Int(floor((point.y - rowsTop) / pitch))
        let column = Int(floor(point.x / pitch))
        guard row < room.rows, column < columns,
              point.y - (rowsTop + CGFloat(row) * pitch) <= side, point.x - CGFloat(column) * pitch <= side else { return nil }
        let item = row * columns + column
        return item < room.count ? Place(section: section, item: item) : nil
    }

    /// The tile nearest a point of the content, for keeping a photo where it is as the grid changes: in a header, its
    /// month's first; between tiles or past the last, the one before. None without photos.
    func nearestPlace(to point: CGPoint) -> Place? {
        guard let start = section(atContentY: max(point.y, pageHeader)) else { return nil }
        // A month without photos has no tiles: the next one with some, or the last before it.
        let section = sections.indices[start...].first { sections[$0].count > 0 }
            ?? sections.indices[..<start].last { sections[$0].count > 0 }
        guard let section else { return nil }
        let room = sections[section]
        let rowsTop = sectionTop(section) + room.header
        let row = min(max(0, Int(floor((point.y - rowsTop) / pitch))), room.rows - 1)
        let column = min(max(0, Int(floor(point.x / pitch))), columns - 1)
        return Place(section: section, item: min(row * columns + column, room.count - 1))
    }
}
