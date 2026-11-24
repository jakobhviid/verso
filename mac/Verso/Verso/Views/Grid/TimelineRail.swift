import SwiftUI
import VersoCore

/// Where the grid has scrolled to, for the date scroller. Apart from the grid, so scrolling redraws only the scroller.
@MainActor @Observable final class TimelineRailPosition {
    /// The grid's top in view, in points down its months (below the page's header), once the grid has laid them out.
    var offset: Double?
}

/// The date scroller beside the grid, as Immich's web app has one: the years down the side, placed where their photos
/// are, a tick for each month, a mark where the grid is, and the month under the pointer. A click or a drag goes to
/// exactly the place pointed at, partway into a month as readily as to its start; a click on a year's label goes to the
/// year's first month. Where everything is comes from the shared core (`dateRail`; ARCHITECTURE.md, "The date
/// scroller"), as on Linux and the iPhone: each month takes the room the grid gives it, its header and its rows, so
/// the scroller follows the grid. The grid (`PhotoGridCollection`) scrolls to the point pointed at (`scrollTo`), as
/// the iPhone's does. A drag ticks on a Force Touch trackpad at each month it crosses, as the iPhone's pill does. View >
/// Hide Date Scroller turns it off.
struct TimelineRail: View {
    static let width: CGFloat = 46
    static let shownKey = "grid.showsDateScroller"
    /// The least room between two years' labels.
    static let labelSpacing = 34.0
    /// A month section's header, as `SectionHeader` draws it.
    static let headerHeight = Double(PhotoGridGeometry.headerHeight)

    /// The grid's months, each with as many photos as it shows.
    let sections: [GridSection]
    let columns: Int
    /// A row of photos with the space below it.
    let rowHeight: Double
    let position: TimelineRailPosition
    /// Scrolls the grid to put a place, in points down its months, at the top of the view.
    let scrollTo: (Double) -> Void

    @State private var rails = DateRailCache()
    @State private var pointer: CGFloat?
    /// Where the scroller last put the grid, in points down its months.
    @State private var lastJump: Double?
    /// The month under a drag, so the trackpad ticks as the drag crosses into another.
    @State private var dragMonth: Int?

    var body: some View {
        GeometryReader { geo in
            let shape = RailShape(columns: UInt32(clamping: max(1, columns)), rowHeight: rowHeight,
                                  headerHeight: Self.headerHeight, viewport: max(1, geo.size.height), flows: false)
            if let rail = rails.rail(months: sections.map { RailMonth(bucket: $0.id, count: UInt32(clamping: $0.count)) },
                                     shape: shape) {
                scroller(rail, size: geo.size)
            }
        }
        .frame(width: Self.width)
        .padding(.leading, 16)
        .padding(.trailing, 2)
    }

    private func scroller(_ rail: DateRail, size: CGSize) -> some View {
        let height = max(1, size.height)
        let marks = rail.yearMarks(length: height, spacing: Self.labelSpacing)
        let tops = rail.tops()
        let mark = markFraction(rail)
        return ZStack {
            Canvas { context, canvas in
                // A tick for each month, and a longer one where a year starts.
                let starts = Set(marks.map { Int($0.month) })
                for (index, top) in tops.enumerated() {
                    let length: CGFloat = starts.contains(index) ? 7 : 3
                    let rect = CGRect(x: canvas.width - length - 2, y: top * canvas.height, width: length, height: 1)
                    context.fill(Path(rect), with: .color(.secondary.opacity(starts.contains(index) ? 0.7 : 0.35)))
                }
            }
            // By place, not month: Now and a year of one month so far share their month, and SwiftUI kept one of the
            // two labels by a month alone.
            ForEach(Array(marks.enumerated()), id: \.offset) { _, mark in
                Text(mark.now ? String(localized: "Now") : String(mark.year))
                    .font(.caption.weight(.medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .position(x: size.width / 2 - 5, y: labelY(mark, height: height))
            }
            Capsule()
                .fill(.tint)
                .frame(width: 14, height: 2)
                .position(x: size.width - 9, y: min(max(mark * height, 1), height - 1))
            if let pointer, let title = title(rail, at: pointer / height) {
                Text(title)
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.regularMaterial, in: .capsule)
                    .fixedSize()
                    // Out to the left, over the photos, beside the pointer.
                    .frame(width: size.width, alignment: .trailing)
                    .offset(x: -18)
                    .position(x: size.width / 2, y: min(max(pointer, 10), height - 10))
                    .allowsHitTesting(false)
            }
        }
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active(let location): pointer = location.y
            case .ended: pointer = nil
            }
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    pointer = value.location.y
                    tick(at: value.location.y / height, rail: rail)
                    go(to: value.location.y, height: height, rail: rail, marks: marks, isClick: value.translation == .zero)
                }
                .onEnded { _ in
                    lastJump = nil
                    dragMonth = nil
                }
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Date Scroller"))
        .accessibilityValue(Text(title(rail, at: mark) ?? ""))
        .accessibilityAdjustableAction { direction in
            // A year at a time, down the grid or back up.
            let current = rail.monthAt(fraction: mark).map(Int.init) ?? 0
            let target = direction == .increment
                ? marks.first { Int($0.month) > current }?.month
                : marks.last { Int($0.month) < current }?.month
            guard let target, sections.indices.contains(Int(target)) else { return }
            scrollTo(rail.yAt(fraction: rail.fractionOf(place: RailPlace(month: target, row: nil, offset: 0))))
        }
    }

    /// The trackpad's alignment tick as a drag crosses into another month, as the iPhone's pill gives the selection
    /// haptic at each: none as it starts. A trackpad without Force Touch, or a mouse, gives none.
    private func tick(at fraction: Double, rail: DateRail) {
        guard let month = rail.monthAt(fraction: fraction).map(Int.init) else { return }
        let previous = dragMonth
        dragMonth = month
        guard let previous, previous != month else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    /// The name of the month at a point on the scroller.
    private func title(_ rail: DateRail, at fraction: Double) -> String? {
        guard let index = rail.monthAt(fraction: fraction).map(Int.init), sections.indices.contains(index) else { return nil }
        return sections[index].title
    }

    /// The year label at `y`, drawn just below its year's first month.
    private func labelY(_ mark: RailYear, height: Double) -> Double {
        min(max(mark.fraction * height + 8, 8), height - 8)
    }

    /// Where the mark goes: the grid's top in view.
    private func markFraction(_ rail: DateRail) -> Double {
        position.offset.map { rail.fractionAt(y: $0) } ?? 0
    }

    /// The exact place under the pointer at the top, to the point; a click on a year's label, the year's first month.
    private func go(to y: Double, height: Double, rail: DateRail, marks: [RailYear], isClick: Bool) {
        let label = isClick ? marks.first { abs(labelY($0, height: height) - y) <= 9 } : nil
        let fraction = label.map { rail.fractionOf(place: RailPlace(month: $0.month, row: nil, offset: 0)) } ?? y / height
        // In whole points: a drag scrolls again only when the place moves by one.
        let offset = rail.yAt(fraction: fraction).rounded()
        guard offset != lastJump else { return }
        lastJump = offset
        scrollTo(offset)
    }
}
