import SwiftUI

/// The size of the cards and tiles on Albums, Places, People, Memories and Shared Links, as Linux sizes them
/// (ARCHITECTURE.md, "Verso on the Mac"): five sizes, set with a pinch, with − and + in the toolbar, drawn as the photo
/// grids' pair, or ⌘− and ⌘+; one size for every such page, remembered. The smallest is the default. Albums are cards
/// at every size, as on the iPhone. A step skips a size that fits as many cards in a line as the one shown, at the
/// page's width (`CardLayout`), and − or + is off where no size is left that way.
enum CardSize {
    static let key = "cards.size"
    static let sizes = 0...4
}

extension CardLayout {
    /// The grid's columns at `size`: each card at least the size's width, widened to fill a line.
    func columns(_ size: Int) -> [GridItem] {
        let minimum = width(size)
        return [GridItem(.adaptive(minimum: minimum, maximum: minimum * 1.4), spacing: spacing)]
    }
}

/// The toolbar's − and + for a card page.
struct CardSizeToolbarItems: CustomizableToolbarContent {
    @Binding var size: Int
    let zoom: CardZoom

    var body: some CustomizableToolbarContent {
        // The first items on the right, in a box of their own, as a photo grid's zoom (DESIGN.md, "The toolbar's places").
        ToolbarItem(id: "cardsSmaller") {
            CardSizeButton(size: $size, zoom: zoom, step: -1)
        }
        ToolbarItem(id: "cardsLarger") {
            CardSizeButton(size: $size, zoom: zoom, step: 1)
        }
        if #available(macOS 26, *) { ToolbarSpacer(.fixed) }
    }
}

/// − or +: the next size that changes how many cards fit in a line, off where there is none.
private struct CardSizeButton: View {
    @Binding var size: Int
    let zoom: CardZoom
    let step: Int

    var body: some View {
        let next = zoom.size(from: size, step: step)
        Button {
            if let next { size = next }
        } label: {
            if step > 0 { Label("Zoom In", systemImage: "plus") } else { Label("Zoom Out", systemImage: "minus") }
        }
        .disabled(next == nil)
        .help(step > 0 ? "Larger" : "Smaller")
    }
}

/// A card page's size and its zoom, for ⌘+ and ⌘−.
@MainActor struct CardSizeControl {
    let size: Binding<Int>
    let zoom: CardZoom

    /// The size a step toward larger cards goes to, or nil where none changes what shows.
    var larger: Int? { zoom.size(from: size.wrappedValue, step: 1) }
    /// The size a step toward smaller cards goes to, or nil where none changes what shows.
    var smaller: Int? { zoom.size(from: size.wrappedValue, step: -1) }
}

extension View {
    /// The page's cards follow ⌘+ and ⌘−, as a photo grid's photos do; nil while it shows none.
    func cardSizeCommands(_ size: Binding<Int>?, zoom: CardZoom) -> some View {
        focusedSceneValue(\.cardSize, size.map { CardSizeControl(size: $0, zoom: zoom) })
    }

    /// The card page's scroll view zooms through the card sizes with a pinch and keeps its place as `size` changes.
    func cardZoom(_ size: Binding<Int>, _ zoom: CardZoom) -> some View {
        modifier(CardZoomModifier(size: size, zoom: zoom))
    }

    /// The card page's grid, laid out as `layout` says: it tells the page's zoom how wide its lines are, so a step goes
    /// to a size that changes what shows.
    func cardGrid(_ layout: CardLayout) -> some View {
        modifier(CardGridModifier(layout: layout))
    }

    /// A card of a page with `cardZoom`, by its identity in the page's grid, so a change of size keeps it in place.
    func cardZoomItem(_ id: some Hashable) -> some View {
        modifier(CardZoomItem(id: AnyHashable(id)))
    }
}

/// A card page's zoom, as the iPhone's card pages keep their place (ARCHITECTURE.md, "Verso on the Mac", "Cards and
/// tiles have five sizes"): a trackpad pinch goes through the sizes, a size each time the fingers have spread or closed
/// by a quarter more, and the page is laid out at the new size at once with the card under the fingers kept under them;
/// the toolbar's − and + and ⌘− and ⌘+ keep the card in the middle of the view in place. Nothing slides. Each step,
/// whichever way it comes, goes to a size that changes how many cards fit in a line. Each card page has its own.
@MainActor @Observable final class CardZoom {
    /// The page's grid and the width of its lines, as the grid reports them.
    fileprivate var layout: CardLayout?
    fileprivate var lineWidth: CGFloat = 0
    /// Where each card in view is, in the view, by its identity in the page's grid.
    @ObservationIgnored fileprivate var frames: [AnyHashable: CGRect] = [:]
    @ObservationIgnored fileprivate var viewport: CGSize = .zero
    /// Where the pinch that changed the size is; the middle of the view for any other change.
    @ObservationIgnored fileprivate var pinchPoint: CGPoint?
    /// The pinch's magnification at its last step.
    @ObservationIgnored fileprivate var pinchBase: CGFloat = 1
    /// How far the fingers spread or close for each size.
    fileprivate static let step: CGFloat = 1.25
    /// The page's scroll view, as the cards measure where they are in it.
    nonisolated fileprivate static let space = "cardPage"

    /// The size a step from `size` goes to, toward larger cards (`step` 1) or smaller (-1): the next that fits another
    /// number of cards in a line, or nil where none does. Before the grid has reported, the next size.
    func size(from size: Int, step: Int) -> Int? {
        if let layout { return layout.size(from: size, step: step, lineWidth: lineWidth) }
        let next = size + (step > 0 ? 1 : -1)
        return CardSize.sizes.contains(next) ? next : nil
    }

    /// The card at `point` in the view, or the one nearest it, and the point's height in the view, where the card is
    /// scrolled to at the new size: so the card stays where the point is.
    fileprivate func anchor(at point: CGPoint) -> (id: AnyHashable, unit: UnitPoint)? {
        guard viewport.height > 0,
              let nearest = frames.min(by: { Self.distance($0.value, point) < Self.distance($1.value, point) }) else {
            return nil
        }
        return (nearest.key, UnitPoint(x: 0.5, y: min(1, max(0, point.y / viewport.height))))
    }

    private static func distance(_ frame: CGRect, _ point: CGPoint) -> CGFloat {
        let across = max(frame.minX - point.x, 0, point.x - frame.maxX)
        let down = max(frame.minY - point.y, 0, point.y - frame.maxY)
        return across * across + down * down
    }
}

extension EnvironmentValues {
    /// The card page's zoom, which its grid tells how wide it is and its cards where they are.
    @Entry var cardZoom: CardZoom? = nil
}

private struct CardZoomModifier: ViewModifier {
    @Binding var size: Int
    let zoom: CardZoom

    func body(content: Content) -> some View {
        ScrollViewReader { proxy in
            content
                .coordinateSpace(.named(CardZoom.space))
                .environment(\.cardZoom, zoom)
                .onGeometryChange(for: CGSize.self) { geometry in geometry.size } action: { viewport in
                    zoom.viewport = viewport
                }
                .simultaneousGesture(pinch)
                .onChange(of: size) { keepPlace(proxy) }
        }
    }

    private var pinch: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let ratio = value.magnification / zoom.pinchBase
                guard ratio > CardZoom.step || ratio < 1 / CardZoom.step else { return }
                zoom.pinchBase = value.magnification
                guard let next = zoom.size(from: size, step: ratio > 1 ? 1 : -1) else { return }
                zoom.pinchPoint = value.startLocation
                size = next
            }
            .onEnded { _ in zoom.pinchBase = 1 }
    }

    /// The card under the pinch, or in the middle of the view, where it was in the view, at the new size: found among
    /// the cards as they were laid out before the change.
    private func keepPlace(_ proxy: ScrollViewProxy) {
        let point = zoom.pinchPoint ?? CGPoint(x: zoom.viewport.width / 2, y: zoom.viewport.height / 2)
        zoom.pinchPoint = nil
        guard let anchor = zoom.anchor(at: point) else { return }
        proxy.scrollTo(anchor.id, anchor: anchor.unit)
        // Again once the cards are laid out at the new size, where the lazy grid's first guess of their places was off.
        Task { @MainActor in proxy.scrollTo(anchor.id, anchor: anchor.unit) }
    }
}

private struct CardGridModifier: ViewModifier {
    let layout: CardLayout
    @Environment(\.cardZoom) private var zoom

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGFloat.self) { geometry in geometry.size.width } action: { width in
                zoom?.lineWidth = width
            }
            .onChange(of: layout, initial: true) { _, layout in zoom?.layout = layout }
    }
}

private struct CardZoomItem: ViewModifier {
    let id: AnyHashable
    @Environment(\.cardZoom) private var zoom

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { geometry in
                geometry.frame(in: .named(CardZoom.space))
            } action: { frame in
                zoom?.frames[id] = frame
            }
            .onDisappear { zoom?.frames[id] = nil }
    }
}
