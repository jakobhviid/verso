import CoreGraphics

/// A card page's grid at each of the five card sizes (`CardSize`), as SwiftUI's adaptive columns lay it out: as many
/// cards in a line as fit at the size's least width, with `spacing` between them, widened to fill it. A step of the size
/// goes on to the next size that fits another number of cards in a line at the page's width, so each step changes what
/// shows; past the last such size there is no step (ARCHITECTURE.md, "Verso on the Mac", "Cards and tiles have five
/// sizes").
struct CardLayout: Equatable {
    /// The least width of a card at each size, the smallest size first.
    let widths: [CGFloat]
    /// The space between two cards in a line.
    var spacing: CGFloat = 20

    /// The least width of a card at `size`.
    func width(_ size: Int) -> CGFloat {
        widths[min(max(size, 0), widths.count - 1)]
    }

    /// How many cards fit in a line `lineWidth` wide at `size`: at least one.
    func cardsPerLine(_ size: Int, lineWidth: CGFloat) -> Int {
        max(1, Int(((lineWidth + spacing) / (width(size) + spacing)).rounded(.down)))
    }

    /// The size a step from `size` goes to, toward larger cards (`step` 1) or smaller (-1), at `lineWidth`: the nearest
    /// that fits another number of cards in a line, or nil where none does. Before the page knows its width, the next
    /// size.
    func size(from size: Int, step: Int, lineWidth: CGFloat) -> Int? {
        guard step != 0, !widths.isEmpty else { return nil }
        let start = min(max(size, 0), widths.count - 1)
        let direction = step > 0 ? 1 : -1
        var next = start + direction
        guard lineWidth > 0 else { return widths.indices.contains(next) ? next : nil }
        let shown = cardsPerLine(start, lineWidth: lineWidth)
        while widths.indices.contains(next) {
            if cardsPerLine(next, lineWidth: lineWidth) != shown { return next }
            next += direction
        }
        return nil
    }
}
