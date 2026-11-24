// Logic tests of backing up's store (ios/Verso/Backup/BackupStore.swift) on a fresh SQLite file: the change token kept
// with its rows, a photo found again under a new identifier, fingerprints kept across accounts, a photo's state worked
// out from its parts and the server's facts, the journal's intent and result with recovery's facts, and the uploads
// planned: nothing unchecked, a Live Photo's still only after its video; and Immich's photos found on the phone by their
// asset, for Save to Photos.

import XCTest

final class BackupStoreTests: XCTestCase {
    private var directory: URL!
    private var store: BackupStore!
    private let account = "https://immich.example/api|user"

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("BackupStoreTests-\(UUID().uuidString)")
        store = try BackupStore(file: directory.appendingPathComponent("backup.sqlite"))
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private func photo(_ identifier: String, cloud: String? = nil, created: TimeInterval = 1_700_000_000,
                       subtypes: Int = 0) -> BackupPhotoRow {
        BackupPhotoRow(localID: identifier, cloudID: cloud, created: Date(timeIntervalSince1970: created), added: nil,
                       modified: Date(timeIntervalSince1970: created), kind: 1, subtypes: subtypes, favorite: false,
                       hidden: false, burst: nil, burstPick: false, latitude: nil, longitude: nil, name: nil)
    }

    private func part(_ identifier: String, _ role: BackupPartRole = .original, name: String = "IMG_0001.HEIC") -> BackupPartRow {
        BackupPartRow(localID: identifier, role: role, name: name)
    }

    /// The store keeps its files' paths relative to the backup folder, which moves with the app's container: a store
    /// opened where the container is now finds them there, also one kept whole by an earlier version; the sweep keeps
    /// what is in use; and the folder stays out of the phone's own backup.
    func testFilesAreFoundWhereTheFolderIsNow() throws {
        let before = BackupFiles(root: directory.appendingPathComponent("before/Backup"))
        let now = BackupFiles(root: directory.appendingPathComponent("now/Backup"))
        let file = directory.appendingPathComponent("files.sqlite")
        let first = try BackupStore(file: file, files: before)
        try first.upsertPhotos([photo("one")])
        try first.setParts("one", [part("one")], account: account)
        try first.setFingerprint("one", .original, checksum: "sum", size: 10, staged: before.staged.appendingPathComponent("download").path)
        let body = try first.beginStep(account: account, "one", role: .original, kind: .upload, checksum: "sum",
                                       file: before.uploads.appendingPathComponent("body").path)
        let legacy = try first.beginStep(account: account, "one", role: .original, kind: .upload, checksum: "sum",
                                         file: "/var/mobile/Containers/Data/Application/OLD/Library/Application Support/Backup/Uploads/legacy")
        XCTAssertEqual(try first.database.first("SELECT staged FROM part", []) { $0.text(0) }, "Downloads/download")

        let moved = try BackupStore(file: file, files: now)
        XCTAssertEqual(try moved.parts("one").first?.staged, now.staged.appendingPathComponent("download").path)
        XCTAssertEqual(try moved.step(body)?.file, now.uploads.appendingPathComponent("body").path)
        XCTAssertEqual(try moved.step(legacy)?.file, now.uploads.appendingPathComponent("legacy").path)
        XCTAssertEqual(now.path("/tmp/elsewhere"), "/tmp/elsewhere", "a file outside the folder is left as it is")

        now.prepare()
        XCTAssertEqual(try now.root.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        for name in ["Downloads/download", "Uploads/body", "Uploads/legacy", "Uploads/left"] {
            FileManager.default.createFile(atPath: now.root.appendingPathComponent(name).path, contents: Data())
        }
        now.sweep(keeping: try moved.filesInUse())
        for name in ["Downloads/download", "Uploads/body", "Uploads/legacy"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: now.root.appendingPathComponent(name).path), name)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: now.root.appendingPathComponent("Uploads/left").path),
                       "what nothing uses goes")
    }

    func testTheDatabaseIsInWALMode() throws {
        let mode = try store.database.first("PRAGMA journal_mode", []) { $0.text(0) }
        XCTAssertEqual(mode, "wal")
    }

    func testTheTokenIsKeptWithTheRowsItCovers() throws {
        try store.upsertPhotos([photo("one")], gone: [], token: Data([1, 2, 3]))
        XCTAssertEqual(try store.metaData("changeToken"), Data([1, 2, 3]))
        XCTAssertEqual(try store.photoCount(), 1)
        XCTAssertThrowsError(try store.database.transaction {
            try store.upsertPhotos([photo("two")], gone: [], token: Data([4]))
            throw CancellationError()
        })
        XCTAssertEqual(try store.metaData("changeToken"), Data([1, 2, 3]), "a failed batch keeps neither its rows nor its token")
        XCTAssertEqual(try store.photoCount(), 1)
    }

    func testAPhotoUnderANewIdentifierKeepsItsHistory() throws {
        try store.upsertPhotos([photo("old", cloud: "cloud-1")])
        try store.setParts("old", [part("old")], account: account)
        try store.setFingerprint("old", .original, checksum: "sum", size: 10)
        try store.ensureBackupRows(account: account)
        try store.recordChecks(account: account, ["sum": (.present, "asset")])
        try store.refreshState(account: account, "old")
        XCTAssertEqual(try store.state(account: account, "old"), .backedUp)

        try store.markGone(["old"])
        XCTAssertEqual(try store.photosByCloudIdentifier(["cloud-1"]), ["cloud-1": "old"])
        try store.remap(from: "old", to: "new")
        XCTAssertNil(try store.photo("old"))
        XCTAssertEqual(try store.photo("new")?.gone, false)
        XCTAssertEqual(try store.parts("new").first?.checksum, "sum", "the fingerprint follows")
        XCTAssertEqual(try store.state(account: account, "new"), .backedUp, "not taken for new")
    }

    func testImmichsPhotosFromThisPhoneAreFoundByTheirAsset() throws {
        try store.upsertPhotos([photo("one"), photo("two"), photo("gone")])
        for identifier in ["one", "two", "gone"] {
            try store.setParts(identifier, [part(identifier)], account: account)
            try store.setFingerprint(identifier, .original, checksum: "sum-\(identifier)", size: 10)
        }
        try store.recordChecks(account: account, ["sum-one": (.present, "asset-one"), "sum-gone": (.present, "asset-gone")])
        try store.recordChecks(account: "https://other.example/api|user", ["sum-two": (.present, "asset-two")])
        try store.markGone(["gone"])
        XCTAssertEqual(try store.phonePhotos(account: account, assets: ["asset-one", "asset-two", "asset-gone", "asset-none"]),
                       ["asset-one": "one"], "another account's asset and a photo gone from the phone are not found")
    }

    func testFingerprintsAreKeptAcrossAccountsAndCheckedPerAccount() throws {
        try store.upsertPhotos([photo("one")])
        try store.setParts("one", [part("one")], account: account)
        try store.setFingerprint("one", .original, checksum: "sum", size: 10)
        let other = "https://other.example/api|user"
        try store.ensureBackupRows(account: account)
        try store.ensureBackupRows(account: other)
        try store.recordChecks(account: account, ["sum": (.present, "asset")])
        XCTAssertEqual(try store.checksumsToCheck(account: account, limit: 10), [])
        XCTAssertEqual(try store.checksumsToCheck(account: other, limit: 10), ["sum"], "a new server costs a check, not a fingerprint")
        XCTAssertEqual(try store.partsToFingerprint(limit: 10, screenshots: true).count, 0)
    }

    func testAnEditsNewRenderingIsFingerprintedAgainAndTheOldOneKept() throws {
        try store.upsertPhotos([photo("one")])
        var render = part("one", .render, name: "IMG_0001.jpg")
        render.adjustment = "first edit"
        try store.setParts("one", [part("one"), render], account: account)
        try store.setFingerprint("one", .original, checksum: "original", size: 10)
        try store.setFingerprint("one", .render, checksum: "render-1", size: 10)
        try store.ensureBackupRows(account: account)
        try store.recordUploaded(account: account, checksum: "render-1", assetID: "asset-render-1", trashed: false)

        try store.setParts("one", [part("one"), render], account: account)
        XCTAssertEqual(try store.parts("one").first { $0.role == .render }?.checksum, "render-1", "the same edit keeps its fingerprint")

        render.adjustment = "second edit"
        try store.setParts("one", [part("one"), render], account: account)
        XCTAssertNil(try store.parts("one").first { $0.role == .render }?.checksum, "a new edit is fingerprinted again")
        XCTAssertEqual(try store.parts("one").first { $0.role == .original }?.checksum, "original")
        XCTAssertEqual(try store.previousTops(account: account, "one"), ["asset-render-1"], "kept in the stack, never deleted")
    }

    func testFailuresWaitAndShow() throws {
        try store.upsertPhotos([photo("one")])
        try store.setParts("one", [part("one")], account: account)
        try store.ensureBackupRows(account: account)
        let now = Date()
        try store.setFingerprintFailure("one", .original, reason: "iCloud said no", retryAfter: now.addingTimeInterval(3600), now: now)
        XCTAssertEqual(try store.partsToFingerprint(limit: 10, now: now, screenshots: true).count, 0, "tried again later")
        XCTAssertEqual(try store.partsToFingerprint(limit: 10, now: now.addingTimeInterval(7200), screenshots: true).count, 1)
        XCTAssertEqual(try store.photosReadyForState(account: account, limit: 10), ["one"])
        try store.refreshState(account: account, "one")
        XCTAssertEqual(try store.state(account: account, "one"), .needsLook)
        XCTAssertEqual(try store.reason(account: account, "one"), "iCloud said no")
    }

    /// A read that fails is tried again quietly: the photo stays still to check, with no reason shown, until it has
    /// failed for long enough to need the person (BackupRules.readNeedsLook).
    func testAFailedReadIsTriedAgainQuietly() throws {
        try store.upsertPhotos([photo("one")])
        try store.setParts("one", [part("one")], account: account)
        try store.ensureBackupRows(account: account)
        let now = Date()
        try store.setFingerprintRetry("one", .original, retryAfter: now.addingTimeInterval(300), reason: "Couldn't be read", now: now)
        try store.refreshState(account: account, "one")
        XCTAssertEqual(try store.state(account: account, "one"), .unchecked, "still to check, not Needs a Look")
        XCTAssertNil(try store.reason(account: account, "one"))
        XCTAssertEqual(try store.partsToFingerprint(limit: 10, now: now, screenshots: true).count, 0, "tried again later")
        let waiting = try store.partsToFingerprint(limit: 10, now: now.addingTimeInterval(600), screenshots: true)
        XCTAssertEqual(waiting.first?.1.failures, 1)
        XCTAssertEqual(waiting.first?.1.firstFailure?.timeIntervalSince1970 ?? 0, now.timeIntervalSince1970, accuracy: 0.01)
    }

    /// A part put off says why, and the soonest of them is when a pass wakes; a fingerprint taken clears the reason.
    func testWhatWaitsSaysWhyAndWhen() throws {
        try store.upsertPhotos([photo("one"), photo("two")])
        try store.setParts("one", [part("one")], account: account)
        try store.setParts("two", [part("two")], account: account)
        try store.ensureBackupRows(account: account)
        let now = Date()
        try store.postpone("one", .original, until: now.addingTimeInterval(600), reason: "Only in iCloud, waiting for Wi-Fi to download it")
        try store.postpone("two", .original, until: now.addingTimeInterval(30), reason: "Immich didn't take it this time (bad gateway)")
        XCTAssertEqual(try store.nextRetry(account: account, now: now)?.timeIntervalSince(now) ?? 0, 30, accuracy: 0.01)
        XCTAssertEqual(try store.parts("one").first?.waitReason, "Only in iCloud, waiting for Wi-Fi to download it")
        XCTAssertNil(try store.nextRetry(account: account, now: now.addingTimeInterval(700)), "nothing put off any longer")
        try store.setFingerprint("one", .original, checksum: "sum", size: 10)
        XCTAssertNil(try store.parts("one").first?.waitReason, "read at last: nothing waits")
        XCTAssertNil(try store.nextRetry(account: "another|account", now: now), "each account's own")
    }

    /// Don't Send on a photo that could not be read: the person's word holds over the failure.
    func testDontSendHoldsOverAFailedRead() throws {
        try store.upsertPhotos([photo("one")])
        try store.setParts("one", [part("one")], account: account)
        try store.ensureBackupRows(account: account)
        try store.setFingerprintFailure("one", .original, reason: "iCloud said no", retryAfter: Date().addingTimeInterval(3600))
        try store.refreshState(account: account, "one")
        XCTAssertEqual(try store.state(account: account, "one"), .needsLook)
        try store.setDecision(account: account, ["one"], .skip)
        XCTAssertEqual(try store.state(account: account, "one"), .skipped)
    }

    /// A fingerprint borrowed from Immich is marked as such, and the mark goes with the fingerprint when the part
    /// changes; a store from before the mark gains its column.
    func testABorrowedFingerprintIsMarked() throws {
        try store.upsertPhotos([photo("one")])
        try store.setParts("one", [part("one")], account: account)
        try store.setFingerprint("one", .original, checksum: "theirs", size: 10, borrowed: true)
        XCTAssertEqual(try store.parts("one").first?.borrowed, true)
        XCTAssertEqual(try store.borrowedCount(), 1)
        try store.setParts("one", [part("one", name: "IMG_0001_2.HEIC")], account: account)
        XCTAssertEqual(try store.parts("one").first?.borrowed, false, "read again, it is the phone's")

        let file = directory.appendingPathComponent("old.sqlite")
        let old = try BackupDatabase(file: file)
        try old.execute("""
        CREATE TABLE part (
            local_id TEXT NOT NULL, role TEXT NOT NULL, name TEXT NOT NULL, uti TEXT, size INTEGER, checksum TEXT,
            adjustment TEXT, failure TEXT, failures INTEGER NOT NULL DEFAULT 0, first_failure REAL, retry_after REAL,
            staged TEXT, PRIMARY KEY (local_id, role));
        INSERT INTO part(local_id, role, name, checksum) VALUES ('kept', 'original', 'IMG_0002.HEIC', 'sum');
        """)
        let upgraded = try BackupStore(file: file)
        XCTAssertEqual(try upgraded.parts("kept").first?.borrowed, false, "the column added, the row kept")
        XCTAssertEqual(try upgraded.meta("schema"), "2")
    }

    // MARK: Free Up Space

    /// A photo backed up whole: its part fingerprinted, found in Immich as `asset`.
    private func backedUp(_ row: BackupPhotoRow, size: Int64 = 1_000) throws {
        try store.upsertPhotos([row])
        try store.setParts(row.localID, [part(row.localID)], account: account)
        try store.setFingerprint(row.localID, .original, checksum: "sum-\(row.localID)", size: size)
        try store.ensureBackupRows(account: account)
        try store.recordChecks(account: account, ["sum-\(row.localID)": (.present, "asset-\(row.localID)")])
        try store.setAnotherForm(account: account, row.localID, assetID: nil)
        try store.refreshState(account: account, row.localID)
    }

    /// What Free Up Space may remove: backed up whole and old enough by the later of taken and added; not a favourite
    /// where those stay; not hidden; a burst only with every frame in Immich.
    func testFreeUpTakesOnlyWhatIsSafeAndOldEnough() throws {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let old = now.timeIntervalSince1970 - 400 * 24 * 3600
        try backedUp(photo("old", created: old), size: 2_000)
        var recent = photo("received", created: old)
        recent.added = now.addingTimeInterval(-10 * 24 * 3600)
        try backedUp(recent)
        var favourite = photo("favourite", created: old)
        favourite.favorite = true
        try backedUp(favourite)
        var video = photo("video", created: old)
        video.kind = 2
        try backedUp(video)
        try store.upsertPhotos([photo("waiting", created: old)])
        try store.setParts("waiting", [part("waiting")], account: account)
        try store.ensureBackupRows(account: account)
        var frame = photo("frame", created: old)
        frame.burst = "burst"
        try backedUp(frame)
        var other = photo("other frame", created: old)
        other.burst = "burst"
        try store.upsertPhotos([other])
        try store.setParts("other frame", [part("other frame")], account: account)
        try store.ensureBackupRows(account: account)

        let cutoff = FreeUpRules.cutoff(months: 6, now: now)
        let all = try store.freeUpCandidates(account: account, cutoff: cutoff, keepFavorites: true)
        XCTAssertEqual(Set(all.map(\.photo.localID)), ["old", "video"],
                       "not one received lately, a favourite, one not backed up, nor a burst with a frame not in Immich")
        XCTAssertEqual(all.first { $0.photo.localID == "old" }?.size, 2_000)
        XCTAssertEqual(all.first { $0.photo.localID == "old" }?.parts.first?.assetID, "asset-old")
        let favouritesToo = try store.freeUpCandidates(account: account, cutoff: cutoff, keepFavorites: false)
        XCTAssertEqual(Set(favouritesToo.map(\.photo.localID)), ["old", "favourite", "video"])
    }

    /// A hidden photo is Free Up Space's only where hidden photos are backed up and not kept.
    func testHiddenPhotosAreFreedOnlyWhereAsked() throws {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        var hidden = photo("hidden", created: now.timeIntervalSince1970 - 400 * 24 * 3600)
        hidden.hidden = true
        try backedUp(hidden)
        let cutoff = FreeUpRules.cutoff(months: 6, now: now)
        XCTAssertTrue(try store.freeUpCandidates(account: account, cutoff: cutoff, keepFavorites: true).isEmpty)
        XCTAssertEqual(try store.freeUpCandidates(account: account, cutoff: cutoff, keepFavorites: true, includeHidden: true)
            .map(\.photo.localID), ["hidden"])
    }

    /// What was freed is watched while Recently Deleted keeps it, said once, and forgotten after 30 days.
    func testFreedPhotosAreWatchedThirtyDays() throws {
        let now = Date()
        try backedUp(photo("one"))
        let candidates = try store.freeUpCandidates(account: account, cutoff: now, keepFavorites: true)
        try store.recordFreed(account: account, candidates, now: now)
        let watched = try store.freedToWatch(account: account, since: now.addingTimeInterval(-30 * 24 * 3600))
        XCTAssertEqual(watched.map(\.checksum), ["sum-one"])
        try store.markFreedAnnounced(account: account, ["sum-one"])
        XCTAssertTrue(try store.freedToWatch(account: account, since: now.addingTimeInterval(-30 * 24 * 3600)).isEmpty, "said once")
        try store.pruneFreed(before: now.addingTimeInterval(1))
        XCTAssertEqual(try store.database.first("SELECT count(*) FROM freed", []) { $0.int(0) }, 0)
    }

    /// The Backup page's facts: what Verso sent, and the screenshots left out while their setting is off.
    func testTheFactsCountWhatVersoSentAndTheScreenshots() throws {
        try store.upsertPhotos([photo("sent"), photo("there"), photo("shot", subtypes: BackupPhotoRow.screenshotSubtype)])
        try store.ensureBackupRows(account: account)
        try store.database.run("UPDATE backup SET uploaded = 1 WHERE local_id = 'sent'", [])
        XCTAssertEqual(try store.sentByVerso(account: account), 1)
        XCTAssertEqual(try store.sentByVerso(account: "another|account"), 0, "each account's own")
        XCTAssertEqual(try store.screenshots(), 1)
    }

    /// Verso Dev's reset forgets everything, so the first run starts from the listing again.
    func testTheResetForgetsEverything() throws {
        try store.upsertPhotos([photo("one")])
        try store.setParts("one", [part("one")], account: account)
        try store.setFingerprint("one", .original, checksum: "sum", size: 10)
        try store.ensureBackupRows(account: account)
        try store.setMeta("firstRunStarted.\(account)", "1")
        _ = try store.beginStep(account: account, "one", role: .original, kind: .upload, checksum: "sum")
        try store.forgetEverything()
        XCTAssertNil(try store.photo("one"))
        XCTAssertEqual(try store.parts("one"), [])
        XCTAssertNil(try store.meta("firstRunStarted.\(account)"))
        XCTAssertEqual(try store.openSteps(), [])
    }

    func testScreenshotsCanBeLeftOut() throws {
        try store.upsertPhotos([photo("shot", subtypes: BackupPhotoRow.screenshotSubtype), photo("photo")])
        try store.setParts("shot", [part("shot")], account: account)
        try store.setParts("photo", [part("photo")], account: account)
        XCTAssertEqual(try store.partsToFingerprint(limit: 10, screenshots: false).map(\.0.localID), ["photo"])
        XCTAssertEqual(try store.partsToFingerprint(limit: 10, screenshots: true).count, 2)
    }

    func testNothingIsPlannedBeforeItsCheckAndALiveStillWaitsForItsVideo() throws {
        try store.upsertPhotos([photo("live", subtypes: BackupPhotoRow.liveSubtype)])
        try store.setParts("live", [part("live"), part("live", .originalPair, name: "IMG_0001.MOV")], account: account)
        try store.setFingerprint("live", .original, checksum: "still", size: 10)
        try store.setFingerprint("live", .originalPair, checksum: "video", size: 20)
        try store.ensureBackupRows(account: account)
        try store.setState(account: account, "live", .toUpload)
        XCTAssertEqual(try store.uploadCandidates(account: account, limit: 10, screenshots: true).count, 0, "nothing unchecked goes")

        try store.recordChecks(account: account, ["still": (.absent, nil), "video": (.absent, nil)])
        try store.setAnotherForm(account: account, "live", assetID: nil)
        XCTAssertEqual(try store.state(account: account, "live"), .toUpload)
        let first = try store.uploadCandidates(account: account, limit: 10, screenshots: true)
        XCTAssertEqual(first.map(\.part.role), [.originalPair], "the video first; the still waits for it")

        let step = try store.beginStep(account: account, "live", role: .originalPair, kind: .upload, checksum: "video", file: "/tmp/body")
        XCTAssertEqual(try store.uploadCandidates(account: account, limit: 10, screenshots: true).count, 0, "not twice while on its way")
        try store.setStepTask(step, task: 42)
        XCTAssertEqual(try store.openSteps().map(\.task), [42])

        try store.recordUploaded(account: account, checksum: "video", assetID: "video-asset", trashed: false)
        XCTAssertTrue(try store.finishStep(step, result: "created", assetID: "video-asset"))
        XCTAssertFalse(try store.finishStep(step, result: "duplicate"), "a step's result is written once")
        let second = try store.uploadCandidates(account: account, limit: 10, screenshots: true)
        XCTAssertEqual(second.map(\.part.role), [.original])
        XCTAssertEqual(second.first?.pairedVideoAssetID, "video-asset", "the still points at its video")
        XCTAssertEqual(try store.bytesToUpload(account: account, screenshots: true), 10)

        try store.recordUploaded(account: account, checksum: "still", assetID: "still-asset", trashed: false)
        try store.refreshState(account: account, "live")
        XCTAssertEqual(try store.state(account: account, "live"), .backedUp)
        XCTAssertEqual(try store.counts(account: account, screenshots: true), [.backedUp: 1])
    }

    func testAPhotoNotInImmichWaitsForTheAnotherFormLook() throws {
        try store.upsertPhotos([photo("one")])
        try store.setParts("one", [part("one")], account: account)
        try store.setFingerprint("one", .original, checksum: "sum", size: 10)
        try store.ensureBackupRows(account: account)
        try store.recordChecks(account: account, ["sum": (.absent, nil)])
        XCTAssertEqual(try store.photosReadyForState(account: account, limit: 10), [], "not before the look")
        XCTAssertEqual(try store.photosToMatch(account: account, limit: 10).map(\.localID), ["one"])
        try store.setAnotherForm(account: account, "one", assetID: "server-asset")
        XCTAssertEqual(try store.state(account: account, "one"), .anotherForm)
        XCTAssertEqual(try store.anotherFormAsset(account: account, "one"), "server-asset")
        try store.setDecision(account: account, ["one"], .skip)
        XCTAssertEqual(try store.state(account: account, "one"), .skipped)
    }

    func testTheWeeklyCheckReadsWhatVersoCountsAsInImmich() throws {
        try store.recordChecks(account: account, ["here": (.present, "a"), "trash": (.trashed, "b"), "never": (.absent, nil)])
        XCTAssertEqual(try store.checksumsToVerify(account: account, after: "", limit: 10), ["here", "trash"])
        try store.recordChecks(account: account, ["here": (.absent, nil), "trash": (.absent, nil)])
        XCTAssertEqual(try store.checksumsToVerify(account: account, after: "", limit: 10), ["here", "trash"],
                       "gone from Immich, still Verso's to account for")
    }
}
