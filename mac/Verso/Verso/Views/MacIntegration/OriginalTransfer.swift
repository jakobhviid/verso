import CoreTransferable
import Foundation
import Synchronization
import UniformTypeIdentifiers

/// The single drag payload of a grid or viewer asset. Outside the app it is only the original
/// file; the marker and album asset IDs follow it for the app's own drop targets. The iPhone's and the iPad's tiles
/// drag it too, without album IDs (ios/Verso/Grid/TimelineGrid.swift).
struct OriginalTransfer: Transferable, Identifiable, Sendable {
    let id: String
    var isVideo = false
    let client: ImmichClient
    /// Asset IDs for album drops. `nil` (Locked Folder, viewer) exports no album representation.
    var albumIDs: [String]? = nil
    /// The original's name and type, read only once a drag starts: its own, or its place in a drag of several.
    let file: OriginalFile

    init(id: String, isVideo: Bool = false, client: ImmichClient, albumIDs: [String]? = nil, file: OriginalFile? = nil) {
        self.id = id
        self.isVideo = isVideo
        self.client = client
        self.albumIDs = albumIDs
        self.file = file ?? OriginalFile(id: id, client: client)
    }

    static var transferRepresentation: some TransferRepresentation {
        // The original first: the Finder saves the first representation it can. Exactly one of these is exported,
        // with its real name: receivers name the file before it is downloaded. It is the original's own format
        // when known, else its kind: data-only receivers can decode public.jpeg and derive an extension,
        // whereas public.image can leave them an unnamed temporary file with no usable extension.
        formats
        original(.image)
        original(.movie)
        original(.data)
        ProxyRepresentation(exporting: { _ in OriginalDragMarker() })
        ProxyRepresentation(exporting: { item in AlbumAssetTransfer(ids: item.albumIDs ?? []) })
            .exportingCondition { $0.albumIDs != nil }
    }

    /// CoreTransferable takes one static type per representation: one for each of `OriginalFile.formats`.
    @TransferRepresentationBuilder<OriginalTransfer>
    private static var formats: some TransferRepresentation<OriginalTransfer> {
        original(.jpeg)
        original(.heic)
        original(.heif)
        original(.png)
        original(.gif)
        original(.webP)
        original(.tiff)
        original(.quickTimeMovie)
        original(.mpeg4Movie)
    }

    private static func original(_ type: UTType) -> some TransferRepresentation<OriginalTransfer> {
        FileRepresentation(exportedContentType: type) { item in
            // A copy for the receiver: the cached original expires after ten minutes. One numbered in its drag is
            // saved under that name too, so the file and its suggested name agree.
            SentTransferredFile(try await item.client.macIntegrationOriginal(item.id, name: item.file.renamed),
                                allowAccessingOriginalFile: false)
        }
        .exportingCondition { $0.file.resolved.type == type }
        .suggestedFileName { $0.file.resolved.name }
    }
}

/// The name and type of one original in a drag (`OriginalDrag`), which receivers such as the Finder take when the
/// drag starts, before the original is downloaded.
struct OriginalFile: Sendable {
    struct Resolved: Sendable, Equatable {
        let name: String
        /// One of `formats` when the name's extension is one, else `.image`, `.movie` or `.data`: Immich's kind of asset.
        let type: UTType
    }

    /// The formats advertised under their own type. `OriginalTransfer` has a representation for each.
    static let formats: [UTType] = [.jpeg, .heic, .heif, .png, .gif, .webP, .tiff, .quickTimeMovie, .mpeg4Movie]

    /// How long a drag waits for the details before it starts with what it has.
    static let timeout: TimeInterval = 1
    private let drag: OriginalDrag
    private let position: Int

    /// An original dragged alone.
    init(id: String, client: ImmichClient) {
        self.init(drag: OriginalDrag(ids: [id], client: client), position: 0)
    }

    /// One of the originals dragged together.
    init(drag: OriginalDrag, position: Int) {
        self.drag = drag
        self.position = position
    }

    /// Starts reading the details of every original in the drag at once.
    func start() { drag.start() }

    /// The server's name, numbered when an earlier original in the drag has it, and kind; or the asset ID and generic
    /// data when they don't arrive in time.
    var resolved: Resolved { drag.decision(at: position).resolved }

    /// The numbered name, when an earlier original in the drag has the server's.
    var renamed: String? {
        let decision = drag.decision(at: position)
        return decision.renamed ? decision.resolved.name : nil
    }

    static func resolve(_ asset: AssetResponse) -> Resolved {
        let name = (asset.originalFileName as NSString).lastPathComponent
        let kind: UTType = switch asset.type {
        case .image: .image
        case .video: .movie
        default: .data
        }
        // From the extension, so the type always agrees with the suggested name. Never for other kinds of asset.
        let format = kind == .data ? nil : UTType(filenameExtension: (name as NSString).pathExtension, conformingTo: kind)
        return Resolved(name: name.isEmpty || name == "." || name == ".." ? asset.id : name,
                        type: format.flatMap { formats.contains($0) ? $0 : nil } ?? kind)
    }
}

/// The originals of one drag: a photo dragged alone, or the selection dragged from the grid. The timeline has no
/// names or formats, so they come from the assets' details, read for the dragged assets alone once the drag starts,
/// `concurrentLookups` at a time, and waited for only briefly (`OriginalFile.timeout`), since the drag can't start
/// until then; what hasn't arrived by then is named after its asset, and nothing more is read. The names are decided
/// together, in the drag's order, and once: one an earlier original in the drag already has gets a number, as the
/// Finder numbers a copy ("IMG_0001 2.HEIC"), so the files of one drop never share a name. Nothing is downloaded until
/// a receiver asks for the file.
final class OriginalDrag: Sendable {
    struct Decision: Sendable, Equatable {
        let resolved: OriginalFile.Resolved
        /// Numbered to tell it from an earlier original in the drag.
        let renamed: Bool
    }

    /// Details read at a time: a few hundred arrive in the time a drag waits, and the server is never flooded.
    static let concurrentLookups = 16
    private let ids: [String]
    private let client: ImmichClient
    private let lookups = DispatchGroup()
    private struct State {
        var started: Date?
        var found: [Int: OriginalFile.Resolved] = [:]
        var reading: Task<Void, Never>?
        var decisions: [Decision]?
    }
    private let state = Mutex(State())

    init(ids: [String], client: ImmichClient) {
        self.ids = ids
        self.client = client
    }

    /// The original of the asset at `position` in the drag.
    func file(at position: Int) -> OriginalFile { OriginalFile(drag: self, position: position) }

    /// Starts reading the details, once.
    func start() {
        state.withLock { state in
            guard state.started == nil else { return }
            let started = Date()
            state.started = started
            lookups.enter()
            let (ids, client) = (ids, client)
            state.reading = Task.detached { [self] in
                await withTaskGroup(of: Void.self) { group in
                    for (position, id) in ids.enumerated() {
                        if position >= Self.concurrentLookups { await group.next() }
                        // Once the names are decided, or the drag has waited its while, the rest are not read.
                        if Task.isCancelled || Date().timeIntervalSince(started) > OriginalFile.timeout { break }
                        group.addTask {
                            guard let asset = try? await client.asset(id) else { return }
                            self.state.withLock { $0.found[position] = OriginalFile.resolve(asset) }
                        }
                    }
                }
                lookups.leave()
            }
        }
    }

    /// The name and type of the original at `position`, decided for the whole drag the first time any is asked for.
    func decision(at position: Int) -> Decision {
        if let decisions = state.withLock({ $0.decisions }) { return decisions[position] }
        start()
        let deadline = state.withLock { $0.started! }.addingTimeInterval(OriginalFile.timeout)
        _ = lookups.wait(timeout: .now() + max(0, deadline.timeIntervalSinceNow))
        return state.withLock { state in
            if state.decisions == nil {
                state.decisions = Self.named(ids.indices.map { state.found[$0] ?? .init(name: ids[$0], type: .data) })
                state.reading?.cancel()
            }
            return state.decisions![position]
        }
    }

    /// The names in the drag's order, each one an earlier original already has numbered. Names are compared as the
    /// Mac's file systems compare them, whatever their case.
    static func named(_ originals: [OriginalFile.Resolved]) -> [Decision] {
        var taken = Set<String>()
        var lastNumber: [String: Int] = [:]
        return originals.map { original in
            let key = comparable(original.name)
            var name = original.name
            var number = lastNumber[key, default: 1]
            while taken.contains(comparable(name)) {
                number += 1
                name = numbered(original.name, number)
            }
            lastNumber[key] = number
            taken.insert(comparable(name))
            return Decision(resolved: .init(name: name, type: original.type), renamed: name != original.name)
        }
    }

    /// The name with a number before its extension, as the Finder names a copy.
    static func numbered(_ name: String, _ number: Int) -> String {
        let stem = (name as NSString).deletingPathExtension
        let fileExtension = (name as NSString).pathExtension
        return fileExtension.isEmpty ? "\(stem) \(number)" : "\(stem) \(number).\(fileExtension)"
    }

    private static func comparable(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.lowercased()
    }
}

/// Marks original-file drags without changing their file representation or album selection, so the app's own drop
/// targets that import files leave its own photos alone.
struct OriginalDragMarker: Codable, Transferable {
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .immichOriginalDrag)
    }
}

extension UTType {
    static let immichOriginalDrag = UTType(exportedAs: "dev.hviid.Verso.original-drag", conformingTo: .data)
}
