// Logic tests of backing up's rules (ios/Verso/Backup/BackupModel.swift), with no server, no PhotoKit and no store:
// a photo's state from its parts, Not in Immich's groups and the "most of the library gone" stop, the first run's
// tally, the another-form match, the disk budget and recovery's plan.

import XCTest

final class BackupRulesTests: XCTestCase {
    private func part(_ role: BackupPartRole = .original, _ checksum: String? = "a", remote: BackupRemoteState? = nil,
                      sent: Bool = false, seenTrashed: Bool = false, failure: String? = nil) -> BackupPartFacts {
        BackupPartFacts(role: role, checksum: checksum, failure: failure, remote: remote, sent: sent, seenTrashed: seenTrashed)
    }

    // MARK: A photo's state

    func testAPhotoIsBackedUpOnlyWhenEveryPartIsInImmich() {
        let live = BackupPhotoFacts(parts: [part(.original, "still", remote: .present), part(.originalPair, "video", remote: .absent)],
                                    anotherForm: false)
        XCTAssertEqual(BackupRules.state(of: live).state, .toUpload, "a Live Photo without its video is not backed up")
        var both = live
        both.parts[1].remote = .present
        XCTAssertEqual(BackupRules.state(of: both).state, .backedUp)
    }

    /// A part that cannot be read needs the person only after five failures over at least three days: nearly every
    /// such failure passes (an interrupted iCloud download, Verso stopped mid-read).
    func testAFailedReadNeedsALookOnlyOnceItHasLasted() {
        let now = Date()
        let threeDays: TimeInterval = 3 * 24 * 3600
        XCTAssertFalse(BackupRules.readNeedsLook(failures: 1, since: now, now: now), "a first failure is tried again quietly")
        XCTAssertFalse(BackupRules.readNeedsLook(failures: 9, since: now.addingTimeInterval(-3600), now: now), "many, but within hours")
        XCTAssertFalse(BackupRules.readNeedsLook(failures: 4, since: now.addingTimeInterval(-2 * threeDays), now: now), "long, but few")
        XCTAssertTrue(BackupRules.readNeedsLook(failures: 5, since: now.addingTimeInterval(-threeDays), now: now))
    }

    func testDontSendHoldsUnlessThePhotoIsInImmichWhole() {
        var photo = BackupPhotoFacts(parts: [part(failure: "unreadable")])
        photo.decision = .skip
        XCTAssertEqual(BackupRules.state(of: photo).state, .skipped)
        let there = BackupPhotoFacts(parts: [part(remote: .present)], decision: .skip)
        XCTAssertEqual(BackupRules.state(of: there).state, .backedUp, "in Immich whole, it is backed up whatever was said")
    }

    // MARK: Free Up Space

    /// A photo's age runs from the later of when it was taken and when it came to the phone; the reminder comes with
    /// a gigabyte or more, at most once a month.
    func testFreeUpRules() {
        let taken = Date(timeIntervalSince1970: 1_600_000_000)
        let added = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(FreeUpRules.ageStart(created: taken, added: added), added)
        XCTAssertEqual(FreeUpRules.ageStart(created: taken, added: nil), taken)
        XCTAssertNil(FreeUpRules.ageStart(created: nil, added: nil))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let now = Date(timeIntervalSince1970: 1_714_557_600)
        XCTAssertEqual(FreeUpRules.cutoff(months: 6, now: now, calendar: calendar), Date(timeIntervalSince1970: 1_698_832_800))
        XCTAssertEqual(FreeUpRules.month(of: now, calendar: calendar), "2024-05")
        XCTAssertFalse(FreeUpRules.remind(bytes: 500 << 20, lastReminded: nil, now: now), "not worth it")
        XCTAssertTrue(FreeUpRules.remind(bytes: 2 << 30, lastReminded: nil, now: now))
        XCTAssertFalse(FreeUpRules.remind(bytes: 2 << 30, lastReminded: now.addingTimeInterval(-10 * 24 * 3600), now: now), "a month apart")
        XCTAssertTrue(FreeUpRules.remind(bytes: 2 << 30, lastReminded: now.addingTimeInterval(-31 * 24 * 3600), now: now))
    }

    /// The Library's cards: a gigabyte or more to gain; once put aside, the ready card again a month later or with
    /// another gigabyte, the short-of-space card in three months; short of space under 5 GB or a tenth of the phone.
    func testFreeUpCards() {
        let now = Date(timeIntervalSince1970: 1_714_557_600)
        let days: (Double) -> Date = { now.addingTimeInterval(-$0 * 24 * 3600) }
        XCTAssertFalse(FreeUpRules.cardShown(bytes: 500 << 20, putAside: nil, now: now), "not worth it")
        XCTAssertTrue(FreeUpRules.cardShown(bytes: 2 << 30, putAside: nil, now: now))
        XCTAssertFalse(FreeUpRules.cardShown(bytes: 2 << 30, putAside: (days(5), 2 << 30), now: now), "put aside")
        XCTAssertTrue(FreeUpRules.cardShown(bytes: 3 << 30, putAside: (days(5), 2 << 30), now: now), "another gigabyte")
        XCTAssertTrue(FreeUpRules.cardShown(bytes: 2 << 30, putAside: (days(31), 2 << 30), now: now), "a month later")
        XCTAssertTrue(FreeUpRules.lowOnSpace(free: 4_000_000_000, total: 512_000_000_000))
        XCTAssertTrue(FreeUpRules.lowOnSpace(free: 6_000_000_000, total: 64_000_000_000), "under a tenth")
        XCTAssertFalse(FreeUpRules.lowOnSpace(free: 60_000_000_000, total: 256_000_000_000))
        XCTAssertFalse(FreeUpRules.spaceCardShown(bytes: 500 << 20, putAside: nil, now: now))
        XCTAssertTrue(FreeUpRules.spaceCardShown(bytes: 8 << 30, putAside: nil, now: now))
        XCTAssertFalse(FreeUpRules.spaceCardShown(bytes: 8 << 30, putAside: days(60), now: now), "Not Now holds")
        XCTAssertTrue(FreeUpRules.spaceCardShown(bytes: 8 << 30, putAside: days(91), now: now))
    }

    // MARK: Immich's own app's iCloud identifiers

    /// The upload's metadata, as Immich's own app writes it: its key, the identifier, the time to the second with
    /// milliseconds in UTC, and the place; none for an identifier iCloud has not finished.
    func testTheMobileAppMetadataIsWrittenAsImmichsAppWritesIt() throws {
        let taken = Date(timeIntervalSince1970: 1_714_557_600.75)
        let field = try XCTUnwrap(BackupMobileApp.field(cloudID: "GUID:001:HASH", created: taken, latitude: 55.6761, longitude: 12.5683))
        let items = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(field.utf8)) as? [[String: Any]])
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?["key"] as? String, "mobile-app")
        XCTAssertEqual(items.first?["value"] as? [String: String],
                       ["iCloudId": "GUID:001:HASH", "createdAt": "2024-05-01T10:00:00.000Z", "latitude": "55.6761", "longitude": "12.5683"])
        XCTAssertNil(BackupMobileApp.field(cloudID: "GUID:001:", created: taken, latitude: nil, longitude: nil), "an unfinished identifier")
        XCTAssertNil(BackupMobileApp.field(cloudID: nil, created: taken, latitude: nil, longitude: nil))
        let placeless = try XCTUnwrap(BackupMobileApp.field(cloudID: "GUID:001:HASH", created: taken, latitude: nil, longitude: nil))
        XCTAssertFalse(placeless.contains("latitude"), "no place, none written")
    }

    /// A match is all of it: the same identifier, the same second, the same place, and no edit.
    func testAMatchNeedsEveryFieldAndNoEdit() {
        let taken = Date(timeIntervalSince1970: 1_714_557_600)
        let value = ["iCloudId": "GUID:001:HASH", "createdAt": "2024-05-01T10:00:00.000Z", "latitude": "55.6761", "longitude": "12.5683"]
        func matches(_ value: [String: String], _ cloudID: String = "GUID:001:HASH", _ created: Date? = nil,
                     _ latitude: Double? = 55.6761, _ longitude: Double? = 12.5683) -> Bool {
            BackupMobileApp.matches(value, cloudID: cloudID, created: created ?? taken, latitude: latitude, longitude: longitude)
        }
        XCTAssertTrue(matches(value))
        XCTAssertTrue(matches(value, "GUID:001:HASH", taken.addingTimeInterval(0.6)), "the same second")
        XCTAssertFalse(matches(value, "GUID:002:HASH"))
        XCTAssertFalse(matches(value, "GUID:001:HASH", taken.addingTimeInterval(1)))
        XCTAssertFalse(matches(value, "GUID:001:HASH", nil, 55.6762), "another place")
        XCTAssertFalse(matches(value, "GUID:001:HASH", nil, nil, nil), "a place on one side only")
        var edited = value
        edited["adjustmentTime"] = "2024-06-01T10:00:00.000Z"
        XCTAssertFalse(matches(edited), "an edit Immich's app saw: its time is not Verso's to compare")
        let placeless = ["iCloudId": "GUID:001:HASH", "createdAt": "2024-05-01T10:00:00Z"]
        XCTAssertTrue(matches(placeless, "GUID:001:HASH", nil, nil, nil), "no place on either side, and no milliseconds")
    }

    func testNothingIsDecidedBeforeEveryPartIsChecked() {
        XCTAssertEqual(BackupRules.state(of: BackupPhotoFacts(parts: [part(remote: nil)])).state, .unchecked)
        XCTAssertEqual(BackupRules.state(of: BackupPhotoFacts(parts: [part(.original, nil)])).state, .unchecked)
        let edit = BackupPhotoFacts(parts: [part(.original, "a", remote: .present), part(.render, nil)])
        XCTAssertEqual(BackupRules.state(of: edit).state, .unchecked, "an edit's new rendering waits for its fingerprint")
    }

    func testAFailedFingerprintIsAStateWithItsReason() {
        let photo = BackupPhotoFacts(parts: [part(.original, nil, failure: "Its original could not be downloaded from iCloud.")])
        let (state, reason) = BackupRules.state(of: photo)
        XCTAssertEqual(state, .needsLook)
        XCTAssertEqual(reason, "Its original could not be downloaded from iCloud.")
    }

    func testTheFirstRunLooksForAnotherFormBeforeAnythingGoes() {
        var photo = BackupPhotoFacts(parts: [part(remote: .absent)])
        XCTAssertEqual(BackupRules.state(of: photo).state, .unchecked, "not looked at yet: nothing goes")
        photo.anotherForm = true
        XCTAssertEqual(BackupRules.state(of: photo).state, .anotherForm)
        photo.decision = .send
        XCTAssertEqual(BackupRules.state(of: photo).state, .toUpload)
        photo.decision = .skip
        XCTAssertEqual(BackupRules.state(of: photo).state, .skipped)
        photo.decision = nil
        photo.anotherForm = false
        XCTAssertEqual(BackupRules.state(of: photo).state, .toUpload)
    }

    func testAnUploadImmichRefusedNeedsALook() {
        let photo = BackupPhotoFacts(parts: [part(remote: .absent)], anotherForm: false, uploadFailure: "Immich did not take it: unsupported")
        XCTAssertEqual(BackupRules.state(of: photo).state, .needsLook)
    }

    func testANewEditOfABackedUpPhotoGoesWithoutAsking() {
        let photo = BackupPhotoFacts(parts: [part(.original, "a", remote: .present, sent: true), part(.render, "b", remote: .absent)],
                                     previous: .backedUp)
        XCTAssertEqual(BackupRules.state(of: photo).state, .toUpload, "the original is in Immich: the new rendering goes")
    }

    // MARK: Not in Immich

    func testAPhotoGoneWithoutBeingSeenDeletedIsMissing() {
        let photo = BackupPhotoFacts(parts: [part(remote: .absent, sent: true)], previous: .backedUp)
        XCTAssertEqual(BackupRules.state(of: photo).state, .missingFromImmich)
    }

    func testAPhotoSeenInTheTrashThenGoneWasDeletedOnPurpose() {
        let photo = BackupPhotoFacts(parts: [part(remote: .absent, sent: true, seenTrashed: true)], previous: .inImmichTrash)
        XCTAssertEqual(BackupRules.state(of: photo).state, .deletedInImmich)
    }

    func testAPhotoInTheTrashWhenFirstFoundIsLeftThere() {
        let photo = BackupPhotoFacts(parts: [part(remote: .trashed, seenTrashed: true)])
        XCTAssertEqual(BackupRules.state(of: photo).state, .inImmichTrash, "never uploaded again on its own")
        var emptied = photo
        emptied.parts[0].remote = .absent
        emptied.previous = .inImmichTrash
        XCTAssertEqual(BackupRules.state(of: emptied).state, .deletedInImmich, "the trash emptied: deleted on purpose")
    }

    func testThePersonsAnswersOnAMissingPhoto() {
        var photo = BackupPhotoFacts(parts: [part(remote: .absent, sent: true)], previous: .missingFromImmich)
        photo.decision = .letGo
        XCTAssertEqual(BackupRules.state(of: photo).state, .deletedInImmich)
        photo.decision = .sendAgain
        XCTAssertEqual(BackupRules.state(of: photo).state, .toUpload)
        photo.parts[0].remote = .present
        XCTAssertEqual(BackupRules.state(of: photo).state, .backedUp)
    }

    func testAMissingPhotoIsNeverSentAgainOnItsOwn() {
        let photo = BackupPhotoFacts(parts: [part(remote: .absent, sent: true)], previous: .missingFromImmich, anotherForm: false)
        XCTAssertEqual(BackupRules.state(of: photo).state, .missingFromImmich)
    }

    func testTheWeeklyCheckSaysEachMissingPhotoOnce() {
        let photos = [
            "kept": BackupPhotoFacts(parts: [part(remote: .present, sent: true)], previous: .backedUp),
            "lost": BackupPhotoFacts(parts: [part(remote: .absent, sent: true)], previous: .backedUp),
            "said": BackupPhotoFacts(parts: [part(remote: .absent, sent: true)], previous: .backedUp),
            "known": BackupPhotoFacts(parts: [part(remote: .absent, sent: true)], previous: .missingFromImmich),
            "deleted": BackupPhotoFacts(parts: [part(remote: .absent, sent: true, seenTrashed: true)], previous: .inImmichTrash),
        ]
        let verification = BackupRules.verify(photos, announced: ["said"])
        XCTAssertEqual(verification.newlyMissing, ["lost"], "one said before is not said again, nor one already missing")
        XCTAssertEqual(verification.states["deleted"], .deletedInImmich, "quiet")
        XCTAssertEqual(verification.states["kept"], .backedUp)
        XCTAssertFalse(verification.mostGone)
    }

    func testMostOfTheLibraryGoneAtOnceStops() {
        var photos: [String: BackupPhotoFacts] = [:]
        for index in 0..<30 {
            photos["photo\(index)"] = BackupPhotoFacts(parts: [part(remote: index < 20 ? .absent : .present, sent: true)], previous: .backedUp)
        }
        let verification = BackupRules.verify(photos, announced: [])
        XCTAssertTrue(verification.mostGone, "20 of 30 gone at once is the server's problem")
        XCTAssertEqual(verification.goneNow, 20)
        XCTAssertEqual(verification.wereBackedUp, 30)
        var few: [String: BackupPhotoFacts] = [:]
        for index in 0..<10 { few["photo\(index)"] = BackupPhotoFacts(parts: [part(remote: .absent, sent: true)], previous: .backedUp) }
        XCTAssertFalse(BackupRules.verify(few, announced: []).mostGone, "a small library losing a few is not a stop")
    }

    // MARK: The first run

    func testTheTally() {
        let tally = BackupTally(states: [.backedUp: 87, .toUpload: 13, .anotherForm: 4, .unchecked: 6, .inImmichTrash: 2],
                                toUploadBytes: 52_000_000_000)
        XCTAssertEqual(tally.total, 112)
        XCTAssertEqual(tally.checked, 106)
        XCTAssertEqual(tally.alreadyInImmich, 87)
        XCTAssertEqual(tally.toUpload, 13)
        XCTAssertEqual(tally.anotherForm, 4)
        XCTAssertFalse(tally.isComplete)
    }

    func testAnotherFormIsTheSameSecondAndName() {
        let locals = [BackupAnotherForm.Local(identifier: "phone", takenSecond: 1_700_000_000, name: "IMG_0001.HEIC"),
                      BackupAnotherForm.Local(identifier: "alone", takenSecond: 1_700_000_500, name: "IMG_0002.HEIC")]
        let remotes = [BackupAnotherForm.Remote(assetID: "server", takenSecond: 1_700_000_000),
                       BackupAnotherForm.Remote(assetID: "near", takenSecond: 1_700_000_001)]
        XCTAssertEqual(BackupAnotherForm.sameSecond(locals, remotes), ["phone": ["server"]], "to the second")
        XCTAssertTrue(BackupAnotherForm.sameName("IMG_0001.HEIC", "img_0001.jpg"), "an export changes the extension")
        XCTAssertTrue(BackupAnotherForm.sameName("IMG_0001.HEIC", "IMG_0001_edited.jpg"))
        XCTAssertFalse(BackupAnotherForm.sameName("IMG_0001.HEIC", "IMG_0010.HEIC"))
        XCTAssertFalse(BackupAnotherForm.sameName(".HEIC", ".HEIC"), "no name, no match")
        XCTAssertEqual(BackupAnotherForm.second(Date(timeIntervalSince1970: 1_700_000_000.9)), 1_700_000_000)
        let camera = BackupAnotherForm.Local(identifier: "camera", takenSecond: 1_700_000_000, name: "DSC_0001.JPG",
                                             wallClockSecond: 1_700_003_600)
        XCTAssertEqual(BackupAnotherForm.sameSecond([camera], [BackupAnotherForm.Remote(assetID: "utc", takenSecond: 1_700_003_600)]),
                       ["camera": ["utc"]], "a file without a time zone, which Immich reads as UTC")
    }

    // MARK: Sending

    func testTheDiskBudget() {
        let gigabyte: Int64 = 1 << 30
        XCTAssertTrue(BackupDiskBudget.fits(gigabyte, used: 0, free: 100 * gigabyte), "2 GB of 100 GB free")
        XCTAssertFalse(BackupDiskBudget.fits(gigabyte, used: 1_500_000_000, free: 100 * gigabyte),
                       "never more than 2 GB while others are held")
        XCTAssertFalse(BackupDiskBudget.fits(gigabyte, used: 100_000_000, free: 5 * gigabyte),
                       "a tenth of 5 GB is half a gigabyte, while others are held")
        XCTAssertTrue(BackupDiskBudget.fits(gigabyte, used: 0, free: 5 * gigabyte), "alone, beyond a tenth of 5 GB")
        XCTAssertFalse(BackupDiskBudget.fits(100_000_000, used: 0, free: gigabyte), "1 GB always left free")
    }

    /// A long 4K video, larger than the budget: it goes alone, with 1 GB left free, and never with others held.
    func testAFileLargerThanTheBudgetGoesAlone() {
        let gigabyte: Int64 = 1 << 30
        let video = 3 * gigabyte
        XCTAssertTrue(BackupDiskBudget.fits(video, used: 0, free: 100 * gigabyte))
        XCTAssertFalse(BackupDiskBudget.fits(video, used: 1, free: 100 * gigabyte))
        XCTAssertTrue(BackupDiskBudget.goesAlone(video, free: 100 * gigabyte))
        XCTAssertFalse(BackupDiskBudget.goesAlone(gigabyte, free: 100 * gigabyte))
        XCTAssertFalse(BackupDiskBudget.fits(video, used: 0, free: video + gigabyte / 2), "1 GB always left free")
        XCTAssertEqual(BackupDiskBudget.freeNeeded(for: video), 4 * gigabyte)
    }

    func testRecoveryLeavesTasksOnTheirWayAndAsksForTheRest() {
        let started = Date()
        let steps = [
            BackupStep(id: 1, account: "a", localID: "p", role: .original, kind: .upload, checksum: "x", file: nil, task: 7, started: started),
            BackupStep(id: 2, account: "a", localID: "p", role: .originalPair, kind: .upload, checksum: "y", file: nil, task: 8, started: started),
            BackupStep(id: 3, account: "a", localID: "q", role: .original, kind: .upload, checksum: "z", file: nil, task: nil, started: started),
            BackupStep(id: 4, account: "a", localID: "p", role: nil, kind: .stack, checksum: nil, file: nil, task: nil, started: started),
        ]
        let plan = BackupRecovery.plan(steps, tasksOnTheirWay: [7])
        XCTAssertEqual(plan.leave, [1])
        XCTAssertEqual(plan.ask, [2, 3], "a task the session no longer has, and one cut short before its task")
        XCTAssertEqual(plan.redo, [4])
        XCTAssertEqual(BackupRecovery.result(of: BackupCheck(state: .present, assetID: "asset")).result, "duplicate")
        XCTAssertTrue(BackupRecovery.result(of: BackupCheck(state: .trashed, assetID: "asset")).arrived)
        XCTAssertFalse(BackupRecovery.result(of: BackupCheck(state: .absent)).arrived, "absent: it goes again")
        XCTAssertFalse(BackupRecovery.result(of: nil).arrived)
    }
}
