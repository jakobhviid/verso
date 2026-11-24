// Sharing an album, one way in, as on the Mac and Linux: one sheet with the people it is shared with and their roles,
// Add People from the server's users, and its links with how far each reaches and until when, to copy, share, change
// or delete, and Create Link. Only the album's owner changes who may see it.

import SwiftUI

struct AlbumSharingSheet: View {
    let session: LibrarySession
    let albumID: String

    @Environment(\.dismiss) private var dismiss
    @State private var album: AlbumDetails?
    @State private var users: [User] = []
    /// The server lists no users to share with, such as when sharing is off for the account.
    @State private var usersUnavailable = false
    @State private var busy = false
    @State private var error: String?
    @State private var creatingLink = false
    @State private var editingLink: SharedLink?
    @State private var deletingLink: SharedLink?
    @State private var copied = false

    private var isOwner: Bool { album?.isOwner(session.user?.id) == true }
    private var links: [SharedLink] { session.sharing.links.filter { $0.album?.id == albumID } }
    private var members: [AlbumMember] { (album?.albumUsers ?? []).filter { $0.role != "owner" } }
    private var candidates: [User] {
        users.filter { user in user.id != album?.albumOwner?.id && !members.contains { $0.id == user.id } }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let album {
                    form(album)
                } else if let error {
                    ContentUnavailableView {
                        Label("Couldn't Load the Album", systemImage: "rectangle.stack.badge.minus")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("Try Again") { Task { await load() } }
                    }
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Share Album")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                if busy {
                    ToolbarItem(placement: .topBarLeading) { ProgressView() }
                }
            }
            .alert("Sharing Failed", isPresented: errorShown) {
                Button("OK") { error = nil }
            } message: {
                Text(error ?? "")
            }
            .confirmationDialog("Delete Link?", isPresented: deletingShown, titleVisibility: .visible, presenting: deletingLink) { link in
                Button("Delete Link", role: .destructive) {
                    change { try await session.client.deleteSharedLink(link.id) }
                }
            } message: { _ in
                Text("Anyone with the link loses access to the album.")
            }
            .sheet(isPresented: $creatingLink, onDismiss: { Task { await session.sharing.reload() } }) {
                SharedLinkForm(session: session, albumID: albumID)
            }
            .sheet(item: $editingLink, onDismiss: { Task { await session.sharing.reload() } }) { link in
                SharedLinkForm(session: session, link: link)
            }
            .sensoryFeedback(.success, trigger: copied)
        }
        .task {
            await load()
            await SharedLinkAddresses.shared.read(session.client)
        }
    }

    private var errorShown: Binding<Bool> {
        Binding(get: { album != nil && error != nil }, set: { shown in if !shown { error = nil } })
    }

    private var deletingShown: Binding<Bool> {
        Binding(get: { deletingLink != nil }, set: { shown in if !shown { deletingLink = nil } })
    }

    private func form(_ album: AlbumDetails) -> some View {
        Form {
            Section {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(album.albumName).font(.headline)
                        Text(SharingReach.album(people: members.count, links: links).title)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    AlbumsShareReachIcon(reach: .album(people: members.count, links: links))
                        .foregroundStyle(.tint)
                }
            }
            peopleSection(album)
            linksSection
        }
        .disabled(busy)
        .refreshable { await load() }
    }

    // MARK: People

    @ViewBuilder private func peopleSection(_ album: AlbumDetails) -> some View {
        Section {
            if let owner = album.albumOwner {
                personRow(owner) {
                    Text("Owner").foregroundStyle(.secondary)
                }
            }
            ForEach(members) { member in
                personRow(member.user) {
                    if isOwner {
                        Picker("Role", selection: roleBinding(member)) {
                            Text("Viewer").tag("viewer")
                            Text("Editor").tag("editor")
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                    } else {
                        Text(member.role == "editor" ? "Editor" : "Viewer").foregroundStyle(.secondary)
                    }
                }
                .swipeActions {
                    if isOwner {
                        Button("Remove", role: .destructive) {
                            change { try await session.client.removeAlbumUser(albumID, userID: member.id) }
                        }
                    }
                }
                .contextMenu {
                    if isOwner {
                        Button("Stop Sharing with \(member.user.name)", systemImage: "person.crop.circle.badge.minus", role: .destructive) {
                            change { try await session.client.removeAlbumUser(albumID, userID: member.id) }
                        }
                    }
                }
            }
            if isOwner && !usersUnavailable {
                NavigationLink {
                    AlbumAddPeopleView(session: session, candidates: candidates) { chosen, role in
                        for user in chosen {
                            try await session.client.addAlbumUser(albumID, userID: user.id, role: role)
                        }
                        await reloadAfterChange()
                    }
                } label: {
                    Label("Add People", systemImage: "person.badge.plus")
                }
                .disabled(candidates.isEmpty)
            }
        } header: {
            Text("People")
        } footer: {
            if isOwner {
                Text("Viewers see the album in Immich and Verso. Editors can also add their photos to it.")
            }
        }
    }

    private func personRow<Trailing: View>(_ user: User, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 12) {
            AlbumsMemberAvatar(user: user, client: session.client, size: 36)
            VStack(alignment: .leading, spacing: 1) {
                Text(user.name)
                Text(user.email)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            Spacer(minLength: 8)
            trailing()
        }
    }

    private func roleBinding(_ member: AlbumMember) -> Binding<String> {
        Binding {
            member.role
        } set: { role in
            guard role != member.role else { return }
            change { try await session.client.updateAlbumUser(albumID, userID: member.id, role: role) }
        }
    }

    // MARK: Links

    @ViewBuilder private var linksSection: some View {
        Section {
            if links.isEmpty {
                Text(noLinks)
                    .foregroundStyle(.secondary)
            }
            ForEach(links) { link in
                linkRow(link)
            }
            if isOwner && session.sharing.linksAvailable {
                Button("Create Link", systemImage: "link.badge.plus") { creatingLink = true }
            }
        } header: {
            Text("Links")
        }
    }

    private var noLinks: String {
        isOwner ? "No links yet. A link lets anyone who has it see the album." : "You have no links to this album."
    }

    private func linkRow(_ link: SharedLink) -> some View {
        let address = SharedLinkAddresses.shared.url(link, client: session.client)
        let expired = link.isExpired
        return HStack(spacing: 12) {
            Button { editingLink = link } label: {
                HStack(spacing: 12) {
                    AlbumsShareReachIcon(reach: .link(link))
                        .foregroundStyle(.tint)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(linkName(link))
                            .foregroundStyle(.primary)
                        Text(SharedLinkWords.expiry(link))
                            .font(.footnote)
                            .foregroundStyle(expired ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    }
                    .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(Text("Edits the link"))
            Button {
                copy(link)
            } label: {
                Label("Copy Link", systemImage: "doc.on.doc")
            }
            .labelStyle(.iconOnly)
            if let address {
                ShareLink(item: address) {
                    Label("Share Link", systemImage: "square.and.arrow.up")
                }
                .labelStyle(.iconOnly)
            }
        }
        .buttonStyle(.borderless)
        .swipeActions {
            Button("Delete", systemImage: "trash", role: .destructive) { deletingLink = link }
            Button("Edit", systemImage: "pencil") { editingLink = link }
        }
        .contextMenu {
            Button("Copy Link", systemImage: "doc.on.doc") { copy(link) }
            if let address {
                ShareLink(item: address) { Label("Share Link", systemImage: "square.and.arrow.up") }
            }
            Button("Edit Link", systemImage: "pencil") { editingLink = link }
            Divider()
            Button("Delete Link", systemImage: "trash", role: .destructive) { deletingLink = link }
        }
    }

    /// A link to the album is named by its description, or by how far it reaches.
    private func linkName(_ link: SharedLink) -> String {
        if let description = link.description, !description.isEmpty { return description }
        return link.hasPassword ? "Link with a password" : "Public link"
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

    // MARK: Loading and changing

    private func load() async {
        do {
            let details = try await session.client.albumDetails(albumID)
            album = details
            session.albumActions.details[albumID] = details
            error = nil
        } catch {
            session.handle(error)
            self.error = error.localizedDescription
            return
        }
        if session.sharing.links.isEmpty { await session.sharing.reload() }
        guard isOwner, users.isEmpty, !usersUnavailable else { return }
        do {
            users = try await session.client.albumUsers()
        } catch ImmichError.http(404, _) {
            usersUnavailable = true
        } catch {
            session.handle(error)
        }
    }

    private func change(_ action: @escaping () async throws -> Void) {
        busy = true
        Task {
            defer { busy = false }
            do {
                try await action()
                await reloadAfterChange()
            } catch {
                session.handle(error)
                self.error = error.localizedDescription
            }
        }
    }

    /// After a change: the album's people, the links, and the albums' list with its sharing.
    private func reloadAfterChange() async {
        if let details = try? await session.client.albumDetails(albumID) {
            album = details
            session.albumActions.details[albumID] = details
        }
        await session.sharing.reload()
        await session.reloadAlbums()
    }
}

/// Choosing people from the server's users to share the album with, and the role they get.
private struct AlbumAddPeopleView: View {
    let session: LibrarySession
    let candidates: [User]
    let add: ([User], String) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var chosen: Set<String> = []
    @State private var role = "viewer"
    @State private var query = ""
    @State private var busy = false
    @State private var error: String?

    private var shown: [User] {
        guard !query.isEmpty else { return candidates }
        return candidates.filter { $0.name.localizedStandardContains(query) || $0.email.localizedStandardContains(query) }
    }

    var body: some View {
        List {
            Section {
                Picker("Role", selection: $role) {
                    Text("Viewer").tag("viewer")
                    Text("Editor").tag("editor")
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            } footer: {
                Text(role == "editor" ? "Editors can see the album and add their photos to it." : "Viewers can see the album.")
            }
            Section {
                ForEach(shown) { user in
                    Button { toggle(user) } label: {
                        HStack(spacing: 12) {
                            AlbumsMemberAvatar(user: user, client: session.client, size: 36)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(user.name).foregroundStyle(.primary)
                                Text(user.email).font(.footnote).foregroundStyle(.secondary)
                            }
                            .lineLimit(1)
                            Spacer(minLength: 8)
                            if chosen.contains(user.id) {
                                Image(systemName: "checkmark")
                                    .fontWeight(.semibold)
                                    .foregroundStyle(.tint)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(chosen.contains(user.id) ? .isSelected : [])
                }
            }
        }
        .overlay {
            if candidates.isEmpty {
                ContentUnavailableView("No One to Add", systemImage: "person.2",
                                       description: Text("Everyone on the server can already see the album."))
            } else if shown.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
        .searchable(text: $query, prompt: "Name or Email")
        .navigationTitle("Add People")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if busy {
                    ProgressView()
                } else {
                    Button("Add") { Task { await addChosen() } }
                        .disabled(chosen.isEmpty)
                }
            }
        }
        .alert("Couldn't Add People", isPresented: Binding(get: { error != nil }, set: { shown in if !shown { error = nil } })) {
            Button("OK") { error = nil }
        } message: {
            Text(error ?? "")
        }
    }

    private func toggle(_ user: User) {
        if chosen.contains(user.id) { chosen.remove(user.id) } else { chosen.insert(user.id) }
    }

    private func addChosen() async {
        busy = true
        defer { busy = false }
        do {
            try await add(candidates.filter { chosen.contains($0.id) }, role)
            dismiss()
        } catch {
            session.handle(error)
            self.error = error.localizedDescription
        }
    }
}
