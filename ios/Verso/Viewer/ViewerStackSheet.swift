// The stack of the viewer's photo on iOS, opened from its badge under More: the stack's photos in a strip under the one
// chosen, shown large, as Photos shows a burst's photos, with the Mac's actions (AssetsStackBrowser): Set as Cover
// along the bottom, and in More, Remove from Stack, Unstack, and Move Others to Recently Deleted (the shared
// AssetsStackMutation, which reads the stack again first and never deletes for good). Only the owner of every photo in
// it changes a stack, and not in Recently Deleted. When the shown photo was the cover, which stands for the stack in
// the grid, the viewer shows the new cover once it is set (ViewerState.stackChanged).

import SwiftUI

struct ViewerStackSheet: View {
    let state: ViewerState
    let stackID: String
    @Environment(\.dismiss) private var dismiss
    @State private var stack: AssetsStack?
    @State private var selectedID: String?
    @State private var loadError: String?
    @State private var actionError: String?
    @State private var busy = false
    @State private var confirmingUnstack = false
    @State private var confirmingTrash = false
    /// Whether the sheet still shows, read by a change finishing after it has gone.
    @State private var presence = ViewerStackPresence()

    private var session: LibrarySession { state.session }
    private var model: AssetGridModel { state.model }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Stack")
                .navigationSubtitle(stack.map { String(localized: "\($0.assets.count) Photos") } ?? "")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbarContent }
                .confirmationDialog("Unstack \(stack?.assets.count ?? 0) Photos?", isPresented: $confirmingUnstack,
                                    titleVisibility: .visible) {
                    Button("Unstack") { unstack() }
                } message: {
                    Text("All photos remain in your library.")
                }
                .confirmationDialog("Move \(max((stack?.assets.count ?? 1) - 1, 0)) Photos to Recently Deleted?",
                                    isPresented: $confirmingTrash, titleVisibility: .visible) {
                    Button("Move to Recently Deleted", role: .destructive) { trashOthers() }
                } message: {
                    Text("Only the cover stays in the stack. You can restore the others from Recently Deleted.")
                }
                .alert("Can't Change the Stack", isPresented: Binding(get: { actionError != nil },
                                                                      set: { if !$0 { actionError = nil } })) {
                    Button("OK") {}
                } message: {
                    Text(actionError ?? "")
                }
        }
        .task { await firstLoad() }
        .onDisappear { presence.shown = false }
    }

    @ViewBuilder
    private var content: some View {
        if let stack, let selected = stack.assets.first(where: { $0.id == selectedID }) {
            VStack(spacing: 14) {
                ViewerStackPreview(asset: selected, pipeline: session.pipeline)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                strip(stack)
                HStack(spacing: 6) {
                    Text(selected.originalFileName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if selected.id == stack.primaryAssetId {
                        Text("Cover")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.footnote)
                .padding(.horizontal, 16)
            }
            .padding(.vertical, 12)
        } else if let loadError {
            ContentUnavailableView {
                Label("Can't Load the Stack", systemImage: "exclamationmark.triangle")
            } description: {
                Text(loadError)
            }
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func strip(_ stack: AssetsStack) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(stack.assets) { member in
                    Button { selectedID = member.id } label: {
                        ViewerStackTile(asset: member, pipeline: session.pipeline, selected: member.id == selectedID,
                                        cover: member.id == stack.primaryAssetId)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(member.originalFileName))
                    .accessibilityAddTraits(member.id == selectedID ? .isSelected : [])
                }
            }
            .padding(.horizontal, 16)
        }
        .scrollIndicators(.hidden)
        .frame(height: 64)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .confirmationAction) {
            Button(role: .close) { dismiss() }
        }
        ToolbarItem(placement: .bottomBar) {
            Button("Set as Cover") { setCover() }
                .disabled(!canChange || selectedID == nil || selectedID == stack?.primaryAssetId)
        }
        ToolbarSpacer(.flexible, placement: .bottomBar)
        ToolbarItem(placement: .bottomBar) {
            Menu {
                Button("Remove from Stack", systemImage: "rectangle.stack.badge.minus") { removeSelected() }
                    .disabled(selectedID == nil || selectedID == stack?.primaryAssetId)
                Button("Unstack", systemImage: "square.stack.3d.up.slash") { confirmingUnstack = true }
                // Find Similar Photos' way to keep one: the cover stays and the rest go to Recently Deleted, never for
                // good.
                if session.features.trash, model.source != .locked {
                    Button("Move Others to Recently Deleted", systemImage: "trash", role: .destructive) {
                        confirmingTrash = true
                    }
                    .disabled((stack?.assets.count ?? 0) < 2)
                }
            } label: {
                Label("More", systemImage: "ellipsis")
            }
            .disabled(!canChange)
        }
    }

    /// As on the Mac: the owner of every photo in the stack, outside Recently Deleted, while nothing else runs.
    private var canChange: Bool {
        guard let stack, !busy, model.source != .trash, let userID = session.user?.id else { return false }
        return stack.assets.allSatisfy { $0.ownerId == userID }
    }

    // MARK: Loading and changing

    private func firstLoad() async {
        do {
            if try await load() == nil { dismiss() }
        } catch where !error.isCancellation {
            session.handle(error)
            loadError = error.localizedDescription
        } catch {}
    }

    /// Reads the stack again, its photos in or out of the Locked Folder as the grid's are: nil once it has gone
    /// (unstacked, or down to one photo), as Immich then answers that it has none.
    private func load() async throws -> AssetsStack? {
        do {
            let loaded = try await session.client.assetsStack(stackID)
            let locked = model.source == .locked
            let visible = AssetsStack(id: loaded.id, primaryAssetId: loaded.primaryAssetId,
                                      assets: loaded.assets.filter { ($0.visibility == "locked") == locked })
            if presence.shown {
                stack = visible
                if !visible.assets.contains(where: { $0.id == selectedID }) { selectedID = visible.primaryAssetId }
            }
            return visible
        } catch ImmichError.http(404, _) {
            return nil
        }
    }

    private func setCover() {
        guard let selectedID else { return }
        let stackID = stackID
        let client = session.client
        perform { _ = try await client.assetsSetPrimary(stack: stackID, asset: selectedID) }
    }

    private func removeSelected() {
        guard let selectedID else { return }
        let stackID = stackID
        let client = session.client
        perform { try await client.assetsRemoveFromStack(stackID, asset: selectedID) }
    }

    private func unstack() {
        let stackID = stackID
        let client = session.client
        perform(closes: true) { try await client.assetsUnstack(stackID) }
    }

    /// Reads the stack again and moves only photos still in it, still the account's and still not the cover.
    private func trashOthers() {
        guard let shown = stack, let userID = session.user?.id, !userID.isEmpty else { return }
        let stackID = stackID
        let session = session
        let presence = presence
        perform(closes: true) {
            try await AssetsStackMutation.trashOthers(client: session.client, stackID: stackID, shown: shown,
                                                      userID: userID, isCurrent: { presence.shown })
            await session.reloadAlbums()
        }
    }

    /// Runs a change, then the grids read themselves again and the stack is read again; the viewer follows the cover
    /// and reads the shown photo's details again, also when the sheet has gone meanwhile.
    private func perform(closes: Bool = false, _ change: @escaping @MainActor () async throws -> Void) {
        guard canChange, let previousCover = stack?.primaryAssetId else { return }
        busy = true
        let state = state
        let session = session
        let presence = presence
        Task {
            defer { if presence.shown { busy = false } }
            do {
                try await change()
            } catch where !error.isCancellation {
                session.handle(error)
                if presence.shown { actionError = error.localizedDescription }
                return
            } catch {
                return
            }
            session.invalidateGrids()
            var newCover: AssetResponse?
            var gone = false
            do {
                if let reloaded = try await load() {
                    newCover = reloaded.assets.first { $0.id == reloaded.primaryAssetId }
                } else {
                    gone = true
                }
            } catch {
                // The stack as shown stays, and the grids read it again.
            }
            state.stackChanged(previousCover: previousCover, newCover: newCover)
            if presence.shown, gone || closes { dismiss() }
        }
    }
}

/// Whether the stack's sheet still shows, for changes that finish after it has gone.
@MainActor
private final class ViewerStackPresence {
    var shown = true
}

/// The chosen photo of the stack, large; the one before stays until the next has loaded.
private struct ViewerStackPreview: View {
    let asset: AssetResponse
    let pipeline: ImagePipeline
    @State private var image: CGImage?

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFit()
            } else {
                ProgressView()
            }
        }
        .accessibilityHidden(true)
        .task(id: asset.id) {
            if let cached = pipeline.cachedThumbnail(asset.id, size: .preview) {
                image = cached
                return
            }
            if let preview = await pipeline.thumbnail(asset.id, size: .preview), !Task.isCancelled { image = preview }
        }
    }
}

/// A photo in the stack's strip: square, outlined while chosen, the cover marked with a star.
private struct ViewerStackTile: View {
    let asset: AssetResponse
    let pipeline: ImagePipeline
    let selected: Bool
    let cover: Bool
    @State private var image: CGImage?

    var body: some View {
        Rectangle()
            .fill(.quaternary)
            .overlay {
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .scaledToFill()
                }
            }
            .frame(width: 56, height: 56)
            .clipShape(.rect(cornerRadius: 8))
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(.tint, lineWidth: 3)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if cover {
                    Image(systemName: "star.fill")
                        .font(.caption2)
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.6), radius: 2)
                        .padding(4)
                        .accessibilityLabel(Text("Cover"))
                }
            }
            .padding(.vertical, 4)
            .contentShape(.rect)
            .task(id: asset.id) {
                image = pipeline.cachedThumbnail(asset.id, size: .thumbnail)
                if image == nil { image = await pipeline.thumbnail(asset.id, size: .thumbnail) }
            }
    }
}
