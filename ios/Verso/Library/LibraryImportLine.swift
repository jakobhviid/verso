// An import under the Library's title on iOS, as Photos says "Syncing 1 Item…" there (ROADMAP.md, M10): the import's
// ring and "Importing 3 of 12…", or what it came to once it ended, until it goes into the notifications. A tap opens
// each file (ImportDetailsSheet), and the import stays shown while they are open.

import SwiftUI

struct LibraryImportLine: View {
    let queue: UploadQueue
    @State private var showingDetails = false

    var body: some View {
        let status = ImportProgress(queue: queue, coordinator: ImportCoordinator.of(queue))
        Button {
            showingDetails = true
        } label: {
            HStack(spacing: 6) {
                ImportRing(progress: status, size: 17)
                Text(Self.line(status))
                    .lineLimit(1)
            }
            .font(.headline)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(status.title)
        .accessibilityValue(status.detail ?? "")
        .accessibilityHint("Shows each file")
        .sheet(isPresented: $showingDetails) {
            ImportDetailsSheet(queue: queue)
        }
        .onChange(of: showingDetails) { _, open in queue.detailsOpen = open }
    }

    /// The import's title, going on while files are still on their way.
    private static func line(_ status: ImportProgress) -> String {
        switch status.phase {
        case .preparing, .working: status.title + "…"
        case .looking, .done, .attention: status.title
        }
    }
}
