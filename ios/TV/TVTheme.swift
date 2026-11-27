import SwiftUI

// What every page of the TV shares, drawn as the iPhone draws it (ios/Verso/Grid/PageTitle.swift, Cards/CardCollection.swift,
// Grid/GridTile.swift) at a sofa's distance: the iPhone's proportions, its type a step larger, and focus in place of a
// finger, a quiet lift and a soft shadow rather than tvOS's platter.

enum TVMetrics {
    /// What a page lays out in before it has measured its own: tvOS's 1920 points less its safe area on both sides.
    static let pageWidth: CGFloat = 1760
    /// Photos to a row: the iPhone's five at its default, a little more room on the sofa's wide screen.
    static let tileColumns = 6
    /// Between tiles, as thin as the iPhone's two points are on a phone.
    static let tileSpacing: CGFloat = 8
    /// Between cards, across and down: the iPhone's 12 to 14 points, scaled.
    static let cardSpacing: CGFloat = 32
    /// A card's corner: the iPhone's 12 on a card about 180 wide, on one about 420.
    static let cardRadius: CGFloat = 24
    /// Cards to a row: the iPhone's two albums, three faces and three cities, one row's worth on a wide screen.
    static let albumColumns = 4
    static let personColumns = 6
    static let cityColumns = 4
    static let memoryColumns = 3
    /// Years and Months: the iPhone's cards of 300 and 340 points at the least.
    static let yearColumns = 4
    static let monthColumns = 3
}

/// A page's title and the line under it, large and bold at the leading edge, as the iPhone's pages have them.
struct TVPageTitle<Accessory: View>: View {
    let title: String
    var line: String?
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(alignment: .top, spacing: 40) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.largeTitle.bold())
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                // A line's room is kept while there is nothing to say yet (empty), so the photos do not move; a card
                // page has none (nil).
                if let line {
                    Text(line.isEmpty ? " " : line)
                        .font(.headline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            accessory
        }
    }
}

extension TVPageTitle where Accessory == EmptyView {
    init(_ title: String, line: String? = nil) {
        self.init(title: title, line: line) { EmptyView() }
    }
}

/// A button that lifts a little when the remote's focus is on it: larger, with a soft shadow beneath, and pressed in a
/// little while it is clicked. The card platter of tvOS's `.card` style, with its wide padding, is what this leaves out.
struct TVLiftStyle: ButtonStyle {
    var scale: CGFloat = 1.06
    var cornerRadius: CGFloat = 0

    func makeBody(configuration: Configuration) -> some View {
        Lifted(label: configuration.label, isPressed: configuration.isPressed, scale: scale, cornerRadius: cornerRadius)
    }

    private struct Lifted<Label: View>: View {
        let label: Label
        let isPressed: Bool
        let scale: CGFloat
        let cornerRadius: CGFloat
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            label
                .clipShape(.rect(cornerRadius: isFocused ? max(cornerRadius, 6) : cornerRadius, style: .continuous))
                .scaleEffect(isPressed ? scale - 0.02 : isFocused ? scale : 1)
                .shadow(color: .black.opacity(isFocused ? 0.5 : 0), radius: isFocused ? 24 : 0, y: isFocused ? 14 : 0)
                .animation(.easeOut(duration: 0.18), value: isFocused)
                .animation(.easeOut(duration: 0.12), value: isPressed)
        }
    }
}

/// The Siri Remote's keys on a full-screen view: left and right, a click, play/pause and Menu. A modifier of its own so a
/// view's chain of them stays short enough for the compiler.
struct TVRemote: ViewModifier {
    var left: () -> Void = {}
    var right: () -> Void = {}
    var select: () -> Void = {}
    var playPause: () -> Void = {}
    var menu: () -> Void = {}
    /// Off while something inside has the remote of its own, as a video's player has.
    var takesFocus = true

    func body(content: Content) -> some View {
        content
            .focusable(takesFocus)
            .onMoveCommand { direction in
                switch direction {
                case .left: left()
                case .right: right()
                default: break
                }
            }
            .onTapGesture(perform: select)
            .onPlayPauseCommand(perform: playPause)
            .onExitCommand(perform: menu)
    }
}

extension View {
    /// Focus lifts this, as `TVLiftStyle` does, in place of tvOS's own focus effect.
    func tvLifts() -> some View { focusEffectDisabled() }
}

/// What a page says where it has nothing to show, or could not: the iPhone's empty states, a retry the remote can click.
struct TVNotice: View {
    let title: LocalizedStringKey
    let systemImage: String
    var message: String?
    var retry: (() -> Void)?

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            if let message { Text(message) }
        } actions: {
            if let retry { Button("Try Again", action: retry) }
        }
        .frame(maxWidth: .infinity, minHeight: 500)
    }
}

/// A heading above a row of cards, as the iPhone's sections have: the title, and how many it holds in grey.
struct TVSectionHeader: View {
    let title: String
    var count: Int?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title).font(.title3.weight(.semibold))
            if let count { Text(count.formatted()).font(.callout).foregroundStyle(.secondary) }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// The width of what a page lays out, read once it is on screen, for the tiles' and cards' sizes.
struct TVWidth: ViewModifier {
    @Binding var width: CGFloat

    func body(content: Content) -> some View {
        content.onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }
}

/// Cards laid out in rows of `columns` over a width: a lazy grid sized from what the page measured, so a card's picture
/// is as wide as its column.
func tvColumns(_ count: Int, spacing: CGFloat = TVMetrics.cardSpacing) -> [GridItem] {
    Array(repeating: GridItem(.flexible(), spacing: spacing, alignment: .top), count: count)
}
