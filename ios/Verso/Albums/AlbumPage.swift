// One album on iOS: its photos in the grid (AssetGridPage), edge to edge under the glass, its name the large title in
// the bar's row, and above the photos its header, drawn as the Mac's (mac/Verso/Verso/Views/Albums/AlbumDetailView.swift):
// how many and the days they span, the description, written in place by the owner, and a row of statuses and actions
// (HeaderStatus.swift): how far it reaches, which opens its sharing, with the owner and the people it is shared with
// as faces; its comments and likes where it has them; then Add Photos. The header leaves the name to the title, which
// stays in view as the photos scroll. The album's menu in the toolbar sorts it, newest or oldest first, for anyone
// (AlbumOrders: its owner's order on the server, anyone else's on this device), and the page opens at the first photo
// of its order; for its owner it renames it, chooses its cover, turns its comments and likes on or off, and deletes it;
// for the people it is shared with it leaves it.

import SwiftUI

struct AlbumPage: View {
    let session: LibrarySession
    let album: Album

    @Environment(\.dismiss) private var dismiss
    @State private var details: AlbumDetails?
    @State private var error: String?
    @State private var sharing = false
    @State private var adding = false
    @State private var choosingCover = false
    @State private var renaming = false
    @State private var newName = ""
    @State private var showingActivity = false
    /// The album's comments and likes, counted, where it has them.
    @State private var activity: AlbumActivityStatistics?
    @State private var deleting = false
    @State private var leaving = false
    /// Deleted or left: the page is on its way out.
    @State private var closed = false
    @AppStorage(AlbumOrders.storageKey) private var storedOrders = "{}"

    private var model: AssetGridModel { session.gridModel(for: .album(album.id)) }
    private var userID: String? { session.user?.id }
    private var isOwner: Bool { details?.isOwner(userID) == true }
    private var isMember: Bool { details?.albumUsers?.contains { $0.id == userID } == true }
    private var name: String { details?.albumName ?? album.albumName }

    var body: some View {
        Group {
            if closed {
                ContentUnavailableView("Album Closed", systemImage: "rectangle.stack")
            } else {
                AssetGridPage(session: session, source: .album(album.id), title: name, header: AnyView(header))
                    // A grid of its own for each order, which opens at its top: the first photo of the order.
                    .id(model.albumOrder)
                    // Photos dropped from another app on an iPad go into the library and the album, where the account
                    // may add to it.
                    .importDrops(queue: session.upload, albumID: album.id, refused: details?.canEdit(userID) != true)
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { albumMenu }
        }
        .task(id: album.id) { await load() }
        // Photos added or taken out elsewhere (Add to Album, Remove from Album): the header's count and dates follow.
        .onChange(of: session.albumActions.revisions[album.id, default: 0]) {
            guard !closed else { return }
            Task { await load() }
        }
        .sheet(isPresented: $sharing, onDismiss: { Task { await load() } }) {
            AlbumSharingSheet(session: session, albumID: album.id)
        }
        .sheet(isPresented: $adding) {
            // The album's own photos are not listed in its details, so the picker dims none; adding one already there
            // is no failure.
            AlbumsPhotoPicker(session: session, title: "Add to \(name)", source: .library) { ids in
                try await session.client.changeAlbumAssets(album.id, ids: ids)
                await photosChanged()
            }
        }
        .sheet(isPresented: $choosingCover) {
            AlbumsPhotoPicker(session: session, title: "Choose Cover", source: .album(album.id), choosesOne: true,
                              confirmTitle: "Choose") { ids in
                guard let cover = ids.first else { return }
                try await apply(AlbumUpdate(albumThumbnailAssetId: cover))
            }
        }
        .sheet(isPresented: $showingActivity, onDismiss: { Task { await loadActivity() } }) {
            if let details { AlbumActivitySheet(session: session, album: details) }
        }
        .alert("Rename Album", isPresented: $renaming) {
            TextField("Title", text: $newName)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, trimmed != name else { return }
                Task { await perform { try await apply(AlbumUpdate(albumName: trimmed)) } }
            }
            .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .confirmationDialog("Delete Album?", isPresented: $deleting, titleVisibility: .visible) {
            Button("Delete Album", role: .destructive) { close(leaving: false) }
        } message: {
            Text("The album will be deleted for everyone. Its photos and videos stay in the library.")
        }
        .confirmationDialog("Leave Album?", isPresented: $leaving, titleVisibility: .visible) {
            Button("Leave Album", role: .destructive) { close(leaving: true) }
        } message: {
            Text("You will no longer see this album until its owner shares it with you again.")
        }
        .alert("Album Error", isPresented: errorShown) {
            Button("OK") { error = nil }
        } message: {
            Text(error ?? "")
        }
    }

    private var errorShown: Binding<Bool> {
        Binding(get: { error != nil }, set: { shown in if !shown { error = nil } })
    }

    // MARK: The header

    private var header: some View {
        AlbumPageHeader(session: session, album: album, details: details, activity: activity,
                        share: { sharing = true }, addPhotos: { adding = true }, showActivity: { showingActivity = true },
                        describe: describe)
    }

    /// Saves the description written in the header.
    private func describe(_ description: String) {
        Task { await perform { try await apply(AlbumUpdate(description: description)) } }
    }

    // MARK: The album's menu

    /// What matters less on the page, in a menu named by its icon (DESIGN.md, "The toolbar's places"); adding photos,
    /// sharing and the description are the header's.
    private var albumMenu: some View {
        Menu {
            Section {
                Picker(selection: orderBinding) {
                    Text("Newest First").tag(AlbumOrders.newestFirst)
                    Text("Oldest First").tag(AlbumOrders.oldestFirst)
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }
                .pickerStyle(.menu)
            }
            if isOwner {
                Section {
                    Button("Rename", systemImage: "pencil") {
                        newName = name
                        renaming = true
                    }
                    Button("Choose Cover", systemImage: "photo") { choosingCover = true }
                        .disabled((details?.assetCount ?? album.assetCount) == 0)
                    if details?.isActivityEnabled != nil {
                        Toggle("Comments and Likes", systemImage: "bubble.left.and.bubble.right", isOn: activityBinding)
                    }
                }
                Section {
                    Button("Delete Album", systemImage: "trash", role: .destructive) { deleting = true }
                }
            } else if isMember {
                Section {
                    Button("Leave Album", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) { leaving = true }
                }
            }
        } label: {
            Label("Album", systemImage: "rectangle.stack")
        }
        .disabled(details == nil || closed)
    }

    /// Whether those it is shared with may comment and like, kept on the server.
    private var activityBinding: Binding<Bool> {
        Binding {
            details?.isActivityEnabled == true
        } set: { enabled in
            Task {
                await perform { try await apply(AlbumUpdate(isActivityEnabled: enabled)) }
                await loadActivity()
            }
        }
    }

    /// The album's order: its owner's, kept on the server for everyone who sees it, or anyone else's, on this device
    /// for this album alone (AlbumOrders).
    private var orderBinding: Binding<String> {
        Binding {
            details.map { AlbumOrders.order(of: $0, stored: storedOrders) } ?? AlbumOrders.newestFirst
        } set: { order in
            guard let details, order != AlbumOrders.order(of: details, stored: storedOrders) else { return }
            if isOwner {
                storedOrders = AlbumOrders.choosing(nil, for: details, in: storedOrders)
                Task { await perform { try await apply(AlbumUpdate(order: order)) } }
            } else {
                storedOrders = AlbumOrders.choosing(order, for: details, in: storedOrders)
                Task { await read(in: order) }
            }
        }
    }

    /// The grid in the album's order, read again where it changed.
    private func read(in order: String) async {
        guard model.albumOrder != order else { return }
        model.albumOrder = order
        await model.reload()
    }

    // MARK: Loading and changing

    private func load() async {
        do {
            let loaded = try await session.client.albumDetails(album.id)
            session.albumActions.details[album.id] = loaded
            details = loaded
            // The grid reads the album in this device's order for it, else its owner's.
            await read(in: AlbumOrders.order(of: loaded, stored: storedOrders))
            await loadActivity()
        } catch {
            guard !error.isCancellation else { return }
            session.handle(error)
            if details == nil { self.error = error.localizedDescription }
        }
    }

    /// How many comments and likes the album has, where it is shared and they are on; nothing where the server
    /// cannot say.
    private func loadActivity() async {
        guard let details, details.shared, details.isActivityEnabled == true else {
            activity = nil
            return
        }
        activity = try? await session.client.albumActivityStatistics(album.id, assetID: nil)
    }

    /// A change to the album itself (its name, description, cover or order), then the page and the albums' list.
    private func apply(_ update: AlbumUpdate) async throws {
        let updated = try await session.client.updateAlbum(album.id, update)
        session.albumActions.details[album.id] = updated
        details = updated
        await read(in: AlbumOrders.order(of: updated, stored: storedOrders))
        await session.reloadAlbums()
    }

    /// Photos joined the album: its grid and its header read again, and every page showing it follows.
    private func photosChanged() async {
        session.invalidateAlbumGrid(album.id)
        await model.reload()
        await load()
        await session.reloadAlbums()
    }

    private func perform(_ action: () async throws -> Void) async {
        do {
            try await action()
        } catch {
            session.handle(error)
            self.error = error.localizedDescription
        }
    }

    private func close(leaving: Bool) {
        Task {
            do {
                if leaving {
                    try await session.client.removeAlbumUser(album.id, userID: "me")
                } else {
                    try await session.client.deleteAlbum(album.id)
                }
                closed = true
                session.discardAlbumGrid(album.id)
                await session.reloadAlbums()
                dismiss()
            } catch {
                session.handle(error)
                self.error = error.localizedDescription
            }
        }
    }
}

/// The album's header above its photos, as the Mac's: how many and the days they span, the description, and a row of
/// statuses and actions (DESIGN.md, "A page header's controls are statuses"). The name is the bar's large title.
private struct AlbumPageHeader: View {
    let session: LibrarySession
    let album: Album
    let details: AlbumDetails?
    let activity: AlbumActivityStatistics?
    let share: () -> Void
    let addPhotos: () -> Void
    let showActivity: () -> Void
    let describe: (String) -> Void

    private var userID: String? { session.user?.id }
    private var isOwner: Bool { details?.isOwner(userID) == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            facts
            AlbumDescriptionField(text: details?.description ?? album.description ?? "", editable: isOwner,
                                  commit: describe)
            statuses
                .padding(.leading, -8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 14)
    }

    /// How many, and the days they span.
    private var facts: some View {
        let count = details?.assetCount ?? album.assetCount
        let counted = count == 1 ? String(localized: "1 item") : String(localized: "\(count.formatted()) items")
        let days = AlbumsDateRange.text(start: details?.startDate ?? album.startDate, end: details?.endDate ?? album.endDate)
        return Text(days.map { "\(counted) · \($0)" } ?? counted)
            .font(.subheadline)
            .foregroundStyle(.secondary)
    }

    /// How far it reaches with whom it is shared beside it, its comments and likes, and then Add Photos.
    private var statuses: some View {
        HeaderStatusRow {
            Button(action: share) {
                Label {
                    Text(reach.title)
                } icon: {
                    AlbumsShareReachIcon(reach: reach)
                }
            }
            .accessibilityHint(Text("Shows whom the album is shared with, and its links"))
            members
            if let activity, details?.shared == true, details?.isActivityEnabled == true {
                Button(action: showActivity) {
                    Label(activityTitle(activity), systemImage: "bubble.left.and.bubble.right")
                }
                .accessibilityHint(Text("Shows the album's comments and likes"))
            }
            if details?.canEdit(userID) == true {
                HeaderStatusRule()
                Button("Add Photos", systemImage: "photo.badge.plus", action: addPhotos)
            }
        }
        .buttonStyle(.headerStatus)
    }

    private func activityTitle(_ activity: AlbumActivityStatistics) -> String {
        var parts: [String] = []
        if activity.comments > 0 {
            parts.append(activity.comments == 1 ? String(localized: "1 comment")
                         : String(localized: "\(activity.comments) comments"))
        }
        if activity.likes > 0 {
            parts.append(activity.likes == 1 ? String(localized: "1 like") : String(localized: "\(activity.likes) likes"))
        }
        return parts.isEmpty ? String(localized: "No Comments") : parts.joined(separator: ", ")
    }

    private var links: [SharedLink] { session.sharing.links.filter { $0.album?.id == album.id } }

    private var reach: AlbumsShareReach {
        if let details {
            return .album(people: (details.albumUsers ?? []).filter { $0.role != "owner" }.count, links: links)
        }
        return .album(album, links: links)
    }

    /// The owner and the people it is shared with, as circles, four and then how many more; for the owner, a plus that
    /// shares it with more. Nothing where the album is the owner's alone and another's to share.
    @ViewBuilder private var members: some View {
        let members = details?.albumUsers ?? album.albumUsers ?? []
        let owner = members.first { $0.role == "owner" }?.user
        let others = members.filter { $0.role != "owner" }.map(\.user)
        let everyone: [User] = [owner].compactMap { $0 } + others
        if !others.isEmpty || isOwner {
            Button(action: share) {
                HStack(spacing: -6) {
                    ForEach(everyone.prefix(4)) { user in
                        AlbumsMemberAvatar(user: user, client: session.client, size: 26)
                            .overlay { Circle().stroke(Color(uiColor: .systemBackground), lineWidth: 1.5) }
                    }
                    if everyone.count > 4 {
                        Text(verbatim: "+\(everyone.count - 4)")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.primary)
                            .frame(width: 26, height: 26)
                            .background(Color(uiColor: .tertiarySystemFill), in: .circle)
                            .overlay { Circle().stroke(Color(uiColor: .systemBackground), lineWidth: 1.5) }
                    }
                    if isOwner {
                        Image(systemName: "plus")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tint)
                            .frame(width: 26, height: 26)
                            .background(Color(uiColor: .tertiarySystemFill), in: .circle)
                            .overlay { Circle().stroke(Color(uiColor: .systemBackground), lineWidth: 1.5) }
                            .padding(.leading, 10)
                    }
                }
                .padding(.vertical, 2)
                .padding(.horizontal, 4)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(everyone.map(\.name).formatted(.list(type: .and))))
            .accessibilityHint(isOwner ? Text("Shares the album with more people") : Text("Shows whom the album is shared with"))
            .accessibilityAddTraits(.isButton)
        }
    }
}

/// An album's description, written where it shows, as Immich's web app and the Mac have it: for the owner a field that
/// is the text itself, "Add a Description" where there is none, saved when the keyboard's Done or a tap elsewhere ends
/// it; for anyone else the text, or nothing.
private struct AlbumDescriptionField: View {
    let text: String
    let editable: Bool
    let commit: (String) -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        if editable {
            TextField("Add a Description", text: $draft, axis: .vertical)
                .font(.body)
                .focused($focused)
                .onAppear { draft = text }
                .onChange(of: text) { _, now in if !focused { draft = now } }
                .onChange(of: focused) { _, now in if !now { finish() } }
                .toolbar {
                    if focused {
                        ToolbarItemGroup(placement: .keyboard) {
                            Spacer()
                            Button("Done") { focused = false }
                        }
                    }
                }
        } else if !text.isEmpty {
            Text(verbatim: text)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Saves the description once it changed; an emptied one clears it.
    private func finish() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = trimmed
        guard trimmed != text else { return }
        commit(trimmed)
    }
}
