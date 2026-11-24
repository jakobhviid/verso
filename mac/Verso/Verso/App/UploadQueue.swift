#if os(macOS)
import AppKit
#endif
import Foundation
import Observation

@MainActor @Observable
final class UploadQueue {
    struct Item: Identifiable {
        enum State: Hashable {
            case waiting, preparing, uploading, adding, done, duplicate, failed, cancelled
            var title: String {
                switch self {
                case .waiting: String(localized: "Waiting")
                case .preparing: String(localized: "Preparing")
                case .uploading: String(localized: "Uploading")
                case .adding: String(localized: "Adding to album")
                case .done: String(localized: "Imported")
                case .duplicate: String(localized: "Duplicate")
                case .failed: String(localized: "Failed")
                case .cancelled: String(localized: "Cancelled")
                }
            }
        }
        let id = UUID()
        let url: URL
        let albumID: String?
        var state: State = .waiting
        var sent: Int64 = 0
        var total: Int64 = 0
        var error: String?
        var response: UploadResponse?
        var finished: Bool { [.done, .duplicate, .failed, .cancelled].contains(state) }
    }

    private(set) var items: [Item] = []
    private(set) var discovering = false
    /// Counts the moments the grids should show what came in so far: every two seconds while files arrive, each grid
    /// reading again only the months that changed.
    private(set) var revision = 0
    /// The import's bar shows under the page's header: from the start of an import until it is closed or goes by itself.
    var showsBanner = false
    var lastError: String? {
        didSet {
            guard lastError != nil else { return }
            showsBanner = true
            if !isRunning { hideLater() }
        }
    }
    /// The list of each file is open: the import stays shown while it is, and goes 5 seconds after it closes.
    var detailsOpen = false {
        didSet { if !detailsOpen && showsBanner && !isRunning { hideLater() } }
    }
    private(set) var unreadableCount = 0
    private(set) var unsupportedCount = 0
    private(set) var completed = 0
    private(set) var imported = 0
    private(set) var duplicates = 0
    private(set) var failed = 0
    private(set) var cancelled = 0
    private struct Key: Hashable { let url: URL; let albumID: String? }
    @ObservationIgnored private var indices: [Key: Int] = [:]
    @ObservationIgnored private var pending: [Int] = []
    @ObservationIgnored private var nextPending = 0
    @ObservationIgnored private var needsRefresh = false
    @ObservationIgnored private var refreshPending = false
    @ObservationIgnored private var hiding: Task<Void, Never>?
    /// The albums photos joined during this import, read again once it ends.
    @ObservationIgnored private var albumsChanged: Set<String> = []
    @ObservationIgnored var onError: (Error) -> Void = { _ in }
    @ObservationIgnored private let client: ImmichClient
    @ObservationIgnored private var workers: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var discovery: Task<Void, Never>?
    @ObservationIgnored private let access = UploadFileAccess()
    /// The import ended (or Immich has had time to read what it brought): the grids and the albums read again, and
    /// the albums given read their pages again.
    @ObservationIgnored var onFinished: (Set<String>) -> Void = { _ in }
    /// The import went by itself, 5 seconds after it ended: what it came to, for the bell. Closed with its cross, it
    /// goes without one.
    @ObservationIgnored var onEnded: (VersoNotification) -> Void = { _ in }

    init(client: ImmichClient) { self.client = client }
    var isRunning: Bool { discovering || !workers.isEmpty || completed < items.count }
    /// What the import came to, as Linux says it: "Imported 12, 2 already in the library".
    var summary: String {
        var parts = [String(localized: "Imported \(imported)")]
        if duplicates > 0 { parts.append(String(localized: "\(duplicates) already in the library")) }
        if failed > 0 { parts.append(String(localized: "\(failed) not imported")) }
        if cancelled > 0 { parts.append(String(localized: "\(cancelled) cancelled")) }
        return parts.joined(separator: ", ")
    }

    /// How far the import is, a file being sent counted by the bytes sent.
    var progress: Double {
        guard !items.isEmpty else { return 0 }
        let sending = items.lazy.filter { $0.state == .uploading && $0.total > 0 }.reduce(0.0) { $0 + Double($1.sent) / Double($1.total) }
        return min(1, (Double(completed) + sending) / Double(items.count))
    }

    private func transition(_ index: Int, to state: Item.State) {
        func count(_ state: Item.State, _ delta: Int) {
            switch state {
            case .done: imported += delta; completed += delta
            case .duplicate: duplicates += delta; completed += delta
            case .failed: failed += delta; completed += delta
            case .cancelled: cancelled += delta; completed += delta
            default: break
            }
        }
        count(items[index].state, -1)
        items[index].state = state
        count(state, 1)
        if state == .done || state == .duplicate { needsRefresh = true }
        if state == .done { refreshSoon() }
    }

    /// The grids show what came in so far, two seconds from the first file that did, so a large import redraws them
    /// every two seconds rather than for every file.
    private func refreshSoon() {
        guard !refreshPending else { return }
        refreshPending = true
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self else { return }
            refreshPending = false
            revision += 1
        }
    }

    /// The status's cross once the import ended: it leaves, and the list with it, without a notification.
    func closeBanner() {
        guard !isRunning else { return }
        hiding?.cancel()
        hiding = nil
        showsBanner = false
        clear()
    }

    /// Once the import ended, cleanly or not, it stays shown 5 seconds, then goes into the bell (`onEnded`), where
    /// what it came to is kept: read when everything came in, unread when something needs a look.
    private func hideLater() {
        guard hiding == nil else { return }
        hiding = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, !Task.isCancelled else { return }
            hiding = nil
            guard showsBanner, !isRunning, !detailsOpen else { return }
            onEnded(outcome)
            closeBanner()
        }
    }

    /// An import is shown and has ended, with something to say: files that came in or not, or why none did.
    private var hasEnded: Bool {
        showsBanner && !isRunning && (!items.isEmpty || lastError != nil || unsupportedCount + unreadableCount > 0)
    }

    /// What the import came to, as the sidebar says it once it ended and its notification keeps it: "Imported 12"
    /// over what else ("2 already in the library"), "Nothing new" when every file was there already, or "Nothing
    /// imported" over why. The same words as on Linux.
    var outcome: VersoNotification {
        if let error = lastError {
            return VersoNotification(title: String(localized: "Nothing imported"), detail: error, needsLook: true)
        }
        var others: [String] = []
        if duplicates > 0 { others.append(String(localized: "\(duplicates) already in the library")) }
        if failed > 0 { others.append(String(localized: "\(failed) not imported")) }
        if cancelled > 0 { others.append(String(localized: "\(cancelled) cancelled")) }
        if unsupportedCount > 0 { others.append(String(localized: "\(unsupportedCount) not photos or videos")) }
        if unreadableCount > 0 { others.append(String(localized: "\(unreadableCount) could not be read")) }
        let title = if imported > 0 { String(localized: "Imported \(imported)") }
            else if failed + cancelled == 0 && duplicates > 0 { String(localized: "Nothing new") }
            else { String(localized: "Nothing imported") }
        let files = items.filter { $0.state == .failed || $0.state == .cancelled }
            .map { VersoNotification.File(name: $0.url.lastPathComponent, reason: $0.error ?? $0.state.title) }
        return VersoNotification(title: title, detail: others.isEmpty ? nil : others.joined(separator: ", "),
                                 needsLook: failed + cancelled + unreadableCount > 0 || imported + duplicates == 0, files: files)
    }

    #if os(macOS)
    /// File > Import…: into `album` too when one is given (the album page shown, when the account may add to it).
    func chooseFiles(into album: ImportAlbum? = nil) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Import")
        panel.message = if let album {
            String(localized: "Choose photos, videos, or folders to import into “\(album.name)”. Folders include their subfolders.")
        } else {
            String(localized: "Choose photos, videos, or folders to import. Folders include their subfolders.")
        }
        panel.begin { [weak self] result in
            guard result == .OK else { return }
            Task { @MainActor in self?.enqueue(panel.urls, albumID: album?.id) }
        }
    }
    #endif

    /// Import files and folders, into album `albumID` too. An import after the last one ended starts the list afresh.
    func enqueue(_ urls: [URL], albumID: String? = nil) {
        guard !discovering else { lastError = String(localized: "Please wait for the current folder scan to finish, then try again."); return }
        if !isRunning {
            // An import still shown goes into the bell before this one takes its place, so a failure is kept.
            if hasEnded { onEnded(outcome) }
            clear()
        }
        hiding?.cancel()
        hiding = nil
        // Keep the original provider URLs alive even when no explicit scope was granted.
        access.roots.append(contentsOf: urls)
        for url in urls where url.startAccessingSecurityScopedResource() { access.urls.append(url) }
        showsBanner = true
        discovering = true
        lastError = nil
        discovery = Task {
            do {
                let types = try await client.uploadMediaTypes()
                let scan = Task.detached { try Self.scan(urls) }
                let files = try await withTaskCancellationHandler { try await scan.value } onCancel: { scan.cancel() }
                try Task.checkCancellation()
                unreadableCount += files.unreadableCount
                let extensions = types.extensions
                for file in files.urls {
                    guard extensions.contains("." + file.pathExtension.lowercased()) else { unsupportedCount += 1; continue }
                    let key = Key(url: file, albumID: albumID)
                    if let index = indices[key] {
                        if items[index].state == .cancelled && workers[items[index].id] == nil {
                            transition(index, to: .waiting)
                            items[index].sent = 0
                            items[index].error = nil
                            pending.append(index)
                        }
                        continue
                    }
                    indices[key] = items.count
                    pending.append(items.count)
                    items.append(Item(url: file, albumID: albumID))
                }
                if files.urls.isEmpty && files.unreadableCount == 0 {
                    lastError = String(localized: "No files were found in the selected folders.")
                }
            } catch {
                if !Task.isCancelled { lastError = error.localizedDescription; onError(error) }
            }
            discovering = false
            discovery = nil
            pump()
        }
    }

    struct ScanResult: Sendable {
        var urls: [URL]
        var unreadableCount: Int
    }

    nonisolated static func scan(_ urls: [URL]) throws -> ScanResult {
        var files = Set<URL>()
        var unreadable = Set<URL>()
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        for url in urls {
            try Task.checkCancellation()
            guard let values = try? url.resourceValues(forKeys: keys) else { unreadable.insert(url); continue }
            if values.isDirectory == true {
                guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys),
                    options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { url, _ in unreadable.insert(url); return true }) else {
                    unreadable.insert(url)
                    continue
                }
                for case let file as URL in enumerator {
                    try Task.checkCancellation()
                    guard let info = try? file.resourceValues(forKeys: keys) else { unreadable.insert(file); continue }
                    if info.isRegularFile == true && info.isSymbolicLink != true { files.insert(file.standardizedFileURL) }
                }
            } else if values.isRegularFile == true && values.isSymbolicLink != true {
                files.insert(url.standardizedFileURL)
            }
        }
        // Upload both Live Photo components as the web client does. Server metadata jobs link their content IDs.
        return ScanResult(urls: files.sorted { $0.path < $1.path }, unreadableCount: unreadable.count)
    }

    func cancelAll() {
        discovery?.cancel()
        workers.values.forEach { $0.cancel() }
        for index in items.indices where !items[index].finished { transition(index, to: .cancelled) }
    }

    func retryFailed() {
        guard workers.isEmpty else { return }
        hiding?.cancel()
        hiding = nil
        showsBanner = true
        for index in items.indices where items[index].state == .failed || items[index].state == .cancelled {
            transition(index, to: .waiting)
            if workers[items[index].id] == nil { pending.append(index) }
            items[index].error = nil
            items[index].sent = 0
        }
        pump()
    }

    func clear() {
        guard !isRunning else { return }
        items.removeAll()
        indices.removeAll()
        pending.removeAll()
        nextPending = 0
        completed = 0; imported = 0; duplicates = 0; failed = 0; cancelled = 0
        unreadableCount = 0; unsupportedCount = 0
        access.release()
        lastError = nil
    }

    private func pump() {
        while workers.count < 2 && nextPending < pending.count {
            let index = pending[nextPending]
            nextPending += 1
            guard items[index].state == .waiting else { continue }
            transition(index, to: .preparing)
            workers[items[index].id] = Task { await process(index) }
        }
        guard !isRunning else { return }
        if needsRefresh {
            needsRefresh = false
            let albums = albumsChanged
            albumsChanged = []
            onFinished(albums)
            // Immich reads a new file's date, shape and thumbnail in the background: until then it shows grey, square
            // and at the day it came in. The grids read again once it has had time, and again later, as on Linux.
            if imported > 0 {
                Task { [weak self] in
                    for seconds in [5, 15] {
                        try? await Task.sleep(for: .seconds(seconds))
                        self?.onFinished([])
                    }
                }
            }
        }
        if hasEnded { hideLater() }
    }

    private func process(_ index: Int) async {
        let id = items[index].id
        let file = items[index].url
        do {
            try Task.checkCancellation()
            if items[index].response == nil {
                transition(index, to: .preparing)
                let hashing = Task.detached { try UploadMultipart.checksum(file) }
                let checksum = try await withTaskCancellationHandler { try await hashing.value } onCancel: { hashing.cancel() }
                try Task.checkCancellation()
                var existing: UploadResponse?
                if let result = try await client.checkUpload(checksum: checksum, name: file.lastPathComponent).results.first,
                   result.action == "reject", let assetID = result.assetId {
                    // A duplicate waiting in Recently Deleted comes back, as importing it again asks for it (as on Linux).
                    if result.isTrashed == true { try await client.restore([assetID]); refreshSoon() }
                    existing = UploadResponse(id: assetID, status: "duplicate", isTrashed: result.isTrashed)
                }
                if let existing { items[index].response = existing }
                else {
                    items[index].response = try await client.uploadFile(file, checksum: checksum) { [weak self] sent, total in
                        Task { @MainActor in
                            guard let self, !Task.isCancelled, self.workers[id]?.isCancelled == false,
                                  self.items[index].state == .preparing || self.items[index].state == .uploading else { return }
                            self.transition(index, to: .uploading)
                            self.items[index].sent = sent
                            self.items[index].total = total
                        }
                    }
                }
            }
            try Task.checkCancellation()
            guard let response = items[index].response else { throw URLError(.cannotParseResponse) }
            if let albumID = items[index].albumID {
                transition(index, to: .adding)
                try await client.addUploadToAlbum(response.id, albumID: albumID)
                albumsChanged.insert(albumID)
                refreshSoon()
            }
            try Task.checkCancellation()
            transition(index, to: response.status == "duplicate" ? .duplicate : .done)
        } catch {
            transition(index, to: Task.isCancelled ? .cancelled : .failed)
            if !Task.isCancelled { items[index].error = error.localizedDescription; showsBanner = true; onError(error) }
        }
        workers[id] = nil
        pump()
    }
}

/// The album File > Import… adds to as well: the album page shown, when the account may add to it.
struct ImportAlbum: Hashable {
    let id: String
    let name: String
}

// Balance sandbox access on Clear and when a signed-out queue finishes releasing its tasks.
private final class UploadFileAccess {
    var roots: [URL] = []
    var urls: [URL] = []
    func release() {
        urls.forEach { $0.stopAccessingSecurityScopedResource() }
        urls.removeAll()
        roots.removeAll()
    }
    deinit { urls.forEach { $0.stopAccessingSecurityScopedResource() } }
}
