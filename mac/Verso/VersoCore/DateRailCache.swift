import Foundation

// The date scroller's arithmetic comes from the core (`dateRail`, over `verso_core::rail`; ARCHITECTURE.md, "The date
// scroller"), the same as on Linux, for the Mac's rail and the iPhone's pill alike.

/// A grid's date scroller, made again only when its months, how they are laid out or how much is in view change: the
/// scroller draws again on every scroll and every move of the pointer.
public final class DateRailCache {
    private var key: Int?
    private var rail: DateRail?

    public init() {}

    /// The scroller for `months` laid out in `shape`; none where a month is not a timeline's.
    public func rail(months: [RailMonth], shape: RailShape) -> DateRail? {
        var hasher = Hasher()
        for month in months {
            hasher.combine(month.bucket)
            hasher.combine(month.count)
        }
        hasher.combine(shape.columns)
        hasher.combine(shape.rowHeight)
        hasher.combine(shape.headerHeight)
        hasher.combine(shape.viewport)
        hasher.combine(shape.flows)
        let key = hasher.finalize()
        if key != self.key {
            self.key = key
            rail = dateRail(months: months, shape: shape)
        }
        return rail
    }
}
