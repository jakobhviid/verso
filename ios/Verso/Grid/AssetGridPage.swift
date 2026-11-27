// A page of photos from any of the library's sources (GridSource): the Library, an album, a person, a search, the
// favorites. The grid with the header the page gives it, View Options and Select in the top toolbar as two glass items,
// the selection's toolbar, the long press's menu, and the viewer that opens out of a tile, shown in place over the
// tabs (ViewerHost).
// Every area of the app shows its photos with it, inside its tab's NavigationStack (LibraryTabs), as a route's page or
// a tab's own.
//
// The title is Photos': large and bold with one line under it, in the bar's own row on a tab's own page and under the
// back button on a page pushed onto it, staying put as the photos scroll on under it (PageTitle). The line says where
// the grid is: the days of the photos in view while it scrolls, and the number of items at the end where a timeline
// opens, its newest photos; or the page's own words in its place.
//
// A timeline (a page without a header whose photos are the library's by date, `opensAtNewest`) has its newest photos
// at the end GridNewestEnd chooses, the bottom by default, and opens there; an album keeps its own order. Changing it
// makes the grid anew, at its newest photos, and the viewer pages in the grid's order.
//
// Selecting is Photos': Select in the toolbar, or a finger held on a photo and dragged (TimelineGrid), the count in the
// title, the tab bar giving way to the selection's actions along the bottom, and Cancel to end it. A long press on a
// photo and the selection's "..." hold the one menu of photo actions (PhotoActionsMenu, GridActions).
//
// The Library's own timeline (All Items, `showsPhoneTiles`) also shows the photos that came to the phone after backing
// up was switched on and are not in Immich yet (BackupCenter.libraryTiles), at its newest end among Immich's photos,
// from the phone and with their marks; a tap opens one from the phone (PhoneViewer). They are a layer of iOS's own over
// the grid's model, which stays Immich's and the Mac's. When one's upload lands, the grid reads again as an import
// makes it, and Immich's photo takes the tile's place once the model has it.

import SwiftUI

struct AssetGridPage: View {
    let session: LibrarySession
    let source: GridSource
    let title: String
    /// Shown above the photos, such as an album's header.
    var header: AnyView? = nil
    /// Said under the title in place of where the grid is; empty for nothing.
    var subtitle: String? = nil
    /// Shown under the title in place of the line, such as an import's progress.
    var titleLine: AnyView? = nil
    /// Said after the number of items at the newest end, where the line says it: the Library's backup, "· Backed Up".
    var countAccessory: AnyView? = nil
    /// The Library tab's own page, whatever its filter shows: it reads as the Library does, opening at its newest
    /// photos, also where its filter's photos come from a search.
    var isLibrary = false
    /// The tab whose own page this is, other than the Library's (the Archive in the tab bar): a tap on the tab while it
    /// shows takes the grid to its newest photos.
    var landsOnTab: LibraryTab? = nil
    /// The page's View Options in place of those its source offers (the Library's).
    var viewOptions: AnyView? = nil
    /// The grid's model in place of the window's for the source (a search of the Library's own beside Search's).
    var model: AssetGridModel? = nil
    /// Told when the grid comes to the end it opens at or leaves it.
    var onOpeningEnd: ((Bool) -> Void)? = nil
    /// Told when the person scrolls away from the end the grid opens at, which shrinks the tab bar.
    var onScrolledAway: (() -> Void)? = nil
    /// The photos on their way from the phone show among Immich's: the Library's own timeline, All Items.
    var showsPhoneTiles = false
    @AppStorage(GridNewestEnd.storageKey) private var newestEnd = GridNewestEnd.bottom
    @State private var state = GridPageState()
    /// This page, among the window's pages selecting and those that open at their bottom (LibraryChrome).
    @State private var pageID = UUID()
    @Environment(LibraryChrome.self) private var chrome: LibraryChrome?
    @Environment(\.accountInTopBar) private var accountInTopBar
    @Environment(\.pushRoute) private var pushRoute
    /// Where the viewer shows: over the tabs, or over a viewer whose details opened this page.
    @Environment(ViewerHost.self) private var viewerHost: ViewerHost?
    /// Where the phone's own tiles zoom from as they open their viewer (TimelineGrid's `phoneZoom`).
    @Namespace private var phoneZoom

    var body: some View {
        let model = model ?? session.gridModel(for: source)
        let actions = GridActions(model: model, session: session, state: state, chrome: chrome)
        let opensAtNewest = opensAtNewest(model)
        let newestAtTop = opensAtNewest && followsNewestEnd(model) && newestEnd == .top
        let opensAtBottom = opensAtNewest && !newestAtTop
        // The model's months come newest first, or oldest first where the Mac's Order says so.
        let modelOldestFirst = model.arrangement?.order == .oldestFirst
        let reversed = opensAtNewest && (newestAtTop ? modelOldestFirst : !modelOldestFirst)
        let phone = phoneTiles(model)
        lifecycle(dialogs(
        TimelineGrid(model: model, pipeline: session.pipeline, actions: actions, header: header, reversed: reversed,
                     opensAtBottom: opensAtBottom,
                     landingRequests: landingTab.map { chrome?.landings[$0] ?? 0 } ?? 0,
                     phone: phone, phoneByDate: model.arrangement?.sortsByDateAdded != true,
                     standIns: showsPhoneTiles ? standIns : [:], phoneZoom: phoneZoom)
            // A grid of its own for each end, which opens at its newest photos.
            .id(newestAtTop)
            .navigationTitle(state.isSelecting ? actions.selectionTitle : title)
            .pageTitle(title, line: pageSubtitle(model, opensAtNewest: opensAtNewest),
                       lineView: titleLine ?? countLine(model, opensAtNewest: opensAtNewest),
                       systemTitle: state.isSelecting)
            .toolbar { toolbar(actions, opensAtNewest: opensAtNewest, phone: phone) }
            // The selection's actions take the bottom of the window, where the tab bar was, as in Photos.
            .toolbarVisibility(state.isSelecting ? .hidden : .automatic, for: .tabBar)
            // A tile tapped opens the viewer in place. Closing flies back into the tile of the photo shown last (the
            // viewer keeps it in `model.viewerID`), which the grid keeps in view.
            .modifier(GridViewerOpening(host: viewerHost, state: state, session: session, model: model,
                                        readsBackwards: reversed, pushRoute: pushRoute))
            // The phone's own tiles open their viewer with SwiftUI's zoom.
            .phoneViewer(session: session, state: state, photos: phone.map(\.photo), readsUp: opensAtBottom,
                         zoomNamespace: phoneZoom),
            actions: actions, model: model), actions: actions, model: model, opensAtBottom: opensAtBottom)
    }

    // The body's modifiers in parts, each type-checked on its own: Xcode 26 could not type-check them as one
    // chain.

    /// The sheets and the questions of the grid's actions.
    private func dialogs(_ content: some View, actions: GridActions, model: AssetGridModel) -> some View {
        content
        .shareSheet(item: $state.sharing) { request in
            actions.rules.shareContent(request.ids)
        } onClose: {
            actions.endSelecting()
        }
        .confirmationDialog(actions.deleteTitle(state.pendingDelete?.ids.count ?? 0), isPresented: deleteAsked,
                            titleVisibility: .visible, presenting: state.pendingDelete) { request in
            Button(actions.deletesPermanently ? "Delete Permanently" : "Delete", role: .destructive) {
                actions.delete(request.ids)
            }
        } message: { request in
            Text(actions.deleteMessage(request.ids))
        }
        .confirmationDialog(actions.removalTitle ?? "", isPresented: removalAsked, titleVisibility: .hidden,
                            presenting: state.pendingRemoval) { request in
            Button(actions.removalTitle ?? "Remove", role: .destructive) { actions.remove(request.ids) }
        } message: { _ in
            Text("The photos remain in your library.")
        }
        .alert("Something Went Wrong", isPresented: errorShown(model)) {
            Button("OK") { model.lastError = nil }
        } message: {
            Text(model.lastError ?? "")
        }
    }

    /// What the grid follows while it is shown: the selection, its ends, the window's chrome, reading again.
    private func lifecycle(_ content: some View, actions: GridActions, model: AssetGridModel, opensAtBottom: Bool) -> some View {
        reloading(content, actions: actions, model: model)
        .onChange(of: state.isSelecting) { _, selecting in
            chrome?.setSelecting(pageID, selecting)
        }
        .onChange(of: state.atOpeningEnd) { _, atEnd in onOpeningEnd?(atEnd) }
        .onChange(of: state.awayScrolls) { onScrolledAway?() }
        .onChange(of: opensAtBottom) { _, atBottom in chrome?.setOpensAtBottom(pageID, atBottom) }
        // A page pushed over this one, or another tab, has the bottom of the window while this one is away.
        .onAppear {
            chrome?.setSelecting(pageID, state.isSelecting)
            chrome?.setOpensAtBottom(pageID, opensAtBottom)
            onOpeningEnd?(state.atOpeningEnd)
        }
        .onDisappear {
            chrome?.setSelecting(pageID, false)
            chrome?.setOpensAtBottom(pageID, false)
        }
    }

    /// The grid reading itself again, a selection taken by an album sheet, and the actions' sheets and notices.
    private func reloading(_ content: some View, actions: GridActions, model: AssetGridModel) -> some View {
        content
        // An album sheet of the window's took the selection (Add to Album).
        .onChange(of: chrome?.finishedSelection) { _, finished in
            if finished?.grid == ObjectIdentifier(model) { actions.endSelecting() }
        }
        // As on the Mac: the grid reads itself again once something marked it stale or its view options changed,
        // and shows what an import brought, reading again only the months that changed.
        .modifier(GridOptionsReloader(model: model))
        .task(id: session.macGridRevision) { await model.loadIfNeeded() }
        .onChange(of: session.upload.revision) { Task { await model.reload(keepingUnchanged: true) } }
        // A photo on its way arrived: the grid reads again, as an import makes it, and Immich's photo takes its
        // tile's place.
        .onChange(of: BackupCenter.shared.arrivals) {
            if showsPhoneTiles { Task { await model.reload(keepingUnchanged: true) } }
        }
        .overlay(alignment: .bottom) { noticeView }
        // A function of its own: Xcode 26 could not type-check this chain with the closure written in it.
        .task(id: state.notice) { await clearNoticeLater() }
        // The sheets of the menu's actions (Add To, the editors), and the preferences the menu reads.
        .modifier(PhotoActionsPresentation(session: session, actions: actions))
    }

    /// A notice that does not hold goes after three seconds.
    private func clearNoticeLater() async {
        guard state.notice != nil, !state.noticeHolds else { return }
        try? await Task.sleep(for: .seconds(3))
        guard !Task.isCancelled else { return }
        state.clearNotice()
    }

    /// A word at the grid's foot, such as the photos on their way an action left out, for a few seconds.
    @ViewBuilder
    private var noticeView: some View {
        if let notice = state.notice {
            Text(notice)
                .font(.footnote.weight(.medium))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .glassEffect(.regular, in: .capsule)
                .padding(.bottom, 72)
                .padding(.horizontal, 24)
                .accessibilityIdentifier("Grid Notice")
        }
    }

    // MARK: Photos on their way

    /// Every photo the page shows selected, the photos on their way among them.
    private func selectAll(_ model: AssetGridModel) {
        model.selectAll()
        model.selection.formUnion(phoneTiles(model).map(\.photo.gridID))
    }

    /// The photos on their way the grid shows among Immich's: on the Library's own timeline, in its usual order
    /// (newest first in the model). Each that arrived shows until the model has Immich's photo for it; while its month
    /// is counted and still being read, Immich's photo is among the month's placeholders, so the tile goes.
    private func phoneTiles(_ model: AssetGridModel) -> [BackupLibraryTile] {
        guard showsPhoneTiles, model.arrangement?.order != .oldestFirst else { return [] }
        return BackupCenter.shared.libraryTiles.filter { tile in
            guard let asset = tile.arrivedAsset else { return true }
            if model.item(asset) != nil { return false }
            let month = TimelinePhoneMerge.month(of: tile.photo.created ?? .now)
            if let section = model.sections.first(where: { $0.id.prefix(7) == month }), section.assets == nil { return false }
            return true
        }
    }

    /// Immich's photos that arrived from the phone, by asset, with the phone's photo they show until their thumbnail
    /// comes.
    private var standIns: [String: String] {
        Dictionary(BackupCenter.shared.libraryTiles.compactMap { tile in tile.arrivedAsset.map { ($0, tile.photo.localID) } },
                   uniquingKeysWith: { first, _ in first })
    }

    @ToolbarContentBuilder
    private func toolbar(_ actions: GridActions, opensAtNewest: Bool, phone: [BackupLibraryTile]) -> some ToolbarContent {
        let model = actions.model
        if state.isSelecting {
            ToolbarItem(placement: .topBarLeading) {
                let total = model.totalCount + phone.count
                let everything = total > 0 && model.selection.count >= total
                Button(everything ? "Deselect All" : "Select All") {
                    if everything { model.selection = [] } else { selectAll(model) }
                }
                // ⌘A on a hardware keyboard, while Select All is offered: the button's, as iPadOS's menus hold ⌘A
                // for text (VersoCommands); the selection's other keys are the grid's (GridKeys).
                .keyboardShortcut(everything ? nil : KeyboardShortcut("a", modifiers: .command))
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Cancel", systemImage: "xmark", role: .close) { actions.endSelecting() }
            }
            GridSelectionToolbar(actions: actions)
        } else {
            ToolbarItem(placement: .topBarTrailing) {
                if let viewOptions {
                    viewOptions
                } else {
                    GridOptionsMenu(page: model.source.gridPage, readsDown: !opensAtNewest,
                                    offersDateScroller: model.showsSectionHeaders,
                                    offersNewestEnd: opensAtNewest && followsNewestEnd(model))
                }
            }
            ToolbarSpacer(.fixed, placement: .topBarTrailing)
            ToolbarItem(placement: .topBarTrailing) {
                Button("Select") {
                    model.selection = []
                    state.isSelecting = true
                }
                .disabled(model.totalCount == 0 && phone.isEmpty)
            }
            AccountToolbarItems(session: session, chrome: chrome, shown: accountInTopBar)
        }
    }

    /// The line under the title: the page's own, or the number of items at the end where a timeline opens (its whole
    /// count is known only where its months are), or the days of the photos in view, or else their months. A page
    /// with a header says nothing at its top, where the header does.
    /// The number of items at the newest end with what follows it (`countAccessory`), where the line says the number.
    private func countLine(_ model: AssetGridModel, opensAtNewest: Bool) -> AnyView? {
        guard let countAccessory, !state.isSelecting, subtitle == nil, header == nil, state.atOpeningEnd, opensAtNewest,
              !model.isPaged, model.totalCount > 0 else { return nil }
        return AnyView(HStack(spacing: 0) {
            Text(pageSubtitle(model, opensAtNewest: opensAtNewest))
                .font(.headline)
            countAccessory
        }
        .lineLimit(1))
    }

    private func pageSubtitle(_ model: AssetGridModel, opensAtNewest: Bool) -> String {
        guard !state.isSelecting else { return "" }
        if let subtitle { return subtitle }
        if state.atOpeningEnd {
            if header != nil { return "" }
            if opensAtNewest, !model.isPaged, model.totalCount > 0 {
                let count = model.totalCount
                return count == 1 ? String(localized: "1 Item") : String(localized: "\(count.formatted()) Items")
            }
        }
        if let dates = state.visibleDates { return dates }
        return model.showsSectionHeaders ? model.visibleMonths ?? "" : ""
    }

    /// Whether the page is a timeline as Photos' library is, opening at its newest photos: at the bottom, the oldest at
    /// the top, or the other way about with Newest at the Top. A page with a header above its photos (an album's, a
    /// person's) and the pages of results read down from the top, in the model's order.
    private func opensAtNewest(_ model: AssetGridModel) -> Bool {
        guard header == nil else { return false }
        if isLibrary { return true }
        switch source {
        case .library, .favorites, .videos, .archive, .trash, .locked, .geolocation, .partner, .person, .album: return true
        default: return false
        }
    }

    /// Whether the page's newest photos are at the end GridNewestEnd chooses: every timeline but an album's, which
    /// keeps its own order.
    private func followsNewestEnd(_ model: AssetGridModel) -> Bool {
        if case .album = model.source { return false }
        return true
    }

    /// The tab whose landings take the grid to its newest photos: the Library's, or the one the page is the own page of.
    private var landingTab: LibraryTab? {
        isLibrary ? .library : landsOnTab
    }

    private var deleteAsked: Binding<Bool> {
        Binding(get: { state.pendingDelete != nil }, set: { shown in if !shown { state.pendingDelete = nil } })
    }

    private var removalAsked: Binding<Bool> {
        Binding(get: { state.pendingRemoval != nil }, set: { shown in if !shown { state.pendingRemoval = nil } })
    }

    private func errorShown(_ model: AssetGridModel) -> Binding<Bool> {
        Binding(get: { model.lastError != nil }, set: { shown in if !shown { model.lastError = nil } })
    }
}

/// The photo the viewer opens on, one tap's asking: a second tap on the same photo asks again.
struct OpenedAsset: Identifiable, Hashable {
    let id: String
    var request = UUID()
}

/// Opens the viewer in place as a tile asks, on the host over the page (ViewerHost); the page gone (the Locked Folder
/// locking), its viewer goes with it.
private struct GridViewerOpening: ViewModifier {
    let host: ViewerHost?
    let state: GridPageState
    let session: LibrarySession
    let model: AssetGridModel
    let readsBackwards: Bool
    let pushRoute: PushRoute

    func body(content: Content) -> some View {
        content
            .onChange(of: state.opened) { _, opened in
                guard let opened else { return }
                host?.open(opened, grid: state, session: session, model: model, readsBackwards: readsBackwards,
                           pushRoute: pushRoute)
            }
            .onDisappear { host?.closeAtOnce(from: state) }
    }
}
