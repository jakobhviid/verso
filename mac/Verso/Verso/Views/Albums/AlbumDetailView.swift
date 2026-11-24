import SwiftUI

struct AlbumDetailView: View {
    @Environment(LibrarySession.self) private var session
    @Environment(\.dismiss) private var dismiss
    let id: String
    var onClose: (() -> Void)?
    @State private var album: AlbumDetails?
    @State private var error: String?
    @State private var editing = false
    /// The Share sheet, on its own page, or on the one about the album's reach when nil.
    @State private var sharing: SharingRequest?
    @State private var deleting = false
    @State private var leaving = false
    @State private var showActivity = false
    @State private var removed = false
    @State private var adding = false
    @AppStorage(AlbumOrders.storageKey) private var storedOrders = "{}"

    private var model: AssetGridModel { session.gridModel(for: .album(id)) }

    var body: some View {
        Group {
            if removed {
                ContentUnavailableView("Album Closed", systemImage: "rectangle.stack")
            } else if let album {
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        // As in Immich, the album's header is where it is named, described and shared; it scrolls away
                        // with the photos, and the toolbar shows the name once it has.
                        AssetGridContainer(source: .album(id), title: Text(verbatim: album.albumName), headerScrolls: true) {
                            header(album)
                        }
                        // A grid of its own for each order, which opens at its top: the first photo of the order.
                        .id(model.albumOrder)
                        .environment(\.gridEmptyAddPhotos, album.canEdit(session.user?.id) ? GridAddPhotos(id: id) { adding = true } : nil)
                .environment(\.gridPageControls, pageControls(album))
                        if showActivity && album.shared && album.isActivityEnabled == true {
                            Divider()
                            AlbumActivityPanel(album: album, assetID: model.viewerID)
                                .id(model.viewerID ?? "album")
                                .frame(width: 280)
                                .transition(.move(edge: .trailing).combined(with: .opacity))
                        }
                    }
                }

            } else if let error {
                ContentUnavailableView { Label("Couldn't Load Album", systemImage: "rectangle.stack.badge.minus") }
                description: { Text(error) } actions: { Button("Try Again") { Task { await load() } } }
                .pageToolbar("albumError")
            } else { ProgressView().pageToolbar("albumLoading") }
        }
        // Files dropped on the page join the album, and File > Import… adds to it, for those who may add; on an album
        // they may only view, a drop is refused rather than falling to the library, and Import… imports to the library.
        .modifier(UploadDropModifier(queue: session.upload, albumID: id,
                                     viewOnly: album.flatMap { $0.canEdit(session.user?.id) ? nil : $0.albumName })) // Upload
        .focusedSceneValue(\.importAlbum, album.flatMap { $0.canEdit(session.user?.id) ? ImportAlbum(id: id, name: $0.albumName) : nil })
        .task(id: id) { await load() }
        .onChange(of: session.albumActions.revisions[id, default: 0]) {
            guard !removed else { return }
            Task { await load(); await model.reload() }
        }
        .sheet(isPresented: $editing) {
            if let album {
                AlbumNameSheet(title: "Edit Album", name: album.albumName, description: album.description ?? "") { name, description in
                    self.album = try await session.client.updateAlbum(id, AlbumUpdate(albumName: name, description: description))
                    session.albumActions.details[id] = self.album
                    await session.reloadAlbums()
                }
            }
        }
        .sheet(isPresented: $adding) {
            // The album's own photos are not listed in its details, so the picker dims none; adding one already
            // there is no failure.
            PhotoPicker(title: String(localized: "Add Photos to “\(album?.albumName ?? "")”")) { ids in
                try await session.client.changeAlbumAssets(id, ids: ids)
                session.invalidateAlbumGrid(id)
                session.albumActions.revisions[id, default: 0] += 1
                await session.reloadAlbums()
            }
        }
        .sheet(item: $sharing, onDismiss: { Task { await load() } }) { request in
            if let album { AlbumSharingSheet(album: album, page: request.page) }
        }
        .confirmationDialog("Delete Album?", isPresented: $deleting, titleVisibility: .visible) {
            Button("Delete Album", role: .destructive) { closeAlbum(leaving: false) }
        } message: { Text("The album will be deleted for everyone. Its photos and videos stay in the library.") }
        .confirmationDialog("Leave Album?", isPresented: $leaving, titleVisibility: .visible) {
            Button("Leave Album", role: .destructive) { closeAlbum(leaving: true) }
        } message: { Text("You will lose access to this album until the owner invites you again.") }
        .alert("Album Error", isPresented: Binding(get: { album != nil && error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }

    /// The album's actions, in a toolbar menu of their own beside the photos' controls: what Immich puts in its
    /// album page's menu.
    /// What matters less on this page, in the top bar's Album menu (DESIGN.md, "The toolbar's places").
    private func albumMenu(_ album: AlbumDetails) -> some View {
        let isOwner = album.isOwner(session.user?.id)
        let isMember = album.albumUsers?.contains(where: { $0.id == session.user?.id }) == true
        return Menu {
            Button("Download Album as ZIP…") { AssetsDownloader.start(album: album.id, session: session) }
            if isOwner, album.isActivityEnabled != nil {
                Toggle("Comments and Likes", isOn: Binding(get: { album.isActivityEnabled == true },
                                                           set: { update(AlbumUpdate(isActivityEnabled: $0)) }))
            }
            if isOwner || isMember {
                Divider()
                if isOwner {
                    Button("Delete Album…", role: .destructive) { deleting = true }
                } else {
                    Button("Leave Album…", role: .destructive) { leaving = true }
                }
            }
        } label: { Label("Album", systemImage: "rectangle.stack") }
        .menuIndicator(.hidden)
        .help("Album")
    }

    /// The album's own top bar items, after the zoom in a box of their own: its order, its comments shown or not, and
    /// its menu.
    private func pageControls(_ album: AlbumDetails) -> GridPageControls {
        let isOwner = album.isOwner(session.user?.id)
        let comments = album.shared && album.isActivityEnabled == true
        let key = [album.id, AlbumOrders.order(of: album, stored: storedOrders), String(isOwner), String(comments),
                   String(showActivity), String(album.isActivityEnabled == true)].joined(separator: "|")
        return GridPageControls(key: key, view: AnyView(HStack(spacing: 0) {
            sortMenu(album, isOwner: isOwner)
            if comments {
                Toggle(isOn: $showActivity.animation(.smooth(duration: 0.3))) {
                    Label("Comments", systemImage: "bubble.left.and.bubble.right")
                }
                .help(showActivity ? "Hide Comments" : "Show Comments")
            }
            albumMenu(album)
        }))
    }

    /// The album's order, in the top bar as sorting always is: its owner's, kept on the server for everyone who sees
    /// it, or anyone else's, on this Mac for this album alone (AlbumOrders).
    private func sortMenu(_ album: AlbumDetails, isOwner: Bool) -> some View {
        let order = Binding {
            AlbumOrders.order(of: album, stored: storedOrders)
        } set: { order in
            guard order != AlbumOrders.order(of: album, stored: storedOrders) else { return }
            if isOwner {
                storedOrders = AlbumOrders.choosing(nil, for: album, in: storedOrders)
                update(AlbumUpdate(order: order))
            } else {
                storedOrders = AlbumOrders.choosing(order, for: album, in: storedOrders)
                model.albumOrder = order
                Task { await model.reload() }
            }
        }
        return Menu {
            Picker("Sort", selection: order) {
                Text("Newest First").tag(AlbumOrders.newestFirst)
                Text("Oldest First").tag(AlbumOrders.oldestFirst)
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: { Label("Sort", systemImage: "arrow.up.arrow.down") }
        .menuIndicator(.hidden)
        .help("Sort Photos")
    }

    /// What the album is, and under it a row of its statuses and actions (DESIGN.md, "The apps' interfaces"): how far it
    /// reaches, its state named, which opens the Share sheet, with whom it is shared just beside it; then changing it
    /// (Add Photos, Edit).
    private func header(_ album: AlbumDetails) -> some View {
        let isOwner = album.isOwner(session.user?.id)
        return VStack(alignment: .leading, spacing: 10) {
            headerText(album)
            HStack(spacing: 4) {
                Button { sharing = SharingRequest(page: nil) } label: { SharingReachLabel(reach: reach(album)) }
                    .help("Share…")
                members(album, isOwner: isOwner)
                Divider().frame(height: 18).padding(.horizontal, 8)
                if album.canEdit(session.user?.id) {
                    Button { adding = true } label: { Label("Add Photos", systemImage: "photo.badge.plus") }
                        .help("Add Photos…")
                }
                if isOwner {
                    Button { editing = true } label: { Label("Edit", systemImage: "pencil") }
                        .help("Edit the album's name and description")
                }
            }
            .buttonStyle(.headerStatus)
            .padding(.leading, -8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 12)
    }

    /// Immich's album header: the name and description, the dates and count, and who the album is shared with. The
    /// name and description are text, changed with Edit (AlbumActionsView), not in place: a field there took the keys
    /// the grid answers (Space, the arrows) while one typed, and the page has the Edit button for them.
    private func headerText(_ album: AlbumDetails) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: album.albumName)
                .font(.largeTitle.bold())
            HStack(spacing: 6) {
                Text("\(album.assetCount) items")
                if let start = album.startDate.flatMap(ImmichDate.parse) {
                    Text(verbatim: "·")
                    Text(start, style: .date)
                    if let end = album.endDate.flatMap(ImmichDate.parse), end != start { Text("–"); Text(end, style: .date) }
                }
            }
            .font(.callout).foregroundStyle(.secondary)
            if let description = album.description, !description.isEmpty {
                Text(verbatim: description)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: 640, alignment: .leading)
            }
        }
    }

    /// The owner and the people the album is shared with, and, for the owner, a button to share it with more.
    private func members(_ album: AlbumDetails, isOwner: Bool) -> some View {
        let owner = album.albumOwner
        let others = (album.albumUsers ?? []).filter { $0.user.id != owner?.id }.map(\.user)
        return HStack(spacing: 6) {
            ForEach([owner].compactMap { $0 } + others) { user in
                UserAvatar(user: user, size: 26)
                    .help(user.id == owner?.id ? Text("\(user.name) (owner)") : Text(verbatim: user.name))
                    .accessibilityLabel(Text(verbatim: user.name))
            }
            if isOwner {
                Button { sharing = SharingRequest(page: .people) } label: {
                    Image(systemName: "plus").font(.callout.weight(.semibold))
                        .frame(width: 26, height: 26)
                        .background(.quaternary, in: Circle())
                }
                .buttonStyle(.plain)
                .help("Share with People…")
                .accessibilityLabel("Share with People…")
            }
        }
        .padding(.top, 2)
    }

    private func reach(_ album: AlbumDetails) -> SharingReach {
        SharingReach.album(people: (album.albumUsers ?? []).filter { $0.role != "owner" }.count,
                           links: session.sharing.links.filter { $0.album?.id == album.id })
    }

    private func load() async {
        do {
            let detail = try await session.client.albumDetails(id)
            // This Mac's order for the album, else its owner's.
            let order = AlbumOrders.order(of: detail, stored: storedOrders)
            if model.albumOrder != order { model.markStale() }
            model.albumOrder = order
            session.albumActions.details[id] = detail
            album = detail
            error = nil
        } catch { session.handle(error); self.error = error.localizedDescription }
    }

    private func update(_ update: AlbumUpdate) {
        Task {
            do {
                album = try await session.client.updateAlbum(id, update)
                session.albumActions.details[id] = album
                model.albumOrder = album.map { AlbumOrders.order(of: $0, stored: storedOrders) } ?? AlbumOrders.newestFirst
                await model.reload()
                await session.reloadAlbums()
            } catch { session.handle(error); self.error = error.localizedDescription }
        }
    }

    private func closeAlbum(leaving: Bool) {
        Task {
            do {
                if leaving { try await session.client.removeAlbumUser(id, userID: "me") }
                else { try await session.client.deleteAlbum(id) }
                removed = true
                session.discardAlbumGrid(id)
                await session.reloadAlbums()
                if let onClose { onClose() } else { dismiss() }
            } catch { session.handle(error); self.error = error.localizedDescription }
        }
    }
}

/// The Share sheet asked for, on a page of its own or on the one about the album's reach.
struct SharingRequest: Identifiable {
    let id = UUID()
    let page: AlbumSharingSheet.Page?
}
