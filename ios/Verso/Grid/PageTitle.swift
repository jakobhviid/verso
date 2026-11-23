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
// row is found from where the bars end and where the navigation bar starts (NavigationBarRow), so the title rises into
// it on any device and in either orientation: under the status bar on an iPhone, and on an iPad under the tab bar at
// the top where iPadOS gives the navigation bar a row of its own, beside the page's buttons, rather than into the tab
// bar's row with its line left a row below. Where the tab bar shares the bar's row and leaves the title too little room
// beside it (an iPad mini in portrait), the title stands under the row instead, as on a pushed page; in a window
// resized on an iPad it keeps clear of the window's controls (WindowControls). Before the bar is found, the window's
// top safe area stands for it (LibraryChrome.windowTopInset).

import SwiftUI
import UIKit

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
    /// Where the navigation bar's row starts in the window, and where the tab bar starts where it shares that row.
    @State private var barRow: NavigationBarRow.Found?
    /// The title's own width, for whether it fits beside the tab bar.
    @State private var titleWidth: CGFloat = 0

    /// The room the page's buttons take at the trailing end of the bar's row.
    private let buttonsRoom: CGFloat = 150

    func body(content: Content) -> some View {
        let windowTop = barRow?.top ?? chrome?.windowTopInset
        // Clear of a resized iPad window's controls at its top leading corner (WindowControls).
        let leading = max(16, (chrome?.windowControlsInset ?? 0) + 8)
        let crowded = barRow?.tabBarLeading.map { leading + titleWidth + 12 > $0 } ?? false
        let lift = isPushed || crowded ? 0 : max(0, (barBottom ?? 0) - (windowTop ?? 0))
        let placed = isPushed || (barBottom != nil && windowTop != nil)
        content
            .scrollEdgeEffectStyle(.soft, for: .top)
            .toolbarTitleDisplayMode(.inline)
            .toolbar(removing: systemTitle ? nil : .title)
            .safeAreaBar(edge: .top, alignment: .leading) {
                // The line starts below the bar, never under it, where the bar would take a tap on it (an import's
                // or a backup's line opens its page).
                block(lineDrop: line == nil && lineView == nil ? 0 : max(0, lift - titleHeight))
                    .padding(.leading, isPushed ? 16 : leading)
                    .padding(.trailing, isPushed ? 16 : buttonsRoom)
                    .padding(.top, isPushed ? 4 : 0)
                    .padding(.bottom, 8)
                    .padding(.top, -lift)
                    .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { barBottom = $0 }
                    .background {
                        if !isPushed { NavigationBarRow(barBottom: barBottom) { barRow = $0 } }
                    }
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
                .background {
                    Text(title)
                        .font(.largeTitle.bold())
                        .fixedSize()
                        .hidden()
                        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { titleWidth = $0 }
                }
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

/// Where the navigation bar's row starts in the window, from UIKit's own bar, told again as the bars move: under the
/// status bar on an iPhone; on an iPad under the tab bar at the top, or beside it where iPadOS puts the bar's buttons
/// in the tab bar's row, with where the tab bar starts then.
struct NavigationBarRow: UIViewRepresentable {
    struct Found: Equatable {
        let top: CGFloat
        /// The tab bar's leading edge in the window, where it shares the navigation bar's row.
        let tabBarLeading: CGFloat?
    }

    /// Where the bars end, which changes as they move, so the row is looked for again.
    let barBottom: CGFloat?
    let found: (Found) -> Void

    func makeUIView(context: Context) -> Probe {
        let probe = Probe()
        probe.isUserInteractionEnabled = false
        probe.found = found
        return probe
    }

    func updateUIView(_ probe: Probe, context: Context) {
        probe.found = found
        probe.setNeedsLayout()
    }

    final class Probe: UIView {
        var found: ((Found) -> Void)?
        private var told: Found?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            look()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            look()
        }

        private func look() {
            guard let window else { return }
            var responder: UIResponder? = self
            while let next = responder?.next {
                if let controller = next as? UIViewController, let navigation = controller.navigationController {
                    let bar = navigation.navigationBar
                    guard !bar.isHidden, bar.bounds.height > 0 else { return }
                    let row = bar.convert(bar.bounds, to: window)
                    let tabBar = Self.tabBar(of: controller, in: window)
                    // The tab bar shares the row where their middles are within a row of each other.
                    let sharing = tabBar.map { abs($0.midY - row.midY) < row.height / 2 } ?? false
                    let found = Found(top: row.minY, tabBarLeading: sharing ? tabBar?.minX : nil)
                    guard found != told else { return }
                    told = found
                    // Not inside the layout pass it was found in.
                    Task { @MainActor [weak self] in self?.found?(found) }
                    return
                }
                responder = next
            }
        }

        /// The tab bar's frame in the window: the tab bar controller's own, or the view iPadOS draws at the top that
        /// says it is a tab bar, looked for near the top of the window alone.
        private static func tabBar(of controller: UIViewController, in window: UIWindow) -> CGRect? {
            guard let tabs = controller.tabBarController else { return nil }
            let own = tabs.tabBar
            if !own.isHidden, own.window != nil, own.bounds.width > 0, own.alpha > 0 {
                let frame = own.convert(own.bounds, to: window)
                if frame.minY < 200 { return frame }
            }
            var queue: [UIView] = [tabs.view]
            var looked = 0
            while !queue.isEmpty, looked < 400 {
                let view = queue.removeFirst()
                looked += 1
                let frame = view.convert(view.bounds, to: window)
                guard frame.minY < 200, !view.isHidden else { continue }
                if view !== tabs.view, view.accessibilityTraits.contains(.tabBar), frame.width > 0, frame.height < 120 {
                    return frame
                }
                queue += view.subviews
            }
            return nil
        }
    }
}
