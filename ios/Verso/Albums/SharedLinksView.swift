// The shared links on iOS: every link the account made as a card, as the Mac shows them (SharedLinkCard), in the card
// sizes every card page shares (CardSize), two to a row on an iPhone at the smallest and one from the next; a pinch goes
// through them, as do Zoom Out and Zoom In in View Options. Each card shows what the link shares, how far it reaches
// and until when (Expired in red), with Share in its corner and Copy Link, Share Link, Edit and Delete in its long
// press; a tap pushes its album, or the link's own page with the photos it shares, as a `Route`. Which links show is in View Options,
// as on the Mac: all, album links or chosen photos, and expired ones hidden or not.

import SwiftUI

struct SharedLinksView: View {
    let session: LibrarySession
    @Environment(\.pushRoute) private var pushRoute
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @AppStorage(CardSize.key) private var cardSize = 0
    @State private var page = CardPageWidth()

    // The Mac's view options, under the same names: the Immich web app's tabs, and hiding expired links.
    @AppStorage("sharedLinks.filter") private var filter = SharedLinksFilter.all
    @AppStorage("sharedLinks.hideExpired") private var hideExpired = false

    @State private var editing: SharedLink?
    @State private var deleting: SharedLink?
    @State private var creatingForAlbum: AlbumLinkRequest?
    @State private var copied = false

    /// Whether the view options leave some links out.
    private var isFiltered: Bool { filter != .all || hideExpired }

    var body: some View {
        let sharing = session.sharing
        let links = filter.links(sharing.links, hideExpired: hideExpired)
        CardGrid(
            sections: [CardGridSection(id: "links", count: links.count)],
            card: { _, item, _ in
                let link = links[item]
                return AnyView(SharedLinkCard(session: session, link: link) { pushRoute(route(link)) }
                    .contextMenu { menu(link) })
            },
            ladder: Self.ladder, size: $cardSize, regular: horizontalSizeClass == .regular,
            contentKey: links.map { link in
                [link.id, link.slug ?? "", link.description ?? "", link.expiresAt ?? "", link.hasPassword ? "p" : "",
                 link.allowDownload ? "d" : "", link.allowUpload ? "u" : "", link.showMetadata ? "m" : "",
                 String(link.assets.count), link.album?.albumName ?? ""]
            },
            top: 16, refresh: { await sharing.reload() })
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay { emptyState(links) }
        .cardPageWidth($page, regular: horizontalSizeClass == .regular)
        .cardPageTitle(String(localized: "Shared Links"))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { viewOptions.disabled(!sharing.linksAvailable) }
            ToolbarItem(placement: .topBarTrailing) { newAlbumLink.disabled(!sharing.linksAvailable || ownAlbums.isEmpty) }
        }
        .task {
            await sharing.reload()
            await SharedLinkAddresses.shared.read(session.client)
        }
        .sheet(item: $editing) { link in
            SharedLinkForm(session: session, link: link)
        }
        .sheet(item: $creatingForAlbum) { request in
            SharedLinkForm(session: session, albumID: request.albumID)
        }
        .confirmationDialog("Delete Link?", isPresented: deletingShown, titleVisibility: .visible, presenting: deleting) { link in
            Button("Delete Link", role: .destructive) {
                Task { await sharing.perform { try await session.client.deleteSharedLink(link.id) } }
            }
        } message: { link in
            Text(deletingMessage(link))
        }
        .alert("Sharing Failed", isPresented: sharingErrorShown) {
            Button("OK") { session.sharing.error = nil }
        } message: {
            Text(session.sharing.error ?? "")
        }
        .sensoryFeedback(.success, trigger: copied)
    }

    /// The cards' sizes: two to a row on an iPhone, then one; on an iPad the Mac's widths.
    static let ladder = CardLadder(compactColumns: [2, 1, 1, 1, 1], widths: [260, 300, 360, 430, 500], spacing: 14)

    /// The width the cards share: the page's, less its margins.
    private var cardPage: CardPageWidth {
        CardPageWidth(width: max(0, page.width - 32), regular: page.regular)
    }

    /// An album's link opens the album; a link to chosen photos opens them, on the link's page (SharedLinkPage).
    private func route(_ link: SharedLink) -> Route {
        if let linked = link.album {
            return .album(session.albums.first { $0.id == linked.id } ?? linked)
        }
        return .photos(.sharedLink(link.id), title: SharedLinkWords.title(link))
    }

    @ViewBuilder private func menu(_ link: SharedLink) -> some View {
        Button("Copy Link", systemImage: "doc.on.doc") { copy(link) }
        if let address = SharedLinkAddresses.shared.url(link, client: session.client) {
            ShareLink(item: address) { Label("Share Link", systemImage: "square.and.arrow.up") }
        }
        Button("Edit Link", systemImage: "pencil") { editing = link }
        Divider()
        Button("Delete Link", systemImage: "trash", role: .destructive) { deleting = link }
    }

    @ViewBuilder private func emptyState(_ links: [SharedLink]) -> some View {
        if !session.sharing.linksAvailable {
            ContentUnavailableView("Shared Links Unavailable", systemImage: "link",
                                   description: Text("Shared links are turned off or unavailable on this server."))
        } else if links.isEmpty && !session.sharing.links.isEmpty {
            ContentUnavailableView {
                Label("No Matching Links", systemImage: "line.3.horizontal.decrease.circle")
            } description: {
                Text("No links match the selected view options.")
            } actions: {
                Button("Show All Links") {
                    filter = .all
                    hideExpired = false
                }
            }
        } else if links.isEmpty {
            ContentUnavailableView("No Shared Links", systemImage: "link",
                                   description: Text("Share an album or chosen photos with a link, and it appears here."))
        }
    }

    private var viewOptions: some View {
        Menu {
            CardZoomControls(size: $cardSize, ladder: Self.ladder, page: cardPage)
            Picker("Show", selection: $filter) {
                ForEach(SharedLinksFilter.allCases) { option in Text(option.title).tag(option) }
            }
            .pickerStyle(.inline)
            Toggle("Hide Expired Links", isOn: $hideExpired)
        } label: {
            Label("View Options", systemImage: isFiltered ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease")
        }
    }

    /// The albums the account may make a link to: its own.
    private var ownAlbums: [Album] {
        let userID = session.user?.id
        return session.albums
            .filter { album in album.albumOwner.map { $0.id == userID } ?? true }
            .sorted { $0.albumName.localizedStandardCompare($1.albumName) == .orderedAscending }
    }

    /// A new link to one of the account's albums; links to chosen photos are made where the photos are selected.
    private var newAlbumLink: some View {
        Menu {
            Section("Share an Album with a Link") {
                ForEach(ownAlbums) { album in
                    Button(album.albumName) { creatingForAlbum = AlbumLinkRequest(albumID: album.id) }
                }
            }
        } label: {
            Label("New Album Link", systemImage: "link.badge.plus")
        }
    }

    private func deletingMessage(_ link: SharedLink) -> String {
        link.type == "ALBUM" ? "Anyone with the link loses access to the album. The album stays as it is."
            : "Anyone with the link loses access to its photos. They stay in your library."
    }

    private var deletingShown: Binding<Bool> {
        Binding(get: { deleting != nil }, set: { shown in if !shown { deleting = nil } })
    }

    private var sharingErrorShown: Binding<Bool> {
        Binding(get: { session.sharing.error != nil }, set: { shown in if !shown { session.sharing.error = nil } })
    }

    private func copy(_ link: SharedLink) {
        Task {
            do {
                SharedLinkAddresses.copy(try await SharedLinkAddresses.shared.address(link, client: session.client))
                copied.toggle()
            } catch {
                session.sharing.error = error.localizedDescription
            }
        }
    }
}

/// The album a new link is asked for.
private struct AlbumLinkRequest: Identifiable {
    let id = UUID()
    let albumID: String
}

/// A link to chosen photos: its photos in the grid, newest first, under a header with how many, until when it works,
/// what visitors may do, how far it reaches, and Edit Link and Add Photos, as an album's header has Add Photos. Its menu
/// copies and shares it, adds photos, changes and deletes it.
/// `Route.photos(.sharedLink(id), title:)` leads here.
struct SharedLinkPage: View {
    let session: LibrarySession
    let linkID: String
    /// The link's name, while the link itself is read.
    let title: String

    @Environment(\.dismiss) private var dismiss
    @State private var link: SharedLink?
    @State private var error: String?
    @State private var editing = false
    @State private var adding = false
    @State private var deleting = false
    @State private var deleted = false
    @State private var copied = false

    private var model: AssetGridModel { session.gridModel(for: .sharedLink(linkID)) }

    var body: some View {
        Group {
            if deleted {
                ContentUnavailableView("Link Deleted", systemImage: "link")
            } else {
                AssetGridPage(session: session, source: .sharedLink(linkID), title: link.map(SharedLinkWords.title) ?? title,
                              header: AnyView(SharedLinkHeader(link: link, edit: { editing = true },
                                                               addPhotos: { adding = true })))
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { linkMenu }
        }
        .task(id: linkID) {
            await load()
            await SharedLinkAddresses.shared.read(session.client)
        }
        // A photo taken out in the grid (Remove from Link): the header's count follows.
        .onChange(of: model.totalCount) { Task { await load() } }
        .sheet(isPresented: $editing, onDismiss: { Task { await load() } }) {
            if let link { SharedLinkForm(session: session, link: link) }
        }
        .sheet(isPresented: $adding) {
            AlbumsPhotoPicker(session: session, title: "Add to Link", source: .library,
                              present: Set(link?.assets.map(\.id) ?? [])) { ids in
                try await session.client.changeSharedLinkAssets(linkID, assetIDs: ids, adding: true)
                session.services.linkPreviews.forget(linkID)
                await model.reload()
                await load()
                await session.sharing.reload()
            }
        }
        .confirmationDialog("Delete Link?", isPresented: $deleting, titleVisibility: .visible) {
            Button("Delete Link", role: .destructive) { deleteLink() }
        } message: {
            Text("Anyone with the link loses access to its photos. They stay in your library.")
        }
        .alert("Link Error", isPresented: errorShown) {
            Button("OK") { error = nil }
        } message: {
            Text(error ?? "")
        }
        .sensoryFeedback(.success, trigger: copied)
    }

    private var errorShown: Binding<Bool> {
        Binding(get: { error != nil }, set: { shown in if !shown { error = nil } })
    }

    /// The link's menu, named by its icon (DESIGN.md, "The toolbar's places").
    private var linkMenu: some View {
        Menu {
            if let link {
                Section {
                    Button("Copy Link", systemImage: "doc.on.doc") { copy(link) }
                    if let address = SharedLinkAddresses.shared.url(link, client: session.client) {
                        ShareLink(item: address) { Label("Share Link", systemImage: "square.and.arrow.up") }
                    }
                }
                Section {
                    Button("Add Photos", systemImage: "photo.badge.plus") { adding = true }
                    Button("Edit Link", systemImage: "pencil") { editing = true }
                }
                Section {
                    Button("Delete Link", systemImage: "trash", role: .destructive) { deleting = true }
                }
            }
        } label: {
            Label("Link", systemImage: "link")
        }
        .disabled(link == nil || deleted)
    }

    private func load() async {
        do {
            link = try await session.client.sharedLink(linkID)
        } catch {
            guard !error.isCancellation else { return }
            session.handle(error)
            if link == nil { self.error = error.localizedDescription }
        }
    }

    private func copy(_ link: SharedLink) {
        Task {
            do {
                SharedLinkAddresses.copy(try await SharedLinkAddresses.shared.address(link, client: session.client))
                copied.toggle()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func deleteLink() {
        Task {
            do {
                try await session.client.deleteSharedLink(linkID)
                deleted = true
                await session.sharing.reload()
                dismiss()
            } catch {
                session.handle(error)
                self.error = error.localizedDescription
            }
        }
    }
}

/// A link's header above its photos: how many, until when it works, what visitors may do, and a row of how far it
/// reaches, which opens its settings, Edit Link and Add Photos.
private struct SharedLinkHeader: View {
    let link: SharedLink?
    let edit: () -> Void
    let addPhotos: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let link {
                let expired = link.isExpired
                HStack(spacing: 6) {
                    Text(link.assets.count == 1 ? "1 photo" : "\(link.assets.count.formatted()) photos")
                    Text(verbatim: "·")
                    Text(SharedLinkWords.expiry(link))
                        .foregroundStyle(expired ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                Text(SharedLinkWords.visitorsMay(link))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                // How far it reaches, then Edit Link and Add Photos, as an album's header has its reach and Add Photos.
                HeaderStatusRow {
                    Button(action: edit) {
                        Label {
                            Text(AlbumsShareReach.link(link).title)
                        } icon: {
                            AlbumsShareReachIcon(reach: .link(link))
                        }
                    }
                    .accessibilityHint(Text("Edits the link"))
                    HeaderStatusRule()
                    Button("Edit Link", systemImage: "pencil", action: edit)
                    Button("Add Photos", systemImage: "photo.badge.plus", action: addPhotos)
                }
                .buttonStyle(.headerStatus)
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 12)
    }
}
