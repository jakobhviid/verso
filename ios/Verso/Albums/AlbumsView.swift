// Every album on iOS, as cards (ROADMAP.md, M10): the root of a tab of its own, Albums, by default, and a page
// Collections pushes when the tab bar does not hold it. The cards come in the five sizes every card page shares
// (CardSize): the Mac's cards, two to a row on iPhone at the smallest, then one; a pinch goes through them, as do Zoom
// Out and Zoom In in View Options. The albums are in sections by year by default, the newest first, as on the Mac and
// in Immich; View Options offers Photos' own (My Albums, then Shared with Me), by owner or none, and the order. Above the albums a search field over their titles and a
// segmented control for all of them, the account's own or those shared with it sit hidden at rest, above the top of
// the page, and come into view as the page is pulled down, as Mail's and Settings' search does (CardGrid's `finder`);
// a pull further reads the albums again. New Album in the toolbar. A card pushes its album as a `Route`, into the
// stack of the tab it is in.

import SwiftUI

struct AlbumsView: View {
    let session: LibrarySession

    // The same settings as the Mac's albums page and Immich's, under the same names, with Photos' sections as iOS's own:
    // by year by default, as the Mac's and Immich's `albums.groupBy`.
    @AppStorage("albums.sections") private var sectioning = AlbumsSectioning.year
    @AppStorage("albums.groupOrder") private var groupOrder = AlbumsSortOrder.descending
    @AppStorage("albums.sortBy") private var sortBy = AlbumsSortBy.mostRecentPhoto
    @AppStorage("albums.sortOrder") private var sortOrder = AlbumsSortOrder.descending
    @AppStorage(CardSize.key) private var cardSize = 0
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.pushRoute) private var pushRoute

    @State private var query = ""
    /// The search field has the keyboard.
    @State private var searching = false
    @State private var page = CardPageWidth()
    @State private var naming = false
    @State private var newName = ""
    @State private var sharingAlbum: Album?
    @State private var renamingAlbum: Album?
    @State private var deletingAlbum: Album?
    @State private var leavingAlbum: Album?
    @State private var error: String?

    var body: some View {
        let shown = sections(of: session.albums)
        CardGrid(
            sections: shown.map { section in
                CardGridSection(id: section.id, count: section.albums.count,
                                header: section.title.map { AnyView(sectionHeader(section, title: $0)) })
            },
            card: { section, item, _ in AnyView(card(shown[section].albums[item])) },
            finder: AnyView(finder),
            searching: searching || !query.isEmpty,
            footer: shown.isEmpty ? AnyView(emptyState.frame(maxWidth: .infinity).padding(.top, 48)) : nil,
            ladder: Self.ladder, size: $cardSize, regular: horizontalSizeClass == .regular,
            contentKey: shown.flatMap(\.albums),
            refresh: {
                await session.reloadAlbums()
                await session.sharing.reload()
            })
        .cardPageWidth($page, regular: horizontalSizeClass == .regular)
        // Large in the bar's row, where it stays put, as Photos' Library has it, also while the search field is hidden.
        .cardPageTitle(String(localized: "Albums"))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { viewOptions }
            ToolbarItem(placement: .topBarTrailing) {
                Button("New Album", systemImage: "rectangle.stack.badge.plus") {
                    newName = ""
                    naming = true
                }
            }
        }
        .task {
            await session.reloadAlbums()
            await session.sharing.reload()
        }
        .alert("New Album", isPresented: $naming) {
            TextField("Title", text: $newName)
            Button("Cancel", role: .cancel) {}
            Button("Save") { createAlbum() }
                .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("Enter a name for this album.")
        }
        .alert("Rename Album", isPresented: renamingShown, presenting: renamingAlbum) { album in
            TextField("Title", text: $newName)
            Button("Cancel", role: .cancel) {}
            Button("Save") { rename(album) }
                .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .confirmationDialog("Delete Album?", isPresented: deletingShown, titleVisibility: .visible, presenting: deletingAlbum) { album in
            Button("Delete Album", role: .destructive) { remove(album, leaving: false) }
        } message: { _ in
            Text("The album will be deleted for everyone. Its photos and videos stay in the library.")
        }
        .confirmationDialog("Leave Album?", isPresented: leavingShown, titleVisibility: .visible, presenting: leavingAlbum) { album in
            Button("Leave Album", role: .destructive) { remove(album, leaving: true) }
        } message: { _ in
            Text("You will no longer see this album until its owner shares it with you again.")
        }
        .sheet(item: $sharingAlbum, onDismiss: { Task { await session.reloadAlbums() } }) { album in
            AlbumSharingSheet(session: session, albumID: album.id)
        }
        .alert("Album Error", isPresented: errorShown) {
            Button("OK") { error = nil }
        } message: {
            Text(error ?? "")
        }
    }

    // MARK: Sections

    /// The card sizes on this page: the Mac's cards, two and then one to a row on iPhone; on iPad the Mac's widths.
    static let ladder = CardLadder(compactColumns: [2, 2, 1, 1, 1], widths: [240, 240, 300, 370, 450], spacing: 14)

    /// The width the cards share: the page's, less its margins.
    private var cardPage: CardPageWidth {
        CardPageWidth(width: max(0, page.width - 32), regular: page.regular)
    }

    /// What the page searches and shows, hidden at rest above its top (CardGrid's `finder`): a search field over the
    /// albums' titles, and which albums show, all of them, the account's own or those shared with it.
    private var finder: some View {
        VStack(spacing: 10) {
            PageSearchField(prompt: "Search Albums", text: $query, isFocused: $searching)
            Picker("Show", selection: ownershipBinding) {
                ForEach(AlbumsOwnership.allCases) { option in Text(option.title).tag(option) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 14)
    }

    /// The segmented control's choice, kept while the app runs.
    private var ownership: AlbumsOwnership { AlbumsPageMemory.shared.ownership }

    private var ownershipBinding: Binding<AlbumsOwnership> {
        Binding(get: { AlbumsPageMemory.shared.ownership }, set: { option in AlbumsPageMemory.shared.ownership = option })
    }

    /// The Mac's arrangement, for the sections and the order; the segmented control does the filtering.
    private var arrangement: AlbumsArrangement {
        AlbumsArrangement(filter: .all, groupBy: sectioning.groupBy ?? AlbumsGroupBy.none, groupOrder: groupOrder,
                          sortBy: sortBy, sortOrder: sortOrder)
    }

    private func sections(of albums: [Album]) -> [AlbumsSection] {
        let userID = session.user?.id
        let ownership = self.ownership
        let matching = albums.filter { album in
            ownership.includes(album, userID: userID) && (query.isEmpty || album.albumName.localizedStandardContains(query))
        }
        guard sectioning == .ownership else {
            return arrangement.groups(matching, userID: userID).map { group in
                // Under Mine, the account's own albums are all there is, and need no header saying so.
                let header = ownership == .mine && group.header == .mine ? nil : group.header
                return AlbumsSection(id: group.id, title: header.map(title), albums: group.albums)
            }
        }
        let sorted = arrangement.sorted(matching)
        guard !sorted.isEmpty else { return [] }
        // One kind shown: one section, without a header for the kind the control already names.
        switch ownership {
        case .mine: return [AlbumsSection(id: "mine", title: nil, albums: sorted)]
        case .sharedWithMe: return [AlbumsSection(id: "shared-with-me", title: nil, albums: sorted)]
        case .all: break
        }
        // Photos' own sections: the account's albums, then the ones others share with it.
        let mine = sorted.filter { AlbumsOwnership.mine.includes($0, userID: userID) }
        let others = sorted.filter { AlbumsOwnership.sharedWithMe.includes($0, userID: userID) }
        return [AlbumsSection(id: "mine", title: "My Albums", albums: mine),
                AlbumsSection(id: "shared-with-me", title: "Shared with Me", albums: others)]
            .filter { !$0.albums.isEmpty }
    }

    private func title(_ header: AlbumsGroup.Header) -> String {
        switch header {
        case .year(let year): String(year)
        case .unknownYear: "Unknown Year"
        case .mine: "My Albums"
        case .owner(let name): name
        }
    }

    /// A section's title and how many albums it holds.
    private func sectionHeader(_ section: AlbumsSection, title: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)
            Text(section.albums.count.formatted())
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.top, 8)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    /// What the page says where no album shows: none matches the search, none is shared with the account, or there
    /// are none yet.
    @ViewBuilder private var emptyState: some View {
        if !query.isEmpty {
            ContentUnavailableView.search(text: query)
        } else if ownership == .sharedWithMe {
            ContentUnavailableView("No Shared Albums", systemImage: "rectangle.stack.badge.person.crop",
                                   description: Text("Albums others share with you appear here."))
        } else {
            ContentUnavailableView {
                Label("No Albums", systemImage: "rectangle.stack")
            } description: {
                Text(ownership == .mine ? "Albums you create appear here."
                     : "Albums you create or that are shared with you appear here.")
            } actions: {
                Button("New Album") {
                    newName = ""
                    naming = true
                }
            }
        }
    }

    // MARK: Cards

    private func card(_ album: Album) -> some View {
        let isOwner = album.albumOwner.map { $0.id == session.user?.id } ?? true
        return AlbumCard(session: session, album: album)
            .cardOpens { pushRoute(.album(album)) }
            .contextMenu {
                Button("Share Album", systemImage: "person.2") { sharingAlbum = album }
                if isOwner {
                    Button("Rename", systemImage: "pencil") {
                        newName = album.albumName
                        renamingAlbum = album
                    }
                    Divider()
                    Button("Delete Album", systemImage: "trash", role: .destructive) { deletingAlbum = album }
                } else {
                    Divider()
                    Button("Leave Album", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) { leavingAlbum = album }
                }
            }
    }

    // MARK: View options

    /// The cards' size, how the albums are cut into sections and in which order, as on the Mac; which show is the
    /// segmented control's.
    private var viewOptions: some View {
        Menu {
            CardZoomControls(size: $cardSize, ladder: Self.ladder, page: cardPage)
            Picker(selection: sectioningBinding) {
                ForEach(AlbumsSectioning.allCases) { option in
                    Text(option.title).tag(option)
                }
            } label: {
                Label("Sections", systemImage: "square.grid.2x2")
            }
            .pickerStyle(.menu)
            if sectioning == .year || sectioning == .owner {
                Picker(selection: $groupOrder) {
                    ForEach(AlbumsSortOrder.allCases) { order in Text(order.title).tag(order) }
                } label: {
                    Label("Section Order", systemImage: "arrow.up.arrow.down.square")
                }
                .pickerStyle(.menu)
            }
            Section {
                Picker(selection: sortByBinding) {
                    ForEach(AlbumsSortBy.allCases) { option in Text(option.title).tag(option) }
                } label: {
                    Label("Sort By", systemImage: "arrow.up.arrow.down")
                }
                .pickerStyle(.menu)
                Picker(selection: $sortOrder) {
                    ForEach(AlbumsSortOrder.allCases) { order in Text(order.title).tag(order) }
                } label: {
                    Label("Album Order", systemImage: "arrow.up.arrow.down.circle")
                }
                .pickerStyle(.menu)
            }
        } label: {
            Label("View Options", systemImage: "line.3.horizontal.decrease")
        }
    }

    /// Year sections need the photos' dates, so sorting by the albums' own dates leaves them out, as Immich does.
    private var sectioningBinding: Binding<AlbumsSectioning> {
        Binding {
            sectioning == .year && !arrangement.allows(.year) ? .flat : sectioning
        } set: { option in
            guard option != sectioning else { return }
            sectioning = option
            if let groupBy = option.groupBy { groupOrder = groupBy.defaultOrder }
        }
    }

    private var sortByBinding: Binding<AlbumsSortBy> {
        Binding {
            sortBy
        } set: { option in
            guard option != sortBy else { return }
            sortBy = option
            sortOrder = option.defaultOrder
        }
    }

    // MARK: Changing albums

    private var renamingShown: Binding<Bool> {
        Binding(get: { renamingAlbum != nil }, set: { shown in if !shown { renamingAlbum = nil } })
    }

    private var deletingShown: Binding<Bool> {
        Binding(get: { deletingAlbum != nil }, set: { shown in if !shown { deletingAlbum = nil } })
    }

    private var leavingShown: Binding<Bool> {
        Binding(get: { leavingAlbum != nil }, set: { shown in if !shown { leavingAlbum = nil } })
    }

    private var errorShown: Binding<Bool> {
        Binding(get: { error != nil }, set: { shown in if !shown { error = nil } })
    }

    /// Makes the album, then opens it in this tab's stack, as Photos does.
    private func createAlbum() {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let push = pushRoute
        Task {
            do {
                let made = try await session.client.createAlbum(name: name, assetIDs: [])
                await session.reloadAlbums()
                push(.album(session.albums.first { $0.id == made.id }
                    ?? Album(id: made.id, albumName: made.albumName, assetCount: made.assetCount, shared: made.shared)))
            } catch {
                session.handle(error)
                self.error = error.localizedDescription
            }
        }
    }

    private func rename(_ album: Album) {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != album.albumName else { return }
        Task {
            do {
                let updated = try await session.client.updateAlbum(album.id, AlbumUpdate(albumName: name))
                session.albumActions.details[album.id] = updated
                await session.reloadAlbums()
            } catch {
                session.handle(error)
                self.error = error.localizedDescription
            }
        }
    }

    private func remove(_ album: Album, leaving: Bool) {
        Task {
            do {
                if leaving {
                    try await session.client.removeAlbumUser(album.id, userID: "me")
                } else {
                    try await session.client.deleteAlbum(album.id)
                }
                session.discardAlbumGrid(album.id)
                await session.reloadAlbums()
            } catch {
                session.handle(error)
                self.error = error.localizedDescription
            }
        }
    }
}

/// Which albums the albums page shows, as the segmented control at its top picks them: all, the account's own, or
/// those others share with it. An album whose owner the list leaves out counts as the account's own.
enum AlbumsOwnership: CaseIterable, Identifiable {
    case all, mine, sharedWithMe

    var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .all: "All"
        case .mine: "Mine"
        case .sharedWithMe: "Shared with Me"
        }
    }

    func includes(_ album: Album, userID: String?) -> Bool {
        let isMine = album.albumOwner.map { $0.id == userID } ?? true
        switch self {
        case .all: return true
        case .mine: return isMine
        case .sharedWithMe: return !isMine
        }
    }
}

/// What the albums page keeps while the app runs, and forgets when it quits: which albums its segmented control shows,
/// the same in every tab and window that shows the page.
@MainActor @Observable final class AlbumsPageMemory {
    static let shared = AlbumsPageMemory()

    var ownership = AlbumsOwnership.all
}

/// How the albums page is cut into sections on iOS: Photos' own (the account's albums, then those shared with it), or
/// one of the Mac's and Immich's groupings.
enum AlbumsSectioning: String, CaseIterable, Identifiable {
    case ownership, year, owner, flat

    var id: Self { self }

    var title: String {
        switch self {
        case .ownership: "Mine and Shared with Me"
        case .year: "Year"
        case .owner: "Owner"
        case .flat: "No Sections"
        }
    }

    /// The Mac's grouping it stands for; nil for Photos' own.
    var groupBy: AlbumsGroupBy? {
        switch self {
        case .ownership: nil
        case .year: .year
        case .owner: .owner
        case .flat: AlbumsGroupBy.none
        }
    }
}

/// A section of the albums page.
private struct AlbumsSection: Identifiable {
    let id: String
    /// Nil for the one section of an ungrouped page, which has no title.
    let title: String?
    let albums: [Album]
}
