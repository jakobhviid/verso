// Choosing photos in a sheet, as on the Mac and Linux: the library newest first to add to an album or a link, or an
// album's own photos to choose its cover from. A tap chooses a photo or lets it go; photos already there are dimmed
// and cannot be chosen.

import SwiftUI
import VersoCore

struct AlbumsPhotoPicker: View {
    /// Where the photos to choose from come from.
    enum Source {
        /// The library's timeline, newest first.
        case library
        /// An album's photos.
        case album(String)
    }

    let session: LibrarySession
    let title: String
    let source: Source
    /// The photos already there, dimmed.
    var present: Set<String> = []
    /// One photo, such as a cover, rather than several.
    var choosesOne = false
    /// The confirming button's name, which a count follows when several are chosen.
    var confirmTitle = "Add"
    let done: ([String]) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var photos: [PickerPhoto] = []
    @State private var chosen: [String] = []
    @State private var loading = false
    @State private var finished = false
    @State private var busy = false
    @State private var error: String?
    @State private var errorTitle = ""
    /// The library's next page of results.
    @State private var nextPage: ImmichClient.SearchPage? = .init(page: 1)
    /// An album's months still to read.
    @State private var albumMonths: [String]?

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 88), spacing: 2)], spacing: 2) {
                    ForEach(photos) { photo in
                        tile(photo)
                            .onAppear { if photo.id == photos.last?.id { loadMore() } }
                    }
                }
                if loading {
                    ProgressView().padding()
                } else if photos.isEmpty && finished {
                    ContentUnavailableView("No Photos", systemImage: "photo.on.rectangle",
                                           description: Text("There are no photos to choose from."))
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if busy {
                        ProgressView()
                    } else {
                        Button(confirmLabel) { Task { await confirm() } }
                            .disabled(chosen.isEmpty)
                    }
                }
            }
            .alert(errorTitle, isPresented: errorShown) {
                Button("OK") { error = nil }
            } message: {
                Text(error ?? "")
            }
        }
        .interactiveDismissDisabled(busy || !chosen.isEmpty)
        .task { loadMore() }
    }

    private var confirmLabel: String {
        choosesOne || chosen.isEmpty ? confirmTitle : "\(confirmTitle) (\(chosen.count))"
    }

    private var errorShown: Binding<Bool> {
        Binding(get: { error != nil }, set: { shown in if !shown { error = nil } })
    }

    private func tile(_ photo: PickerPhoto) -> some View {
        let isPresent = present.contains(photo.id)
        let isChosen = chosen.contains(photo.id)
        return AlbumsThumbnail(pipeline: session.pipeline, assetID: photo.id)
            .aspectRatio(1, contentMode: .fit)
            .opacity(isPresent ? 0.4 : 1)
            .overlay(alignment: .bottomLeading) {
                if photo.isVideo {
                    Image(systemName: "video.fill")
                        .font(.caption)
                        .foregroundStyle(.white)
                        .shadow(radius: 2)
                        .padding(5)
                }
            }
            .overlay {
                if isChosen {
                    Rectangle().fill(.white.opacity(0.15))
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if isChosen {
                    Image(systemName: "checkmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color.accentColor)
                        .font(.title3)
                        .padding(4)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { toggle(photo, isPresent: isPresent) }
            .accessibilityElement()
            .accessibilityLabel(photo.isVideo ? Text("Video") : Text("Photo"))
            .accessibilityValue(isPresent ? Text("Already added") : isChosen ? Text("Chosen") : Text(""))
            .accessibilityAddTraits(isChosen ? [.isButton, .isSelected] : .isButton)
    }

    private func toggle(_ photo: PickerPhoto, isPresent: Bool) {
        guard !isPresent else { return }
        if choosesOne {
            chosen = chosen == [photo.id] ? [] : [photo.id]
        } else if let index = chosen.firstIndex(of: photo.id) {
            chosen.remove(at: index)
        } else {
            chosen.append(photo.id)
        }
    }

    private func loadMore() {
        guard !loading, !finished else { return }
        loading = true
        Task {
            defer { loading = false }
            do {
                switch source {
                case .library: try await loadLibraryPage()
                case .album(let id): try await loadAlbumMonth(id)
                }
            } catch {
                guard !error.isCancellation else { return }
                session.handle(error)
                errorTitle = "Couldn't Load Photos"
                self.error = error.localizedDescription
                finished = true
            }
        }
    }

    /// The library's next page, newest first, as the Library shows it.
    private func loadLibraryPage() async throws {
        guard let page = nextPage else {
            finished = true
            return
        }
        let result = try await session.client.metadataSearch(visibility: "timeline", order: "desc", page: page, size: 250)
        photos += result.items.filter { $0.visibility != "locked" }.map { PickerPhoto(id: $0.id, isVideo: $0.type == .video) }
        if let cursor = result.nextCursor {
            nextPage = .init(cursor: cursor)
        } else {
            nextPage = result.nextPage.flatMap(Int.init).map { .init(page: $0) }
        }
        if nextPage == nil { finished = true }
    }

    /// The album's next months of photos, newest first, until one adds a photo to show.
    private func loadAlbumMonth(_ id: String) async throws {
        let timeline = CoreTimeline(source: .album(id: id), settings: .stacked)
        if albumMonths == nil {
            albumMonths = try await session.client.timeBuckets(timeline).map(\.timeBucket)
        }
        var added = 0
        while added == 0 {
            guard var months = albumMonths, !months.isEmpty else {
                finished = true
                return
            }
            let month = months.removeFirst()
            albumMonths = months
            let assets = try await session.client.timeBucket(month, timeline)
            let known = Set(photos.map(\.id))
            let shown = assets.id.indices
                .filter { index in assets.visibility?.indices.contains(index) != true || assets.visibility?[index] != "locked" }
                .filter { index in !known.contains(assets.id[index]) }
                .map { index in PickerPhoto(id: assets.id[index], isVideo: !assets.isImage[index]) }
            photos += shown
            added = shown.count
        }
        if albumMonths?.isEmpty != false { finished = true }
    }

    private func confirm() async {
        busy = true
        defer { busy = false }
        do {
            try await done(chosen)
            dismiss()
        } catch {
            session.handle(error)
            errorTitle = "Couldn't Save"
            self.error = error.localizedDescription
        }
    }
}

/// A photo the picker shows.
private struct PickerPhoto: Identifiable, Hashable {
    let id: String
    let isVideo: Bool
}
