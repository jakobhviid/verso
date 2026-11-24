import SwiftUI

/// Where a memory's card opens.
struct MemoryRoute: Hashable {
    let id: String
}

/// A memory as a gallery, as an album is (ARCHITECTURE.md, "Verso on the Mac"): its photos in the grid, in its order,
/// to look at, open, select and take out of it (Remove from Memory; ⌫ takes them out, and never deletes them, as they
/// are the library's). Above them what it recalls, the day and how many, where and whom, and a row with its status:
/// Kept or Not Kept, which a click changes, as Immich's cleanup removes a memory after 30 days unless it is kept, and
/// Delete Memory beside it. Opening it marks it seen.
struct MemoryDetailView: View {
    @Environment(LibrarySession.self) private var session
    @Environment(\.dismiss) private var dismiss
    let id: String
    @State private var memory: ExploreMemory?
    @State private var error: String?
    @State private var deleting = false
    @State private var deleted = false

    private var model: AssetGridModel { session.gridModel(for: .memory(id)) }

    var body: some View {
        Group {
            if deleted {
                ContentUnavailableView("Memory Deleted", systemImage: "rectangle.stack.badge.play")
            } else if let memory {
                AssetGridContainer(source: .memory(id), title: Text(verbatim: memory.title), headerScrolls: true) {
                    header(memory)
                }
            } else if let error {
                ContentUnavailableView { Label("Couldn't Load Memory", systemImage: "rectangle.stack.badge.play") }
                description: { Text(error) } actions: { Button("Try Again") { Task { await load() } } }
                .pageToolbar("memoryError")
            } else {
                ProgressView().pageToolbar("memoryLoading")
            }
        }
        .task(id: id) {
            await load()
            try? await session.client.exploreSeenMemory(id)
        }
        // A photo taken out in the grid: the header's count follows.
        .onChange(of: model.totalCount) { Task { await load() } }
        .confirmationDialog("Delete Memory?", isPresented: $deleting, titleVisibility: .visible) {
            Button("Delete Memory", role: .destructive) { deleteMemory() }
        } message: { Text("The photos in this memory are kept.") }
        .alert("Memory", isPresented: Binding(get: { memory != nil && error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }

    private func header(_ memory: ExploreMemory) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(memory.title).font(.largeTitle.bold()).lineLimit(2)
            Text(dayLine(memory)).font(.callout).foregroundStyle(.secondary)
            if let about = about(memory) { Text(about).font(.callout).foregroundStyle(.secondary) }
            // Its status, under its details, as an album's (DESIGN.md, "The apps' interfaces").
            HStack(spacing: 4) {
                let kept = memory.isSaved == true
                Button { setKept(!kept) } label: {
                    Label(kept ? "Kept" : "Not Kept", systemImage: kept ? "bookmark.fill" : "bookmark")
                }
                .help(kept ? "Kept: Immich won't remove it. Click to let it go."
                           : "Immich removes a memory after 30 days unless it is kept. Click to keep it.")
                Divider().frame(height: 18).padding(.horizontal, 8)
                Button { deleting = true } label: { Label("Delete Memory", systemImage: "trash") }
                    .help("Delete Memory…")
            }
            .buttonStyle(.headerStatus)
            .padding(.leading, -8)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 12)
    }

    /// The day it recalls, read in UTC as Immich keeps it, and how many.
    private func dayLine(_ memory: ExploreMemory) -> String {
        let count = memory.assets.count == 1 ? String(localized: "1 photo") : String(localized: "\(memory.assets.count) photos")
        guard let day = memory.memoryAt.flatMap(ImmichDate.parse) else { return count }
        var style = Date.FormatStyle(date: .long, time: .omitted)
        style.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return "\(day.formatted(style)) · \(count)"
    }

    /// Where most were taken and the named people in the most of them.
    private func about(_ memory: ExploreMemory) -> String? {
        func mostCommon(_ values: [String], limit: Int) -> [String] {
            var counts: [String: Int] = [:]
            for value in values { counts[value, default: 0] += 1 }
            let ranked: [(name: String, count: Int)] = counts.map { (name: $0.key, count: $0.value) }
            let sorted = ranked.sorted { first, second in
                first.count != second.count ? first.count > second.count : first.name < second.name
            }
            return sorted.prefix(limit).map(\.name)
        }
        let place = mostCommon(memory.assets.compactMap { $0.exifInfo?.city }.filter { !$0.isEmpty }, limit: 1).first
        let people = mostCommon(memory.assets.flatMap { $0.people ?? [] }.map(\.name).filter { !$0.isEmpty }, limit: 3)
        let parts = [place, people.isEmpty ? nil : people.formatted(.list(type: .and))].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func load() async {
        do {
            var loaded = try await session.client.exploreMemory(id)
            loaded.assets.removeAll { $0.visibility == "locked" }
            memory = loaded
            error = nil
        } catch {
            session.handle(error)
            self.error = error.localizedDescription
        }
    }

    private func setKept(_ keep: Bool) {
        Task {
            do {
                try await session.client.exploreKeepMemory(id, keep: keep)
                memory?.isSaved = keep
            } catch { self.error = error.localizedDescription }
        }
    }

    private func deleteMemory() {
        Task {
            do {
                try await session.client.exploreDeleteMemory(id)
                deleted = true
                dismiss()
            } catch {
                session.handle(error)
                self.error = error.localizedDescription
            }
        }
    }
}
