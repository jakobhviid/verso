// The Library tab's own page on iOS, as Photos' Library: a large "Library" title in the bar's row with one line under
// it that says what matters now (PageTitle), and trailing only View Options (LibraryOptionsMenu) and Select, two glass
// items. The timeline, every photo edge to edge under the glass bars, the newest at the bottom (or the top, with
// Newest at the Top, GridNewestEnd) where the page opens (AssetGridPage over the library's source), or its Years and
// Months (LibraryOverviewPage), chosen in the tab bar's bottom accessory once the bar has shrunk (LibraryTabs). A
// filter shows one kind of photo instead; Years and Months, which are the whole library's, go while one is on.
//
// The Library's home is its newest photo, at whichever end, where it opens: whatever replaces what the grid shows lands
// there, a filter (a page of its own for each), the sort and Library View (LibraryChrome.landLibrary), and Years or
// Months back to All without a photo picked; a photo picked in them, Show in All Photos and the viewer keep theirs.
//
// The line under the title is an import's progress while one runs (LibraryImportLine), then backing up's while it has
// something to say (BackupLibraryLine), and otherwise the grid's: the days of the photos in view while it scrolls, and
// the number of items at the newest end. The tab's NavigationStack is LibraryTabs'.
//
// All Items also shows the photos that came to the phone after backing up was switched on and are not in Immich yet,
// among Immich's at the newest end, from the phone (AssetGridPage's `showsPhoneTiles`); the filters, Years and Months
// are Immich's alone. While backing up is off and the person has not said Not Now, a card above the tab bar, by the
// newest photos where the Library opens, offers it (BackupInvitationCard); while it is on, the same place has Free Up
// Space's card once there is real space to gain (FreeUpCard).

import SwiftUI

struct LibraryTabView: View {
    let session: LibrarySession
    @Environment(LibraryChrome.self) private var chrome
    private let filterSetting = LibraryFilterSetting()
    @AppStorage(GridPage.library.key("sortBy")) private var sortBy = GridSortBy.dateTaken
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    /// The partners have been read once, so a filter of a partner no longer sharing goes back to All Items.
    @State private var partnersRead = false

    var body: some View {
        let partners = session.sharing.receivedPartners
        let filter = shownFilter(partners)
        let importShown = ImportProgress.isShown(for: session.upload)
        Group {
            if filter.showsWholeLibrary && chrome.libraryMode != .all {
                LibraryOverviewPage(session: session, mode: chrome.libraryMode)
                    .transition(.opacity)
            } else {
                AssetGridPage(session: session, source: filter.source, title: "Library",
                              titleLine: importShown ? AnyView(LibraryImportLine(queue: session.upload))
                                  : BackupLibraryLine.isShown ? AnyView(BackupLibraryLine(services: session.services)) : nil,
                              countAccessory: BackupCountAccessory.isShown ? AnyView(BackupCountAccessory()) : nil,
                              isLibrary: true,
                              viewOptions: AnyView(LibraryOptionsMenu(session: session, partners: partners,
                                                                      filter: filterBinding)),
                              model: filter == .notInAlbum ? chrome.notInAlbumModel(session: session) : nil,
                              onOpeningEnd: { atEnd in chrome.libraryAtNewestEnd = atEnd },
                              onScrolledAway: { chrome.libraryScrolledBack() },
                              showsPhoneTiles: filter == .all)
                    .safeAreaInset(edge: .bottom) {
                        if !chrome.isSelecting {
                            if BackupCenter.shared.invitationShown {
                                BackupInvitationCard()
                            } else if let card = FreeUpCard.shown {
                                FreeUpCard(kind: card)
                            }
                        }
                    }
                    // A page of its own for each filter, which opens at its newest photos.
                    .id(filter)
                    .transition(.opacity)
                    // In a regular width the page's own capsule holds Years, Months and All (the accessory is a
                    // phone's, LibraryTabs).
                    .overlay(alignment: .bottom) {
                        if horizontalSizeClass == .regular, filter.showsWholeLibrary, !chrome.libraryAtNewestEnd,
                           !chrome.isSelecting {
                            LibraryModeCapsule(mode: modeBinding)
                                .padding(.bottom, 12)
                        }
                    }
            }
        }
        // The sort replaces what the grid shows, as a filter does.
        .onChange(of: sortBy) { chrome.landLibrary() }
        .task {
            guard !partnersRead else { return }
            await readPartners()
        }
        // Not in an Album reads again when photos join albums or leave the library, as the window's grids do.
        .onChange(of: session.macGridRevision) { chrome.notInAlbumGridChanged(shown: filter == .notInAlbum) }
    }

    /// The filter kept, or All Items where it names a partner who no longer shares with the account.
    private func shownFilter(_ partners: [SharingPartner]) -> LibraryFilter {
        let filter = filterSetting.filter
        if case .sharedWithYou(let partnerID) = filter, partnersRead, !partners.contains(where: { $0.id == partnerID }) {
            return .all
        }
        return filter
    }

    private var modeBinding: Binding<LibraryMode> {
        Binding(get: { chrome.libraryMode }, set: { chrome.libraryMode = $0 })
    }

    private var filterBinding: Binding<LibraryFilter> {
        Binding(get: { shownFilter(session.sharing.receivedPartners) },
                set: { filter in withAnimation(.easeInOut(duration: 0.25)) { filterSetting.filter = filter } })
    }

    /// The partners who share with the account, for Shared with You and Library View, with whether each is in the
    /// account's timeline. Collections reads them with the rest of sharing; the Library needs only these.
    private func readPartners() async {
        do {
            session.sharing.receivedPartners = try await session.client.sharingPartners(direction: "shared-with")
            partnersRead = true
        } catch ImmichError.http(404, _) {
            // A server without partner sharing: the menu offers neither Shared with You nor Library View.
            partnersRead = true
        } catch {
            // Offline or cancelled: read again when the page next shows.
        }
    }
}

/// Library's Years, Months or All: the system's segmented control.
struct LibraryModePicker: View {
    @Binding var mode: LibraryMode

    var body: some View {
        Picker("Years, Months or All", selection: $mode.animation(.easeInOut(duration: 0.25))) {
            Text("Years").tag(LibraryMode.years)
            Text("Months").tag(LibraryMode.months)
            Text("All").tag(LibraryMode.all)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }
}

/// Years, Months and All in the tab bar's bottom accessory, as Photos has them beside the shrunk tab bar: across the
/// accessory's glass between the Library's tab and Search. It tells the window where the system put it, which takes it
/// away the moment it is expanded above the whole tab bar (LibraryTabs).
struct LibraryModeAccessory: View {
    @Binding var mode: LibraryMode
    let chrome: LibraryChrome
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement

    var body: some View {
        LibraryModePicker(mode: $mode)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 6)
            .onChange(of: placement, initial: true) { _, placement in chrome.libraryAccessoryPlaced(placement) }
    }
}

/// Years, Months and All in a glass capsule of the page's own above the whole tab bar, hugging its three segments: in
/// Years and Months, where the tab bar stays whole, and in a regular width.
struct LibraryModeCapsule: View {
    @Binding var mode: LibraryMode

    var body: some View {
        LibraryModePicker(mode: $mode)
            .frame(width: 270)
            .padding(5)
            .glassEffect(.regular.interactive(), in: .capsule)
    }
}
