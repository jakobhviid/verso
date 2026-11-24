// A photo page's View Options on iOS, as Photos' filter button has them (ROADMAP.md, M10): one glass menu in the top
// toolbar, the horizontal lines tinted while a filter is on. At the top the sort, Added or Captured, as two large
// buttons side by side; then "Filter:" with what the page can show; Order where the page reads down from the top; and
// a View Options submenu with the aspect ratio grid, the date scroller, and on a timeline Newest at the Bottom or at
// the Top (GridNewestEnd).
//
// What a page offers is the Mac's (GridPage, GridArrangement, mac/Verso/Verso/Views/Grid/GridViewOptions.swift): the
// settings are kept per page under the Mac's keys, and the grid model reads them on every reload, so a change reloads
// the page's grid (GridOptionsReloader). A page with no GridPage (an album, a search, a link) has the View Options
// submenu alone. A page that opens at its newest photos, as Photos' library, offers no Order: its newest are at the
// end Newest at the Bottom or at the Top puts them, whichever order the Mac keeps for it. The Library's own menu is
// LibraryOptionsMenu, from these pieces.

import SwiftUI

/// The settings key of a page's view option, or one no page uses for a page without view options.
private func gridOptionKey(_ page: GridPage?, _ setting: String) -> String {
    page?.key(setting) ?? "grid.none.\(setting)"
}

struct GridOptionsMenu: View {
    let page: GridPage?
    /// The page reads down from the top, where the order decides what comes first.
    let readsDown: Bool
    /// The grid's photos are a timeline's, by month, which the date scroller goes through.
    let offersDateScroller: Bool
    /// The page opens at its newest photos, at the end GridNewestEnd chooses.
    let offersNewestEnd: Bool
    @AppStorage private var show: GridShow
    @AppStorage private var mediaType: GridMediaType
    @AppStorage private var sortBy: GridSortBy
    @AppStorage private var order: GridOrder
    @AppStorage private var location: GridLocation

    init(page: GridPage?, readsDown: Bool, offersDateScroller: Bool, offersNewestEnd: Bool) {
        self.page = page
        self.readsDown = readsDown
        self.offersDateScroller = offersDateScroller
        self.offersNewestEnd = offersNewestEnd
        _show = AppStorage(wrappedValue: .all, gridOptionKey(page, "show"))
        _mediaType = AppStorage(wrappedValue: .all, gridOptionKey(page, "mediaType"))
        _sortBy = AppStorage(wrappedValue: .dateTaken, gridOptionKey(page, "sortBy"))
        _order = AppStorage(wrappedValue: .newestFirst, gridOptionKey(page, "order"))
        _location = AppStorage(wrappedValue: page?.defaultLocation ?? .all, gridOptionKey(page, "location"))
    }

    var body: some View {
        Menu {
            if let page {
                if page.offersSortBy {
                    // Photos or videos alone come from search, which cannot order by the date added.
                    GridSortControl(sortBy: $sortBy, dateAddedAvailable: !page.offersMediaTypeFilter || mediaType == .all)
                }
                filters(page)
                if readsDown && page.offersOrder {
                    Section {
                        Picker("Order", selection: $order) {
                            ForEach(GridOrder.allCases) { option in
                                Text(option.title).tag(option)
                            }
                        }
                        .pickerStyle(.inline)
                    }
                }
            }
            GridViewOptionsSubmenu(offersDateScroller: offersDateScroller, offersNewestEnd: offersNewestEnd)
        } label: {
            GridOptionsLabel()
        }
        .gridOptionsTint(isFiltered)
    }

    /// One filter at a time, as Photos' Library has them: everything, the favourites, or one kind of photo.
    @ViewBuilder
    private func filters(_ page: GridPage) -> some View {
        if page.offersLocationFilter {
            Section("Filter:") {
                Picker("Location", selection: $location) {
                    ForEach(GridLocation.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.inline)
            }
        }
        if page.offersFavoritesFilter || page.offersMediaTypeFilter {
            Section("Filter:") {
                GridFilterToggle(title: "All Items", systemImage: "square.grid.3x3",
                                 isOn: show == .all && mediaType == .all) { choose(show: .all, mediaType: .all) }
                if page.offersFavoritesFilter {
                    GridFilterToggle(title: "Favorites", systemImage: "heart",
                                     isOn: show == .favorites) { choose(show: .favorites, mediaType: .all) }
                }
                if page.offersMediaTypeFilter {
                    Menu("Media Types", systemImage: "photo.on.rectangle.angled") {
                        GridFilterToggle(title: "Photos", systemImage: "photo",
                                         isOn: mediaType == .photos) { choose(show: .all, mediaType: .photos) }
                        GridFilterToggle(title: "Videos", systemImage: "video",
                                         isOn: mediaType == .videos) { choose(show: .all, mediaType: .videos) }
                    }
                }
            }
        }
    }

    private func choose(show newShow: GridShow, mediaType newType: GridMediaType) {
        show = newShow
        mediaType = newType
    }

    private var isFiltered: Bool {
        guard let page else { return false }
        return (page.offersFavoritesFilter && show != .all) || (page.offersMediaTypeFilter && mediaType != .all)
            || (page.offersLocationFilter && location != .all)
    }
}

/// The sort at the top of View Options, as Photos has it: Added and Captured, two large buttons side by side, the one
/// in use selected.
struct GridSortControl: View {
    @Binding var sortBy: GridSortBy
    /// Date Added can order these photos (it cannot photos or videos alone, which come from search).
    let dateAddedAvailable: Bool

    var body: some View {
        ControlGroup {
            Toggle(isOn: chosen(.dateAdded)) {
                Label("Added", systemImage: "clock")
            }
            .disabled(!dateAddedAvailable)
            .accessibilityLabel("Sort by Date Added")
            Toggle(isOn: chosen(.dateTaken)) {
                Label("Captured", systemImage: "camera")
            }
            .accessibilityLabel("Sort by Date Captured")
        }
    }

    private func chosen(_ option: GridSortBy) -> Binding<Bool> {
        Binding(get: { (dateAddedAvailable ? sortBy : .dateTaken) == option },
                set: { on in if on { sortBy = option } })
    }
}

/// A filter in View Options: a check mark while it is the one shown, choosing it on a tap.
struct GridFilterToggle: View {
    let title: String
    let systemImage: String
    let isOn: Bool
    let choose: () -> Void

    var body: some View {
        Toggle(isOn: Binding(get: { isOn }, set: { on in if on { choose() } })) {
            Label(title, systemImage: systemImage)
        }
    }
}

/// View Options' own submenu: square tiles or the whole photo in each, the date scroller where the grid has months,
/// and on a page that opens at its newest photos the end they are at.
struct GridViewOptionsSubmenu: View {
    let offersDateScroller: Bool
    let offersNewestEnd: Bool
    @AppStorage(GridTile.aspectRatioKey) private var fitsWhole = false
    @AppStorage(DateScroller.shownKey) private var showsDateScroller = true

    var body: some View {
        Section {
            Menu("View Options") {
                Toggle("Aspect Ratio Grid", systemImage: "aspectratio", isOn: $fitsWhole)
                if offersDateScroller {
                    Toggle("Date Scroller", systemImage: "calendar", isOn: $showsDateScroller)
                }
                if offersNewestEnd {
                    GridNewestEndPicker()
                }
            }
        }
    }
}

/// The View Options button's face: Photos' horizontal lines.
struct GridOptionsLabel: View {
    var body: some View {
        Label("View Options", systemImage: "line.3.horizontal.decrease")
    }
}

extension View {
    /// The View Options button in the accent colour while a filter is on, as Photos tints its filter button. A toolbar's
    /// menu keeps its own glass under `.glassProminent`, so the prominent bordered style tints it.
    @ViewBuilder
    func gridOptionsTint(_ filtered: Bool) -> some View {
        if filtered {
            buttonStyle(.borderedProminent)
                .tint(.accentColor)
                .accessibilityValue("Filtered")
        } else {
            self
        }
    }
}

/// Reloads a page's grid when its view options change, from its own menu or any other page of the same kind, as the
/// Mac's GridViewOptionsReloader does. The model reads the options again only when they differ from those it read last.
struct GridOptionsReloader: ViewModifier {
    let model: AssetGridModel
    @AppStorage private var show: GridShow
    @AppStorage private var mediaType: GridMediaType
    @AppStorage private var sortBy: GridSortBy
    @AppStorage private var order: GridOrder
    @AppStorage private var location: GridLocation
    @AppStorage private var owner: GridOwner

    init(model: AssetGridModel) {
        self.model = model
        let page = model.source.gridPage
        _show = AppStorage(wrappedValue: .all, gridOptionKey(page, "show"))
        _mediaType = AppStorage(wrappedValue: .all, gridOptionKey(page, "mediaType"))
        _sortBy = AppStorage(wrappedValue: .dateTaken, gridOptionKey(page, "sortBy"))
        _order = AppStorage(wrappedValue: .newestFirst, gridOptionKey(page, "order"))
        _location = AppStorage(wrappedValue: page?.defaultLocation ?? .all, gridOptionKey(page, "location"))
        _owner = AppStorage(wrappedValue: .anyone, gridOptionKey(page, "owner"))
    }

    func body(content: Content) -> some View {
        content.onChange(of: GridArrangement(show: show, mediaType: mediaType, sortBy: sortBy, order: order, location: location,
                                             owner: owner)) {
            guard model.source.gridPage != nil else { return }
            Task { await model.loadIfNeeded() }
        }
    }
}
