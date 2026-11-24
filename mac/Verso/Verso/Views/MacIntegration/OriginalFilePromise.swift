import AppKit
import UniformTypeIdentifiers

/// One photo of a drag out of the Mac's photo grid (`PhotoGridCollectionView`), as AppKit drags files: a promise of its
/// original, which the receiver (Finder, the desktop, Mail, another app) names as the drag starts and asks for as it
/// takes the drop, and nothing is downloaded before then. It carries what `OriginalTransfer` carries for SwiftUI's
/// drags: the original in its own format under Immich's name, numbered with the others of its drag (`OriginalDrag`),
/// then the in-app marker, which keeps the sidebar from uploading it, and its ID for album drops, which a Locked Folder
/// photo has none of. ARCHITECTURE.md, "Verso on the Mac", "Dragging originals out".
final class OriginalFilePromise: NSFilePromiseProvider, NSFilePromiseProviderDelegate, @unchecked Sendable {
    let assetID: String
    let file: OriginalFile
    private let client: ImmichClient
    /// What it carries besides the promise, by type.
    private let extras: [NSPasteboard.PasteboardType: Data]
    private let writing = OperationQueue()

    /// The original of `id`, at its place in a drag (`file`); `albumIDs` nil for a Locked Folder photo. Reads the
    /// drag's details, waiting for them at most `OriginalFile.timeout` the first time one of its photos asks.
    init(id: String, file: OriginalFile, client: ImmichClient, albumIDs: [String]?) {
        assetID = id
        self.file = file
        self.client = client
        var extras: [NSPasteboard.PasteboardType: Data] = [:]
        if let marker = try? JSONEncoder().encode(OriginalDragMarker()) {
            extras[NSPasteboard.PasteboardType(UTType.immichOriginalDrag.identifier)] = marker
        }
        if let albumIDs, let ids = try? JSONEncoder().encode(AlbumAssetTransfer(ids: albumIDs)) {
            extras[NSPasteboard.PasteboardType(UTType.albumAssetIDs.identifier)] = ids
        }
        self.extras = extras
        super.init()
        fileType = file.resolved.type.identifier
        delegate = self
        writing.name = "Verso original drag"
    }

    // MARK: What it carries

    override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        // The promise first: the Finder takes the first type it can.
        super.writableTypes(for: pasteboard) + extras.keys.sorted { $0.rawValue < $1.rawValue }
    }

    override func writingOptions(forType type: NSPasteboard.PasteboardType, pasteboard: NSPasteboard) -> NSPasteboard.WritingOptions {
        extras[type] != nil ? [] : super.writingOptions(forType: type, pasteboard: pasteboard)
    }

    override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        extras[type] ?? super.pasteboardPropertyList(forType: type)
    }

    // MARK: The promise

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        file.resolved.name
    }

    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue { writing }

    /// Downloads the original and puts a copy where the receiver asks: the cached original expires after ten minutes.
    /// One numbered in its drag is saved under that name, so the file and its name agree.
    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL,
                             completionHandler: @escaping (Error?) -> Void) {
        let done = PromiseCompletion(call: completionHandler)
        let (client, id, renamed) = (client, assetID, file.renamed)
        Task.detached {
            do {
                let original = try await client.macIntegrationOriginal(id, name: renamed)
                try FileManager.default.copyItem(at: original, to: url)
                done.call(nil)
            } catch {
                done.call(error)
            }
        }
    }
}

/// The receiver's completion, called once the original is written, from the task that writes it.
private struct PromiseCompletion: @unchecked Sendable {
    let call: (Error?) -> Void
}
