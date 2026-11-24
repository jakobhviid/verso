// Backing up's PhotoKit side (ARCHITECTURE.md, "Backing the iPhone up", "Reading the library"), platform-neutral Swift
// with no UIKit:
// - Full access to the library is needed; with limited access the Backup page says why.
// - The first run saves the library's change token, then lists every photo in pages of 500, newest first, a row each
//   (BackupStore's `photo`), resuming after the last page written if it was cut short.
// - Each later run reads only what changed since the token (`fetchPersistentChanges(since:)`), each change's rows
//   saved with its token. An expired token or lost details mean a full reconcile, which a weekly one repeats: every
//   identifier and modification date compared with the store's.
// - Local identifiers can change after a new iPhone's Quick Start or an iOS update: photos that vanish are looked up by
//   the iCloud identifier kept for them (`PHCloudIdentifier`), and one found under a new identifier keeps its rows.
// - A photo's parts are its stored resources with content of their own (BackupPartRole): the original, a Live Photo's
//   video, RAW+JPEG's second file, an edit's rendering and its video. Never a fresh render or export, whose bytes differ
//   every time. An edit's adjustment data is fingerprinted, so its rendering is read again only when it changes.
// - Hidden photos are listed, marked hidden, and backed up into Immich's Locked Folder where Hidden Photos is on. iOS
//   shows them to apps only while Photos' Use Face ID is off; while it is on, they are as gone. iCloud Shared Albums and
//   photos synced from a computer are left out.

import CoreLocation
import CryptoKit
import Foundation
import Photos

enum BackupLibrary {
    /// Backing up needs the whole library.
    static var hasFullAccess: Bool { PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized }

    static var accessStatus: PHAuthorizationStatus { PHPhotoLibrary.authorizationStatus(for: .readWrite) }

    static func requestAccess() async -> PHAuthorizationStatus {
        await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }

    /// The fetch every listing uses: the person's own library, every frame of a burst, and hidden photos where asked
    /// for, which every listing and change does (whether they are backed up is the store's question).
    static func fetchOptions(includingHidden: Bool = false) -> PHFetchOptions {
        let options = PHFetchOptions()
        options.includeAllBurstAssets = true
        options.includeHiddenAssets = includingHidden
        options.includeAssetSourceTypes = [.typeUserLibrary]
        return options
    }

    static func asset(_ identifier: String) -> PHAsset? {
        PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: fetchOptions(includingHidden: true)).firstObject
    }

    // MARK: Free Up Space

    /// The phone's own albums, for Always Keep: their identifiers, names and sizes.
    static func albums() -> [(id: String, title: String, count: Int)] {
        let collections = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil)
        var albums: [(id: String, title: String, count: Int)] = []
        collections.enumerateObjects { collection, _, _ in
            let count = PHAsset.fetchAssets(in: collection, options: nil).count
            albums.append((collection.localIdentifier, collection.localizedTitle ?? "", count))
        }
        return albums.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// The photos in these albums, by their local identifiers.
    static func members(ofAlbums identifiers: [String]) -> Set<String> {
        guard !identifiers.isEmpty else { return [] }
        var members = Set<String>()
        let collections = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: identifiers, options: nil)
        collections.enumerateObjects { collection, _, _ in
            PHAsset.fetchAssets(in: collection, options: nil).enumerateObjects { asset, _, _ in members.insert(asset.localIdentifier) }
        }
        return members
    }

    /// Whether a photo's original is stored on the phone, or only in iCloud: its first bytes asked for without the
    /// network, and the request ended there. Deleting one only in iCloud deletes it from iCloud and every device.
    static func isOnPhone(_ identifier: String) async -> Bool {
        guard let asset = asset(identifier), let resource = BackupParts.resource(.original, of: asset) else { return false }
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = false
        let answer = OnPhoneAnswer()
        return await withCheckedContinuation { continuation in
            answer.continuation = continuation
            let request = PHAssetResourceManager.default().requestData(for: resource, options: options) { _ in
                answer.give(true)
            } completionHandler: { error in
                answer.give(error == nil)
            }
            answer.started(request)
        }
    }

    // MARK: Rows

    /// A photo's row, its iCloud identifier given where it was mapped. Its name comes with its parts, which are read
    /// later, as reading every photo's resources would slow the listing down.
    static func row(_ asset: PHAsset, cloudID: String?) -> BackupPhotoRow {
        BackupPhotoRow(localID: asset.localIdentifier, cloudID: cloudID, created: asset.creationDate,
                              added: asset.addedDate, modified: asset.modificationDate, kind: asset.mediaType.rawValue,
                              subtypes: Int(asset.mediaSubtypes.rawValue), favorite: asset.isFavorite,
                              hidden: asset.isHidden, burst: asset.burstIdentifier, burstPick: asset.representsBurst,
                              latitude: asset.location?.coordinate.latitude, longitude: asset.location?.coordinate.longitude,
                              name: nil)
    }

    /// The rows of these assets, with their iCloud identifiers mapped in one call.
    static func rows(_ assets: [PHAsset]) -> [BackupPhotoRow] {
        let mappings = cloudIdentifiers(assets.map(\.localIdentifier))
        return assets.map { row($0, cloudID: mappings[$0.localIdentifier]) }
    }

    static func cloudIdentifiers(_ identifiers: [String]) -> [String: String] {
        guard !identifiers.isEmpty else { return [:] }
        var found: [String: String] = [:]
        for (local, result) in PHPhotoLibrary.shared().cloudIdentifierMappings(forLocalIdentifiers: identifiers) {
            if case .success(let cloud) = result { found[local] = cloud.stringValue }
        }
        return found
    }

    /// The local identifiers these iCloud identifiers have on this phone now.
    static func localIdentifiers(forCloud cloudIDs: [String]) -> [String: String] {
        guard !cloudIDs.isEmpty else { return [:] }
        var found: [String: String] = [:]
        let identifiers = cloudIDs.map { PHCloudIdentifier(stringValue: $0) }
        for (cloud, result) in PHPhotoLibrary.shared().localIdentifierMappings(for: identifiers) {
            if case .success(let local) = result { found[cloud.stringValue] = local }
        }
        return found
    }

    // MARK: The change token

    static var currentToken: Data? {
        try? NSKeyedArchiver.archivedData(withRootObject: PHPhotoLibrary.shared().currentChangeToken, requiringSecureCoding: true)
    }

    static func token(_ data: Data?) -> PHPersistentChangeToken? {
        guard let data else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: PHPersistentChangeToken.self, from: data)
    }

    static func archived(_ token: PHPersistentChangeToken) -> Data? {
        try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
    }
}

/// Reading the library into the store: the first listing, the changes since, and the full reconcile.
struct BackupDiscovery: Sendable {
    let store: BackupStore
    static let pageSize = 500

    enum Outcome: Sendable, Equatable {
        case listed(Int)
        case changed(inserted: Int, gone: Int)
        case reconciled(gone: Int, remapped: Int)
        case nothingNew
    }

    /// One pass: the first listing until it is done, then the changes since the token; a full reconcile when the
    /// changes cannot be read, or a week after the last. `listed` is told the rows written so far.
    func run(listed: @Sendable (Int) -> Void = { _ in }) async throws -> Outcome {
        guard BackupLibrary.hasFullAccess else { throw BackupError.noLibraryAccess }
        if try store.meta("listed") != "done" { return try await firstListing(listed: listed) }
        // A library first listed without its hidden photos lists them once.
        if try store.meta("hiddenListed") == nil {
            let outcome = try await reconcile()
            try store.setMeta("hiddenListed", "yes")
            return outcome
        }
        let lastReconcile = try store.metaDate("reconciled") ?? .distantPast
        if Date().timeIntervalSince(lastReconcile) > 7 * 24 * 3600 { return try await reconcile() }
        do {
            return try changesSinceToken()
        } catch let error as PHPhotosError where [.persistentChangeTokenExpired, .persistentChangeDetailsUnavailable].contains(error.code) {
            return try await reconcile()
        }
    }

    /// The first listing: the token first, then every photo newest first, a page at a time, each page saved with the
    /// date it reached so a listing cut short goes on from there.
    private func firstListing(listed: @Sendable (Int) -> Void) async throws -> Outcome {
        if try store.metaData("changeToken") == nil, let token = BackupLibrary.currentToken {
            try store.setMetaData("changeToken", token)
        }
        let options = BackupLibrary.fetchOptions(includingHidden: true)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        if let cursor = try store.metaDate("listCursor") {
            options.predicate = NSPredicate(format: "creationDate <= %@", cursor as NSDate)
        }
        let result = PHAsset.fetchAssets(with: options)
        var written = try store.photoCount()
        var start = 0
        while start < result.count {
            try Task.checkCancellation()
            let end = min(start + Self.pageSize, result.count)
            let assets = result.objects(at: IndexSet(integersIn: start..<end))
            let rows = BackupLibrary.rows(assets)
            try store.database.transaction {
                try store.upsertPhotos(rows)
                if let oldest = rows.compactMap(\.created).min() { try store.setMetaDate("listCursor", oldest) }
            }
            written += rows.count
            listed(written)
            start = end
            await Task.yield()
        }
        try store.database.transaction {
            try store.setMeta("listed", "done")
            try store.setMeta("hiddenListed", "yes")
            try store.setMetaDate("reconciled", Date())
        }
        return .listed(written)
    }

    /// What changed since the token: each change's photos written with its token, in one transaction.
    private func changesSinceToken() throws -> Outcome {
        guard let token = BackupLibrary.token(try store.metaData("changeToken")) else {
            throw PHPhotosError(.persistentChangeTokenExpired)
        }
        let changes = try PHPhotoLibrary.shared().fetchPersistentChanges(since: token)
        var inserted = 0
        var goneCount = 0
        for change in changes {
            let details = try change.changeDetails(for: .asset)
            let changed = details.insertedLocalIdentifiers.union(details.updatedLocalIdentifiers)
            let found = PHAsset.fetchAssets(withLocalIdentifiers: Array(changed), options: BackupLibrary.fetchOptions(includingHidden: true))
            var assets: [PHAsset] = []
            found.enumerateObjects { asset, _, _ in assets.append(asset) }
            try adoptRenamed(Set(details.insertedLocalIdentifiers).intersection(assets.map(\.localIdentifier)),
                             deleted: details.deletedLocalIdentifiers)
            let rows = BackupLibrary.rows(assets)
            let foundIDs = Set(assets.map(\.localIdentifier))
            let gone = Array(details.deletedLocalIdentifiers) + changed.filter { !foundIDs.contains($0) }
            try store.upsertPhotos(rows, gone: gone, token: BackupLibrary.archived(change.changeToken))
            inserted += details.insertedLocalIdentifiers.count
            goneCount += details.deletedLocalIdentifiers.count
        }
        return inserted + goneCount == 0 ? .nothingNew : .changed(inserted: inserted, gone: goneCount)
    }

    /// New identifiers that are photos the store knows under an old one that is gone, found by their iCloud
    /// identifier: the old rows follow them, so they are not taken for new.
    private func adoptRenamed(_ inserted: Set<String>, deleted: Set<String>) throws {
        guard !inserted.isEmpty else { return }
        let clouds = BackupLibrary.cloudIdentifiers(Array(inserted))
        let known = try store.photosByCloudIdentifier(Array(clouds.values))
        for (local, cloud) in clouds {
            guard let old = known[cloud], old != local else { continue }
            let oldIsGone = try store.photo(old)?.gone ?? false
            if deleted.contains(old) || oldIsGone {
                try store.remap(from: old, to: local)
            }
        }
    }

    /// The whole library compared with the store: identifiers that vanished are looked up by their iCloud
    /// identifiers before they are taken as gone, and every photo's row is written again, its parts read again where its
    /// modification date changed. The token taken before it is saved after.
    func reconcile() async throws -> Outcome {
        let token = BackupLibrary.currentToken
        let options = BackupLibrary.fetchOptions(includingHidden: true)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let result = PHAsset.fetchAssets(with: options)
        var library = Set<String>()
        library.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in library.insert(asset.localIdentifier) }
        // The store's identifiers, a page at a time, against the library's.
        var vanished: [String] = []
        var known = Set<String>()
        var after = ""
        while true {
            let page = try store.knownIdentifiers(after: after, limit: 5000)
            guard let last = page.last else { break }
            for identifier in page {
                known.insert(identifier)
                if !library.contains(identifier) { vanished.append(identifier) }
            }
            after = last
        }
        let appeared = library.subtracting(known)
        var remapped = 0
        if !vanished.isEmpty && !appeared.isEmpty {
            let vanishedRows = try store.photos(vanished)
            let clouds = vanishedRows.compactMap(\.cloudID)
            let current = BackupLibrary.localIdentifiers(forCloud: clouds)
            for row in vanishedRows {
                if let cloud = row.cloudID, let local = current[cloud], appeared.contains(local) {
                    try store.remap(from: row.localID, to: local)
                    remapped += 1
                }
            }
        }
        let stillVanished = try vanished.filter { try store.photo($0)?.gone == false && !library.contains($0) }
        try store.markGone(stillVanished)
        var start = 0
        while start < result.count {
            try Task.checkCancellation()
            let end = min(start + BackupDiscovery.pageSize, result.count)
            try store.upsertPhotos(BackupLibrary.rows(result.objects(at: IndexSet(integersIn: start..<end))))
            start = end
            await Task.yield()
        }
        try store.database.transaction {
            if let token { try store.setMetaData("changeToken", token) }
            try store.setMeta("listed", "done")
            try store.setMetaDate("reconciled", Date())
        }
        return .reconciled(gone: stillVanished.count, remapped: remapped)
    }
}

// MARK: Parts

enum BackupParts {
    /// The parts of a photo as Photos stores them now, with an edit's adjustment data fingerprinted. None while the
    /// camera is still finishing the photo (only its proxy is there).
    static func parts(of asset: PHAsset) async -> [BackupPartRow] {
        let resources = PHAssetResource.assetResources(for: asset)
        let original = resources.first { [.photo, .video, .audio].contains($0.type) }
        let stem = ((original?.originalFilename ?? "Photo") as NSString).deletingPathExtension
        var adjustment: String?
        if resources.contains(where: { $0.type == .fullSizePhoto || $0.type == .fullSizeVideo }),
           let data = resources.first(where: { $0.type == .adjustmentData }) {
            adjustment = await fingerprint(small: data) ?? asset.modificationDate.map { "modified \($0.timeIntervalSince1970)" }
        }
        var parts: [BackupPartRow] = []
        for resource in resources {
            guard let role = role(of: resource) else { continue }
            guard !parts.contains(where: { $0.role == role }) else { continue }
            let name: String = switch role {
            case .original, .originalPair, .alternate: resource.originalFilename
            case .render, .renderPair:
                // An edit keeps the photo's name, in its rendering's format.
                stem + "." + (resource.originalFilename as NSString).pathExtension
            }
            parts.append(BackupPartRow(localID: asset.localIdentifier, role: role, name: name, uti: resource.uniformTypeIdentifier,
                                       adjustment: role == .render || role == .renderPair ? adjustment : nil))
        }
        return parts
    }

    static func role(of resource: PHAssetResource) -> BackupPartRole? {
        switch resource.type {
        case .photo, .video, .audio: .original
        case .pairedVideo: .originalPair
        case .alternatePhoto: .alternate
        case .fullSizePhoto, .fullSizeVideo: .render
        case .fullSizePairedVideo: .renderPair
        default: nil
        }
    }

    static func resource(_ role: BackupPartRole, of asset: PHAsset) -> PHAssetResource? {
        PHAssetResource.assetResources(for: asset).first { self.role(of: $0) == role }
    }

    /// The SHA-1 of a small resource, such as an edit's adjustment data.
    private static func fingerprint(small resource: PHAssetResource) async -> String? {
        let sink = BackupSink(file: nil)
        do {
            try await BackupReader.read(resource, networkAllowed: true, into: sink)
            return sink.result.checksum
        } catch {
            return nil
        }
    }
}

/// Where a part's bytes go as they are read: always through SHA-1 (CryptoKit, streamed), counted, and into a file when
/// one is given. The same code reads a part for its fingerprint and for its upload, so the two must agree.
final class BackupSink: @unchecked Sendable {
    private let lock = NSLock()
    private var hash = Insecure.SHA1()
    private var count: Int64 = 0
    private let file: FileHandle?
    /// Stop writing past this many bytes (the disk budget), failing the read.
    let limit: Int64?

    init(file: FileHandle?, limit: Int64? = nil) {
        self.file = file
        self.limit = limit
    }

    func take(_ data: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        count += Int64(data.count)
        if let limit, count > limit { throw BackupError.noRoom(needs: count) }
        hash.update(data: data)
        try file?.write(contentsOf: data)
    }

    var result: (checksum: String, size: Int64) {
        lock.lock()
        defer { lock.unlock() }
        return (Data(hash.finalize()).base64EncodedString(), count)
    }
}

enum BackupReader {
    /// Streams a resource's stored bytes into `sink`; with the network not allowed, an original only in iCloud fails
    /// with `BackupError.inCloudOnly`.
    static func read(_ resource: PHAssetResource, networkAllowed: Bool, into sink: BackupSink) async throws {
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = networkAllowed
        let request = BackupRequest()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let identifier = PHAssetResourceManager.default().requestData(for: resource, options: options) { data in
                    do { try sink.take(data) } catch { request.fail(error) }
                } completionHandler: { error in
                    if request.isCancelled { continuation.resume(throwing: CancellationError()); return }
                    if let failure = request.failure { continuation.resume(throwing: failure); return }
                    if let error {
                        let code = (error as NSError).code
                        if !networkAllowed && code == PHPhotosError.Code.networkAccessRequired.rawValue {
                            continuation.resume(throwing: BackupError.inCloudOnly)
                        } else {
                            continuation.resume(throwing: BackupError.unreadable(error.localizedDescription))
                        }
                    } else {
                        continuation.resume()
                    }
                }
                request.started(identifier)
            }
        } onCancel: {
            request.cancel()
        }
        try Task.checkCancellation()
    }
}

/// A data request in flight, cancelled when its task is, or when the sink refuses more bytes.
private final class BackupRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var identifier: PHAssetResourceDataRequestID?
    private var cancelled = false
    private var failed: Error?

    var isCancelled: Bool { lock.withLock { cancelled } }
    var failure: Error? { lock.withLock { failed } }

    func started(_ identifier: PHAssetResourceDataRequestID) {
        lock.lock()
        self.identifier = identifier
        let cancelNow = cancelled || failed != nil
        lock.unlock()
        if cancelNow { PHAssetResourceManager.default().cancelDataRequest(identifier) }
    }

    func fail(_ error: Error) {
        lock.lock()
        let first = failed == nil
        if first { failed = error }
        let identifier = identifier
        lock.unlock()
        if first, let identifier { PHAssetResourceManager.default().cancelDataRequest(identifier) }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let identifier = identifier
        lock.unlock()
        if let identifier { PHAssetResourceManager.default().cancelDataRequest(identifier) }
    }
}

enum BackupError: LocalizedError, Equatable {
    case noLibraryAccess
    case inCloudOnly
    case unreadable(String)
    case noRoom(needs: Int64)
    case changed
    case gone

    var errorDescription: String? {
        switch self {
        case .noLibraryAccess: "Verso needs access to all of your photos to back them up."
        case .inCloudOnly: "Its original is in iCloud only."
        case .unreadable(let reason): "Photos could not read it: \(reason)"
        case .noRoom(let needs):
            "Waiting for room: it needs more than \(needs.formatted(.byteCount(style: .file))) of free space."
        case .changed: "It changed while it was read, so it is read again."
        case .gone: "It is no longer on this \(DeviceWords.model)."
        }
    }
}

/// isOnPhone's answer, given once: the first bytes say yes and end the request, an error says no.
private final class OnPhoneAnswer: @unchecked Sendable {
    private let lock = NSLock()
    var continuation: CheckedContinuation<Bool, Never>?
    private var request: PHAssetResourceDataRequestID?
    private var answered = false

    func started(_ request: PHAssetResourceDataRequestID) {
        lock.lock()
        let cancel = answered
        self.request = request
        lock.unlock()
        if cancel { PHAssetResourceManager.default().cancelDataRequest(request) }
    }

    func give(_ value: Bool) {
        lock.lock()
        guard !answered else { lock.unlock(); return }
        answered = true
        let continuation = self.continuation
        let request = self.request
        lock.unlock()
        continuation?.resume(returning: value)
        if value, let request { PHAssetResourceManager.default().cancelDataRequest(request) }
    }
}
