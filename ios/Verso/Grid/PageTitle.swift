// A page's title on iOS, as Photos has it (ROADMAP.md, M10): large and bold, on a photo page with one line under it,
// which stay put while the photos or cards scroll on under them with the soft scroll edge effect, never shrinking to a
// small title. The soft edge is asked for here, for every page's scroll view: without it, iOS cut the card pages'
// cards in a hard line under the title. On a tab's own page they stand in the bar's own row, leading, beside the page's buttons; on a page
// pushed onto the tab, under the back button's row, as iOS sets a large title below a back button. A card page
// (Albums, People, Memories) has the title alone (`cardPageTitle`).
//
// They are the page's own view in a bar over the content (`safeAreaBar`), not the system's large title, which shrinks
// to a small one once the content is scrolled from its top, and a timeline opens scrolled to its bottom. The navigation
// title stays set, for VoiceOver, the back button's menu and the app switcher, and while selecting the bar shows it
// inline ("3 Photos Selected") in place of the page's own, which keeps its room so the photos do not move. The bar's
// row is found from where the bar ends and where the window's top safe area ends (LibraryChrome.windowTopInset), so the
// title rises into it on any device and in either orientation.

import SwiftUI

extension View {
    /// The page's title and its line, as Photos shows them; `lineView` in place of the line (an import's progress), no
    /// line at all for nil, and the system's inline title instead while `systemTitle` (selecting).
    func pageTitle(_ title: String, line: String?, lineView: AnyView? = nil, systemTitle: Bool = false) -> some View {
        modifier(PageTitle(title: title, line: line, lineView: lineView, systemTitle: systemTitle))
    }

    /// A card page's title: the photo pages' title without a line, and the page's navigation title.
    func cardPageTitle(_ title: String) -> some View {
        navigationTitle(title)
            .pageTitle(title, line: nil)
    }
}

private struct PageTitle: ViewModifier {
    let title: String
    let line: String?
    let lineView: AnyView?
    let systemTitle: Bool
    @Environment(\.isPresented) private var isPushed
    @Environment(LibraryChrome.self) private var chrome: LibraryChrome?
    /// Where the bars over the content end, in the window: the title rises from there into the bar's row.
    @State private var barBottom: CGFloat?
    /// The title's height, so the line under it starts where the bar ends.
    @State private var titleHeight: CGFloat = 0

    /// The room the page's buttons take at the trailing end of the bar's row.
    private let buttonsRoom: CGFloat = 150

    func body(content: Content) -> some View {
        let windowTop = chrome?.windowTopInset
        let lift = isPushed ? 0 : max(0, (barBottom ?? 0) - (windowTop ?? 0))
        let placed = isPushed || (barBottom != nil && windowTop != nil)
        content
            .scrollEdgeEffectStyle(.soft, for: .top)
            .toolbarTitleDisplayMode(.inline)
            .toolbar(removing: systemTitle ? nil : .title)
            .safeAreaBar(edge: .top, alignment: .leading) {
                // The line starts below the bar, never under it, where the bar would take a tap on it (an import's
                // or a backup's line opens its page).
                block(lineDrop: line == nil && lineView == nil ? 0 : max(0, lift - titleHeight))
                    .padding(.leading, 16)
                    .padding(.trailing, isPushed ? 16 : buttonsRoom)
                    .padding(.top, isPushed ? 4 : 0)
                    .padding(.bottom, 8)
                    .padding(.top, -lift)
                    .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { barBottom = $0 }
                    // Seen once it stands in its place, and gone while the system's title says the selection.
                    .opacity(placed && !systemTitle ? 1 : 0)
                    .allowsHitTesting(!systemTitle)
                    .accessibilityHidden(systemTitle)
            }
    }

    private func block(lineDrop: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.largeTitle.bold())
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { titleHeight = $0 }
            Group {
                if let lineView {
                    lineView
                } else if let line {
                    // A line's room is kept while there is nothing to say, so the photos do not move.
                    Text(line.isEmpty ? " " : line)
                        .font(.headline)
                        .lineLimit(1)
                        .accessibilityHidden(line.isEmpty)
                }
            }
            .padding(.top, lineDrop)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
