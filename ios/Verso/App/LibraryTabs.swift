// The signed-in app on iOS: Photos' tabs, Library first, then the pages the person chose for the tab bar (TabBarChoice),
// Collections, and Search in the trailing search tab, apart from the others (ROADMAP.md, "M10. Verso on iOS"). The
// system's tab bar and its glass are iOS's own: at the foot on an iPhone, and on an iPad iPadOS's floating bar at the
// top, never a sidebar, which made the iPad look like another app. No tab's own
// page but Collections' has the account; Collections' tab carries the number of unread notifications as its badge.
//
// The tab bar shrinks to the tab shown as a page scrolls away from where it opens: back in time, up, on a page that
// opens at its newest photos at the bottom (the Library, a timeline, with Newest at the Bottom, GridNewestEnd), down
// the page elsewhere. A tap on the tab shown, on the Library's own page or the Archive's, goes to its newest photos
// (iOS's habit is the top, which with Newest at the Bottom is the oldest); a tap on the status bar keeps going to the
// top.
//
// Every tab is a NavigationStack over its own path of routes (Routes.swift), which registers where every route leads
// at its root and gives the pages inside it `pushRoute` for a push from code; the stack of the tab shown opens an album
// made from a selection (`opensAlbumMade`). The paths live in LibraryChrome, so Show in All Photos can empty the
// Library's.
//
// Search sits apart at the trailing end, as Photos has it, through its search role and search activation: iOS 26 sets
// the search tab apart by its role alone, and iOS 27 gives that place to a search tab whose selection activates search
// (`tabViewSearchActivation(.searchTabSelection)`, as UIKit's `automaticallyActivatesSearch`), leaving a search tab
// without it inline among the others. Dismissing the search goes back to the tab shown before.
//
// Years, Months and All, as Photos has them: at the newest end of All neither shows and the whole tab bar does; scrolled
// back, the tab bar shrinks to the Library's tab and the picker stands between it and Search, in the tab bar's bottom
// accessory. The accessory is never shown at its full width above the whole tab bar, which is how iOS shows it beside
// a whole tab bar: it is on only while the bar is shrunk, as the accessory itself last found
// (`tabViewBottomAccessoryPlacement`) or as the person lets go of a scroll back in time, which has shrunk the bar by
// then (`.onScrollUp`), and it goes the moment it finds itself expanded (a tap on the shrunk tab expands the bar; a
// scroll forward does not, short of the end). In Years and Months the whole tab bar stays (`.never`) with the picker in
// a glass capsule of the page's own above it (LibraryOverviewPage). Landing at the newest end, the tab bar is brought
// back to its whole width by `.never` for a moment, as nothing else expands it without a scroll.
// `tabViewBottomAccessory(isEnabled:)` leaves no empty glass capsule behind. An import's progress is the line under
// the Library's title (LibraryTabView).

import SwiftUI

/// The tabs, as `TabView` selects them.
enum LibraryTab: Hashable {
    case library, collections, search
    /// A page the person put in the tab bar.
    case choice(TabBarChoice)
}

extension LibraryChrome {
    /// The tab a window opens on: Library, or in Verso Dev the one its launch arguments name (`-startTab collections`,
    /// `search`, or a tab bar choice such as `albums`), so a script can look at each tab, as it signs in.
    static var startTab: LibraryTab {
        #if DEBUG
        switch UserDefaults.standard.string(forKey: "startTab") {
        case "collections": return .collections
        case "search": return .search
        case let name?: if let choice = TabBarChoice(rawValue: name) { return .choice(choice) }
        case nil: break
        }
        #endif
        return .library
    }
}

/// A tab's pages, as its NavigationStack shows them: empty at the tab's own page.
@MainActor @Observable final class TabPath {
    var routes: [Route] = []
}

/// What the window's tabs and the pages inside them share: the tab shown, each tab's pages, Library's Years, Months or
/// All and whether its grid is at its newest photos, the pages selecting (whose selection toolbar takes the bottom of
/// the window from the tab bar and its accessory), the pages shown that open at their bottom, and Show in All Photos
/// and Show in Archive, which any page may ask for.
@MainActor @Observable final class LibraryChrome {
    var selectedTab = LibraryChrome.startTab
    var libraryMode = LibraryMode.all
    /// The Library's grid is at its newest photos, at whichever end, where the whole tab bar shows without Years,
    /// Months and All.
    var libraryAtNewestEnd = true
    /// The tab bar is shrunk to the Library's tab: as the bottom accessory last found itself, or as the person's scroll
    /// back in time shrinks it.
    private(set) var libraryBarShrunk = false
    /// The tab bar stands at its whole width for a moment (`.never`), which brings it back from shrunk.
    private(set) var tabBarExpanding = false
    /// Asks a tab's own page, the Library's or the Archive's, to go to its newest photos: how many times each tab asked.
    private(set) var landings: [LibraryTab: Int] = [:]
    /// The window's top safe area, the status bar, from which a page's title rises into the bar's row (PageTitle).
    var windowTopInset: CGFloat?
    private(set) var selectingPages: Set<UUID> = []
    /// The pages shown that open at their bottom and read back in time upwards: timelines with Newest at the Bottom.
    private(set) var bottomOpeningPages: Set<UUID> = []
    /// The Library's Not in an Album, a search grid of its own beside the window's one for Search's results.
    @ObservationIgnored private var notInAlbumGrid: AssetGridModel?
    /// The grid whose selection an album sheet of the window's last took: its page ends selecting.
    private(set) var finishedSelection: FinishedSelection?
    /// Each tab's path, made as the tab first shows; each is observed on its own, so a push redraws its tab alone.
    @ObservationIgnored private var paths: [LibraryTab: TabPath] = [:]

    struct FinishedSelection: Equatable {
        let grid: ObjectIdentifier
        let serial: Int
    }

    var isSelecting: Bool { !selectingPages.isEmpty }

    /// A page shown opens at its bottom, so the tab bar shrinks as it scrolls up, back in time; elsewhere as it scrolls
    /// down.
    var showsBottomOpeningPage: Bool { !bottomOpeningPages.isEmpty }

    func setOpensAtBottom(_ page: UUID, _ opens: Bool) {
        if opens { bottomOpeningPages.insert(page) } else { bottomOpeningPages.remove(page) }
    }

    /// The Library's Not in an Album grid, made once for the window.
    func notInAlbumModel(session: LibrarySession) -> AssetGridModel {
        if let notInAlbumGrid { return notInAlbumGrid }
        let model = AssetGridModel(source: LibraryFilter.notInAlbum.source, session: session)
        notInAlbumGrid = model
        return model
    }

    /// The window's grids changed (photos added to albums, deleted, imported): Not in an Album reads again, at once
    /// while it is shown and otherwise when it next shows, as the window's own grids do.
    func notInAlbumGridChanged(shown: Bool) {
        guard let notInAlbumGrid else { return }
        notInAlbumGrid.markStale()
        if shown { Task { await notInAlbumGrid.loadIfNeeded() } }
    }

    /// How many times the Library's page was asked to go to its newest photos.
    var libraryLandings: Int { landings[.library] ?? 0 }

    /// A tab's own page goes to its newest photos.
    func land(_ tab: LibraryTab) {
        landings[tab, default: 0] += 1
    }

    /// The Library's page goes to its newest photos.
    func landLibrary() {
        land(.library)
    }

    /// The person scrolled the Library back in time, which shrinks the tab bar, unless it is standing at its whole width.
    func libraryScrolledBack() {
        guard !tabBarExpanding else { return }
        libraryBarShrunk = true
    }

    /// Where the bottom accessory found itself: inline beside the shrunk tab bar, or expanded above the whole one, which
    /// it is never left to be.
    func libraryAccessoryPlaced(_ placement: TabViewBottomAccessoryPlacement?) {
        switch placement {
        case .inline: libraryBarShrunk = true
        case .expanded: libraryBarShrunk = false
        default: break
        }
    }

    /// The tab bar back at its whole width, as a scroll to the newest end or another tab has it.
    func expandTabBar() {
        libraryBarShrunk = false
        guard !tabBarExpanding else { return }
        tabBarExpanding = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            tabBarExpanding = false
        }
    }

    /// The tab bar no longer counts as shrunk for the Library: another tab or page shows, or the selection's toolbar,
    /// after which iOS may bring the bar back either way; the next scroll back in time shrinks it again.
    func libraryBarLeft() {
        libraryBarShrunk = false
    }

    func path(for tab: LibraryTab) -> TabPath {
        if let path = paths[tab] { return path }
        let path = TabPath()
        paths[tab] = path
        return path
    }

    func finishSelection(of model: AssetGridModel?) {
        guard let model else { return }
        finishedSelection = FinishedSelection(grid: ObjectIdentifier(model), serial: (finishedSelection?.serial ?? 0) + 1)
    }

    func setSelecting(_ page: UUID, _ selecting: Bool) {
        if selecting { selectingPages.insert(page) } else { selectingPages.remove(page) }
    }

    /// Show in All Photos: the Library tab at its own page, every photo shown, at the photo once its month is loaded,
    /// as the Mac's ViewerState does.
    func showInLibrary(_ id: String, from model: AssetGridModel, session: LibrarySession) {
        guard model.source != .locked, session.lockedFolder == nil else { return }
        Task {
            do {
                let asset = try await session.client.asset(id)
                // Every photo, before the Library's grid reads its view options again.
                LibraryFilterSetting.showAll()
                let library = session.gridModel(for: .library)
                await library.loadIfNeeded()
                try await library.loadForReveal(asset)
                guard library.item(id) != nil else {
                    model.lastError = "This item isn't in All Photos. It may be archived, hidden, trashed, or part of a stack."
                    return
                }
                libraryMode = .all
                path(for: .library).routes = []
                selectedTab = .library
                library.viewerScrollTarget = id
            } catch {
                guard !error.isCancellation else { return }
                model.lastError = error.localizedDescription
                session.handle(error)
            }
        }
    }

    /// Show in Archive, Verso's counterpart of Show in All Photos for an archived photo: the Archive at the photo once
    /// its month is loaded, on its own tab where the person put it in the tab bar, else as Collections' Archive page.
    func showInArchive(_ id: String, from model: AssetGridModel, session: LibrarySession) {
        guard model.source != .locked, session.lockedFolder == nil else { return }
        Task {
            do {
                let asset = try await session.client.asset(id)
                let archive = session.gridModel(for: .archive)
                await archive.loadIfNeeded()
                try await archive.loadForReveal(asset)
                guard archive.item(id) != nil else {
                    model.lastError = String(localized: "This item isn't in the Archive. It may be in the library again, hidden, trashed, or part of a stack.")
                    return
                }
                let stored = UserDefaults.standard.string(forKey: TabBarChoice.storageKey) ?? ""
                if TabBarChoice.decode(stored).contains(.archive) {
                    path(for: .choice(.archive)).routes = []
                    selectedTab = .choice(.archive)
                } else {
                    path(for: .collections).routes = [.photos(.archive, title: String(localized: "Archive"))]
                    selectedTab = .collections
                }
                archive.viewerScrollTarget = id
            } catch {
                guard !error.isCancellation else { return }
                model.lastError = error.localizedDescription
                session.handle(error)
            }
        }
    }
}

struct LibraryTabs: View {
    let services: AccountServices
    /// This window's session over the account: its grids and selection, as each of the Mac's windows has one.
    @State private var session: LibrarySession?
    @State private var chrome = LibraryChrome()
    /// Library's Years, Months or All, kept for the window as Photos keeps it.
    @SceneStorage("library.mode") private var savedLibraryMode = LibraryMode.all
    /// The pages the person put in the tab bar, kept on this device (TabBarChoice).
    @AppStorage(TabBarChoice.storageKey) private var storedChoices = ""
    /// What the Library shows: Years, Months and All are for every photo.
    private let libraryFilter = LibraryFilterSetting()
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        Group {
            if let session {
                tabs(session)
            } else {
                ProgressView()
            }
        }
        .task {
            if session == nil {
                chrome.libraryMode = savedLibraryMode
                session = LibrarySession(services: services)
            }
            #if DEBUG
            // `-showPhoto <id>`: Show in All Photos for that photo once signed in, so a UI test can open it.
            if let id = UserDefaults.standard.string(forKey: "showPhoto"), let session {
                chrome.showInLibrary(id, from: session.gridModel(for: .library), session: session)
            }
            #endif
        }
        .onChange(of: chrome.libraryMode) { _, mode in savedLibraryMode = mode }
        .onChange(of: storedChoices) { _, stored in leaveRemovedChoices(TabBarChoice.decode(stored)) }
    }

    private func tabs(_ session: LibrarySession) -> some View {
        @Bindable var chrome = chrome
        @Bindable var backup = BackupCenter.shared
        let choices = TabBarChoice.decode(storedChoices)
        return TabView(selection: Binding(get: { chrome.selectedTab }, set: { tab in
            if tab == chrome.selectedTab { reselected(tab) }
            chrome.selectedTab = tab
        })) {
            Tab("Library", systemImage: "photo.on.rectangle", value: LibraryTab.library) {
                TabStack(session: session, tab: .library) {
                    LibraryTabView(session: session)
                }
            }
            ForEach(choices) { choice in
                Tab(choice.title, systemImage: choice.systemImage, value: LibraryTab.choice(choice)) {
                    TabStack(session: session, tab: .choice(choice)) {
                        ChosenTabPage(session: session, choice: choice)
                    }
                }
            }
            Tab("Collections", systemImage: "rectangle.stack", value: LibraryTab.collections) {
                TabStack(session: session, tab: .collections) {
                    CollectionsTabView(session: session)
                }
            }
            // The notifications wait in the account's sheet on Collections' page; none unread shows no badge.
            .badge(session.services.unreadNotificationCount)
            Tab(value: LibraryTab.search, role: .search) {
                TabStack(session: session, tab: .search) {
                    SearchTabView(session: session)
                }
            }
        }
        .tabViewStyle(.tabBarOnly)
        .tabBarMinimizeBehavior(minimizeBehavior)
        .tabViewSearchActivation(.searchTabSelection)
        .tabViewBottomAccessory(isEnabled: modePickerShown) {
            LibraryModeAccessory(mode: $chrome.libraryMode, chrome: chrome)
        }
        .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.top } action: { chrome.windowTopInset = $0 }
        // A photo opened from any tab's grid shows over the tabs, in place (ViewerHost).
        .viewerHost()
        // At the newest end, and in Years and Months, the whole tab bar shows.
        .onChange(of: chrome.libraryAtNewestEnd) { _, atEnd in if atEnd { chrome.expandTabBar() } }
        .onChange(of: chrome.libraryMode) { chrome.expandTabBar() }
        .onChange(of: chrome.selectedTab) { chrome.libraryBarLeft() }
        .onChange(of: chrome.path(for: .library).routes.count) { chrome.libraryBarLeft() }
        .onChange(of: chrome.isSelecting) { chrome.libraryBarLeft() }
        .modifier(GridAlbumActionsPresentation(session: session, chrome: chrome))
        // The Backup page, from wherever it is asked for: the Library's card and line, a notification, a Live Activity.
        .sheet(isPresented: $backup.pageShown) {
            NavigationStack {
                BackupPage(services: services)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button(role: .close) { BackupCenter.shared.pageShown = false }
                        }
                    }
            }
        }
        .environment(chrome)
        .alert("Album Error", isPresented: albumErrorShown(session)) {
            Button("OK") { session.albumActions.error = nil }
        } message: {
            Text(session.albumActions.error ?? "")
        }
    }

    /// The Library's own page shows the whole library, where Years, Months and All are.
    private var libraryPageShowsWholeLibrary: Bool {
        chrome.selectedTab == .library && chrome.path(for: .library).routes.isEmpty && libraryFilter.filter.showsWholeLibrary
    }

    /// Years, Months and All in the accessory: on the Library's own page in All once its grid has scrolled back from the
    /// newest photos, while the tab bar is shrunk beside it, in a compact width (a regular one shows the page's own
    /// capsule, LibraryTabView). While selecting, the selection's toolbar has the bottom of the window.
    private var modePickerShown: Bool {
        guard !chrome.isSelecting, libraryPageShowsWholeLibrary, chrome.libraryMode == .all, horizontalSizeClass != .regular else {
            return false
        }
        return !chrome.libraryAtNewestEnd && chrome.libraryBarShrunk
    }

    /// The tab bar shrinks on a scroll away from where the page opens, and stays whole in Years and Months, where the
    /// picker stands above it, and for a moment when it is brought back.
    private var minimizeBehavior: TabBarMinimizeBehavior {
        if chrome.tabBarExpanding || (libraryPageShowsWholeLibrary && chrome.libraryMode != .all) { return .never }
        return chrome.showsBottomOpeningPage ? .onScrollUp : .onScrollDown
    }

    /// A tap on the tab shown: on the Library's own page or the Archive's, its newest photos.
    private func reselected(_ tab: LibraryTab) {
        guard tab == .library || tab == .choice(.archive), chrome.path(for: tab).routes.isEmpty else { return }
        chrome.land(tab)
    }

    /// A page taken out of the tab bar loses its tab and the pages open on it; Collections, which lists it again, shows
    /// in its place if it was the tab shown.
    private func leaveRemovedChoices(_ choices: [TabBarChoice]) {
        for choice in TabBarChoice.allCases where !choices.contains(choice) {
            chrome.path(for: .choice(choice)).routes = []
            if chrome.selectedTab == .choice(choice) { chrome.selectedTab = .collections }
        }
    }

    private func albumErrorShown(_ session: LibrarySession) -> Binding<Bool> {
        Binding(get: { session.albumActions.error != nil },
                set: { shown in if !shown { session.albumActions.error = nil } })
    }
}

/// A tab's NavigationStack over the tab's path: its own page at the root, where every route's page is registered and,
/// while the tab shows, an album made from a selection opens, and `pushRoute` for the pages inside it.
private struct TabStack<Root: View>: View {
    let session: LibrarySession
    let tab: LibraryTab
    @ViewBuilder let root: () -> Root
    @Environment(LibraryChrome.self) private var chrome

    var body: some View {
        let tabPath = chrome.path(for: tab)
        @Bindable var path = tabPath
        NavigationStack(path: $path.routes) {
            root()
                .versoDestinations(session: session)
                .opensAlbumMade(session: session, whileShown: chrome.selectedTab == tab)
        }
        .environment(\.pushRoute, PushRoute { route in tabPath.routes.append(route) })
    }
}

/// A page the person put in the tab bar, as its tab's own page; the account is on Collections' page alone.
private struct ChosenTabPage: View {
    let session: LibrarySession
    let choice: TabBarChoice

    @ViewBuilder var body: some View {
        switch choice {
        case .albums: AlbumsView(session: session)
        case .people: PeopleView(session: session)
        case .places: PlacesView(session: session)
        case .memories: MemoriesView(session: session)
        case .sharedLinks: SharedLinksView(session: session)
        // The Archive's photos, as Collections opens them, going to the newest on a tap on its tab.
        case .archive:
            AssetGridPage(session: session, source: .archive, title: String(localized: "Archive"), landsOnTab: .choice(.archive))
        }
    }
}
