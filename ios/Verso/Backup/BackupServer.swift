// What backing up asks of Immich (ARCHITECTURE.md, "Backing the iPhone up", "Never twice" and "Sending"), behind a
// protocol so the engine does not know the client, and the shared Swift client's calls behind it (ImmichClient,
// mac/Verso/Verso/API):
// - the duplicate check (`POST /assets/bulk-upload-check`), 500 fingerprints at a time, before anything is uploaded;
// - an upload's request (`POST /assets`, multipart) with `x-immich-checksum`, so Immich answers "duplicate" before
//   the body is sent, for the background session to carry; its body written by BackupUploadBody;
// - the server's photos taken at a second, for "In Immich in another form": the months of the account's own timeline
//   (`GET /timeline/buckets` and `/timeline/bucket`, every asset unstacked, archived ones too), which say when each was
//   taken in a few bytes, and an asset's name read only where a phone's photo was taken at the same second;
// - stacks (`POST /stacks`, which takes in the stacks of the ids it is given) and the metadata set after an upload
//   (`PUT /assets`) where Photos' date or place differs from the file's, and the favourite where the person changed it
//   on the phone after the upload's body was written.

import Foundation

/// The facts of an asset the metadata step compares with Photos'.
struct BackupAssetFacts: Sendable, Equatable {
    var name: String
    var takenAt: Date?
    /// Whether Immich has read the file's metadata yet.
    var extracted: Bool
    var timeZone: String?
    var latitude: Double?
    var longitude: Double?
    var stackPrimary: String?
    var isFavorite = false
}

protocol BackupServer: Sendable {
    /// The account's key in the store: the server's API address and the user.
    var account: String { get }
    func check(_ checksums: [String]) async throws -> [String: BackupCheck]
    func timelineMonths() async throws -> [String]
    func timelineMonth(_ bucket: String) async throws -> [BackupAnotherForm.Remote]
    func asset(_ id: String) async throws -> BackupAssetFacts?
    func stack(_ ids: [String]) async throws
    func setMetadata(_ ids: [String], takenAt: String?, latitude: Double?, longitude: Double?) async throws
    func setFavorite(_ ids: [String], _ favorite: Bool) async throws
    func uploadRequest(boundary: String, checksum: String, cellular: Bool) throws -> URLRequest
    /// The `mobile-app` metadata Immich's own app keeps with an asset (BackupMobileApp), or nil where it has none.
    func mobileAppMetadata(_ id: String) async throws -> [String: String]?
    /// The asset's fingerprint as Immich keeps it, with its file's size.
    func fingerprint(_ id: String) async throws -> (checksum: String, size: Int64)?
    /// What Free Up Space checks of an asset before its photo leaves the phone, or nil where Immich has none.
    func freeUpFacts(_ id: String) async throws -> BackupFreeUpFacts?
    /// Whether the asset's original is on the server's disk: its first byte, read.
    func originalReadable(_ id: String) async throws -> Bool
}

/// An asset as Free Up Space checks it: whose it is, whether it is in the trash or an external library's, and the
/// checksum and size of its file.
struct BackupFreeUpFacts: Sendable, Equatable {
    var ownerID: String?
    var trashed: Bool
    var external: Bool
    var checksum: String?
    var size: Int64?
}

/// Immich, through the shared client.
struct ImmichBackupServer: BackupServer {
    let client: ImmichClient
    let userID: String

    var account: String { client.apiURL.absoluteString + "|" + userID }

    func check(_ checksums: [String]) async throws -> [String: BackupCheck] {
        struct Item: Encodable { let id: String; let checksum: String }
        struct Body: Encodable { let assets: [Item] }
        var results: [String: BackupCheck] = [:]
        var start = 0
        while start < checksums.count {
            let end = min(start + 500, checksums.count)
            let page = Array(checksums[start..<end])
            let items = page.enumerated().map { Item(id: String($0.offset), checksum: $0.element) }
            let answer: UploadCheckResponse = try await client.send("POST", "assets/bulk-upload-check", body: Body(assets: items))
            for result in answer.results {
                guard let index = Int(result.id), page.indices.contains(index) else { continue }
                if result.action == "reject", result.reason == "duplicate", let asset = result.assetId {
                    results[page[index]] = BackupCheck(state: result.isTrashed == true ? .trashed : .present, assetID: asset)
                } else {
                    // Accepted, or refused for another reason (an unsupported format), which the upload then says.
                    results[page[index]] = BackupCheck(state: .absent)
                }
            }
            start = end
        }
        return results
    }

    func timelineMonths() async throws -> [String] {
        struct Month: Decodable { let timeBucket: String }
        let months: [Month] = try await client.get("timeline/buckets", query: ["userId": userID])
        return months.map(\.timeBucket)
    }

    func timelineMonth(_ bucket: String) async throws -> [BackupAnotherForm.Remote] {
        struct Columns: Decodable { let id: [String]; let fileCreatedAt: [String] }
        let month: Columns = try await client.get("timeline/bucket", query: ["timeBucket": bucket, "userId": userID])
        return zip(month.id, month.fileCreatedAt).compactMap { id, taken in
            BackupServerDates.parse(taken).map { BackupAnotherForm.Remote(assetID: id, takenSecond: BackupAnotherForm.second($0)) }
        }
    }

    func asset(_ id: String) async throws -> BackupAssetFacts? {
        let asset = try await client.asset(id)
        return BackupAssetFacts(name: asset.originalFileName, takenAt: BackupServerDates.parse(asset.fileCreatedAt),
                                extracted: asset.exifInfo != nil, timeZone: asset.exifInfo?.timeZone,
                                latitude: asset.exifInfo?.latitude, longitude: asset.exifInfo?.longitude,
                                stackPrimary: asset.stack?.primaryAssetId, isFavorite: asset.isFavorite)
    }

    func stack(_ ids: [String]) async throws {
        _ = try await client.assetsCreateStack(ids)
    }

    func setMetadata(_ ids: [String], takenAt: String?, latitude: Double?, longitude: Double?) async throws {
        try await client.updateMetadata(MetadataUpdate(ids: ids, dateTimeOriginal: takenAt, latitude: latitude, longitude: longitude))
    }

    func setFavorite(_ ids: [String], _ favorite: Bool) async throws {
        try await client.setFavorite(ids, favorite)
    }

    func mobileAppMetadata(_ id: String) async throws -> [String: String]? {
        struct Answer: Decodable {
            let value: [String: String]
            init(from decoder: Decoder) throws {
                // Each field read as text where it is text; anything else is left out, and then matches nothing.
                let container = try decoder.container(keyedBy: Keys.self)
                let fields = try container.nestedContainer(keyedBy: Keys.self, forKey: Keys(stringValue: "value"))
                var value: [String: String] = [:]
                for key in fields.allKeys { value[key.stringValue] = try? fields.decode(String.self, forKey: key) }
                self.value = value
            }
        }
        struct Keys: CodingKey {
            var stringValue: String
            var intValue: Int? { nil }
            init(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { nil }
        }
        do {
            let answer: Answer = try await client.get("assets/\(id)/metadata/\(BackupMobileApp.key)")
            return answer.value
        } catch ImmichError.http(let status, _) where status == 400 || status == 404 {
            // Immich answers 400 for a key the asset does not have.
            return nil
        }
    }

    func fingerprint(_ id: String) async throws -> (checksum: String, size: Int64)? {
        struct Exif: Decodable { var fileSizeInByte: Int64? }
        struct Asset: Decodable { var checksum: String?; var exifInfo: Exif? }
        let asset: Asset = try await client.get("assets/\(id)")
        return asset.checksum.map { ($0, asset.exifInfo?.fileSizeInByte ?? 0) }
    }

    func freeUpFacts(_ id: String) async throws -> BackupFreeUpFacts? {
        struct Exif: Decodable { var fileSizeInByte: Int64? }
        struct Asset: Decodable {
            var ownerId: String?
            var isTrashed: Bool?
            var libraryId: String?
            var checksum: String?
            var exifInfo: Exif?
        }
        do {
            let asset: Asset = try await client.get("assets/\(id)")
            return BackupFreeUpFacts(ownerID: asset.ownerId, trashed: asset.isTrashed ?? false, external: asset.libraryId != nil,
                                     checksum: asset.checksum, size: asset.exifInfo?.fileSizeInByte)
        } catch ImmichError.http(let status, _) where status == 400 || status == 404 {
            return nil
        }
    }

    func originalReadable(_ id: String) async throws -> Bool {
        var request = try client.request("assets/\(id)/original")
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        do {
            let data = try await client.data(for: request)
            return !data.isEmpty
        } catch ImmichError.http(let status, _) where status == 400 || status == 404 {
            return false
        }
    }

    func uploadRequest(boundary: String, checksum: String, cellular: Bool) throws -> URLRequest {
        var request = try client.request("assets", method: "POST")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue(checksum, forHTTPHeaderField: "x-immich-checksum")
        request.setValue(ImmichClient.userAgent, forHTTPHeaderField: "User-Agent")
        request.allowsCellularAccess = cellular
        request.allowsConstrainedNetworkAccess = false
        request.timeoutInterval = 3600
        return request
    }
}

enum BackupServerDates {
    private nonisolated(unsafe) static let withFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private nonisolated(unsafe) static let plain = ISO8601DateFormatter()
    private static let lock = NSLock()

    /// A date as Immich writes it, with or without fractions of a second, with or without its zone (UTC then).
    static func parse(_ text: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        let zoned = text.hasSuffix("Z") || text.range(of: #"[+-]\d\d:?\d\d$"#, options: .regularExpression) != nil ? text : text + "Z"
        return withFraction.date(from: zoned) ?? plain.date(from: zoned)
    }

    /// A date as Immich takes a photo's time: in the zone given (the photo's own), or UTC.
    static func format(_ date: Date, timeZone: String?) -> String {
        lock.lock()
        defer { lock.unlock() }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = timeZone.flatMap(TimeZone.init(identifier:)) ?? TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }
}

/// An upload's body, a multipart file written in Application Support: the text fields first, then the part's bytes
/// streamed through the same sink that takes their fingerprint, then the closing boundary.
enum BackupUploadBody {
    /// The text fields of a part's upload.
    /// The upload's fields; `mobileApp`, the `metadata` field Immich's own app writes (BackupMobileApp), on a photo never
    /// edited.
    static func fields(photo: BackupPhotoRow, part: BackupPartRow, pairedVideoAssetID: String?,
                       mobileApp: String? = nil) -> [(String, String)] {
        let created = BackupServerDates.format(photo.created ?? photo.modified ?? Date(), timeZone: nil)
        let modified = BackupServerDates.format(photo.modified ?? photo.created ?? Date(), timeZone: nil)
        var fields: [(String, String)] = [
            ("deviceAssetId", "\(photo.localID)/\(part.role.rawValue)"),
            ("deviceId", "verso-ios"),
            ("fileCreatedAt", created),
            ("fileModifiedAt", modified),
            ("filename", part.name),
            ("isFavorite", photo.favorite && !part.role.isPairedVideo ? "true" : "false"),
        ]
        // A Live Photo's video goes hidden, and its still points at it; a photo hidden on the phone goes into the Locked
        // Folder, never the timeline.
        if part.role.isPairedVideo { fields.append(("visibility", "hidden")) }
        else if photo.hidden { fields.append(("visibility", "locked")) }
        if let pairedVideoAssetID { fields.append(("livePhotoVideoId", pairedVideoAssetID)) }
        if let mobileApp { fields.append(("metadata", mobileApp)) }
        return fields
    }

    /// Writes the body to `file`; `content` streams the part's bytes into the sink it is given. The fingerprint and
    /// size of the bytes alone.
    static func write(to file: URL, boundary: String, fields: [(String, String)], fileName: String, mimeType: String,
                      limit: Int64?, content: (BackupSink) async throws -> Void) async throws -> (checksum: String, size: Int64) {
        guard FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            let output = try FileHandle(forWritingTo: file)
            defer { try? output.close() }
            for (name, value) in fields {
                try output.write(contentsOf: Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
            }
            let safeName = fileName.replacingOccurrences(of: "\r", with: "_").replacingOccurrences(of: "\n", with: "_")
                .replacingOccurrences(of: "\"", with: "_").replacingOccurrences(of: "\\", with: "_")
            try output.write(contentsOf: Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"assetData\"; filename=\"\(safeName)\"\r\nContent-Type: \(mimeType)\r\n\r\n".utf8))
            let sink = BackupSink(file: output, limit: limit)
            try await content(sink)
            try output.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
            return sink.result
        } catch {
            try? FileManager.default.removeItem(at: file)
            throw error
        }
    }

    /// Streams a file already on disk (an original downloaded from iCloud) into the sink.
    static func stream(_ file: URL, into sink: BackupSink) throws {
        let input = try FileHandle(forReadingFrom: file)
        defer { try? input.close() }
        while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
            try Task.checkCancellation()
            try sink.take(chunk)
        }
    }
}
