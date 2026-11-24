// The library the picker shows, for the app's account (PickerModel): Immich's client, through the API layer's own
// URLSession rather than the bridge, which keeps the extension small; its photo lists (PhotoFeed), the albums and
// the search; the thumbnails (PickerThumbnails); and the copy of a photo that goes into the message field
// (PickerFiles).
//
// Every list holds photos alone: a video in a conversation is the original or nothing, which is for later.

import Foundation
import ImageIO
import Observation
import UniformTypeIdentifiers

/// One of the library's photos, as a tile of the picker shows it.
struct PickerPhoto: Identifiable, Hashable, Sendable {
    /// Immich's asset. The phone's own photos (On This iPhone) would carry PhotoKit's local identifier instead.
    let id: String
    let thumbhash: String?
}

@MainActor @Observable
final class PickerLibrary {
    let client: ImmichClient
    let thumbnails: PickerThumbnails
    /// The account's server and user, to know whether the app has changed accounts since.
    private let accountKey: String

    /// Immich's timeline, newest first, with the partners shown in it, as the Library has it.
    let recents: PhotoFeed
    let favorites: PhotoFeed
    private(set) var albums: [Album]? = nil
    private(set) var albumsProblem: String? = nil
    /// The search's results, for the text last searched for; nil before a search.
    private(set) var search: PhotoFeed? = nil
    /// Whether the server searches by meaning (Immich's smart search), read once.
    @ObservationIgnored private var smartSearch: Bool?
    /// The app's account was refused by the server: the picker asks the person to open Verso.
    @ObservationIgnored var onSignInEnded: (() -> Void)?

    init(entry: AccountVault.Entry) {
        let account = entry.account
        client = ImmichClient(serverURL: account.serverURL, apiURL: account.apiURL, credential: account.credential,
                              session: Self.session)
        thumbnails = PickerThumbnails(client: client)
        accountKey = Self.key(entry)
        recents = PhotoFeed(client: client, source: .timeline(TimelineQuery(withPartners: true)))
        favorites = PhotoFeed(client: client, source: .timeline(TimelineQuery(visibility: nil, isFavorite: true)))
        for feed in [recents, favorites] { feed.onUnauthorized = { [weak self] in self?.onSignInEnded?() } }
    }

    func belongs(to entry: AccountVault.Entry) -> Bool { accountKey == Self.key(entry) }

    private static func key(_ entry: AccountVault.Entry) -> String {
        let credential = (try? JSONEncoder().encode(entry.account.credential)).map { $0.base64EncodedString() } ?? ""
        return entry.account.apiURL.absoluteString + "|" + entry.userID + "|" + credential
    }

    /// The picker's session: thumbnails kept on disk in the extension's own caches, little in memory.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = URLCache(memoryCapacity: 2 << 20, diskCapacity: 100 << 20)
        configuration.httpAdditionalHeaders = ["User-Agent": ImmichClient.userAgent]
        configuration.httpMaximumConnectionsPerHost = 6
        configuration.timeoutIntervalForRequest = 30
        return URLSession(configuration: configuration)
    }()

    /// The albums, the person's own and those shared with them, the most recently added to first.
    func loadAlbums() async {
        guard albums == nil else { return }
        do {
            albumsProblem = nil
            albums = try await client.albums()
                .filter { $0.assetCount > 0 }
                .sorted { ($0.lastModifiedAssetTimestamp ?? "") > ($1.lastModifiedAssetTimestamp ?? "") }
        } catch {
            guard !error.isCancellation else { return }
            if error.isUnauthorized { onSignInEnded?(); return }
            albumsProblem = error.localizedDescription
        }
    }

    /// An album's photos, newest first.
    func feed(for album: Album) -> PhotoFeed {
        let feed = PhotoFeed(client: client, source: .timeline(TimelineQuery(visibility: nil, albumId: album.id)))
        feed.onUnauthorized = { [weak self] in self?.onSignInEnded?() }
        return feed
    }

    /// Search the library for the text: by meaning where the server can, else by file name.
    func search(for text: String) async {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            search = nil
            return
        }
        if smartSearch == nil { smartSearch = (try? await client.serverFeatures())?.smartSearch ?? false }
        let feed = PhotoFeed(client: client, source: .search(text, smart: smartSearch ?? false))
        feed.onUnauthorized = { [weak self] in self?.onSignInEnded?() }
        search = feed
    }

    func clearSearch() {
        search = nil
    }

    /// A copy of the photo for the message field, in a folder of its own, under the name it was taken with: Immich's
    /// preview as JPEG (or HEIC, when the server makes its previews so), or the original as it is.
    func copy(of photo: PickerPhoto, original: Bool) async throws -> (url: URL, name: String) {
        async let details = client.asset(photo.id)
        let request = original ? client.originalRequest(photo.id) : client.thumbnailRequest(photo.id, size: .preview)
        let (downloaded, response) = try await client.session.download(for: request)
        let folder = try PickerFiles.newFolder()
        let kept = folder.appendingPathComponent("download")
        try FileManager.default.moveItem(at: downloaded, to: kept)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        if status == 401 { throw ImmichError.unauthorized(nil) }
        guard (200..<300).contains(status) else { throw PickerProblem.download(status) }
        let takenName = (try? await details)?.originalFileName ?? photo.id
        if original {
            let name = PickerFiles.safeName(takenName, fallback: photo.id)
            let file = folder.appendingPathComponent(name)
            try FileManager.default.moveItem(at: kept, to: file)
            return (file, name)
        }
        return try PickerFiles.messagesImage(from: kept, in: folder, named: takenName, fallback: photo.id)
    }
}

/// The copies that go into the message field: each in a folder of its own in the extension's temporary folder, and
/// swept a day later, by when Messages has long taken its own copy.
enum PickerFiles {
    private static let prefix = "Sending-"

    static func newFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(prefix + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// The name as a file name of its own, never a path; the asset's identifier when nothing is left of it.
    static func safeName(_ name: String, fallback: String) -> String {
        let last = URL(fileURLWithPath: name).lastPathComponent
        return last.isEmpty || last == "." || last == ".." || last == "/" ? fallback : last
    }

    /// A preview Messages shows as a photo: JPEG, HEIC and PNG as they come, anything else (Immich may make its
    /// previews WebP) written again as JPEG. The name is the photo's, with the extension of what it is.
    static func messagesImage(from file: URL, in folder: URL, named takenName: String,
                              fallback: String) throws -> (url: URL, name: String) {
        let stem = (safeName(takenName, fallback: fallback) as NSString).deletingPathExtension
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              let kind = CGImageSourceGetType(source).flatMap({ UTType($0 as String) }) else {
            throw PickerProblem.download(415)
        }
        if let kept = [UTType.jpeg, .heic, .png].first(where: { kind.conforms(to: $0) }) {
            let name = stem + "." + (kept.preferredFilenameExtension ?? "jpg")
            let target = folder.appendingPathComponent(name)
            try FileManager.default.moveItem(at: file, to: target)
            return (target, name)
        }
        let name = stem + ".jpg"
        let target = folder.appendingPathComponent(name)
        guard let destination = CGImageDestinationCreateWithURL(target as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw PickerProblem.download(415)
        }
        CGImageDestinationAddImageFromSource(destination, source, 0,
                                             [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw PickerProblem.download(415) }
        try? FileManager.default.removeItem(at: file)
        return (target, name)
    }

    /// The folders of copies a day old.
    static func sweep() {
        let manager = FileManager.default
        let keys: [URLResourceKey] = [.creationDateKey]
        let folders = (try? manager.contentsOfDirectory(at: manager.temporaryDirectory, includingPropertiesForKeys: keys)) ?? []
        for folder in folders where folder.lastPathComponent.hasPrefix(prefix) {
            guard let created = (try? folder.resourceValues(forKeys: Set(keys)))?.creationDate,
                  created < Date().addingTimeInterval(-86_400) else { continue }
            try? manager.removeItem(at: folder)
        }
    }
}
