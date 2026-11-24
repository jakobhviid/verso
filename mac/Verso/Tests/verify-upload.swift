// Offline by default; pass --live for the public demo.
// Run with the API sources: swiftc Verso/API/*.swift Verso/App/UploadQueue.swift scripts/verify-upload.swift -o /tmp/verify-upload && /tmp/verify-upload
// Uses the public demo. Creates and removes only its own generated image and album.
import Foundation
import AppKit

@main struct VerifyUpload {
    static func main() async {
        do {
            if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--memory" {
                let source = URL(fileURLWithPath: CommandLine.arguments[2])
                _ = try UploadMultipart.checksum(source)
                let body = try UploadMultipart.make(source)
                try FileManager.default.removeItem(at: body.file)
                print("PASS: large-file hash and multipart copy")
            } else { try await verify() }
        }
        catch { print("FAIL: \(error.localizedDescription)"); exit(1) }
    }
    static func verify() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("Verso-upload-\(UUID().uuidString).png")
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32, bitsPerSample: 8,
                                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 128, bitsPerPixel: 32)!
        for index in 0..<(32 * 32 * 4) { bitmap.bitmapData![index] = UInt8.random(in: 0...255) }
        try bitmap.representation(using: .png, properties: [:])!.write(to: file)
        let abc = directory.appendingPathComponent("abc")
        try Data("abc".utf8).write(to: abc)
        try require(try UploadMultipart.checksum(abc) == "qZk+NkcGgWq6PiVxeFDCbJzQ2J0=")
        let fixture = try JSONDecoder().decode(UploadResponse.self, from: Data("{\"id\":\"test\",\"status\":\"duplicate\"}".utf8))
        try require(fixture.status == "duplicate")
        let body = try UploadMultipart.make(file)
        let bodyData = try Data(contentsOf: body.file)
        try require(bodyData.range(of: Data("name=\"assetData\"".utf8)) != nil)
        try require(bodyData.range(of: try Data(contentsOf: file)) != nil)
        try FileManager.default.removeItem(at: body.file)
        let nested = directory.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let nestedFile = nested.appendingPathComponent("photo.jpg")
        try Data("nested".utf8).write(to: nestedFile)
        let hidden = directory.appendingPathComponent(".hidden")
        try Data("hidden".utf8).write(to: hidden)
        let link = directory.appendingPathComponent("link.jpg")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: nestedFile)
        let scanned = try UploadQueue.scan([directory, file]).urls
        try require(scanned.contains(nestedFile) && scanned.filter { $0 == file }.count == 1)
        try require(!scanned.contains(hidden) && !scanned.contains(link))
        let partial = try UploadQueue.scan([directory.appendingPathComponent("missing"), nestedFile])
        try require(partial.unreadableCount == 1 && partial.urls == [nestedFile])
        let stale = directory.appendingPathComponent("Verso-upload-2147483647-test")
        let active = directory.appendingPathComponent("Verso-upload-\(ProcessInfo.processInfo.processIdentifier)-test")
        try Data().write(to: stale)
        try Data().write(to: active)
        UploadMultipart.sweepStale(in: directory)
        try require(!FileManager.default.fileExists(atPath: stale.path) && FileManager.default.fileExists(atPath: active.path))
        try await verifyQueue(file: file, directory: directory)
        print("PASS: SHA-1, multipart preservation, recursive/partial scan, deduplication, hidden/symlink exclusion, stale-body cleanup")
        if !CommandLine.arguments.contains("--live") { return }
        let server = URL(string: "https://demo.immich.app")!
        let anonymous = ImmichClient(serverURL: server, apiURL: server.appendingPathComponent("api"), credential: nil)
        print("Checking demo login")
        let login = try await anonymous.login(email: "demo@immich.app", password: "demo")
        let client = anonymous.with(credential: .accessToken(login))
        var assetID: String?
        var albumID: String?
        do {
            print("Checking version and media types")
            let version = try await client.serverVersion()
            let types = try await client.uploadMediaTypes()
            try require(types.extensions.contains(".png"))
            let checksum = try UploadMultipart.checksum(file)
            print("Checking duplicate preflight")
            let before = try await client.checkUpload(checksum: checksum, name: file.lastPathComponent)
            try require(before.results.first?.action == "accept")
            print("Checking new upload")
            let uploaded = try await client.uploadFile(file, checksum: checksum) { sent, total in
                assert(sent >= 0 && total > 0)
            }
            guard uploaded.status == "created" else { throw URLError(.badServerResponse) }
            assetID = uploaded.id
            let after = try await client.checkUpload(checksum: checksum, name: file.lastPathComponent)
            try require(after.results.first?.assetId == assetID && after.results.first?.action == "reject")
            let duplicate = try await client.uploadFile(file, checksum: checksum) { _, _ in }
            try require(duplicate.status == "duplicate" && duplicate.id == assetID)
            struct AlbumBody: Encodable { let albumName: String }
            struct NewAlbum: Decodable { let id: String }
            print("Checking album creation")
            let album: NewAlbum = try await client.send("POST", "albums", body: AlbumBody(albumName: "Verso upload verification \(UUID().uuidString)"))
            albumID = album.id
            try await client.addUploadToAlbum(uploaded.id, albumID: album.id)
            try await client.addUploadToAlbum(uploaded.id, albumID: album.id)
            print("PASS: server \(version), media types, SHA-1, multipart, new upload, duplicate preflight/header, album addition and duplicate membership")
        } catch {
            try await cleanup(client, assetID: assetID, albumID: albumID)
            try? await client.logout()
            throw error
        }
        try await cleanup(client, assetID: assetID, albumID: albumID)
        try await client.logout()
        print("PASS: deleted only the generated test asset and test album; logged out test session")
    }
    @MainActor static func verifyQueue(file: URL, directory: URL) async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [UploadFixtureProtocol.self]
        config.timeoutIntervalForRequest = 30
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let server = URL(string: "https://demo.immich.app")!
        let client = ImmichClient(serverURL: server, apiURL: server.appendingPathComponent("api"), credential: nil, session: session)
        let queue = UploadQueue(client: client)
        var refreshes = 0
        var albums: Set<String> = []
        queue.onFinished = { refreshes += 1; albums.formUnion($0) }
        queue.enqueue([file, file], albumID: "fixture-album")
        try require(queue.showsBanner)
        try await settle(queue)
        try require(queue.items.count == 1 && queue.duplicates == 1 && queue.completed == 1)
        try require(queue.items.first?.response?.isTrashed == true && refreshes == 1 && albums == ["fixture-album"])
        // What it came to, as the sidebar says it and the bell keeps it: every file was there already.
        let clean = queue.outcome
        try require(clean.title == "Nothing new" && clean.detail == "1 already in the library" && !clean.needsLook && clean.files.isEmpty)
        try require(UploadFixtureProtocol.albumRequests == 1 && UploadFixtureProtocol.restoreRequests == 1)
        // An import after the last one ended starts the list afresh: the file is checked again and joins its album again.
        queue.enqueue([file], albumID: "fixture-album")
        try await settle(queue)
        try require(queue.items.count == 1 && refreshes == 2 && UploadFixtureProtocol.albumRequests == 2)
        let ignored = directory.appendingPathComponent("unsupported.txt")
        try Data().write(to: ignored)
        queue.enqueue([ignored, directory.appendingPathComponent("missing")])
        try await settle(queue)
        try require(queue.unsupportedCount == 1 && queue.unreadableCount == 1 && queue.items.isEmpty && refreshes == 2)
        queue.clear()
        try require(queue.completed == 0 && queue.duplicates == 0)
        let deniedClient = ImmichClient(serverURL: server, apiURL: server.appendingPathComponent("api"),
                                        credential: .apiKey("fixture-denied"), session: session)
        let denied = UploadQueue(client: deniedClient)
        var unauthorized = 0
        denied.onError = { if case ImmichError.unauthorized = $0 { unauthorized += 1 } }
        denied.enqueue([file])
        try await settle(denied)
        try require(denied.failed == 1 && unauthorized == 1 && denied.revision == 0 && denied.showsBanner)
        let refused = denied.outcome
        try require(refused.title == "Nothing imported" && refused.detail == "1 not imported" && refused.needsLook && refused.files.count == 1)
        denied.retryFailed()
        try await settle(denied)
        try require(denied.failed == 1 && denied.completed == 1 && unauthorized == 2)
        // Ended, it goes by itself 5 seconds later, into the bell; closed with its cross, it goes without.
        var ended: [VersoNotification] = []
        denied.onEnded = { ended.append($0) }
        try await Task.sleep(for: .seconds(5.5))
        try require(ended.count == 1 && ended[0].needsLook && !denied.showsBanner && denied.items.isEmpty)
        denied.enqueue([file])
        try await settle(denied)
        denied.closeBanner()
        try await Task.sleep(for: .seconds(5.5))
        try require(ended.count == 1 && !denied.showsBanner)
        denied.clear()
        // The upload session must preserve URLProtocol while replacing the shared 30-second timeout.
        let result = try await client.uploadFile(file, checksum: UploadMultipart.checksum(file)) { _, _ in }
        try require(result.status == "created" && UploadFixtureProtocol.uploadTimeout == 3600)
        print("PASS: queue counters/deduplication, trashed duplicate restored + album, a new import starting afresh, ignored/unreadable warnings, outcomes, into the bell after 5 s unless closed, 401 routing/retry, upload timeout")
    }

    @MainActor static func settle(_ queue: UploadQueue) async throws {
        let deadline = Date().addingTimeInterval(10)
        while queue.isRunning && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try require(!queue.isRunning)
    }

    static func require(_ condition: Bool) throws {
        if !condition { throw URLError(.badServerResponse) }
    }
    static func cleanup(_ client: ImmichClient, assetID: String?, albumID: String?) async throws {
        if let albumID { try await client.send("DELETE", "albums/\(albumID)") }
        if let assetID { try await client.delete([assetID], force: true) }
    }
}

// All requests in offline checks are intercepted; no network connection is opened.
private final class UploadFixtureProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var albums = 0
    private static var restores = 0
    private static var timeout: TimeInterval = 0
    static var albumRequests: Int { lock.withLock { albums } }
    static var restoreRequests: Int { lock.withLock { restores } }
    static var uploadTimeout: TimeInterval { lock.withLock { timeout } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path
        var code = 200
        let body: String
        switch path {
        case "/api/server/media-types": body = #"{"image":[".png"],"video":[],"sidecar":[]}"#
        case "/api/server/version": body = #"{"major":3,"minor":3,"patch":5}"#
        case "/api/assets/bulk-upload-check":
            if request.value(forHTTPHeaderField: "x-api-key") == "fixture-denied" {
                code = 401; body = #"{"message":"Fixture expired session"}"#
            } else {
                body = #"{"results":[{"id":"fixture","action":"reject","assetId":"own-fixture","isTrashed":true}]}"#
            }
        case "/api/trash/restore/assets":
            Self.lock.withLock { Self.restores += 1 }
            body = #"{"count":1}"#
        case "/api/albums/fixture-album/assets":
            Self.lock.withLock { Self.albums += 1 }
            body = #"[{"id":"own-fixture","success":true}]"#
        case "/api/assets":
            Self.lock.withLock { Self.timeout = request.timeoutInterval }
            body = #"{"id":"own-fixture","status":"created"}"#
        default: fatalError("Unexpected fixture request: \(path)")
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
