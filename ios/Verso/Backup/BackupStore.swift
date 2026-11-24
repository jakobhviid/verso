// Backing the iPhone up's store (ARCHITECTURE.md, "Backing the iPhone up", "The store"): SQLite in WAL mode
// (BackupDatabase), in the App Group's container so an extension can share it. About 30 MB at 100,000 photos, read in
// pages, never loaded whole.
// - `photo`: the phone's facts, a row for each photo: its dates, kind, favourite, hidden, burst, and its iCloud
//   identifier, which finds it again when its local identifier changes.
// - `part`: each stored resource with its own content, with its fingerprint (SHA-1, base64, as Immich keeps it) or why
//   it could not be taken. Kept across accounts, so changing servers costs a check, not new fingerprints.
// - `remote`: the server's facts per account and fingerprint: absent, present or in the trash, with the asset's id;
//   whether Verso sent it or counted it there, and whether it ever saw it in Immich's trash.
// - `backup`: each photo's state per account with its reason, the person's decision, whether Immich has it in another
//   form, and whether its stack and metadata are done.
// - `journal`: each step written before it starts (its intent) and its result after. At launch every step without a
//   result is worked out again from facts (BackupEngine.recover), which is safe because a resend is only a duplicate.
// - `meta`: the library's change token, saved in the same transaction as the rows it covers, and the run's marks:
//   when backing up was switched on for each account (`onSince.<account>`), from which a photo that came to the phone
//   counts as new (BackupOnItsWay), and when its first run started.
// Every write is its own short transaction, so none is open when Verso is suspended.

import Foundation

/// A photo as the phone has it.
struct BackupPhotoRow: Sendable, Equatable {
    var localID: String
    var cloudID: String?
    var created: Date?
    var added: Date?
    var modified: Date?
    /// PHAssetMediaType's raw value: 1 image, 2 video, 3 audio.
    var kind: Int
    /// PHAssetMediaSubtype's raw value.
    var subtypes: Int
    var favorite: Bool
    var hidden: Bool
    var burst: String?
    var burstPick: Bool
    var latitude: Double?
    var longitude: Double?
    var name: String?
    /// Deleted from the phone; kept so a new identifier can find its history.
    var gone = false

    static let screenshotSubtype = 1 << 2
    static let liveSubtype = 1 << 3
    var isVideo: Bool { kind == 2 }
}

/// A part as the phone has it, with its fingerprint once taken.
struct BackupPartRow: Sendable, Equatable {
    var localID: String
    var role: BackupPartRole
    var name: String
    var uti: String?
    var size: Int64?
    var checksum: String?
    /// The fingerprint of an edit's adjustment data, which says when its rendering changed.
    var adjustment: String?
    var failure: String?
    var failures = 0
    var firstFailure: Date?
    var retryAfter: Date?
    /// An original downloaded from iCloud for its fingerprint, waiting for its upload.
    var staged: String?
    /// The fingerprint was taken from Immich, by the iCloud identifier Immich's own app keeps with the asset
    /// (BackupMobileApp), not read from the phone: anything that must know the phone's bytes (freeing space) reads
    /// them first.
    var borrowed = false
    /// Why it waits until `retryAfter`, in the person's words: shown in To Check and To Upload.
    var waitReason: String?
}

/// A step of the journal.
struct BackupStep: Sendable, Equatable {
    enum Kind: String, Sendable { case upload, stack, metadata }
    var id: Int64
    var account: String
    var localID: String
    var role: BackupPartRole?
    var kind: Kind
    var checksum: String?
    var file: String?
    var task: Int?
    var started: Date
}

/// A photo Free Up Space may remove: backed up whole, old enough, and none of what stays; its parts as Immich has them.
struct FreeUpCandidate: Sendable, Equatable {
    struct Part: Sendable, Equatable {
        var role: BackupPartRole
        var checksum: String
        var size: Int64?
        var assetID: String?
        var borrowed: Bool
        var uti: String?
    }
    var photo: BackupPhotoRow
    var parts: [Part]
    /// The bytes of its originals.
    var size: Int64 { parts.reduce(0) { $0 + ($1.size ?? 0) } }
    /// A ProRAW (DNG) photo, which iOS can take long to delete and which goes on its own.
    var isRaw: Bool { parts.contains { $0.uti == "com.adobe.raw-image" } }
}

/// One part ready to go: what the planner hands the transport.
struct BackupUploadCandidate: Sendable, Equatable {
    var photo: BackupPhotoRow
    var part: BackupPartRow
    /// The asset id of the Live Photo's video, which the still points at.
    var pairedVideoAssetID: String?
}

final class BackupStore: @unchecked Sendable {
    let database: BackupDatabase
    /// Where the files the store names are: it keeps their paths relative to the folder, and hands them out whole.
    let files: BackupFiles
    private let hiddenLock = NSLock()
    private var hiddenIncludedValue = false

    /// Hidden photos are backed up (BackupSettings.hiddenPhotos, into Immich's Locked Folder): the store's counts and
    /// work take them in. The Library's photos on their way never do, as Photos' Library shows no hidden photo.
    var hiddenIncluded: Bool {
        get { hiddenLock.withLock { hiddenIncludedValue } }
        set { hiddenLock.withLock { hiddenIncludedValue = newValue } }
    }

    /// The condition that leaves hidden photos out where they are not backed up, for a photo row named `alias`.
    private func shown(_ alias: String? = nil) -> String {
        hiddenIncluded ? "1" : "\(alias.map { "\($0)." } ?? "")hidden = 0"
    }

    /// The store at its place in the App Group's container, or in Application Support where there is none.
    static func defaultFile() -> URL {
        let identifier = Bundle.main.object(forInfoDictionaryKey: "VersoAppGroup") as? String ?? ""
        let base = (identifier.isEmpty ? nil : FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier))
            ?? URL.applicationSupportDirectory
        return base.appendingPathComponent("Backup", isDirectory: true).appendingPathComponent("backup.sqlite")
    }

    init(file: URL, files: BackupFiles = .standard) throws {
        database = try BackupDatabase(file: file)
        self.files = files
        try migrate()
    }

    private func migrate() throws {
        try database.execute("""
        CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value BLOB);
        CREATE TABLE IF NOT EXISTS photo (
            local_id TEXT PRIMARY KEY, cloud_id TEXT, created REAL, added REAL, modified REAL,
            kind INTEGER NOT NULL DEFAULT 1, subtypes INTEGER NOT NULL DEFAULT 0, favorite INTEGER NOT NULL DEFAULT 0,
            hidden INTEGER NOT NULL DEFAULT 0, burst TEXT, burst_pick INTEGER NOT NULL DEFAULT 0,
            latitude REAL, longitude REAL, name TEXT,
            parts_read INTEGER NOT NULL DEFAULT 0, gone INTEGER NOT NULL DEFAULT 0);
        CREATE INDEX IF NOT EXISTS photo_created ON photo(created DESC);
        CREATE INDEX IF NOT EXISTS photo_added ON photo(added);
        CREATE INDEX IF NOT EXISTS photo_cloud ON photo(cloud_id);
        CREATE INDEX IF NOT EXISTS photo_burst ON photo(burst);
        CREATE TABLE IF NOT EXISTS part (
            local_id TEXT NOT NULL, role TEXT NOT NULL, name TEXT NOT NULL, uti TEXT, size INTEGER, checksum TEXT,
            adjustment TEXT, failure TEXT, failures INTEGER NOT NULL DEFAULT 0, first_failure REAL, retry_after REAL,
            staged TEXT, PRIMARY KEY (local_id, role));
        CREATE INDEX IF NOT EXISTS part_checksum ON part(checksum);
        CREATE TABLE IF NOT EXISTS remote (
            account TEXT NOT NULL, checksum TEXT NOT NULL, asset_id TEXT, state INTEGER NOT NULL, checked REAL NOT NULL,
            seen_trashed INTEGER NOT NULL DEFAULT 0, sent INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (account, checksum));
        CREATE TABLE IF NOT EXISTS backup (
            account TEXT NOT NULL, local_id TEXT NOT NULL, state INTEGER NOT NULL DEFAULT 0, reason TEXT,
            another_form TEXT, decision INTEGER, upload_failure TEXT, announced INTEGER NOT NULL DEFAULT 0,
            uploaded INTEGER NOT NULL DEFAULT 0,
            finished INTEGER NOT NULL DEFAULT 0, previous_tops TEXT, updated REAL, PRIMARY KEY (account, local_id));
        CREATE INDEX IF NOT EXISTS backup_state ON backup(account, state);
        CREATE TABLE IF NOT EXISTS journal (
            id INTEGER PRIMARY KEY AUTOINCREMENT, account TEXT NOT NULL, local_id TEXT NOT NULL, role TEXT,
            step TEXT NOT NULL, checksum TEXT, file TEXT, task INTEGER, started REAL NOT NULL, result TEXT,
            asset_id TEXT, finished REAL);
        CREATE INDEX IF NOT EXISTS journal_open ON journal(account, result);
        CREATE TABLE IF NOT EXISTS freed (
            account TEXT NOT NULL, local_id TEXT NOT NULL, checksum TEXT NOT NULL, asset_id TEXT, freed REAL NOT NULL,
            announced INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (account, local_id, checksum));
        """)
        // Schema 2: whether a part's fingerprint was borrowed from Immich (BackupPartRow.borrowed), and why it waits
        // (BackupPartRow.waitReason).
        let partColumns = try database.query("PRAGMA table_info(part)", []) { $0.text(1) ?? "" }
        if !partColumns.contains("borrowed") {
            try database.execute("ALTER TABLE part ADD COLUMN borrowed INTEGER NOT NULL DEFAULT 0")
        }
        if !partColumns.contains("wait_reason") {
            try database.execute("ALTER TABLE part ADD COLUMN wait_reason TEXT")
        }
        try setMeta("schema", "2")
    }

    // MARK: Meta

    func meta(_ key: String) throws -> String? {
        try database.first("SELECT value FROM meta WHERE key = ?", [key]) { $0.text(0) } ?? nil
    }

    func metaData(_ key: String) throws -> Data? {
        try database.first("SELECT value FROM meta WHERE key = ?", [key]) { $0.data(0) } ?? nil
    }

    func setMeta(_ key: String, _ value: String?) throws {
        if let value {
            try database.run("INSERT INTO meta(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                             [key, value])
        } else {
            try database.run("DELETE FROM meta WHERE key = ?", [key])
        }
    }

    func setMetaData(_ key: String, _ value: Data) throws {
        try database.run("INSERT INTO meta(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                         [key, value])
    }

    func metaDate(_ key: String) throws -> Date? {
        try meta(key).flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
    }

    func setMetaDate(_ key: String, _ date: Date?) throws {
        try setMeta(key, date.map { String($0.timeIntervalSince1970) })
    }

    // MARK: Photos

    /// Writes the phone's facts of these photos; a photo whose modification date changed has its parts read again.
    func upsertPhotos(_ photos: [BackupPhotoRow]) throws {
        try database.transaction {
            for photo in photos {
                try database.run("""
                INSERT INTO photo(local_id, cloud_id, created, added, modified, kind, subtypes, favorite, hidden, burst,
                                  burst_pick, latitude, longitude, name, parts_read, gone)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, 0)
                ON CONFLICT(local_id) DO UPDATE SET
                    cloud_id = coalesce(excluded.cloud_id, photo.cloud_id), created = excluded.created,
                    added = excluded.added, kind = excluded.kind, subtypes = excluded.subtypes,
                    favorite = excluded.favorite, hidden = excluded.hidden, burst = excluded.burst,
                    burst_pick = excluded.burst_pick, latitude = excluded.latitude, longitude = excluded.longitude,
                    name = coalesce(excluded.name, photo.name), gone = 0,
                    parts_read = CASE WHEN photo.modified IS excluded.modified THEN photo.parts_read ELSE 0 END,
                    modified = excluded.modified
                """, [photo.localID, photo.cloudID, photo.created, photo.added, photo.modified, photo.kind, photo.subtypes,
                      photo.favorite, photo.hidden, photo.burst, photo.burstPick, photo.latitude, photo.longitude, photo.name])
            }
        }
    }

    /// Writes rows with the change token that covers them, in one transaction: either both are kept or neither.
    func upsertPhotos(_ photos: [BackupPhotoRow], gone: [String], token: Data?) throws {
        try database.transaction {
            try upsertPhotos(photos)
            try markGone(gone)
            if let token { try setMetaData("changeToken", token) }
        }
    }

    func markGone(_ identifiers: [String]) throws {
        try database.transaction {
            for identifier in identifiers {
                try database.run("UPDATE photo SET gone = 1 WHERE local_id = ?", [identifier])
            }
        }
    }

    func photo(_ identifier: String) throws -> BackupPhotoRow? {
        try database.first("SELECT \(Self.photoColumns) FROM photo WHERE local_id = ?", [identifier], Self.readPhoto)
    }

    func photos(_ identifiers: [String]) throws -> [BackupPhotoRow] {
        try identifiers.compactMap { try photo($0) }
    }

    /// Photos whose parts have not been read for their current version, newest first; of `only` these, when given.
    func photosNeedingParts(limit: Int, only: [String]? = nil) throws -> [BackupPhotoRow] {
        try database.query("""
        SELECT \(Self.photoColumns) FROM photo WHERE parts_read = 0 AND gone = 0 AND \(shown())\(Self.only(only, "local_id"))
        ORDER BY created DESC LIMIT ?
        """, (only ?? []) + [limit], Self.readPhoto)
    }

    /// The photos of a burst, the picked one first.
    func burst(_ burst: String) throws -> [BackupPhotoRow] {
        try database.query("""
        SELECT \(Self.photoColumns) FROM photo WHERE burst = ? AND gone = 0 ORDER BY burst_pick DESC, created
        """, [burst], Self.readPhoto)
    }

    /// Photos the store knows, by their cloud identifier, among those gone from the phone or about to be taken as gone.
    func photosByCloudIdentifier(_ cloudIDs: [String]) throws -> [String: String] {
        var found: [String: String] = [:]
        for cloudID in cloudIDs {
            if let local = try database.first("SELECT local_id FROM photo WHERE cloud_id = ? ORDER BY gone DESC", [cloudID], { $0.text(0) }) ?? nil {
                found[cloudID] = local
            }
        }
        return found
    }

    /// A photo's local identifier changed (a new iPhone's Quick Start, an iOS update): its rows follow it, so it is
    /// not taken for new.
    func remap(from old: String, to new: String) throws {
        guard old != new else { return }
        try database.transaction {
            // A row already made for the new identifier gives way to the one with the history.
            for table in ["part", "photo"] { try database.run("DELETE FROM \(table) WHERE local_id = ?", [new]) }
            try database.run("DELETE FROM backup WHERE local_id = ? AND state = 0", [new])
            for table in ["photo", "part", "backup", "journal"] {
                try database.run("UPDATE OR IGNORE \(table) SET local_id = ? WHERE local_id = ?", [new, old])
            }
            try database.run("UPDATE photo SET gone = 0 WHERE local_id = ?", [new])
        }
    }

    /// Every photo identifier the store holds as on the phone, in pages: for a reconcile, which compares them with the
    /// library's.
    func knownIdentifiers(after: String, limit: Int) throws -> [String] {
        try database.query("SELECT local_id FROM photo WHERE gone = 0 AND local_id > ? ORDER BY local_id LIMIT ?",
                           [after, limit]) { $0.text(0) ?? "" }
    }

    func photoCount() throws -> Int {
        try database.first("SELECT count(*) FROM photo WHERE gone = 0 AND \(shown())", [], { $0.int(0) }) ?? 0
    }

    /// A query's limit to these photos, by a column of their local identifiers: nothing when nil.
    private static func only(_ identifiers: [String]?, _ column: String) -> String {
        guard let identifiers else { return "" }
        guard !identifiers.isEmpty else { return " AND 0" }
        return " AND \(column) IN (" + Array(repeating: "?", count: identifiers.count).joined(separator: ", ") + ")"
    }

    private static let photoColumns = """
    local_id, cloud_id, created, added, modified, kind, subtypes, favorite, hidden, burst, burst_pick, latitude, longitude, name, gone
    """
    /// Where a part's columns start after a photo's in a joined row.
    private static let partOffset: Int32 = 15

    /// A list of columns, each with a table's alias.
    private static func columns(_ list: String, _ alias: String) -> String {
        list.split(separator: ",").map { alias + "." + $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .joined(separator: ", ")
    }

    private static func readPhoto(_ row: BackupRow) -> BackupPhotoRow {
        BackupPhotoRow(localID: row.text(0) ?? "", cloudID: row.text(1), created: row.date(2), added: row.date(3),
                       modified: row.date(4), kind: row.int(5), subtypes: row.int(6), favorite: row.bool(7),
                       hidden: row.bool(8), burst: row.text(9), burstPick: row.bool(10), latitude: row.optionalDouble(11),
                       longitude: row.optionalDouble(12), name: row.text(13), gone: row.bool(14))
    }

    // MARK: Parts

    /// The parts of a photo as read now. A part keeps its fingerprint while it is the same resource (its role, name
    /// and, for an edit's rendering, its adjustment data); a rendering whose adjustment changed is fingerprinted again.
    /// Nothing on the server goes when a photo is edited again: the rendering it had stays in the photo's stack.
    func setParts(_ identifier: String, _ parts: [BackupPartRow], account: String?) throws {
        try database.transaction {
            let existing = try self.parts(identifier)
            for part in parts {
                if let old = existing.first(where: { $0.role == part.role }) {
                    let same = old.name == part.name && old.adjustment == part.adjustment
                    if same { continue }
                    if let account, part.role == .render, let oldChecksum = old.checksum,
                       let oldAsset = try remoteAssetID(account: account, checksum: oldChecksum) {
                        try keepPreviousTop(account: account, identifier: identifier, assetID: oldAsset)
                    }
                    try database.run("""
                    UPDATE part SET name = ?, uti = ?, size = NULL, checksum = NULL, adjustment = ?, failure = NULL,
                        failures = 0, first_failure = NULL, retry_after = NULL, staged = NULL, borrowed = 0, wait_reason = NULL
                    WHERE local_id = ? AND role = ?
                    """, [part.name, part.uti, part.adjustment, identifier, part.role.rawValue])
                    if let staged = old.staged { try? FileManager.default.removeItem(atPath: staged) }
                    try factsChanged(identifier)
                } else {
                    try database.run("""
                    INSERT INTO part(local_id, role, name, uti, adjustment) VALUES (?, ?, ?, ?, ?)
                    """, [identifier, part.role.rawValue, part.name, part.uti, part.adjustment])
                    try factsChanged(identifier)
                }
            }
            for old in existing where !parts.contains(where: { $0.role == old.role }) {
                try database.run("DELETE FROM part WHERE local_id = ? AND role = ?", [identifier, old.role.rawValue])
                if let staged = old.staged { try? FileManager.default.removeItem(atPath: staged) }
                try factsChanged(identifier)
            }
            let name = parts.first { $0.role == .original }?.name
            try database.run("UPDATE photo SET parts_read = 1, name = coalesce(?, name) WHERE local_id = ?", [name, identifier])
        }
    }

    /// A photo's parts changed: every account works its state out again, and finishes it again.
    private func factsChanged(_ identifier: String) throws {
        try database.run("UPDATE backup SET state = 0, reason = NULL, finished = 0 WHERE local_id = ?", [identifier])
    }

    /// The photo's parts are read again, as one of them changed while it was read.
    func rereadParts(_ identifier: String) throws {
        try database.run("UPDATE photo SET parts_read = 0 WHERE local_id = ?", [identifier])
    }

    func parts(_ identifier: String) throws -> [BackupPartRow] {
        try database.query("SELECT \(Self.partColumns) FROM part WHERE local_id = ? ORDER BY role", [identifier], readPart)
    }

    /// Parts still without a fingerprint, newest photos first, leaving out those waiting to be tried again; of `only`
    /// these photos, when given.
    func partsToFingerprint(limit: Int, now: Date = Date(), screenshots: Bool,
                            only: [String]? = nil) throws -> [(BackupPhotoRow, BackupPartRow)] {
        let values: [any BackupBindable] = [now, screenshots] + (only ?? []) + [limit]
        return try database.query("""
        SELECT \(Self.columns(Self.photoColumns, "p")),
               \(Self.columns(Self.partColumns, "t"))
        FROM part t JOIN photo p ON p.local_id = t.local_id
        WHERE t.checksum IS NULL AND (t.retry_after IS NULL OR t.retry_after <= ?) AND p.gone = 0 AND \(shown("p"))
          AND (? OR (p.subtypes & \(BackupPhotoRow.screenshotSubtype)) = 0)\(Self.only(only, "p.local_id"))
        ORDER BY p.created DESC LIMIT ?
        """, values) { row in
            (Self.readPhoto(row), self.readPart(row, offset: Self.partOffset))
        }
    }

    /// A photo's favourite, as the person just set it in Photos, so an upload written next carries it.
    func setFavorite(_ identifier: String, _ favorite: Bool) throws {
        try database.run("UPDATE photo SET favorite = ? WHERE local_id = ?", [favorite, identifier])
    }

    func setFingerprint(_ identifier: String, _ role: BackupPartRole, checksum: String, size: Int64, staged: String? = nil,
                        borrowed: Bool = false) throws {
        try database.transaction {
            try database.run("""
            UPDATE part SET checksum = ?, size = ?, failure = NULL, failures = 0, first_failure = NULL, retry_after = NULL,
                staged = ?, borrowed = ?, wait_reason = NULL WHERE local_id = ? AND role = ?
            """, [checksum, size, staged.map(files.kept), borrowed, identifier, role.rawValue])
            try factsChanged(identifier)
        }
    }

    /// A fingerprint that could not be taken: shown with its reason, and tried again later, never an empty value that
    /// blocks the photo for good.
    func setFingerprintFailure(_ identifier: String, _ role: BackupPartRole, reason: String, retryAfter: Date,
                               now: Date = Date()) throws {
        try database.transaction {
            try database.run("""
            UPDATE part SET failure = ?, failures = failures + 1, first_failure = coalesce(first_failure, ?), retry_after = ?
            WHERE local_id = ? AND role = ?
            """, [reason, now, retryAfter, identifier, role.rawValue])
            try factsChanged(identifier)
        }
    }

    /// A fingerprint that could not be taken this time and is tried again quietly: counted, without a reason shown, as
    /// most such failures pass (BackupRules.readNeedsLook).
    func setFingerprintRetry(_ identifier: String, _ role: BackupPartRole, retryAfter: Date, reason: String,
                             now: Date = Date()) throws {
        try database.run("""
        UPDATE part SET failures = failures + 1, first_failure = coalesce(first_failure, ?), retry_after = ?, wait_reason = ?
        WHERE local_id = ? AND role = ?
        """, [now, retryAfter, reason, identifier, role.rawValue])
    }

    /// Clears what a part's earlier failures left, so it is tried again now.
    func clearFailures(account: String, _ identifiers: [String]) throws {
        try database.transaction {
            for identifier in identifiers {
                try database.run("UPDATE part SET failure = NULL, retry_after = NULL, wait_reason = NULL WHERE local_id = ?",
                                 [identifier])
                try database.run("UPDATE backup SET upload_failure = NULL WHERE account = ? AND local_id = ?", [account, identifier])
            }
        }
    }

    func setStaged(_ identifier: String, _ role: BackupPartRole, _ path: String?) throws {
        try database.run("UPDATE part SET staged = ? WHERE local_id = ? AND role = ?", [path.map(files.kept), identifier, role.rawValue])
    }

    /// Every downloaded original still waiting for its upload.
    func stagedFiles() throws -> [String] {
        try database.query("SELECT staged FROM part WHERE staged IS NOT NULL", []) { files.path($0.text(0) ?? "") }
    }

    private static let partColumns = """
    local_id, role, name, uti, size, checksum, adjustment, failure, failures, first_failure, retry_after, staged, borrowed,
    wait_reason
    """

    private func readPart(_ row: BackupRow) -> BackupPartRow { readPart(row, offset: 0) }

    private func readPart(_ row: BackupRow, offset: Int32) -> BackupPartRow {
        BackupPartRow(localID: row.text(offset) ?? "", role: BackupPartRole(rawValue: row.text(offset + 1) ?? "") ?? .original,
                      name: row.text(offset + 2) ?? "", uti: row.text(offset + 3), size: row.optionalInt64(offset + 4),
                      checksum: row.text(offset + 5), adjustment: row.text(offset + 6), failure: row.text(offset + 7),
                      failures: row.int(offset + 8), firstFailure: row.date(offset + 9), retryAfter: row.date(offset + 10),
                      staged: row.text(offset + 11).map(files.path), borrowed: row.bool(offset + 12),
                      waitReason: row.text(offset + 13))
    }

    // MARK: The server's facts

    /// Fingerprints of the library's parts that the account's server has not been asked about; of `only` these photos,
    /// when given.
    func checksumsToCheck(account: String, limit: Int, only: [String]? = nil) throws -> [String] {
        let values: [any BackupBindable] = [account] + (only ?? []) + [limit]
        return try database.query("""
        SELECT DISTINCT t.checksum FROM part t JOIN photo p ON p.local_id = t.local_id
        LEFT JOIN remote r ON r.account = ? AND r.checksum = t.checksum
        WHERE t.checksum IS NOT NULL AND r.checksum IS NULL AND p.gone = 0\(Self.only(only, "p.local_id"))
        ORDER BY p.created DESC LIMIT ?
        """, values) { $0.text(0) ?? "" }
    }

    /// What the server said of these fingerprints. A part found there counts as sent, so it is missed if it goes; one
    /// in the trash is remembered as seen there, which makes it deleted on purpose if it goes.
    func recordChecks(account: String, _ checks: [String: (state: BackupRemoteState, assetID: String?)], now: Date = Date()) throws {
        try database.transaction {
            for (checksum, check) in checks {
                try database.run("""
                INSERT INTO remote(account, checksum, asset_id, state, checked, seen_trashed, sent)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(account, checksum) DO UPDATE SET
                    asset_id = coalesce(excluded.asset_id, remote.asset_id), state = excluded.state,
                    checked = excluded.checked, seen_trashed = max(remote.seen_trashed, excluded.seen_trashed),
                    sent = max(remote.sent, excluded.sent)
                """, [account, checksum, check.assetID, check.state.rawValue, now, check.state == .trashed,
                      check.state == .present])
            }
        }
    }

    /// An upload's answer: the part is on the server, sent by Verso.
    func recordUploaded(account: String, checksum: String, assetID: String, trashed: Bool, now: Date = Date()) throws {
        try recordChecks(account: account, [checksum: (trashed ? .trashed : .present, assetID)], now: now)
        try database.run("UPDATE remote SET sent = 1 WHERE account = ? AND checksum = ?", [account, checksum])
    }

    func remoteAssetID(account: String, checksum: String) throws -> String? {
        try database.first("SELECT asset_id FROM remote WHERE account = ? AND checksum = ?", [account, checksum]) { $0.text(0) } ?? nil
    }

    func remoteState(account: String, checksum: String) throws -> BackupRemoteState? {
        try database.first("SELECT state FROM remote WHERE account = ? AND checksum = ?", [account, checksum]) {
            BackupRemoteState(rawValue: $0.int(0))
        } ?? nil
    }

    /// The fingerprints of every part of photos that were in Immich, for the weekly check, in pages.
    func checksumsToVerify(account: String, after: String, limit: Int) throws -> [String] {
        try database.query("""
        SELECT checksum FROM remote WHERE account = ? AND (sent = 1 OR seen_trashed = 1) AND checksum > ?
        ORDER BY checksum LIMIT ?
        """, [account, after, limit]) { $0.text(0) ?? "" }
    }

    // MARK: Each photo's state

    /// Makes the account's row for every photo on the phone that has none.
    func ensureBackupRows(account: String) throws {
        try database.run("""
        INSERT OR IGNORE INTO backup(account, local_id, state, updated)
        SELECT ?, local_id, 0, ? FROM photo WHERE gone = 0
        """, [account, Date()])
    }

    /// A photo's facts for the rules (BackupRules.state).
    func facts(account: String, _ identifier: String) throws -> BackupPhotoFacts? {
        guard let row = try database.first("""
        SELECT state, decision, another_form, upload_failure FROM backup WHERE account = ? AND local_id = ?
        """, [account, identifier], { row in
            (BackupPhotoState(rawValue: row.int(0)) ?? .unchecked, row.optionalInt(1).flatMap(BackupDecision.init),
             row.text(2), row.text(3))
        }) else { return nil }
        let parts = try database.query("""
        SELECT t.role, t.checksum, t.failure, r.state, coalesce(r.sent, 0), coalesce(r.seen_trashed, 0)
        FROM part t LEFT JOIN remote r ON r.account = ? AND r.checksum = t.checksum WHERE t.local_id = ?
        """, [account, identifier]) { part in
            BackupPartFacts(role: BackupPartRole(rawValue: part.text(0) ?? "") ?? .original, checksum: part.text(1),
                            failure: part.text(2), remote: part.optionalInt(3).flatMap(BackupRemoteState.init),
                            sent: part.bool(4), seenTrashed: part.bool(5))
        }
        return BackupPhotoFacts(parts: parts, previous: row.0, decision: row.1,
                                anotherForm: row.2.map { !$0.isEmpty }, uploadFailure: row.3)
    }

    /// Works a photo's state out again from its facts and keeps it; the new state.
    @discardableResult
    func refreshState(account: String, _ identifier: String, now: Date = Date()) throws -> BackupPhotoState? {
        try database.transaction { () throws -> BackupPhotoState? in
            guard let photo = try photo(identifier), let facts = try facts(account: account, identifier) else { return nil }
            var state = facts.previous
            var reason: String?
            if !photo.gone { (state, reason) = BackupRules.state(of: facts) }
            // Back in Immich, or sent again: the person's decision about its leaving is spent.
            let clearsDecision = state == .backedUp && (facts.decision == .sendAgain || facts.decision == .letGo)
            try database.run("""
            UPDATE backup SET state = ?, reason = ?, updated = ?, decision = CASE WHEN ? THEN NULL ELSE decision END
            WHERE account = ? AND local_id = ?
            """, [state.rawValue, reason, now, clearsDecision, account, identifier])
            return state
        }
    }

    func setState(account: String, _ identifier: String, _ state: BackupPhotoState, reason: String? = nil) throws {
        try database.run("UPDATE backup SET state = ?, reason = ?, updated = ? WHERE account = ? AND local_id = ?",
                         [state.rawValue, reason, Date(), account, identifier])
    }

    func state(account: String, _ identifier: String) throws -> BackupPhotoState? {
        try database.first("SELECT state FROM backup WHERE account = ? AND local_id = ?", [account, identifier]) {
            BackupPhotoState(rawValue: $0.int(0))
        } ?? nil
    }

    /// Photos in a state for the account, newest first, a page at a time.
    func identifiers(account: String, in states: [BackupPhotoState], limit: Int, offset: Int = 0,
                     screenshots: Bool = true) throws -> [String] {
        let list = states.map { String($0.rawValue) }.joined(separator: ",")
        return try database.query("""
        SELECT b.local_id FROM backup b JOIN photo p ON p.local_id = b.local_id
        WHERE b.account = ? AND b.state IN (\(list)) AND p.gone = 0 AND \(shown("p"))
          AND (? OR (p.subtypes & \(BackupPhotoRow.screenshotSubtype)) = 0)
        ORDER BY p.created DESC LIMIT ? OFFSET ?
        """, [account, screenshots, limit, offset]) { $0.text(0) ?? "" }
    }

    func reason(account: String, _ identifier: String) throws -> String? {
        try database.first("SELECT reason FROM backup WHERE account = ? AND local_id = ?", [account, identifier]) { $0.text(0) } ?? nil
    }

    /// How many photos are in each state, for the account, among those backing up looks at.
    func counts(account: String, screenshots: Bool) throws -> [BackupPhotoState: Int] {
        var counts: [BackupPhotoState: Int] = [:]
        for (state, count) in try database.query("""
        SELECT b.state, count(*) FROM backup b JOIN photo p ON p.local_id = b.local_id
        WHERE b.account = ? AND p.gone = 0 AND \(shown("p")) AND (? OR (p.subtypes & \(BackupPhotoRow.screenshotSubtype)) = 0)
        GROUP BY b.state
        """, [account, screenshots], { (BackupPhotoState(rawValue: $0.int(0)), $0.int(1)) }) {
            if let state { counts[state] = count }
        }
        return counts
    }

    /// The photos Verso itself uploaded something of, still on the phone.
    func sentByVerso(account: String) throws -> Int {
        try database.first("""
        SELECT count(*) FROM backup b JOIN photo p ON p.local_id = b.local_id
        WHERE b.account = ? AND b.uploaded = 1 AND p.gone = 0
        """, [account]) { $0.int(0) } ?? 0
    }

    /// Parts whose fingerprints were borrowed from Immich (BackupMobileApp): Verso Dev shows how many.
    func borrowedCount() throws -> Int {
        try database.first("SELECT count(*) FROM part WHERE borrowed = 1", []) { $0.int(0) } ?? 0
    }

    /// Screenshots on the phone, which are left out while the Screenshots setting is off.
    func screenshots() throws -> Int {
        try database.first("""
        SELECT count(*) FROM photo WHERE gone = 0 AND \(shown()) AND (subtypes & \(BackupPhotoRow.screenshotSubtype)) != 0
        """, []) { $0.int(0) } ?? 0
    }

    /// Everything backing up knows, for every account, gone at once: Verso Dev's reset, to walk the first run again.
    /// Immich is not touched.
    func forgetEverything() throws {
        try database.transaction {
            for table in ["journal", "backup", "remote", "part", "photo", "meta", "freed"] {
                try database.run("DELETE FROM \(table)", [])
            }
        }
    }

    // MARK: Free Up Space

    /// The photos Free Up Space may remove, newest first: backed up whole on this account (every part in Immich), on
    /// the phone, hidden only where `includeHidden` (backed up into the Locked Folder, and not kept), old enough (the
    /// later of taken and added before `cutoff`), not a favourite where those stay, and of a burst only once every frame
    /// is in Immich. The albums that stay are left out by the caller.
    func freeUpCandidates(account: String, cutoff: Date, keepFavorites: Bool, includeHidden: Bool = false,
                          ageFromTaken: Bool = false) throws -> [FreeUpCandidate] {
        // Verso Dev's walks age photos by when they were taken alone: a Simulator's were all added lately.
        let added = ageFromTaken ? "0" : "coalesce(p.added, 0)"
        let photos = try database.query("""
        SELECT \(Self.columns(Self.photoColumns, "p")) FROM backup b JOIN photo p ON p.local_id = b.local_id
        WHERE b.account = ? AND b.state = \(BackupPhotoState.backedUp.rawValue) AND p.gone = 0 AND (? OR p.hidden = 0)
          AND (p.created IS NOT NULL OR p.added IS NOT NULL)
          AND max(coalesce(p.created, 0), \(added)) < ?
          AND (? = 0 OR p.favorite = 0)
          AND (p.burst IS NULL OR NOT EXISTS (
              SELECT 1 FROM photo q JOIN backup c ON c.local_id = q.local_id AND c.account = b.account
              WHERE q.burst = p.burst AND q.gone = 0 AND c.state != \(BackupPhotoState.backedUp.rawValue)))
        ORDER BY p.created DESC
        """, [account, includeHidden, cutoff, keepFavorites], Self.readPhoto)
        return try photos.map { photo in
            let parts = try database.query("""
            SELECT t.role, t.checksum, t.size, t.borrowed, t.uti, r.asset_id FROM part t
            LEFT JOIN remote r ON r.account = ? AND r.checksum = t.checksum
            WHERE t.local_id = ? AND t.checksum IS NOT NULL ORDER BY t.role
            """, [account, photo.localID]) { row in
                FreeUpCandidate.Part(role: BackupPartRole(rawValue: row.text(0) ?? "") ?? .original, checksum: row.text(1) ?? "",
                                     size: row.optionalInt64(2), assetID: row.text(5), borrowed: row.bool(3), uti: row.text(4))
            }
            return FreeUpCandidate(photo: photo, parts: parts)
        }
    }

    /// The photos the person freed, each part as Immich has it, watched for 30 days while Recently Deleted keeps them.
    func recordFreed(account: String, _ candidates: [FreeUpCandidate], now: Date = Date()) throws {
        try database.transaction {
            for candidate in candidates {
                for part in candidate.parts {
                    try database.run("""
                    INSERT INTO freed(account, local_id, checksum, asset_id, freed) VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(account, local_id, checksum) DO UPDATE SET freed = excluded.freed, announced = 0
                    """, [account, candidate.photo.localID, part.checksum, part.assetID, now])
                }
            }
        }
    }

    /// The fingerprints of photos freed since `since` and not yet said to be gone, with when each was freed.
    func freedToWatch(account: String, since: Date) throws -> [(checksum: String, localID: String, freed: Date)] {
        try database.query("""
        SELECT checksum, local_id, freed FROM freed WHERE account = ? AND freed > ? AND announced = 0
        """, [account, since]) { ($0.text(0) ?? "", $0.text(1) ?? "", $0.date(2) ?? Date()) }
    }

    func markFreedAnnounced(account: String, _ checksums: [String]) throws {
        try database.transaction {
            for checksum in checksums {
                try database.run("UPDATE freed SET announced = 1 WHERE account = ? AND checksum = ?", [account, checksum])
            }
        }
    }

    /// Freed photos past their 30 days in Recently Deleted: nothing can bring them back, so nothing more to watch.
    func pruneFreed(before: Date) throws {
        try database.run("DELETE FROM freed WHERE freed < ?", [before])
    }

    /// The bytes of the parts still to go, of photos that go.
    func bytesToUpload(account: String, screenshots: Bool) throws -> Int64 {
        try database.first("""
        SELECT coalesce(sum(t.size), 0) FROM part t JOIN backup b ON b.local_id = t.local_id AND b.account = ?
        JOIN photo p ON p.local_id = t.local_id
        LEFT JOIN remote r ON r.account = b.account AND r.checksum = t.checksum
        WHERE b.state = \(BackupPhotoState.toUpload.rawValue) AND (r.state IS NULL OR r.state = 0) AND p.gone = 0
          AND (? OR (p.subtypes & \(BackupPhotoRow.screenshotSubtype)) = 0)
        """, [account, screenshots]) { $0.int64(0) } ?? 0
    }

    func setDecision(account: String, _ identifiers: [String], _ decision: BackupDecision?) throws {
        try database.transaction {
            for identifier in identifiers {
                try database.run("UPDATE backup SET decision = ?, upload_failure = NULL WHERE account = ? AND local_id = ?",
                                 [decision?.rawValue, account, identifier])
                try refreshState(account: account, identifier)
            }
        }
    }

    /// Whether Immich has the photo in another form: the asset it looks like, or none.
    func setAnotherForm(account: String, _ identifier: String, assetID: String?) throws {
        try database.run("UPDATE backup SET another_form = ? WHERE account = ? AND local_id = ?",
                         [assetID ?? "", account, identifier])
        try refreshState(account: account, identifier)
    }

    func anotherFormAsset(account: String, _ identifier: String) throws -> String? {
        try database.first("SELECT another_form FROM backup WHERE account = ? AND local_id = ?", [account, identifier]) {
            $0.text(0)
        }?.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Photos whose state waits to be worked out: every part fingerprinted and checked, or one that failed; those
    /// not in Immich at all only once they were looked at for another form.
    func photosReadyForState(account: String, limit: Int) throws -> [String] {
        try database.query("""
        SELECT b.local_id FROM backup b JOIN photo p ON p.local_id = b.local_id
        WHERE b.account = ? AND b.state = \(BackupPhotoState.unchecked.rawValue) AND p.gone = 0 AND p.parts_read = 1
          AND EXISTS (SELECT 1 FROM part t WHERE t.local_id = b.local_id)
          AND (EXISTS (SELECT 1 FROM part t WHERE t.local_id = b.local_id AND t.failure IS NOT NULL)
               OR (NOT EXISTS (SELECT 1 FROM part t LEFT JOIN remote r ON r.account = b.account AND r.checksum = t.checksum
                               WHERE t.local_id = b.local_id AND (t.checksum IS NULL OR r.state IS NULL))
                   AND (b.another_form IS NOT NULL OR b.decision IS NOT NULL OR b.upload_failure IS NOT NULL
                        OR EXISTS (SELECT 1 FROM part t JOIN remote r ON r.account = b.account AND r.checksum = t.checksum
                                   WHERE t.local_id = b.local_id AND (r.state != 0 OR r.sent = 1 OR r.seen_trashed = 1)))))
        LIMIT ?
        """, [account, limit]) { $0.text(0) ?? "" }
    }

    /// Whether Verso itself uploaded a part of the photo to the account, and when it last did.
    func uploadedByVerso(account: String, _ identifier: String) throws -> Bool {
        try database.first("SELECT uploaded FROM backup WHERE account = ? AND local_id = ?", [account, identifier]) { $0.bool(0) } ?? false
    }

    func lastUpload(account: String, _ identifier: String) throws -> Date? {
        try database.first("""
        SELECT max(finished) FROM journal WHERE account = ? AND local_id = ? AND step = 'upload' AND result = 'created'
        """, [account, identifier]) { $0.date(0) } ?? nil
    }

    /// Downloaded originals that will not go after all: found in Immich, or of photos that do not go.
    func stagedNotGoing(account: String) throws -> [(String, BackupPartRole, String)] {
        try database.query("""
        SELECT t.local_id, t.role, t.staged FROM part t
        LEFT JOIN backup b ON b.account = ? AND b.local_id = t.local_id
        LEFT JOIN remote r ON r.account = ? AND r.checksum = t.checksum
        WHERE t.staged IS NOT NULL AND ((r.state IS NOT NULL AND r.state != 0)
              OR (b.state IS NOT NULL AND b.state NOT IN (\(BackupPhotoState.unchecked.rawValue), \(BackupPhotoState.toUpload.rawValue))))
        """, [account, account]) { row in
            (row.text(0) ?? "", BackupPartRole(rawValue: row.text(1) ?? "") ?? .original, files.path(row.text(2) ?? ""))
        }
    }

    /// Photos not yet looked at for another form, whose parts were all checked and none is in Immich, newest first.
    func photosToMatch(account: String, limit: Int) throws -> [BackupPhotoRow] {
        try database.query("""
        SELECT \(Self.columns(Self.photoColumns, "p"))
        FROM backup b JOIN photo p ON p.local_id = b.local_id
        WHERE b.account = ? AND b.another_form IS NULL AND b.state = \(BackupPhotoState.unchecked.rawValue) AND p.gone = 0
          AND b.decision IS NULL AND p.parts_read = 1
          AND NOT EXISTS (SELECT 1 FROM part t LEFT JOIN remote r ON r.account = b.account AND r.checksum = t.checksum
                          WHERE t.local_id = b.local_id AND (t.checksum IS NULL OR t.failure IS NOT NULL OR r.state IS NULL
                                                             OR r.state != 0 OR r.sent = 1 OR r.seen_trashed = 1))
          AND EXISTS (SELECT 1 FROM part t WHERE t.local_id = b.local_id)
        ORDER BY p.created DESC LIMIT ?
        """, [account, limit], Self.readPhoto)
    }

    /// Parts Immich does not hold under their fingerprints after Verso's upload made them: the bytes it took differ from
    /// those Verso read. They stop counting as sent, so nothing takes them for in Immich, and the photo needs a look
    /// rather than going again on its own, which would make another asset each time.
    func recordNotAsSent(account: String, _ identifier: String, checksums: [String], reason: String) throws {
        try database.transaction {
            for checksum in checksums {
                try database.run("""
                UPDATE remote SET state = \(BackupRemoteState.absent.rawValue), sent = 0, asset_id = NULL
                WHERE account = ? AND checksum = ?
                """, [account, checksum])
            }
            try database.run("UPDATE backup SET upload_failure = ? WHERE account = ? AND local_id = ?", [reason, account, identifier])
        }
        try refreshState(account: account, identifier)
    }

    func setUploadFailure(account: String, _ identifier: String, _ reason: String?) throws {
        try database.run("UPDATE backup SET upload_failure = ? WHERE account = ? AND local_id = ?", [reason, account, identifier])
        try refreshState(account: account, identifier)
    }

    func markAnnounced(account: String, _ identifiers: [String]) throws {
        try database.transaction {
            for identifier in identifiers {
                try database.run("UPDATE backup SET announced = 1 WHERE account = ? AND local_id = ?", [account, identifier])
            }
        }
    }

    func announced(account: String) throws -> Set<String> {
        Set(try database.query("SELECT local_id FROM backup WHERE account = ? AND announced = 1", [account]) { $0.text(0) ?? "" })
    }

    /// Backed-up photos Verso uploaded something of whose stack or metadata is not done yet. Photos that were in
    /// Immich already are left as they are there.
    func photosToFinish(account: String, limit: Int) throws -> [String] {
        try database.query("""
        SELECT b.local_id FROM backup b JOIN photo p ON p.local_id = b.local_id
        WHERE b.account = ? AND b.state = \(BackupPhotoState.backedUp.rawValue) AND b.finished = 0 AND b.uploaded = 1
          AND p.gone = 0
        ORDER BY p.created DESC LIMIT ?
        """, [account, limit]) { $0.text(0) ?? "" }
    }

    /// The assets Verso made for a photo: those its own uploads created, not ones Immich had already.
    func assetsMade(account: String, _ identifier: String) throws -> Set<String> {
        Set(try database.query("""
        SELECT asset_id FROM journal
        WHERE account = ? AND local_id = ? AND step = '\(BackupStep.Kind.upload.rawValue)' AND result = 'created'
          AND asset_id IS NOT NULL
        """, [account, identifier]) { $0.text(0) ?? "" })
    }

    func setFinished(account: String, _ identifier: String, _ finished: Bool) throws {
        try database.run("UPDATE backup SET finished = ? WHERE account = ? AND local_id = ?", [finished, account, identifier])
    }

    /// The asset ids of renderings an edit replaced, which stay in the photo's stack under the newest.
    func previousTops(account: String, _ identifier: String) throws -> [String] {
        let text = try database.first("SELECT previous_tops FROM backup WHERE account = ? AND local_id = ?",
                                      [account, identifier]) { $0.text(0) } ?? nil
        return text?.split(separator: ",").map(String.init) ?? []
    }

    private func keepPreviousTop(account: String, identifier: String, assetID: String) throws {
        var tops = try previousTops(account: account, identifier)
        guard !tops.contains(assetID) else { return }
        tops.append(assetID)
        try database.run("UPDATE backup SET previous_tops = ? WHERE account = ? AND local_id = ?",
                         [tops.joined(separator: ","), account, identifier])
    }

    // MARK: Uploads

    /// Parts of photos that go, ready to be sent, newest first: not on the server, not already on their way, not
    /// waiting to be tried again; a Live Photo's still only once its video is there, so it can point at it.
    func uploadCandidates(account: String, limit: Int, screenshots: Bool, now: Date = Date(),
                          only: [String]? = nil) throws -> [BackupUploadCandidate] {
        let values: [any BackupBindable] = [account, screenshots, now] + (only ?? []) + [limit * 2]
        let rows = try database.query("""
        SELECT \(Self.columns(Self.photoColumns, "p")),
               \(Self.columns(Self.partColumns, "t"))
        FROM backup b JOIN photo p ON p.local_id = b.local_id JOIN part t ON t.local_id = b.local_id
        LEFT JOIN remote r ON r.account = b.account AND r.checksum = t.checksum
        WHERE b.account = ? AND b.state = \(BackupPhotoState.toUpload.rawValue) AND p.gone = 0 AND \(shown("p"))
          AND (? OR (p.subtypes & \(BackupPhotoRow.screenshotSubtype)) = 0)
          AND t.checksum IS NOT NULL AND r.state = 0
          AND (t.retry_after IS NULL OR t.retry_after <= ?)\(Self.only(only, "p.local_id"))
          AND NOT EXISTS (SELECT 1 FROM journal j WHERE j.account = b.account AND j.local_id = b.local_id
                          AND j.role = t.role AND j.step = 'upload' AND j.result IS NULL)
        ORDER BY p.created DESC, CASE WHEN t.role IN ('originalPair', 'renderPair') THEN 0 ELSE 1 END LIMIT ?
        """, values) { row in
            (Self.readPhoto(row), self.readPart(row, offset: Self.partOffset))
        }
        var candidates: [BackupUploadCandidate] = []
        for (photo, part) in rows {
            var candidate = BackupUploadCandidate(photo: photo, part: part)
            if let pairRole = part.role.pairedVideo,
               let pair = try parts(photo.localID).first(where: { $0.role == pairRole }) {
                // The still waits for its video's asset.
                guard let checksum = pair.checksum, try remoteState(account: account, checksum: checksum) == .present,
                      let videoAsset = try remoteAssetID(account: account, checksum: checksum) else { continue }
                candidate.pairedVideoAssetID = videoAsset
            }
            candidates.append(candidate)
            if candidates.count == limit { break }
        }
        return candidates
    }

    /// An upload that failed for now: tried again after `retryAfter`.
    /// A part put off until `retryAfter`, and why, in the person's words (To Check, To Upload).
    func postpone(_ identifier: String, _ role: BackupPartRole, until retryAfter: Date, reason: String) throws {
        try database.run("UPDATE part SET retry_after = ?, wait_reason = ? WHERE local_id = ? AND role = ?",
                         [retryAfter, reason, identifier, role.rawValue])
    }

    /// The soonest a part put off is tried again, of the photos still to check or to upload: when a pass should wake.
    func nextRetry(account: String, now: Date = Date()) throws -> Date? {
        try database.first("""
        SELECT min(t.retry_after) FROM part t JOIN photo p ON p.local_id = t.local_id
        JOIN backup b ON b.account = ? AND b.local_id = t.local_id
        WHERE t.retry_after > ? AND p.gone = 0 AND \(shown("p"))
          AND b.state IN (\(BackupPhotoState.unchecked.rawValue), \(BackupPhotoState.toUpload.rawValue))
        """, [account, now]) { $0.date(0) } ?? nil
    }

    // MARK: The journal

    /// Writes a step's intent before it starts: its id.
    func beginStep(account: String, _ identifier: String, role: BackupPartRole?, kind: BackupStep.Kind,
                   checksum: String? = nil, file: String? = nil, now: Date = Date()) throws -> Int64 {
        try database.transaction {
            try database.run("""
            INSERT INTO journal(account, local_id, role, step, checksum, file, started) VALUES (?, ?, ?, ?, ?, ?, ?)
            """, [account, identifier, role?.rawValue, kind.rawValue, checksum, file.map(files.kept), now])
            return database.lastInsertedRow
        }
    }

    func setStepTask(_ id: Int64, task: Int) throws {
        try database.run("UPDATE journal SET task = ? WHERE id = ?", [task, id])
    }

    /// Writes a step's result after it; a step that already has one keeps it.
    @discardableResult
    func finishStep(_ id: Int64, result: String, assetID: String? = nil, now: Date = Date()) throws -> Bool {
        try database.run("UPDATE journal SET result = ?, asset_id = ?, finished = ? WHERE id = ? AND result IS NULL",
                         [result, assetID, now, id]) > 0
    }

    /// An upload step recovery closed before its answer came (BackupEngine.recover), which Immich's answer says Verso's
    /// upload created.
    func recordCreatedAfterRecovery(_ id: Int64, assetID: String, now: Date = Date()) throws -> Bool {
        try database.run("""
        UPDATE journal SET result = 'created', asset_id = ?, finished = ?
        WHERE id = ? AND step = 'upload' AND result IN ('duplicate', 'lost')
        """, [assetID, now, id]) > 0
    }

    /// Steps written without a result: on their way, or cut short when Verso was stopped.
    func openSteps(account: String? = nil) throws -> [BackupStep] {
        try database.query("""
        SELECT id, account, local_id, role, step, checksum, file, task, started FROM journal
        WHERE result IS NULL AND (? IS NULL OR account = ?) ORDER BY id
        """, [account, account]) { row in
            BackupStep(id: row.int64(0), account: row.text(1) ?? "", localID: row.text(2) ?? "",
                       role: row.text(3).flatMap(BackupPartRole.init), kind: BackupStep.Kind(rawValue: row.text(4) ?? "") ?? .upload,
                       checksum: row.text(5), file: row.text(6).map(files.path), task: row.optionalInt(7), started: row.date(8) ?? Date())
        }
    }

    func step(_ id: Int64) throws -> BackupStep? {
        try database.first("""
        SELECT id, account, local_id, role, step, checksum, file, task, started, result FROM journal WHERE id = ?
        """, [id]) { row in
            BackupStep(id: row.int64(0), account: row.text(1) ?? "", localID: row.text(2) ?? "",
                       role: row.text(3).flatMap(BackupPartRole.init), kind: BackupStep.Kind(rawValue: row.text(4) ?? "") ?? .upload,
                       checksum: row.text(5), file: row.text(6).map(files.path), task: row.optionalInt(7), started: row.date(8) ?? Date())
        }
    }

    /// Steps with their results older than a month go: the facts they led to are in the other tables.
    func pruneJournal(before: Date) throws {
        try database.run("DELETE FROM journal WHERE result IS NOT NULL AND finished < ?", [before])
    }

    /// The upload bodies open steps still use.
    func filesInUse() throws -> Set<String> {
        Set(try database.query("SELECT file FROM journal WHERE result IS NULL AND file IS NOT NULL", []) { files.path($0.text(0) ?? "") })
            .union(try stagedFiles())
    }

    func uploadsOnTheirWay(account: String) throws -> Int {
        try database.first("SELECT count(*) FROM journal WHERE account = ? AND step = 'upload' AND result IS NULL",
                           [account]) { $0.int(0) } ?? 0
    }

    /// The uploads on their way for the account: each step, its photo, and the transport's task.
    func openUploads(account: String) throws -> [(step: Int64, localID: String, task: Int?)] {
        try database.query("""
        SELECT id, local_id, task FROM journal WHERE account = ? AND step = 'upload' AND result IS NULL
        """, [account]) { row in (row.int64(0), row.text(1) ?? "", row.optionalInt(2)) }
    }

    // MARK: On its way

    /// Backing up was switched on for the account: photos that come to the phone from now count as new. The first
    /// time is kept, through switching off and on again.
    func markSwitchedOn(account: String, now: Date = Date()) throws {
        guard try metaDate("onSince.\(account)") == nil else { return }
        try setMetaDate("onSince.\(account)", now)
    }

    /// When photos that came to the phone count as new for the account (BackupOnItsWay.newSince); nil before its first
    /// run started, when nothing is on its way.
    func newSince(account: String) throws -> Date? {
        guard let started = try metaDate("firstRunStarted.\(account)") else { return nil }
        return BackupOnItsWay.newSince(switchedOn: try metaDate("onSince.\(account)"), firstRunStarted: started)
    }

    /// Photos on their way to the account's server, newest first, a page at a time: those to upload or uploading,
    /// those needing a look, and new ones not checked yet. With `onlyNew`, the new ones alone, for the Library. Never a
    /// hidden photo, even where hidden photos are backed up: their pictures stay out of the Library and On Its Way.
    func waitingPhotos(account: String, onlyNew: Bool, screenshots: Bool, limit: Int,
                       offset: Int = 0) throws -> [BackupWaitingPhoto] {
        guard let since = try newSince(account: account) else { return [] }
        let going = "\(BackupPhotoState.toUpload.rawValue), \(BackupPhotoState.needsLook.rawValue)"
        let unchecked = BackupPhotoState.unchecked.rawValue
        let isNew = "(p.added > ? OR (p.added IS NULL AND p.created > ?))"
        let which = onlyNew
            ? "\(isNew) AND coalesce(b.state, \(unchecked)) IN (\(unchecked), \(going))"
            : "(coalesce(b.state, \(unchecked)) IN (\(going)) OR (coalesce(b.state, \(unchecked)) = \(unchecked) AND \(isNew)))"
        return try database.query("""
        SELECT p.local_id, p.created, p.added, p.kind, p.favorite, coalesce(b.state, \(unchecked)),
               EXISTS (SELECT 1 FROM journal j WHERE j.account = ? AND j.local_id = p.local_id AND j.step = 'upload'
                       AND j.result IS NULL)
        FROM photo p LEFT JOIN backup b ON b.account = ? AND b.local_id = p.local_id
        WHERE p.gone = 0 AND p.hidden = 0 AND (? OR (p.subtypes & \(BackupPhotoRow.screenshotSubtype)) = 0) AND \(which)
        ORDER BY p.created DESC LIMIT ? OFFSET ?
        """, [account, account, screenshots, since, since, limit, offset]) { row in
            BackupWaitingPhoto(localID: row.text(0) ?? "", created: row.date(1), added: row.date(2), isVideo: row.int(3) == 2,
                               favorite: row.bool(4), state: BackupPhotoState(rawValue: row.int(5)) ?? .unchecked,
                               uploading: row.bool(6))
        }
    }

    /// How many photos go: those to upload, and new ones not checked yet, which go once they are.
    func goingCount(account: String, screenshots: Bool) throws -> Int {
        let toUpload = try counts(account: account, screenshots: screenshots)[.toUpload] ?? 0
        guard let since = try newSince(account: account) else { return toUpload }
        let unchecked = BackupPhotoState.unchecked.rawValue
        let newUnchecked = try database.first("""
        SELECT count(*) FROM photo p LEFT JOIN backup b ON b.account = ? AND b.local_id = p.local_id
        WHERE p.gone = 0 AND \(shown("p")) AND (? OR (p.subtypes & \(BackupPhotoRow.screenshotSubtype)) = 0)
          AND (p.added > ? OR (p.added IS NULL AND p.created > ?)) AND coalesce(b.state, \(unchecked)) = \(unchecked)
        """, [account, screenshots, since, since]) { $0.int(0) } ?? 0
        return toUpload + newUnchecked
    }

    /// New photos that wait to be checked or sent, newest first, with no upload on its way: the ones that go first.
    func newPhotosToSend(account: String, screenshots: Bool, limit: Int) throws -> [String] {
        guard let since = try newSince(account: account) else { return [] }
        let unchecked = BackupPhotoState.unchecked.rawValue
        return try database.query("""
        SELECT p.local_id FROM photo p LEFT JOIN backup b ON b.account = ? AND b.local_id = p.local_id
        WHERE p.gone = 0 AND \(shown("p")) AND (? OR (p.subtypes & \(BackupPhotoRow.screenshotSubtype)) = 0)
          AND (p.added > ? OR (p.added IS NULL AND p.created > ?))
          AND coalesce(b.state, \(unchecked)) IN (\(unchecked), \(BackupPhotoState.toUpload.rawValue))
          AND NOT EXISTS (SELECT 1 FROM journal j WHERE j.account = ? AND j.local_id = p.local_id AND j.step = 'upload'
                          AND j.result IS NULL)
        ORDER BY p.created DESC LIMIT ?
        """, [account, screenshots, since, since, account, limit]) { $0.text(0) ?? "" }
    }

    /// Of these Immich assets, those whose original or edit's rendering is a photo on the phone that is not gone, each
    /// with the photo's local identifier: Immich has that file's fingerprint as the asset, sent by Verso or found there.
    func phonePhotos(account: String, assets: [String]) throws -> [String: String] {
        var found: [String: String] = [:]
        for asset in assets {
            let local = try database.first("""
            SELECT t.local_id FROM remote r JOIN part t ON t.checksum = r.checksum JOIN photo p ON p.local_id = t.local_id
            WHERE r.account = ? AND r.asset_id = ? AND p.gone = 0 AND t.role IN ('original', 'render') LIMIT 1
            """, [account, asset]) { $0.text(0) } ?? nil
            if let local { found[asset] = local }
        }
        return found
    }

    /// Of these photos, the ones Verso uploaded that are now in Immich, each with the asset the timeline shows for it:
    /// an edit's rendering, or else its original.
    func arrivedAssets(account: String, _ identifiers: [String]) throws -> [String: String] {
        var arrived: [String: String] = [:]
        for identifier in identifiers {
            guard try state(account: account, identifier) == .backedUp,
                  try uploadedByVerso(account: account, identifier) else { continue }
            let assets = try database.query("""
            SELECT t.role, r.asset_id FROM part t JOIN remote r ON r.account = ? AND r.checksum = t.checksum
            WHERE t.local_id = ? AND t.role IN ('render', 'original') AND r.asset_id IS NOT NULL
            """, [account, identifier]) { row in (row.text(0) ?? "", row.text(1) ?? "") }
            if let shown = assets.first(where: { $0.0 == BackupPartRole.render.rawValue }) ?? assets.first {
                arrived[identifier] = shown.1
            }
        }
        return arrived
    }
}
