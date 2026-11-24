// Offline checks of the grid/viewer drag payload (issues #44, #51), through real NSItemProviders.
// Run by scripts/check-integration.py ('original-drag'). URLProtocol fixtures only; no app launch, no network.
// What a receiver negotiates before the drop (advertised type, suggested name: the Finder names its file from it)
// is checked here; the Finder and other apps themselves still need a manual drop.
import AppKit
import Foundation
import Synchronization
import UniformTypeIdentifiers

/// Fixture server. `assets/{id}` answers the details (name and kind), `assets/{id}/original` the bytes.
final class OriginalFixtureProtocol: URLProtocol, @unchecked Sendable {
    static let held = Mutex<OriginalFixtureProtocol?>(nil)
    static let stalled = Mutex<[OriginalFixtureProtocol]>([])
    static let detailRequests = Mutex<[String]>([])
    static let details: [String: (type: String, name: String)] = [
        "a": ("IMAGE", "IMG_0001.HEIC"), "b": ("IMAGE", "IMG_0001.HEIC"), "held": ("IMAGE", "IMG_0001.HEIC"),
        "v": ("VIDEO", "MOV_0002.MOV"), "raw": ("IMAGE", "DSC_0003.NEF"), "audio": ("AUDIO", "voice.m4a"),
        "path": ("IMAGE", "../../Escape.JPG"),
        "p1": ("IMAGE", "P1.JPG"), "p2": ("IMAGE", "P2.JPG"), "p3": ("IMAGE", "P3.JPG"), "p4": ("IMAGE", "P4.JPG"),
        "jpg": ("IMAGE", "A.jpg"), "JPG": ("IMAGE", "A.JPG"), "jpeg": ("IMAGE", "A.jpeg"), "heic": ("IMAGE", "A.heic"), "heif": ("IMAGE", "A.heif"),
        "png": ("IMAGE", "A.png"), "gif": ("IMAGE", "A.gif"), "webp": ("IMAGE", "A.webp"), "tif": ("IMAGE", "A.tif"), "TIFF": ("IMAGE", "A.TIFF"),
        "mov": ("VIDEO", "A.mov"), "MP4": ("VIDEO", "A.MP4"), "mismatch": ("IMAGE", "Clip.mov"), "other": ("OTHER", "Sidecar.jpg"),
    ]
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        if url.lastPathComponent == "original" {
            let id = url.deletingLastPathComponent().lastPathComponent
            if id == "held" { Self.held.withLock { $0 = self }; return }
            respond(id: id)
        } else {
            let id = url.lastPathComponent
            Self.detailRequests.withLock { $0.append(id) }
            if id == "slow" { Self.stalled.withLock { $0.append(self) }; return }
            let reply = { [self] in
                guard let detail = Self.details[id] else { return send(status: 404, headers: [:], body: Data()) }
                let json: [String: Any] = ["id": id, "type": detail.type, "originalFileName": detail.name, "fileCreatedAt": "2024-01-01T00:00:00.000Z",
                                           "localDateTime": "2024-01-01T00:00:00.000Z", "isFavorite": false, "isTrashed": false]
                send(status: 200, headers: ["Content-Type": "application/json"], body: try! JSONSerialization.data(withJSONObject: json))
            }
            // Multi-item drags: the details of several items take one round trip, not one each.
            if id.hasPrefix("p") { DispatchQueue.global().asyncAfter(deadline: .now() + 0.4, execute: reply) } else { reply() }
        }
    }
    func respond(id: String) {
        let failed = id == "missing"
        let name = Self.details[id]?.name ?? "Unknown.bin"
        send(status: failed ? 404 : 200, headers: failed ? [:] : ["Content-Disposition": "attachment; filename=\"\(name)\""], body: Data("original-\(id)".utf8))
    }
    func send(status: Int, headers: [String: String], body: Data) {
        client!.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!,
                            cacheStoragePolicy: .notAllowed)
        client!.urlProtocol(self, didLoad: body)
        client!.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main struct OriginalDragChecks {
    static func provider(_ item: OriginalTransfer) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.register(item)
        return provider
    }

    /// The bytes and name a receiver gets by loading the advertised type. `whileOpen` runs while the receiver
    /// still holds the file, as a receiver reading it later would.
    static func file(_ provider: NSItemProvider, whileOpen: @escaping @Sendable () -> Void = {}) async -> Result<(String, Data), Error> {
        await withCheckedContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: provider.registeredTypeIdentifiers[0]) { url, error in
                whileOpen()
                if let url, let data = try? Data(contentsOf: url) { continuation.resume(returning: .success((url.lastPathComponent, data))) }
                else { continuation.resume(returning: .failure(error ?? CocoaError(.fileReadUnknown))) }
            }
        }
    }

    /// What a receiver in another app is handed: the drag pasteboard carries the advertised type's bytes but not the
    /// suggested name, so its provider is unnamed data of that type (as built by UIKit for Mac Catalyst apps such
    /// as WhatsApp), and the file it asks for is named by the type alone. Returns that file's extension and bytes.
    static func received(_ provider: NSItemProvider) async -> (type: String, fileExtension: String, bytes: Data)? {
        let type = provider.registeredTypeIdentifiers[0]
        let data: Data? = await withCheckedContinuation { continuation in
            _ = provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in continuation.resume(returning: data) }
        }
        guard let data else { return nil }
        let receiver = NSItemProvider()
        receiver.registerDataRepresentation(forTypeIdentifier: type, visibility: .all) { completion in completion(data, nil); return nil }
        return await withCheckedContinuation { continuation in
            _ = receiver.loadInPlaceFileRepresentation(forTypeIdentifier: UTType.data.identifier) { url, _, _ in
                continuation.resume(returning: url.flatMap { url in (try? Data(contentsOf: url)).map { (type, url.pathExtension, $0) } })
            }
        }
    }

    static func albumIDs(_ provider: NSItemProvider) async -> [String]? {
        await withCheckedContinuation { continuation in
            _ = provider.loadTransferable(type: AlbumAssetTransfer.self) { continuation.resume(returning: try? $0.get().ids) }
        }
    }

    static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("original-drag-test-" + UUID().uuidString, isDirectory: true)
        let lockedRoot = root.appendingPathComponent("Locked", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OriginalFixtureProtocol.self]
        let session = URLSession(configuration: configuration)
        let server = URL(string: "https://fixture.invalid/api")!
        let client = ImmichClient(serverURL: server, apiURL: server, credential: nil, session: session, transferRoot: root)
        let lockedClient = ImmichClient(serverURL: server, apiURL: server, credential: nil, session: session, transferRoot: lockedRoot)
        let image = UTType.image.identifier, movie = UTType.movie.identifier, data = UTType.data.identifier
        let marker = UTType.immichOriginalDrag.identifier, ids = UTType.albumAssetIDs.identifier

        // Cells and the viewer build items all the time; only a drag reads the details.
        _ = (0..<100).map { _ in OriginalTransfer(id: "a", client: client, albumIDs: ["a"]) }
        precondition(OriginalFixtureProtocol.detailRequests.withLock { $0.isEmpty }, "Building drag items must not request details")

        // Grid photo: the original first, advertised in its own format under its real name (receivers such as the
        // Finder name the file from it before the download), then the in-app marker and album IDs. Never JSON alone.
        let heic = UTType.heic.identifier
        let grid = provider(OriginalTransfer(id: "a", client: client, albumIDs: ["a"]))
        precondition(grid.registeredTypeIdentifiers == [heic, marker, ids], "\(grid.registeredTypeIdentifiers)")
        precondition(grid.suggestedName == "IMG_0001.HEIC", "\(grid.suggestedName ?? "nil")")
        precondition(grid.hasItemConformingToTypeIdentifier(image) && grid.hasItemConformingToTypeIdentifier(data))
        precondition(!grid.hasItemConformingToTypeIdentifier(movie) && !grid.hasItemConformingToTypeIdentifier(UTType.jpeg.identifier),
                     "A HEIC is not advertised as a movie or a JPEG")
        precondition(UploadDropPolicy.isInternal([grid], pasteboard: .withUniqueName()), "Upload targets reject grid drags")
        // The receiver's file outlives the app's cached original, which expires.
        guard case .success(let (name, bytes)) = await file(grid, whileOpen: { MacTransferCache.prune(root: root, now: .distantFuture) }) else {
            preconditionFailure("Grid drag must export the original")
        }
        precondition(name == "IMG_0001.HEIC" && bytes == Data("original-a".utf8), "Original bytes with the real filename, got \(name)")
        let gridIDs = await albumIDs(grid)
        precondition(gridIDs == ["a"], "Album rows still read the asset IDs")

        // Each kind under its own type and name, bytes unchanged: videos, RAW (no exact type: its kind), and others
        // as plain data.
        for (id, type, expected) in [("v", UTType.quickTimeMovie.identifier, "MOV_0002.MOV"), ("raw", image, "DSC_0003.NEF"), ("audio", data, "voice.m4a"),
                                     ("path", UTType.jpeg.identifier, "Escape.JPG")] {
            let item = provider(OriginalTransfer(id: id, client: client, albumIDs: [id]))
            precondition(item.registeredTypeIdentifiers == [type, marker, ids], "\(id): \(item.registeredTypeIdentifiers)")
            precondition(item.suggestedName == expected, "\(id): \(item.suggestedName ?? "nil")")
            guard case .success(let (_, bytes)) = await file(item) else { preconditionFailure("\(id) must export") }
            precondition(bytes == Data("original-\(id)".utf8))
        }

        // Every exact format has its own representation, whatever the case of the extension, and keeps its name
        // (no extension added or replaced). An extension of the other kind, or on another kind of asset, is not used.
        let formats: [(String, UTType)] = [("jpg", .jpeg), ("JPG", .jpeg), ("jpeg", .jpeg), ("heic", .heic), ("heif", .heif), ("png", .png), ("gif", .gif),
                                           ("webp", .webP), ("tif", .tiff), ("TIFF", .tiff), ("mov", .quickTimeMovie), ("MP4", .mpeg4Movie)]
        precondition(Set(formats.map(\.1)) == Set(OriginalFile.formats), "Every advertised format is checked")
        for (id, type) in formats {
            let item = provider(OriginalTransfer(id: id, client: client, albumIDs: [id]))
            precondition(item.registeredTypeIdentifiers == [type.identifier, marker, ids], "\(id): \(item.registeredTypeIdentifiers)")
            guard case .success(let (name, bytes)) = await file(item) else { preconditionFailure("\(id) must export") }
            precondition(name == "A.\(id)" && bytes == Data("original-\(id)".utf8), "\(id): \(name)")
            // A receiver in another app (WhatsApp) gets the type's bytes without the name: the original, untouched,
            // in a file whose extension is still that format's. Image receivers take it as an image.
            guard let other = await received(item) else { preconditionFailure("\(id) must reach a data receiver") }
            precondition(other.bytes == bytes && UTType(filenameExtension: other.fileExtension) == type, "\(id): .\(other.fileExtension)")
            precondition(item.canLoadObject(ofClass: NSImage.self) == type.conforms(to: .image), "\(id): image receivers")
        }
        for (id, type) in [("mismatch", image), ("other", data)] {
            let item = provider(OriginalTransfer(id: id, client: client))
            precondition(item.registeredTypeIdentifiers == [type, marker], "\(id): \(item.registeredTypeIdentifiers)")
        }
        // Known limit: a kind has no extension, so a data receiver's file has none either (RAW, other video formats).
        let rawReceived = await received(provider(OriginalTransfer(id: "raw", client: client)))
        precondition(rawReceived?.bytes == Data("original-raw".utf8) && UTType(filenameExtension: rawReceived!.fileExtension)?.conforms(to: .image) != true)

        // Details unavailable: generic data named after the asset, never a guessed type; the file still arrives.
        let unknown = provider(OriginalTransfer(id: "nodetails", client: client, albumIDs: ["nodetails"]))
        precondition(unknown.registeredTypeIdentifiers == [data, marker, ids] && unknown.suggestedName == "nodetails")
        guard case .success = await file(unknown) else { preconditionFailure("The original must still export") }

        // Details too slow: the drag starts after the timeout, with the fallback.
        let slowStart = Date()
        let slowItem = OriginalTransfer(id: "slow", client: client)
        let slow = provider(slowItem)
        let waited = Date().timeIntervalSince(slowStart)
        precondition(slow.registeredTypeIdentifiers == [data, marker] && slow.suggestedName == "slow")
        precondition(waited >= OriginalFile.timeout * 0.9 && waited < OriginalFile.timeout + 0.5, "Waited \(waited)s")

        // A response after the deadline cannot change the type/name between representation conditions.
        let lateJSON: [String: Any] = ["id": "slow", "type": "IMAGE", "originalFileName": "LATE.JPG",
            "fileCreatedAt": "2024-01-01T00:00:00.000Z", "localDateTime": "2024-01-01T00:00:00.000Z",
            "isFavorite": false, "isTrashed": false]
        OriginalFixtureProtocol.stalled.withLock { $0.removeFirst() }.send(status: 200,
            headers: ["Content-Type": "application/json"], body: try JSONSerialization.data(withJSONObject: lateJSON))
        try await Task.sleep(for: .milliseconds(100))
        precondition(slowItem.file.resolved == .init(name: "slow", type: .data))
        let late = provider(slowItem)
        precondition(late.registeredTypeIdentifiers == [data, marker] && late.suggestedName == "slow")

        // A multi-item drag reads every item's details at once (one 0.4 s round trip, not four).
        let batchStart = Date()
        let batch = ["p1", "p2", "p3", "p4"].map { OriginalTransfer(id: $0, client: client, albumIDs: [$0]) }
        batch.forEach { $0.file.start() }
        let names = batch.map { provider($0).suggestedName }
        let batchTime = Date().timeIntervalSince(batchStart)
        precondition(names == ["P1.JPG", "P2.JPG", "P3.JPG", "P4.JPG"], "\(names)")
        precondition(batchTime < 1, "Details of a multi-item drag took \(batchTime)s")

        // Duplicate original filenames from a multi-item drag stay separate files.
        guard case .success(let (otherName, otherBytes)) = await file(provider(OriginalTransfer(id: "b", client: client, albumIDs: ["b"]))) else {
            preconditionFailure("Second item must export")
        }
        precondition(otherName == name && otherBytes == Data("original-b".utf8))
        guard case .success = await file(provider(OriginalTransfer(id: "a", client: client))) else { preconditionFailure("Again") }
        let cached = (fm.enumerator(at: root.appendingPathComponent("Drags"), includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
            .filter { $0.lastPathComponent == "IMG_0001.HEIC" }
        let cachedBytes = Set(try cached.map { try Data(contentsOf: $0) })
        precondition(cachedBytes == [Data("original-a".utf8), Data("original-b".utf8)], "Same-named originals must not overwrite each other")

        // One drag's names are decided together, in its order: a name an earlier original has, whatever its case, gets
        // a number before its extension, as the Finder numbers a copy; the type stays.
        let named = OriginalDrag.named([.init(name: "IMG_0001.HEIC", type: .heic), .init(name: "img_0001.heic", type: .heic),
                                        .init(name: "IMG_0001.HEIC", type: .heic), .init(name: "Other.JPG", type: .jpeg),
                                        .init(name: "IMG_0001 2.HEIC", type: .heic), .init(name: "Notes", type: .data),
                                        .init(name: "notes", type: .data)])
        precondition(named.map(\.resolved.name) == ["IMG_0001.HEIC", "img_0001 2.heic", "IMG_0001 3.HEIC", "Other.JPG",
                                                     "IMG_0001 2 2.HEIC", "Notes", "notes 2"], "\(named.map(\.resolved.name))")
        precondition(named.map(\.renamed) == [false, true, true, false, true, false, true])
        precondition(named.map(\.resolved.type) == [.heic, .heic, .heic, .jpeg, .heic, .data, .data])

        // Through the items a receiver gets: the second original of a name is suggested, and saved, numbered; the
        // details are read once for the whole drag; one without details is named after its asset.
        let requestsBefore = OriginalFixtureProtocol.detailRequests.withLock { $0.count }
        let together = OriginalDrag(ids: ["b", "a", "nodetails", "v"], client: client)
        together.start()
        let togetherItems = ["b", "a", "nodetails", "v"].enumerated().map { position, id in
            provider(OriginalTransfer(id: id, client: client, albumIDs: [id], file: together.file(at: position)))
        }
        precondition(togetherItems.map(\.suggestedName) == ["IMG_0001.HEIC", "IMG_0001 2.HEIC", "nodetails", "MOV_0002.MOV"],
                     "\(togetherItems.map(\.suggestedName))")
        precondition(togetherItems.map { $0.registeredTypeIdentifiers[0] } == [heic, heic, data, UTType.quickTimeMovie.identifier])
        let requestsMade = OriginalFixtureProtocol.detailRequests.withLock { $0.count } - requestsBefore
        precondition(requestsMade == 4, "One details request per original in a drag, got \(requestsMade)")
        guard case .success(let (firstName, firstBytes)) = await file(togetherItems[0]),
              case .success(let (secondName, secondBytes)) = await file(togetherItems[1]) else {
            preconditionFailure("Both same-named originals must export")
        }
        precondition(firstName == "IMG_0001.HEIC" && firstBytes == Data("original-b".utf8), firstName)
        precondition(secondName == "IMG_0001 2.HEIC" && secondBytes == Data("original-a".utf8), "The numbered original is saved under its number: \(secondName)")
        precondition(together.file(at: 0).renamed == nil && together.file(at: 1).renamed == "IMG_0001 2.HEIC")

        // A large drag waits no longer than a small one, and stops reading details once its names are decided.
        let large = (0..<100).map { "p-large-\($0)" }
        let largeStart = Date()
        let largeDrag = OriginalDrag(ids: large, client: client)
        largeDrag.start()
        let largeNames = large.indices.map { largeDrag.file(at: $0).resolved.name }
        let largeTime = Date().timeIntervalSince(largeStart)
        precondition(largeNames == large && largeTime < OriginalFile.timeout + 0.5, "A large drag waited \(largeTime)s")
        try await Task.sleep(for: .seconds(1))
        let largeRequests = OriginalFixtureProtocol.detailRequests.withLock { $0.filter { $0.hasPrefix("p-large-") }.count }
        precondition(largeRequests < large.count, "Details are read \(OriginalDrag.concurrentLookups) at a time, and no more once decided: \(largeRequests)")

        // A container drag delivers one item per asset; album drops add each ID once, in order.
        precondition(AlbumAssetTransfer.mergedIDs([.init(ids: ["a", "b"]), .init(ids: ["b", "c"]), .init(ids: ["a"])]) == ["a", "b", "c"])

        // Viewer and Locked Folder items: file and marker only, no album IDs.
        let locked = provider(OriginalTransfer(id: "a", client: lockedClient))
        precondition(locked.registeredTypeIdentifiers == [heic, marker], "\(locked.registeredTypeIdentifiers)")
        let lockedIDs = await albumIDs(locked)
        precondition(lockedIDs == nil)
        precondition(UploadDropPolicy.isInternal([locked], pasteboard: .withUniqueName()))

        // A failed download fails the drag rather than handing over anything else.
        guard case .failure = await file(provider(OriginalTransfer(id: "missing", client: client, albumIDs: ["missing"]))) else {
            preconditionFailure("A failed download must not succeed")
        }

        // Locking during a download: the revoked directory is never recreated and the drag fails.
        let heldProvider = provider(OriginalTransfer(id: "held", client: lockedClient))
        let pending = Task { await file(heldProvider) }
        while OriginalFixtureProtocol.held.withLock({ $0 == nil }) { try await Task.sleep(for: .milliseconds(10)) }
        MacTransferCache.discard(root: lockedRoot)
        OriginalFixtureProtocol.held.withLock { $0 }!.respond(id: "held")
        guard case .failure = await pending.value else { preconditionFailure("Locked drag must fail after locking") }
        precondition(!fm.fileExists(atPath: lockedRoot.path), "Locked transfer root must stay deleted")

        // The collection view's grid drags promised files (OriginalFilePromise): the promise first, then the in-app
        // marker and the photo's ID for album drops; the file named as its drag names it, numbered with the drag's
        // others, and written where the receiver asks with the original's bytes. A Locked Folder photo has no ID.
        let promisedDrag = OriginalDrag(ids: ["b", "a"], client: client)
        promisedDrag.start()
        let promises = ["b", "a"].enumerated().map { position, id in
            OriginalFilePromise(id: id, file: promisedDrag.file(at: position), client: client, albumIDs: [id])
        }
        let pasteboard = NSPasteboard.withUniqueName()
        let promiseTypes = promises[1].writableTypes(for: pasteboard).map(\.rawValue)
        precondition(promiseTypes.first.map { $0 != marker && $0 != ids } == true && promiseTypes.contains(marker) && promiseTypes.contains(ids),
                     "The promise first, then the marker and the IDs: \(promiseTypes)")
        precondition(promises.map(\.fileType) == [heic, heic], "\(promises.map(\.fileType))")
        let promisedNames = promises.map { $0.filePromiseProvider($0, fileNameForType: $0.fileType) }
        precondition(promisedNames == ["IMG_0001.HEIC", "IMG_0001 2.HEIC"], "\(promisedNames)")
        let promisedIDs = (promises[1].pasteboardPropertyList(forType: .init(ids)) as? Data)
            .flatMap { try? JSONDecoder().decode(AlbumAssetTransfer.self, from: $0).ids }
        precondition(promisedIDs == ["a"], "Album rows read the photo's ID: \(String(describing: promisedIDs))")
        let dropped = root.appendingPathComponent("Dropped", isDirectory: true)
        try fm.createDirectory(at: dropped, withIntermediateDirectories: true)
        for (promise, name) in zip(promises, promisedNames) {
            let error: Error? = await withCheckedContinuation { continuation in
                promise.filePromiseProvider(promise, writePromiseTo: dropped.appendingPathComponent(name)) { continuation.resume(returning: $0) }
            }
            precondition(error == nil, "\(name): \(String(describing: error))")
        }
        let droppedBytes = try promisedNames.map { try Data(contentsOf: dropped.appendingPathComponent($0)) }
        precondition(droppedBytes == [Data("original-b".utf8), Data("original-a".utf8)], "The numbered original is written under its number")
        let lockedPromise = OriginalFilePromise(id: "a", file: OriginalFile(id: "a", client: client), client: client, albumIDs: nil)
        let lockedTypes = lockedPromise.writableTypes(for: pasteboard).map(\.rawValue)
        precondition(lockedTypes.contains(marker) && !lockedTypes.contains(ids), "\(lockedTypes)")
        let missingPromise = OriginalFilePromise(id: "missing", file: OriginalFile(id: "missing", client: client), client: client,
                                                 albumIDs: ["missing"])
        let missingError: Error? = await withCheckedContinuation { continuation in
            missingPromise.filePromiseProvider(missingPromise, writePromiseTo: dropped.appendingPathComponent("missing")) {
                continuation.resume(returning: $0)
            }
        }
        precondition(missingError != nil, "A failed download fails the promise")

        print("Original drag checks passed: exact format or kind and real name before the download, a data receiver's file, original bytes, receiver copy outlives the cache, fallbacks, multi-item details, one drag's names numbered together and its large drags bounded, in-app IDs/marker, duplicates, failure, Locked Folder revocation, the grid's promised files")
    }
}
