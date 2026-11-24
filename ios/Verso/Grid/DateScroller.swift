// The date scroller of a long timeline on iOS: a glass pill on the grid's trailing edge that names the month it points
// at, as Photos' scrubber does. It shows while the grid scrolls and goes a moment after; its place down the edge is the
// grid's place in the library. Held, it shows the years down the edge on a strip of the pill's glass, as the Mac's date
// scroller (TimelineRail) has them, gone when it is let go; dragged, it moves the grid to exactly the place it points
// at, a tick at each new month. A finger moved left, away from the edge, scrubs finer, as iOS's video scrubbers do: at
// half speed past about 60 points, at a quarter past about 120. Where the pill sits, the years and the place a point
// stands for come from the shared core (`dateRail`; ARCHITECTURE.md, "The date scroller"), as on the Mac and Linux:
// the months in the grid's rows, which flow on from month to month, worked out from the months' photo counts, so months
// not loaded yet take their true room. View Options switch it off, as the Mac's do.

import SwiftUI
import VersoCore

struct DateScroller: View {
    /// Whether grids show it, kept on this device under the Mac's key for its date scroller.
    static let shownKey = "grid.showsDateScroller"

    let layout: TimelineLayout
    let scroll: GridScrollState
    let metrics: GridTileMetrics
    let rowCount: Int
    /// Moves the grid, whose page's header sits above its rows.
    let scroller: GridScroller
    /// The bars over the grid, which runs on under them: the track runs between them.
    let bars: EdgeInsets
    /// The grid's months are a timeline's, and the date scroller is on.
    let shown: Bool
    /// Told as the pill moves the grid.
    let onJump: () -> Void

    @State private var rails = DateRailCache()
    @State private var hold: Hold?
    /// Where the pill last put the rows' top, so a drag scrolls only when that changes.
    @State private var lastJump: Double?
    @State private var visible = false

    /// The pill held.
    private struct Hold: Equatable {
        /// Where the pill is, from 0 at the top of its track to 1 at the bottom.
        var fraction: Double
        /// The finger's last place, in the window's coordinates.
        var finger: CGPoint
        /// Where the finger came down, across: left of it the pill moves slower than the finger.
        var startX: CGFloat
    }

    private let pillHeight: CGFloat = 34
    /// A timeline gets a scroller once it is this many screens long.
    private let screensForScroller: CGFloat = 4
    private let stripWidth: CGFloat = 52
    /// The least room between two years' labels on the strip.
    private let yearSpacing = 24.0
    /// Verso Dev's probes: the pill and the years' strip always shown, for a screenshot (`-probeDateScroller YES`).
    private var probing: Bool {
        #if DEBUG
        UserDefaults.standard.bool(forKey: "probeDateScroller")
        #else
        false
        #endif
    }

    var body: some View {
        if let rail = offeredRail {
            GeometryReader { geometry in
                let top = bars.top + 8
                let travel = max(0, geometry.size.height - bars.bottom - 8 - pillHeight - top)
                let fraction = hold?.fraction ?? restingFraction(rail)
                let title = monthTitle(rail, at: fraction)
                ZStack(alignment: .topTrailing) {
                    ZStack {
                        if hold != nil || probing {
                            years(rail, travel: travel)
                                .transition(.opacity)
                        }
                    }
                    .animation(.easeOut(duration: 0.2), value: hold != nil)
                    .offset(y: top)
                    pill(title)
                        .gesture(drag(rail, travel: travel))
                        .offset(y: top + travel * fraction)
                        .opacity(visible || probing ? 1 : 0)
                        .allowsHitTesting(visible || probing)
                        .sensoryFeedback(.selection, trigger: hold == nil ? nil : title)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Date Scroller")
                        .accessibilityValue(title)
                        .accessibilityAdjustableAction { direction in
                            step(direction == .increment ? 1 : -1, rail: rail, from: fraction)
                        }
                }
                .padding(.trailing, 6)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
            // The grid's whole height, the track kept clear of the bars by the grid's own insets: laid out inside the bars, as
            // an overlay is, the track lost their height twice, which left the iPhone's two thirds of the room it has.
            .ignoresSafeArea()
            .animation(.easeOut(duration: 0.2), value: visible)
            // Shown while the grid scrolls or the pill is held, and gone a moment after.
            .task(id: scroll.isScrolling || hold != nil) {
                if scroll.isScrolling || hold != nil {
                    visible = true
                    return
                }
                try? await Task.sleep(for: .seconds(1.5))
                if !Task.isCancelled { visible = false }
            }
        }
    }

    /// The scroller's arithmetic, for a timeline long enough to need it: its months in the grid's rows, which flow on
    /// from month to month without headers, and the rows' part in view.
    private var offeredRail: DateRail? {
        let viewport = scroll.viewport
        guard shown, viewport.visibleHeight > 0,
              CGFloat(rowCount) * metrics.pitch > screensForScroller * viewport.visibleHeight else { return nil }
        let shape = RailShape(columns: UInt32(clamping: metrics.columns), rowHeight: Double(metrics.pitch),
                              headerHeight: 0, viewport: Double(viewport.visibleHeight), flows: true)
        return rails.rail(months: layout.months.map { RailMonth(bucket: $0.id, count: UInt32(clamping: $0.count)) },
                          shape: shape)
    }

    /// Where the grid is, as a point on the scroller: its rows' top in view, below the page's header.
    private func restingFraction(_ rail: DateRail) -> Double {
        rail.fractionAt(y: Double(scroll.viewport.visibleTop - scroller.headerHeight))
    }

    private func pill(_ title: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.up.chevron.down")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.footnote.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .frame(height: pillHeight)
        .fixedSize()
        // Not interactive glass, which grows from its middle as it is touched and would push a long month's name past
        // the screen's edge: held, the pill grows from its trailing end.
        .glassEffect(.regular, in: .capsule)
        .contentShape(.capsule)
        .scaleEffect(hold == nil ? 1 : 1.08, anchor: .trailing)
        .animation(.easeOut(duration: 0.15), value: hold == nil)
    }

    /// The years down the pill's track, each where the pill's middle is when the grid is at its first month.
    private func years(_ rail: DateRail, travel: CGFloat) -> some View {
        let marks = rail.yearMarks(length: Double(travel), spacing: yearSpacing)
        return ZStack(alignment: .top) {
            // By place, not month: Now and a year of one month so far share their month, and SwiftUI kept one of the
            // two labels by a month alone.
            ForEach(Array(marks.enumerated()), id: \.offset) { _, mark in
                Text(mark.now ? String(localized: "Now") : String(mark.year))
                    .font(.caption2.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: stripWidth, height: pillHeight)
                    .offset(y: travel * mark.fraction)
            }
        }
        .frame(width: stripWidth, height: travel + pillHeight, alignment: .top)
        // The pill's own glass, so the years stay legible over any photo.
        .glassEffect(.regular, in: .capsule)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func drag(_ rail: DateRail, travel: CGFloat) -> some Gesture {
        // In the window's coordinates: the pill moves with the finger, so its own would move under it.
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                var held = hold ?? Hold(fraction: restingFraction(rail), finger: value.startLocation,
                                        startX: value.startLocation.x)
                let leftward = held.startX - value.location.x
                let speed = leftward > 120 ? 0.25 : leftward > 60 ? 0.5 : 1
                let moved = travel > 0 ? Double((value.location.y - held.finger.y) / travel) * speed : 0
                held.fraction = min(1, max(0, held.fraction + moved))
                held.finger = value.location
                hold = held
                go(to: held.fraction, rail: rail)
            }
            .onEnded { _ in
                hold = nil
                lastJump = nil
            }
    }

    /// Puts the place a point stands for at the top of the view.
    private func go(to fraction: Double, rail: DateRail) {
        let y = rail.yAt(fraction: fraction)
        if let lastJump, abs(lastJump - y) < 0.5 { return }
        lastJump = y
        onJump()
        scroller.scrollTo(y: scroller.headerHeight + CGFloat(y))
    }

    private func monthTitle(_ rail: DateRail, at fraction: Double) -> String {
        guard let index = rail.monthAt(fraction: fraction).map(Int.init), layout.months.indices.contains(index) else {
            return ""
        }
        return ImmichDate.monthTitle(layout.months[index].id)
    }

    /// VoiceOver's swipe up or down: the next month down the grid, or the one before, that starts a row of its own.
    private func step(_ direction: Int, rail: DateRail, from fraction: Double) {
        guard let current = rail.monthAt(fraction: fraction).map(Int.init) else { return }
        var target = current + direction
        while layout.months.indices.contains(target) {
            let start = rail.fractionOf(place: RailPlace(month: UInt32(target), row: nil, offset: 0))
            if rail.monthAt(fraction: start).map(Int.init) != current {
                lastJump = nil
                go(to: start, rail: rail)
                return
            }
            target += direction
        }
    }
}
