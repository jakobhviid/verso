// The pages Collections opens that no other area of the iOS app has: Tags, Folders and Duplicates, as the Mac's
// Explore and Utilities have them, and the Locked Folder (CollectionsLockedFolderPage.swift). Each is a `Route`
// (`.collections`), and their photos open as `Route.photos` in AssetGridPage, which opens the viewer.

import SwiftUI

/// The pages of Collections' own that are not a grid of photos, as `Route.collections` pushes them.
enum CollectionsRoute: Hashable {
    case tags
    case folders
    /// A folder with subfolders: its own photos first, then the subfolders.
    case folder(ExploreFolderNode)
    case duplicates
    case lockedFolder
}

/// The page a Collections route leads to.
struct CollectionsRouteDestination: View {
    let session: LibrarySession
    let route: CollectionsRoute

    var body: some View {
        switch route {
        case .tags: CollectionsTagsPage(session: session)
        case .folders: CollectionsFoldersPage(session: session)
        case .folder(let folder):
            CollectionsFolderList(session: session, nodes: folder.children ?? [], folder: folder)
                .navigationTitle(folder.name)
        case .duplicates: CollectionsDuplicatesPage(session: session)
        case .lockedFolder: CollectionsLockedFolderPage(session: session)
        }
    }
}

/// Every tag, by its full name, each opening its photos.
struct CollectionsTagsPage: View {
    let session: LibrarySession
    @State private var filter = ""

    var body: some View {
        let tags = session.exploreTags.filter { filter.isEmpty || $0.value.localizedCaseInsensitiveContains(filter) }
        List(tags) { tag in
            NavigationLink(value: Route.photos(.explore(.tag(tag.id)), title: tag.value)) {
                Label { Text(verbatim: tag.value) } icon: { Image(systemName: "tag") }
            }
        }
        .overlay {
            if session.exploreTags.isEmpty {
                ContentUnavailableView("No Tags", systemImage: "tag", description: Text("Tags you give photos in Immich show here."))
            } else if tags.isEmpty {
                ContentUnavailableView.search(text: filter)
            }
        }
        .searchable(text: $filter, prompt: "Find a Tag")
        .navigationTitle("Tags")
        .refreshable { await session.loadExploreTags(refresh: true) }
    }
}

/// The folders the library's originals sit in, as Immich's Folders view has them.
struct CollectionsFoldersPage: View {
    let session: LibrarySession
    @State private var roots: [ExploreFolderNode]?
    @State private var error: String?

    var body: some View {
        Group {
            if let roots {
                CollectionsFolderList(session: session, nodes: roots, folder: nil)
            } else if let error {
                ContentUnavailableView("Folders Unavailable", systemImage: "folder", description: Text(error))
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Folders")
        .task(id: session.services.reconnections) { await load() }
    }

    private func load() async {
        do {
            roots = ExploreFolderNode.tree(try await session.client.explorePaths())
            error = nil
        } catch {
            session.handle(error)
            if roots == nil { self.error = error.localizedDescription }
        }
    }
}

/// A folder's subfolders, and its own photos first when it has subfolders.
private struct CollectionsFolderList: View {
    let session: LibrarySession
    let nodes: [ExploreFolderNode]
    let folder: ExploreFolderNode?

    var body: some View {
        List {
            if let folder {
                NavigationLink(value: Route.photos(.explore(.folder(folder.id)), title: folder.name)) {
                    Label("Photos in This Folder", systemImage: "photo.on.rectangle")
                }
            }
            ForEach(nodes) { node in
                NavigationLink(value: node.children == nil ? Route.photos(.explore(.folder(node.id)), title: node.name)
                               : Route.collections(.folder(node))) {
                    Label { Text(verbatim: node.name) } icon: { Image(systemName: "folder") }
                }
            }
        }
        .overlay {
            if nodes.isEmpty && folder == nil {
                ContentUnavailableView("No Folders", systemImage: "folder")
            }
        }
    }
}

/// Immich's duplicate groups, as the Mac's Duplicates page: each group's photos, those to keep ticked (Immich's
/// suggestion at first), then Keep Selected, which moves the others to Recently Deleted, or Not Duplicates.
struct CollectionsDuplicatesPage: View {
    let session: LibrarySession
    @State private var groups: [AssetsDuplicate]?
    @State private var keep: [String: Set<String>] = [:]
    @State private var busy = false
    @State private var error: String?
    /// The group whose action waits for its confirmation, and whether it is Not Duplicates.
    @State private var pending: AssetsDuplicate?
    @State private var dismissing = false
    @AppStorage("duplicates.sortBy") private var sortBy = DuplicatesSortBy.server

    var body: some View {
        Group {
            if let groups, !groups.isEmpty {
                List {
                    ForEach(sortBy.sorted(groups)) { group in
                        Section {
                            groupPhotos(group)
                            Button(session.features.trash ? "Keep Selected, Trash Others" : "Keep Selected, Delete Others") {
                                dismissing = false
                                pending = group
                            }
                            .disabled(keep[group.id, default: []].isEmpty || keep[group.id]?.count == group.assets.count)
                            Button("Not Duplicates") {
                                dismissing = true
                                pending = group
                            }
                        } header: {
                            Text("\(group.assets.count) similar items")
                        }
                    }
                }
            } else if groups != nil || error != nil {
                ContentUnavailableView(error ?? String(localized: "No Duplicates"), systemImage: "square.on.square")
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Duplicates")
        .disabled(busy)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Sort By", selection: $sortBy) {
                        ForEach(DuplicatesSortBy.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }
            }
        }
        .task { await load() }
        .refreshable { await load() }
        .confirmationDialog(dialogTitle, isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                            titleVisibility: .visible, presenting: pending) { group in
            Button(dismissing ? "Not Duplicates" : (session.features.trash ? "Trash Others" : "Delete Permanently"),
                   role: dismissing ? nil : .destructive) {
                Task { await act(on: group, dismissing: dismissing) }
            }
        } message: { _ in
            Text(dismissing ? "All items remain in your library and will no longer be suggested as this duplicate group."
                 : session.features.trash ? "Selected items stay in your library. The other items are moved to Recently Deleted."
                 : "Selected items stay in your library. The other items are permanently deleted. This cannot be undone.")
        }
        .alert("Duplicates", isPresented: Binding(get: { error != nil && groups?.isEmpty == false }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: {
            Text(error ?? "")
        }
    }

    private var dialogTitle: String {
        if dismissing { return String(localized: "Dismiss this duplicate group?") }
        return session.features.trash ? String(localized: "Move unselected items to Recently Deleted?")
            : String(localized: "Permanently delete unselected items?")
    }

    /// The group's photos in a row, each with its size; a tap ticks it to keep or not.
    private func groupPhotos(_ group: AssetsDuplicate) -> some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(group.assets) { asset in
                    let kept = keep[group.id, default: []].contains(asset.id)
                    Button {
                        if kept { keep[group.id, default: []].remove(asset.id) } else { keep[group.id, default: []].insert(asset.id) }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            CollectionsThumbnail(pipeline: session.pipeline, assetID: asset.id)
                                .frame(width: 120, height: 120)
                                .clipShape(.rect(cornerRadius: 8))
                                .overlay(alignment: .bottomTrailing) {
                                    Image(systemName: kept ? "checkmark.circle.fill" : "circle")
                                        .font(.title2)
                                        .foregroundStyle(kept ? AnyShapeStyle(.tint) : AnyShapeStyle(.white))
                                        .background(Circle().fill(kept ? .white : .black.opacity(0.25)).padding(2))
                                        .padding(6)
                                }
                            Text(verbatim: asset.originalFileName)
                                .font(.caption)
                                .lineLimit(1)
                            Text(asset.exifInfo?.fileSizeInByte.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
                                 ?? String(localized: "Size unavailable"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(width: 120, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(verbatim: asset.originalFileName))
                    .accessibilityValue(kept ? Text("Keep") : Text("Remove"))
                }
            }
            .padding(.vertical, 4)
        }
        .scrollIndicators(.hidden)
    }

    private func load() async {
        do {
            let loaded = try await session.client.assetsDuplicates()
            for group in loaded where keep[group.id] == nil {
                keep[group.id] = group.keptAtFirst
            }
            groups = loaded
            error = nil
        } catch ImmichError.http(404, _) {
            groups = []
            error = String(localized: "Duplicates are unavailable on this server.")
        } catch {
            session.handle(error)
            self.error = error.localizedDescription
        }
    }

    private func act(on group: AssetsDuplicate, dismissing: Bool) async {
        busy = true
        defer { busy = false }
        do {
            if dismissing {
                try await session.client.assetsDismissDuplicate(group.id)
            } else {
                try await session.client.assetsResolveDuplicate(group, keep: keep[group.id, default: []])
            }
            session.invalidateGrids()
            await session.reloadAlbums()
            groups?.removeAll { $0.id == group.id }
            keep[group.id] = nil
        } catch {
            session.handle(error)
            self.error = error.localizedDescription
        }
    }
}
