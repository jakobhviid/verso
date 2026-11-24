// The size of the cards on the card pages (Albums, People, Memories, Places and a country's places), as the Mac and
// Linux size them (mac/Verso/Verso/Views/Albums/CardSize.swift): five sizes, one for every such page, kept under the
// Mac's key, the smallest the default. On iOS a pinch goes through them, as the photo grid's pinch goes through its
// zoom levels, and each page's View Options has Zoom Out and Zoom In side by side at its top; both zoom the cards as
// one grid (CardGrid, GridPinch).
//
// Each page says what a size is on it (CardLadder): so many cards to a row on an iPhone, and on an iPad the narrowest a
// card may be, the Mac's widths. A phone has room for fewer than five, so sizes that look the same on a page are passed
// over there: a pinch or Zoom In goes on to the next size that changes the page, and stops where none does.

import SwiftUI
import UIKit

enum CardSize {
    static let key = "cards.size"
    static let sizes = 0...4

    static func clamped(_ size: Int) -> Int { min(max(size, sizes.lowerBound), sizes.upperBound) }
}

/// What each card size is on one page.
struct CardLadder {
    /// Cards to a row on an iPhone at each size.
    let compactColumns: [Int]
    /// The narrowest a card may be at each size where there is more room, as on the Mac.
    let widths: [CGFloat]
    /// Between the cards, across and down.
    var spacing: CGFloat = 12

    /// How many cards to a row at `size`, in a page `width` wide.
    func columns(_ size: Int, width: CGFloat, regular: Bool) -> Int {
        let size = CardSize.clamped(size)
        guard regular, width > 0 else { return compactColumns[size] }
        return max(1, Int((width + spacing) / (widths[size] + spacing)))
    }

    /// What a page looks like at `size`: so many cards to a row.
    private func looks(_ size: Int, width: CGFloat, regular: Bool) -> Int {
        columns(size, width: width, regular: regular)
    }

    /// The smallest size that looks as `size` does.
    func smallestAlike(_ size: Int, width: CGFloat, regular: Bool) -> Int {
        var smallest = CardSize.clamped(size)
        let wanted = looks(smallest, width: width, regular: regular)
        while smallest > CardSize.sizes.lowerBound && looks(smallest - 1, width: width, regular: regular) == wanted {
            smallest -= 1
        }
        return smallest
    }

    /// The next size up or down that changes the page, or `size` itself where none does. Going down it goes on to the
    /// smallest size that looks the same, so zooming out as far as a page goes reaches the smallest size everywhere.
    func step(_ size: Int, larger: Bool, width: CGFloat, regular: Bool) -> Int {
        let start = CardSize.clamped(size)
        let looks = { (candidate: Int) in self.looks(candidate, width: width, regular: regular) }
        let current = looks(start)
        var next = start
        repeat {
            next += larger ? 1 : -1
            guard CardSize.sizes.contains(next) else { return size }
        } while looks(next) == current
        if !larger {
            while next > CardSize.sizes.lowerBound && looks(next - 1) == looks(next) { next -= 1 }
        }
        return next
    }
}

/// Where a card page is shown, for its ladder: its width, and whether it has an iPad's room.
struct CardPageWidth: Equatable {
    var width: CGFloat = 0
    var regular = false
}

extension View {
    /// Keeps `page` up to date with the width the page is shown in.
    func cardPageWidth(_ page: Binding<CardPageWidth>, regular: Bool) -> some View {
        onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            page.wrappedValue = CardPageWidth(width: width, regular: regular)
        }
        .onChange(of: regular) { _, regular in page.wrappedValue.regular = regular }
    }
}

extension View {
    /// A card opened by a tap of one finger, as the photo grid's tiles are, rather than as a button or a link, so a
    /// pinch on it changes the cards' size and does not open it.
    func cardOpens(_ open: @escaping () -> Void) -> some View {
        contentShape(.rect)
            .onTapGesture(perform: open)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(.default, open)
    }
}

/// Zoom Out and Zoom In, side by side at the top of a card page's View Options: the page's grid zooms to the new size
/// as a pinch does, about the middle of the view (CardGrid).
struct CardZoomControls: View {
    @Binding var size: Int
    let ladder: CardLadder
    let page: CardPageWidth

    var body: some View {
        let smaller = ladder.step(size, larger: false, width: page.width, regular: page.regular)
        let larger = ladder.step(size, larger: true, width: page.width, regular: page.regular)
        ControlGroup {
            Button("Zoom Out", systemImage: "minus.magnifyingglass") { size = smaller }
                .disabled(smaller == size)
            Button("Zoom In", systemImage: "plus.magnifyingglass") { size = larger }
            .disabled(larger == size)
        }
    }
}
