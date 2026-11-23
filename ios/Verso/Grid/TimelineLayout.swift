// Where each tile of a photo grid sits, worked out from the model's months alone. The grid flows its photos in rows
// with no break between months, as Photos' All Photos does, so a tile's place follows from how many photos come before
// it: nothing here walks the photos themselves, and a library of any size lays out in the time its months take. The
// Library's photos on their way to Immich, from the phone, are placed among the model's months by TimelinePhoneMerge;
// only a month that has some keeps a list of its tiles.

import Observation
import SwiftUI

/// The model's place for one tile: its month's index in `sections`, the photo's index in the month (the model's own
/// order, newest first on a timeline), and the month's index in the layout. A photo on its way from the phone has its
/// index in the grid's list of them instead, and no section or item of the model's (-1).
struct TilePlace: Equatable {
    let section: Int
    let item: Int
    let month: Int
    var phone: Int? = nil
}

struct TimelineLayout: Equatable {
    /// One of the model's months that has tiles, in the grid's order.
    struct Month: Equatable {
        /// The month's index in the model's `sections`, or -1 for a month only the phone has photos of.
        let section: Int
        /// The model's ID for it: a timeline bucket ("2024-03-01T00:00:00.000Z"), or a paged source's own.
        let id: String
        /// How many tiles come before it in the grid.
        let start: Int
        let count: Int
        /// Its tiles in the model's order where photos on their way are among them (TimelinePhoneMerge); nil where
        /// each tile is the model's photo at its own index.
        var slots: [TimelinePhoneMerge.Slot]? = nil
    }

    let months: [Month]
    let tileCount: Int
    /// The grid reads the model backwards, the oldest month first and the newest photo last, as Photos' library does.
    let reversed: Bool
    /// The photos on their way it was laid out with, as the merge placed them.
    let phone: [TimelinePhoneMerge.Phone]
    /// Each month's place in `months`, by its index in the model's `sections`.
    private let monthBySection: [Int: Int]

    /// The model's months, with the photos on their way from the phone among them where the grid shows them (the
    /// Library's own timeline): by when each was taken (`phoneByDate`), or at the newest end.
    @MainActor
    init(model: AssetGridModel, reversed: Bool, phone: [TimelinePhoneMerge.Phone] = [], phoneByDate: Bool = true) {
        let sections = model.sections
        let phoneMonths = Set(phone.map(\.month))
        let modelMonths = sections.indices.map { index in
            // A month the phone has photos on their way in, with when each of its photos was taken, where they are
            // read.
            let dates = phoneMonths.contains(String(sections[index].id.prefix(7))) ? sections[index].assets?.map(\.date) : nil
            return TimelinePhoneMerge.ModelMonth(section: index, id: sections[index].id,
                                                 count: model.shownCount(sections[index]), dates: dates)
        }
        let merged = TimelinePhoneMerge.merge(modelMonths, phone: phone, byDate: phoneByDate)
        let order = reversed ? Array(merged.reversed()) : merged
        var months: [Month] = []
        var monthBySection: [Int: Int] = [:]
        months.reserveCapacity(order.count)
        var start = 0
        for month in order where month.count > 0 {
            if let section = month.section { monthBySection[section] = months.count }
            months.append(Month(section: month.section ?? -1, id: month.id, start: start, count: month.count, slots: month.slots))
            start += month.count
        }
        self.months = months
        self.monthBySection = monthBySection
        self.tileCount = start
        self.reversed = reversed
        self.phone = phone
    }

    func rowCount(columns: Int) -> Int {
        let columns = max(1, columns)
        return (tileCount + columns - 1) / columns
    }

    /// The tiles of one row, by their index in the grid.
    func tiles(inRow row: Int, columns: Int) -> Range<Int> {
        let first = row * columns
        return min(first, tileCount)..<min(first + columns, tileCount)
    }

    /// The month a tile belongs to, by its index in `months`: the last one that starts at or before it.
    func monthIndex(ofTile index: Int) -> Int? {
        guard index >= 0, index < tileCount, !months.isEmpty else { return nil }
        var low = 0
        var high = months.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if months[middle].start <= index { low = middle } else { high = middle - 1 }
        }
        return low
    }

    /// The model's place for the tile at `index` in the grid's order.
    func place(ofTile index: Int) -> TilePlace? {
        guard let monthIndex = monthIndex(ofTile: index) else { return nil }
        let month = months[monthIndex]
        let offset = index - month.start
        let position = reversed ? month.count - 1 - offset : offset
        guard let slots = month.slots else { return TilePlace(section: month.section, item: position, month: monthIndex) }
        switch slots[position] {
        case .model(let item): return TilePlace(section: month.section, item: item, month: monthIndex)
        case .phone(let phone): return TilePlace(section: month.section, item: -1, month: monthIndex, phone: phone)
        }
    }

    /// The tile that shows the model's photo `item` of month `section`.
    func tileIndex(section: Int, item: Int) -> Int? {
        guard let monthIndex = monthBySection[section] else { return nil }
        let month = months[monthIndex]
        let position: Int
        if let slots = month.slots {
            guard let found = slots.firstIndex(of: .model(item)) else { return nil }
            position = found
        } else {
            guard item >= 0, item < month.count else { return nil }
            position = item
        }
        return month.start + (reversed ? month.count - 1 - position : position)
    }
}

/// One grid's layout, worked out again only when the model's months or the photos on their way change. Observation
/// tells it when the months do, so the redraws for anything else (the selection, scrolling, the zoom) reuse the layout
/// they have.
@MainActor final class TimelineLayoutCache {
    private var layout: TimelineLayout?
    private var phoneByDate = true
    /// Counts the layouts made, so the grid redraws the tiles in view when what they show may have moved.
    private(set) var revision = 0

    func layout(for model: AssetGridModel, reversed: Bool, phone: [TimelinePhoneMerge.Phone] = [],
                phoneByDate: Bool = true) -> TimelineLayout {
        if let layout, layout.reversed == reversed, layout.phone == phone, self.phoneByDate == phoneByDate { return layout }
        let fresh = withObservationTracking {
            TimelineLayout(model: model, reversed: reversed, phone: phone, phoneByDate: phoneByDate)
        } onChange: { [weak self] in
            // The model changes its months on the main actor, where it lives.
            MainActor.assumeIsolated { self?.layout = nil }
        }
        layout = fresh
        self.phoneByDate = phoneByDate
        revision += 1
        return fresh
    }
}

/// The photo grid's zoom levels, chosen with a pinch: every count of photos a row from three to the densest, one level
/// each, as the Mac's grid has every count. A phone in portrait shows the counts themselves, as Photos shows three or
/// five a row on any iPhone's width, up to fifteen a row on a 393-point iPhone and more on a wider one (seventeen on a
/// Pro Max); an iPad in portrait shows them too, as Photos shows five a row on any iPad, its tiles larger; a wider grid
/// (landscape, or an iPad's window wider than tall) keeps the tiles' size and shows more of them in a row.
enum GridZoom {
    static let storageKey = "grid.zoom"
    /// Five a row in portrait, Photos' own default on an iPhone and an iPad.
    static let defaultLevel = 2

    /// The width the densest count is an iPhone's at.
    private static let compactWidth = 393.0
    /// Wider than any phone in portrait.
    private static let portraitWidth = 500.0

    /// The counts a row in a grid of `width` by `height`, the fewest first, the first at level 0: a phone's from its
    /// width, an iPad's (`regular`) from its shorter side, where it shows the counts themselves.
    static func counts(width: CGFloat, height: CGFloat, regular: Bool) -> ClosedRange<Int> {
        let base = regular ? max(1, min(Double(width), Double(height))) : compactWidth
        let scale = Double(width) / base
        let fewest = !regular && Double(width) <= portraitWidth ? 3 : max(3, Int((3 * scale).rounded()))
        return fewest...max(fewest, Int((15 * scale).rounded()))
    }

    /// The levels in a grid of that size.
    static func levels(width: CGFloat, height: CGFloat, regular: Bool) -> ClosedRange<Int> {
        let counts = counts(width: width, height: height, regular: regular)
        return 0...(counts.upperBound - counts.lowerBound)
    }

    static func clamped(_ level: Int, width: CGFloat, height: CGFloat, regular: Bool) -> Int {
        let levels = levels(width: width, height: height, regular: regular)
        return min(max(level, levels.lowerBound), levels.upperBound)
    }

    static func columns(level: Int, width: CGFloat, height: CGFloat, regular: Bool) -> Int {
        counts(width: width, height: height, regular: regular).lowerBound
            + clamped(level, width: width, height: height, regular: regular)
    }
}
