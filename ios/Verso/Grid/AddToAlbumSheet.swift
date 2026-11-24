// Add to Album on iOS: a sheet of the albums one may add to, most recently changed first, each with its cover, a search
// field that narrows them by name, and New Album at the top, as Photos' own sheet has it. The photo menu's Add To opens
// it for the account's own albums that are not shared (Album…) or for the albums shared with people that it may add to
// (Shared Album…: its own, and others' where it is an editor, as Immich's viewers cannot add). A tap adds the photos and
// closes the sheet; the album's grid and the albums read again (AlbumsActions), as on the Mac.

import SwiftUI

struct AddToAlbumSheet: View {
    /// Which albums it lists.
    enum Albums {
        /// Every album the account may add to.
        case all
        /// The account's own albums that are not shared.
        case own
        /// Albums shared with people that the account may add to.
        case shared
    }

    let session: LibrarySession
    let ids: [String]
    var albums: Albums = .all
    /// Called with the album's name once the photos are on their way into it, new or not.
    let onAdded: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var naming = false
    @State private var newName = ""
    @State private var creating = false
    @State private var errorMessage: String?

    private var listed: [Album] {
        let userID = session.user?.id
        let editable = session.albums.filter { album in
            switch albums {
            case .all: album.canEdit(userID)
            case .own: !album.shared && (album.albumOwner.map { $0.id == userID } ?? true)
            case .shared: album.shared && album.canEdit(userID)
            }
        }
        let words = query.trimmingCharacters(in: .whitespaces)
        return words.isEmpty ? editable : editable.filter { $0.albumName.localizedStandardContains(words) }
    }

    private var title: String {
        if albums == .shared {
            return ids.count == 1 ? "Add 1 Item to a Shared Album" : "Add \(ids.count) Items to a Shared Album"
        }
        return ids.count == 1 ? "Add 1 Item to an Album" : "Add \(ids.count) Items to an Album"
    }

    var body: some View {
        let albums = listed
        NavigationStack {
            List {
                // A new shared album is Add To's New Shared Album, which goes on to its sharing.
                if query.isEmpty, self.albums != .shared {
                    Section {
                        Button {
                            newName = ""
                            naming = true
                        } label: {
                            Label("New Album", systemImage: "plus.rectangle.on.rectangle")
                        }
                        .disabled(creating)
                    }
                }
                Section {
                    ForEach(albums) { album in
                        Button { add(to: album) } label: { row(album) }
                            .buttonStyle(.plain)
                    }
                } footer: {
                    if albums.isEmpty {
                        Text(query.isEmpty ? "No albums to add to." : "No album named \u{201C}\(query)\u{201D}.")
                    }
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search Albums")
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark", role: .cancel) { dismiss() }
                }
            }
            .alert("New Album", isPresented: $naming) {
                TextField("Title", text: $newName)
                Button("Cancel", role: .cancel) {}
                Button("Save") { createAlbum() }
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            } message: {
                Text("Enter a name for this album.")
            }
            .alert("Can't Create the Album", isPresented: errorShown) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private var errorShown: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { shown in if !shown { errorMessage = nil } })
    }

    /// An album: its cover, its name and how many items it holds.
    private func row(_ album: Album) -> some View {
        HStack(spacing: 12) {
            GridThumbnailImage(pipeline: session.pipeline, assetID: album.albumThumbnailAssetId)
                .frame(width: 52, height: 52)
                .clipShape(.rect(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(album.albumName)
                    .lineLimit(1)
                Text(album.assetCount == 1 ? "1 item" : "\(album.assetCount) items")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if album.shared {
                Image(systemName: "person.2.fill")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Shared")
            }
        }
        .contentShape(Rectangle())
    }

    private func add(to album: Album) {
        let ids = ids
        let session = session
        let albumID = album.id
        session.albumActions.perform(session: session, albumID: albumID) {
            try await session.client.changeAlbumAssets(albumID, ids: ids)
        }
        onAdded(album.albumName)
        dismiss()
    }

    private func createAlbum() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let ids = ids
        let session = session
        creating = true
        Task {
            do {
                _ = try await session.client.createAlbum(name: name, assetIDs: ids)
                await session.reloadAlbums()
                onAdded(name)
                dismiss()
            } catch {
                session.handle(error)
                errorMessage = error.localizedDescription
            }
            creating = false
        }
    }
}

/// The account's album sheets for the window, as the Mac's AlbumPresentation has them: Add to Album for the photos in
/// `AlbumsActions.choosing`, and New Album (`creating`) with the photos given to `newAlbum(ids:model:)`, if any. Adding
/// ends the selection the photos came from; a new album opens through `navigationAlbumID`, as on the Mac.
struct GridAlbumActionsPresentation: ViewModifier {
    let session: LibrarySession
    let chrome: LibraryChrome

    func body(content: Content) -> some View {
        @Bindable var actions = session.albumActions
        content
            .sheet(item: $actions.choosing) { choice in
                AddToAlbumSheet(session: session, ids: choice.ids) { _ in chrome.finishSelection(of: choice.model) }
            }
            .sheet(isPresented: $actions.creating) {
                GridNewAlbumSheet(session: session)
            }
    }
}

/// New Album: its name and description, in a sheet of iOS's own; the photos it was asked with go into it.
struct GridNewAlbumSheet: View {
    let session: LibrarySession
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var description = ""
    @State private var busy = false
    @State private var errorMessage: String?
    @FocusState private var nameFocused: Bool

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        let count = session.albumActions.initialAssetIDs.count
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $name)
                        .focused($nameFocused)
                        .submitLabel(.done)
                        .onSubmit(create)
                    TextField("Description", text: $description, axis: .vertical)
                        .lineLimit(2...6)
                } footer: {
                    if count > 0 {
                        Text(count == 1 ? "The item selected goes into the new album." : "The \(count) items selected go into the new album.")
                    }
                }
                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("New Album")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark", role: .cancel) { dismiss() }
                        .disabled(busy)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create", systemImage: "checkmark", role: .confirm, action: create)
                        .disabled(busy || trimmedName.isEmpty)
                }
            }
            .disabled(busy)
        }
        .interactiveDismissDisabled(busy)
        .onAppear { nameFocused = true }
    }

    private func create() {
        let title = trimmedName
        guard !title.isEmpty, !busy else { return }
        let actions = session.albumActions
        let ids = actions.initialAssetIDs
        let text = description.trimmingCharacters(in: .whitespacesAndNewlines)
        busy = true
        errorMessage = nil
        Task {
            do {
                let album = try await session.client.createAlbum(name: title, description: text.isEmpty ? nil : text, assetIDs: ids)
                await session.reloadAlbums()
                actions.didCreate(album.id)
                dismiss()
            } catch {
                session.handle(error)
                errorMessage = error.localizedDescription
            }
            busy = false
        }
    }
}
