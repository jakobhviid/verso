import SwiftUI

/// Add to Album…: a small sheet with a search field and the albums under it, as Mail's Move to… and Notes' move panel
/// are, since a submenu of every album grows too long to use (ARCHITECTURE.md, "Verso on the Mac"). The albums one may
/// add to, most recently changed first; typing narrows them by name, the first match marked; ↓ and ↑ move the mark,
/// Return adds to the marked album, a click adds to the one clicked, and Escape cancels. New Album with Selection… is
/// at its foot.
struct AlbumChooser: View {
    @Environment(LibrarySession.self) private var session
    @Environment(\.dismiss) private var dismiss
    let choice: AlbumChoice
    @State private var query = ""
    @State private var marked: String?
    @FocusState private var searching: Bool

    private var albums: [Album] {
        let editable = session.albums.filter { $0.canEdit(session.user?.id) }
        let words = query.trimmingCharacters(in: .whitespaces)
        return words.isEmpty ? editable : editable.filter { $0.albumName.localizedStandardContains(words) }
    }

    private var title: String {
        choice.ids.count == 1 ? String(localized: "Add 1 Photo to an Album") : String(localized: "Add \(choice.ids.count) Photos to an Album")
    }

    var body: some View {
        let albums = albums
        VStack(spacing: 0) {
            Text(title).font(.headline).padding(.top, 16).padding(.bottom, 10)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search Albums", text: $query)
                    .textFieldStyle(.plain)
                    .focused($searching)
                    .onSubmit { if let marked { add(to: marked) } }
                    .onKeyPress(.downArrow) { move(1, in: albums); return .handled }
                    .onKeyPress(.upArrow) { move(-1, in: albums); return .handled }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .padding(.horizontal, 16)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(albums) { album in
                            row(album).id(album.id)
                        }
                    }
                    .padding(8)
                    if albums.isEmpty {
                        Text(query.isEmpty ? "No albums to add to." : "No album named “\(query)”.")
                            .foregroundStyle(.secondary).padding(30)
                    }
                }
                .onChange(of: marked) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
            }
            .frame(minHeight: 320)
            Divider()
            HStack {
                Button("New Album with Selection…") { newAlbum() }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add") { if let marked { add(to: marked) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(marked == nil)
            }
            .padding(12)
        }
        .frame(width: 440, height: 540)
        .onAppear {
            searching = true
            marked = albums.first?.id
        }
        .onChange(of: query) { marked = self.albums.first?.id }
    }

    /// An album: its cover, its name and how many, marked as the one Return adds to.
    private func row(_ album: Album) -> some View {
        let isMarked = album.id == marked
        return HStack(spacing: 10) {
            RemoteThumbnail(pipeline: session.pipeline, assetID: album.albumThumbnailAssetId)
                .frame(width: 36, height: 36)
                .clipShape(.rect(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 1) {
                Text(album.albumName).lineLimit(1)
                Text(album.assetCount == 1 ? String(localized: "1 item") : String(localized: "\(album.assetCount) items"))
                    .font(.caption)
                    .foregroundStyle(isMarked ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.secondary))
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(isMarked ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(isMarked ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.clear),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { add(to: album.id) }
        .onHover { if $0 { marked = album.id } }
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { add(to: album.id) }
    }

    private func move(_ step: Int, in albums: [Album]) {
        guard !albums.isEmpty else { return }
        let index = albums.firstIndex { $0.id == marked } ?? (step > 0 ? -1 : albums.count)
        marked = albums[min(max(index + step, 0), albums.count - 1)].id
    }

    private func add(to albumID: String) {
        let ids = choice.ids
        session.albumActions.perform(session: session, albumID: albumID) {
            try await session.client.changeAlbumAssets(albumID, ids: ids)
        }
        dismiss()
    }

    private func newAlbum() {
        let ids = choice.ids
        let model = choice.model
        let actions = session.albumActions
        dismiss()
        // One sheet at a time: the new album's opens once this one has gone.
        Task {
            try? await Task.sleep(for: .milliseconds(350))
            actions.newAlbum(ids: ids, model: model)
        }
    }
}
