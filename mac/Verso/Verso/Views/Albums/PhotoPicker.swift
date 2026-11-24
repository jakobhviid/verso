import SwiftUI

/// Choosing photos to add, from an album's or a link's page, as on Linux (ARCHITECTURE.md, "Verso on the Mac"): the
/// library newest first, a click choosing a photo or letting it go, and Add for those chosen. Photos already there
/// are dimmed and cannot be chosen. The way to add from where the photos go, beside Add to Album and Add to Public
/// Link in the Library.
struct PhotoPicker: View {
    @Environment(LibrarySession.self) private var session
    @Environment(\.dismiss) private var dismiss
    let title: String
    /// The photos already there.
    var present: Set<String> = []
    let add: ([String]) async throws -> Void
    @State private var photos: [AssetResponse] = []
    @State private var nextPage: ImmichClient.SearchPage? = .init(page: 1)
    @State private var loading = false
    @State private var chosen: [String] = []
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.headline).lineLimit(1)
                Spacer()
                if !chosen.isEmpty {
                    Text(chosen.count == 1 ? String(localized: "1 photo chosen") : String(localized: "\(chosen.count) photos chosen"))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            Divider()
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110, maximum: 160), spacing: 4)], spacing: 4) {
                    ForEach(photos) { photo in
                        tile(photo).onAppear { if photo.id == photos.last?.id { loadMore() } }
                    }
                }
                .padding(8)
                if loading { ProgressView().controlSize(.small).padding() }
                if photos.isEmpty && !loading && nextPage == nil {
                    Text("No photos in the library.").foregroundStyle(.secondary).padding(40)
                }
            }
            Divider()
            HStack {
                if let error { Text(error).foregroundStyle(.red).lineLimit(2).textSelection(.enabled) }
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(chosen.isEmpty ? String(localized: "Add") : String(localized: "Add \(chosen.count)")) { Task { await addChosen() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(chosen.isEmpty || busy)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
        }
        .frame(width: 780, height: 580)
        .task { loadMore() }
    }

    private func tile(_ photo: AssetResponse) -> some View {
        let isPresent = present.contains(photo.id)
        let isChosen = chosen.contains(photo.id)
        return RemoteThumbnail(pipeline: session.pipeline, assetID: photo.id)
            .aspectRatio(1, contentMode: .fit)
            .opacity(isPresent ? 0.4 : 1)
            .overlay(alignment: .bottomTrailing) {
                if isChosen {
                    Image(systemName: "checkmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color.accentColor)
                        .font(.title2)
                        .padding(6)
                }
            }
            .overlay { if isChosen { Rectangle().strokeBorder(Color.accentColor, lineWidth: 3) } }
            .contentShape(Rectangle())
            .onTapGesture {
                guard !isPresent else { return }
                if let index = chosen.firstIndex(of: photo.id) { chosen.remove(at: index) } else { chosen.append(photo.id) }
            }
            .help(isPresent ? String(localized: "Already added") : photo.originalFileName)
            .accessibilityAddTraits(isChosen ? [.isButton, .isSelected] : .isButton)
    }

    /// The library's next page, newest first, as the Library shows it.
    private func loadMore() {
        guard !loading, let page = nextPage else { return }
        loading = true
        Task {
            defer { loading = false }
            do {
                let result = try await session.client.metadataSearch(visibility: "timeline", order: "desc", page: page, size: 250)
                photos += result.items.filter { $0.visibility != "locked" }
                if let cursor = result.nextCursor { nextPage = .init(cursor: cursor) }
                else { nextPage = result.nextPage.flatMap(Int.init).map { .init(page: $0) } }
            } catch {
                session.handle(error)
                self.error = error.localizedDescription
                nextPage = nil
            }
        }
    }

    private func addChosen() async {
        busy = true
        defer { busy = false }
        error = nil
        do {
            try await add(chosen)
            dismiss()
        } catch {
            session.handle(error)
            self.error = error.localizedDescription
        }
    }
}
