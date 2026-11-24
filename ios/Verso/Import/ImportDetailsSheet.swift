// An import's details on iOS, from a tap on its progress in the Library's title line: how it goes, then each file
// under what became of it (failed first, with why; then those on their way, those waiting, those cancelled, those
// imported, and those skipped as already in the library), with Cancel while it runs, and Retry and Clear once it
// ended. While the sheet is open an import that ended stays shown, as the Mac's list of each file keeps it
// (UploadQueue.detailsOpen), and goes into the notifications 5 seconds after the sheet closes.

import SwiftUI

struct ImportDetailsSheet: View {
    let queue: UploadQueue
    @Environment(\.dismiss) private var dismiss

    private struct FileGroup: Identifiable {
        let title: String
        let items: [UploadQueue.Item]
        var id: String { title }
    }

    var body: some View {
        let coordinator = ImportCoordinator.of(queue)
        let status = ImportProgress(queue: queue, coordinator: coordinator)
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 14) {
                        ImportRing(progress: status, size: 44)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(status.title)
                                .font(.headline)
                            if let detail = status.detail {
                                Text(detail)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    if let error = queue.lastError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                    if queue.unreadableCount > 0 {
                        Label("\(queue.unreadableCount) could not be read", systemImage: "questionmark.folder")
                            .foregroundStyle(.orange)
                    }
                    if queue.unsupportedCount > 0 {
                        Label("\(queue.unsupportedCount) not photos or videos, left out", systemImage: "doc")
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(groups) { group in
                    Section("\(group.title) (\(group.items.count))") {
                        ForEach(group.items) { item in
                            ImportFileRow(item: item)
                        }
                    }
                }
            }
            .navigationTitle("Import")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) { dismiss() }
                }
                if status.phase == .preparing {
                    ToolbarItem(placement: .bottomBar) {
                        Button("Cancel Import", role: .destructive) { coordinator.cancelPreparing() }
                    }
                }
                if status.phase == .looking || status.phase == .working {
                    ToolbarItem(placement: .bottomBar) {
                        Button("Cancel Import", role: .destructive) { queue.cancelAll() }
                    }
                }
                if status.canRetry {
                    ToolbarItem(placement: .bottomBar) {
                        Button("Retry", systemImage: "arrow.clockwise") { queue.retryFailed() }
                            .labelStyle(.titleAndIcon)
                    }
                }
                if status.phase == .done || status.phase == .attention {
                    ToolbarSpacer(.flexible, placement: .bottomBar)
                    ToolbarItem(placement: .bottomBar) {
                        Button("Clear") {
                            queue.closeBanner()
                            dismiss()
                        }
                    }
                }
            }
        }
        .onAppear { queue.detailsOpen = true }
        .onDisappear { queue.detailsOpen = false }
    }

    /// The files by what became of them, those that need a look first.
    private var groups: [FileGroup] {
        let items = queue.items
        let sorted: [(String, Set<UploadQueue.Item.State>)] = [
            ("Not Imported", [.failed]),
            ("Importing", [.preparing, .uploading, .adding]),
            ("Waiting", [.waiting]),
            ("Cancelled", [.cancelled]),
            ("Imported", [.done]),
            ("Already in the Library", [.duplicate]),
        ]
        return sorted.compactMap { title, states in
            let matching = items.filter { states.contains($0.state) }
            return matching.isEmpty ? nil : FileGroup(title: title, items: matching)
        }
    }
}

/// One file of the import: its name, what became of it, how far it is sent, and why it failed.
private struct ImportFileRow: View {
    let item: UploadQueue.Item

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(item.url.lastPathComponent)
                .lineLimit(1)
                .truncationMode(.middle)
            if item.state == .uploading && item.total > 0 {
                ProgressView(value: Double(item.sent), total: Double(max(1, item.total)))
                Text("\(item.sent.formatted(.byteCount(style: .file))) of \(item.total.formatted(.byteCount(style: .file)))")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            } else if item.state != .failed {
                Text(item.response?.isTrashed == true ? "Back from Recently Deleted" : item.state.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let error = item.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
