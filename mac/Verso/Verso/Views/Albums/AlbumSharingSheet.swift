import SwiftUI

/// Sharing an album, one way in, as on Linux (ARCHITECTURE.md, "Verso on the Mac"): one sheet with two pages. People
/// has each member with their picture and role, and for the owner Add People and Stop Sharing; Links has each of the
/// album's links with how far it reaches, until when and its password, Copy Link, Open Link, Edit and Delete, and for
/// the owner Create Link. It opens on Links, as on Linux, or on People from the + beside the album's people.
struct AlbumSharingSheet: View {
    enum Page: Hashable { case people, links }

    @Environment(LibrarySession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State var album: AlbumDetails
    @State var page: Page
    @State private var users: [User] = []
    @State private var selectedUser = ""
    @State private var role = "viewer"
    @State private var busy = false
    @State private var error: String?
    @State private var unavailable = false
    @State private var editingLink: SharedLink?
    @State private var creatingLink = false
    @State private var deletingLink: SharedLink?

    /// Opens on Links, unless `page` says.
    init(album: AlbumDetails, page: Page? = nil) {
        _album = State(initialValue: album)
        _page = State(initialValue: page ?? .links)
    }

    private var owner: Bool { album.isOwner(session.user?.id) }
    private var candidates: [User] {
        users.filter { user in user.id != album.albumOwner?.id && album.albumUsers?.contains(where: { $0.id == user.id }) != true }
    }
    private var links: [SharedLink] { session.sharing.links.filter { $0.album?.id == album.id } }
    private var reach: SharingReach {
        SharingReach.album(people: (album.albumUsers ?? []).filter { $0.role != "owner" }.count, links: links)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("Share “\(album.albumName)”").font(.title2.bold()).lineLimit(1)
                Spacer()
                SharingReachLabel(reach: reach).font(.callout).foregroundStyle(.secondary)
            }
            Picker("Page", selection: $page) {
                Text("People").tag(Page.people)
                Text("Links").tag(Page.links)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 260)
            .frame(maxWidth: .infinity)
            switch page {
            case .people: peoplePage
            case .links: linksPage
            }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 580).disabled(busy)
        .task {
            guard owner else { return }
            do { users = try await session.client.albumUsers() }
            catch {
                if case ImmichError.http(404, _) = error { unavailable = true }
                session.handle(error); self.error = error.localizedDescription
            }
        }
        .sheet(item: $editingLink, onDismiss: { Task { await session.sharing.reload() } }) { link in
            SharedLinkEditor(link: link)
        }
        .sheet(isPresented: $creatingLink, onDismiss: { Task { await session.sharing.reload() } }) {
            SharedLinkEditor(albumID: album.id)
        }
        .confirmationDialog("Delete Link?", isPresented: Binding(get: { deletingLink != nil }, set: { if !$0 { deletingLink = nil } }),
                            titleVisibility: .visible) {
            Button("Delete Link", role: .destructive) {
                guard let link = deletingLink else { return }
                mutate { try await session.client.deleteSharedLink(link.id) }
            }
        } message: { Text("Anyone with the link loses access to the album.") }
    }

    // MARK: People

    private var peoplePage: some View {
        VStack(alignment: .leading, spacing: 12) {
            List {
                if let owner = album.albumOwner {
                    HStack {
                        UserAvatar(user: owner, size: 28)
                        VStack(alignment: .leading) { Text(owner.name); Text(owner.email).font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        Text("Owner").foregroundStyle(.secondary)
                    }
                }
                ForEach((album.albumUsers ?? []).filter { $0.role != "owner" }) { member in
                    HStack {
                        UserAvatar(user: member.user, size: 28)
                        VStack(alignment: .leading) { Text(member.user.name); Text(member.user.email).font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        if owner {
                            Picker("Role", selection: Binding(get: { member.role }, set: { role in
                                mutate { try await session.client.updateAlbumUser(album.id, userID: member.id, role: role) }
                            })) {
                                Text("Viewer").tag("viewer")
                                Text("Editor").tag("editor")
                            }.labelsHidden().frame(width: 105)
                            Button("Stop Sharing", role: .destructive) {
                                mutate { try await session.client.removeAlbumUser(album.id, userID: member.id) }
                            }
                        } else { Text(member.role.capitalized).foregroundStyle(.secondary) }
                    }
                }
            }
            .frame(height: 220)
            if owner && !unavailable {
                HStack {
                    Picker("Add People", selection: $selectedUser) {
                        Text("Choose Someone").tag("")
                        ForEach(candidates) { Text("\($0.name) (\($0.email))").tag($0.id) }
                    }
                    Picker("Role", selection: $role) { Text("Viewer").tag("viewer"); Text("Editor").tag("editor") }
                        .labelsHidden().frame(width: 105)
                    Button("Add") {
                        mutate {
                            try await session.client.addAlbumUser(album.id, userID: selectedUser, role: role)
                            selectedUser = ""
                        }
                    }.disabled(selectedUser.isEmpty)
                }
            }
        }
    }

    // MARK: Links

    private var linksPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            List {
                if links.isEmpty {
                    Text(owner ? "No links yet. Create one to share the album with anyone who has it." : "You have no links to this album.")
                        .foregroundStyle(.secondary)
                }
                ForEach(links) { link in
                    HStack(spacing: 10) {
                        SharingReachIcon(reach: .link(link)).frame(width: 22).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(link.description.flatMap { $0.isEmpty ? nil : $0 } ?? (link.hasPassword ? String(localized: "Link with a password") : String(localized: "Public link")))
                            Group {
                                if link.isExpired { Text("Expired").foregroundStyle(.red) }
                                else if let date = link.expiresAt.flatMap(ImmichDate.parse) { Text("Works until \(date.formatted(date: .abbreviated, time: .omitted))") }
                                else { Text("Never expires") }
                            }
                            .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { Task { await copy(link) } } label: { Image(systemName: "doc.on.doc") }.help("Copy Link")
                        Button { Task { await open(link) } } label: { Image(systemName: "safari") }.help("Open Link")
                        Button { editingLink = link } label: { Image(systemName: "pencil") }.help("Edit Link…")
                        Button(role: .destructive) { deletingLink = link } label: { Image(systemName: "trash") }.help("Delete Link…")
                    }
                    .buttonStyle(.borderless)
                    .padding(.vertical, 2)
                }
            }
            .frame(height: 220)
            if owner && session.sharing.linksAvailable {
                Button { creatingLink = true } label: { Label("Create Link…", systemImage: "plus") }
            }
        }
    }

    private func copy(_ link: SharedLink) async {
        do { SharingClipboard.copy(try await session.client.sharingPublicURL(link)) }
        catch { self.error = error.localizedDescription }
    }

    private func open(_ link: SharedLink) async {
        do { NSWorkspace.shared.open(try await session.client.sharingPublicURL(link)) }
        catch { self.error = error.localizedDescription }
    }

    private func mutate(_ action: @escaping () async throws -> Void) {
        busy = true
        Task {
            defer { busy = false }
            do {
                try await action()
                album = try await session.client.albumDetails(album.id)
                await session.sharing.reload()
                await session.reloadAlbums()
                error = nil
            } catch { session.handle(error); self.error = error.localizedDescription }
        }
    }
}
