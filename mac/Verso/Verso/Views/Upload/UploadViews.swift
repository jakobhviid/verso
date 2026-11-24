import SwiftUI
import UniformTypeIdentifiers

struct UploadCommands: Commands {
    let app: AppModel
    @FocusedValue(\.librarySession) private var session
    @FocusedValue(\.importAlbum) private var album
    var body: some Commands {
        CommandGroup(before: .importExport) {
            Button("Import…") { session?.upload.chooseFiles(into: album) }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                .disabled(session == nil)
        }
    }
}

/// Import in the window's toolbar, for Customize Toolbar only: hidden by default, as an import is started with
/// File > Import… or a drop, and shows at the foot of the sidebar (`ImportSidebarStatus`).
struct UploadToolbar: CustomizableToolbarContent {
    let queue: UploadQueue
    var body: some CustomizableToolbarContent {
        ToolbarItem(id: "import", showsByDefault: false) { UploadToolbarButton(queue: queue) }
    }
}

private struct UploadToolbarButton: View {
    let queue: UploadQueue
    /// Changes only as pages do, so reading it here does not rebuild the item on every update (on macOS 15 a toolbar
    /// item rebuilt on every update loops forever).
    @FocusedValue(\.importAlbum) private var album

    var body: some View {
        Button { queue.chooseFiles(into: album) } label: { Label("Import", systemImage: "arrow.up.to.line") }
            .help("Import photos and videos")
    }
}

/// While files are imported, and 5 seconds after, the foot of the sidebar shows the import just above the account
/// (`ImportStatusRow`): it stays in one place whatever the page, and moves no page. Then it goes into the bell, unless
/// it was closed with its cross. As on Linux.
struct ImportSidebarStatus: View {
    let queue: UploadQueue
    @State private var showingDetails = false
    @FocusedValue(\.importAlbum) private var album

    var body: some View {
        if queue.showsBanner {
            ImportStatusRow(status: ImportStatus(queue), showDetails: { showingDetails.toggle() }, retry: { queue.retryFailed() },
                            stop: { if queue.isRunning { queue.cancelAll() } else { queue.closeBanner() } })
                .popover(isPresented: $showingDetails, arrowEdge: .trailing) { UploadProgressView(queue: queue, album: album) }
                .onChange(of: showingDetails) { _, open in queue.detailsOpen = open }
            Divider()
        }
    }
}

extension ImportStatus {
    /// The queue as the sidebar shows it: "Importing 3 of 12" with how far, then what it came to (`outcome`).
    @MainActor init(_ queue: UploadQueue) {
        if queue.isRunning {
            let looking = queue.discovering && queue.items.isEmpty
            self.init(phase: .working,
                      title: looking ? String(localized: "Looking for files…") : String(localized: "Importing \(queue.completed) of \(queue.items.count)"),
                      progress: looking ? nil : queue.progress)
            return
        }
        let outcome = queue.outcome
        self.init(phase: outcome.needsLook ? .attention : .done, title: outcome.title, detail: outcome.detail,
                  canRetry: queue.failed + queue.cancelled > 0)
    }
}

private struct UploadProgressView: View {
    @Bindable var queue: UploadQueue
    let album: ImportAlbum?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Import").font(.headline)
                Spacer()
                Button("Import…") { queue.chooseFiles(into: album) }.disabled(queue.discovering)
            }
            if queue.discovering { ProgressView("Scanning files…") }
            if let error = queue.lastError { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            if queue.unreadableCount > 0 { Text("\(queue.unreadableCount) items could not be read").foregroundStyle(.orange) }
            if queue.unsupportedCount > 0 { Text("\(queue.unsupportedCount) unsupported files ignored").foregroundStyle(.secondary) }
            if queue.items.isEmpty {
                Text("Choose files or folders, or drop them onto the window. Dropped on an album, in the sidebar, on its cover or on its page, they join the album too.")
                    .foregroundStyle(.secondary)
            } else {
                Text(queue.summary).font(.callout).foregroundStyle(.secondary)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(queue.items) { item in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.url.lastPathComponent).lineLimit(1).help(item.url.path)
                                Text(item.state.title).font(.caption).foregroundStyle(.secondary)
                                if item.response?.isTrashed == true { Text("Back from Recently Deleted").font(.caption).foregroundStyle(.secondary) }
                                if item.state == .uploading {
                                    ProgressView(value: Double(item.sent), total: Double(max(1, item.total)))
                                    Text("\(ByteCountFormatter.string(fromByteCount: item.sent, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: item.total, countStyle: .file))")
                                        .font(.caption).monospacedDigit()
                                }
                                if let error = item.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                            }
                        }
                    }
                }.frame(maxHeight: 320)
                HStack {
                    if queue.isRunning { Button("Cancel All", role: .cancel) { queue.cancelAll() } }
                    else {
                        Button("Retry Failed") { queue.retryFailed() }
                            .disabled(queue.failed + queue.cancelled == 0)
                        Spacer()
                        Button("Clear") { queue.closeBanner() }
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 380)
    }
}

/// Files dropped from Finder are imported: into the library, or into album `albumID` too. An album the account may
/// only view (`viewOnly`, its name) takes the drag, so it never falls to the library, and refuses it.
struct UploadDropModifier: ViewModifier {
    let queue: UploadQueue
    var albumID: String?
    var viewOnly: String?
    @State private var targeted = false
    func body(content: Content) -> some View {
        content
            .onDrop(of: [UTType.fileURL], delegate: UploadFileDrop(queue: queue, albumID: albumID, viewOnly: viewOnly, targeted: $targeted))
            .overlay { if targeted { RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor, lineWidth: 3).allowsHitTesting(false) } }
            .animation(.easeOut(duration: 0.15), value: targeted)
    }

    static func enqueue(_ providers: [NSItemProvider], queue: UploadQueue, albumID: String?, viewOnly: String? = nil) -> Bool {
        guard !providers.isEmpty, !UploadDropPolicy.isInternal(providers) else { return false }
        if let viewOnly {
            Task { @MainActor in queue.lastError = String(localized: "You can view “\(viewOnly)” but not add to it.") }
            return false
        }
        Task { @MainActor in
            var urls: [URL] = []
            for provider in providers {
                let url: URL? = await withCheckedContinuation { continuation in
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
                }
                if let url, url.isFileURL { urls.append(url) }
            }
            if !urls.isEmpty { queue.enqueue(urls, albumID: albumID) }
            else { queue.lastError = String(localized: "The dropped files could not be read. Try Import… instead.") }
        }
        return !providers.isEmpty
    }
}

private struct UploadFileDrop: DropDelegate {
    let queue: UploadQueue
    let albumID: String?
    let viewOnly: String?
    @Binding var targeted: Bool

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.fileURL]) && !UploadDropPolicy.isInternal(info.itemProviders(for: [.fileURL]))
    }

    // Where the drop would import nothing, no outline, and the pointer says so, as Finder's over a folder it cannot write.
    func dropEntered(info: DropInfo) { targeted = viewOnly == nil && validateDrop(info: info) }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: viewOnly == nil ? .copy : .forbidden) }
    func dropExited(info: DropInfo) { targeted = false }

    func performDrop(info: DropInfo) -> Bool {
        targeted = false
        guard validateDrop(info: info) else { return false }
        return UploadDropModifier.enqueue(info.itemProviders(for: [.fileURL]), queue: queue, albumID: albumID, viewOnly: viewOnly)
    }
}
