// Logic tests of how an upload's answer is recorded (ios/Verso/Backup/BackupTransport.swift, BackupAnswers), on a fresh
// store: created and duplicate both put the part in Immich, a duplicate being the photo's own earlier upload whose
// answer was lost; a step's result is written once, but for a created answer after recovery closed its step; a full
// server stops backing up and is said once, as does a sign-in Immich does not let upload; a refusal needs a look, also a
// file too large for the server; anything else is tried again later, and five such in a row pause backing up until an
// upload lands; an upload that arrived otherwise than it was sent needs a look.

import XCTest

final class BackupAnswersTests: XCTestCase {
    private var directory: URL!
    private var store: BackupStore!
    private let account = "https://immich.example/api|user"

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("BackupAnswersTests-\(UUID().uuidString)")
        store = try BackupStore(file: directory.appendingPathComponent("backup.sqlite"))
        try store.upsertPhotos([BackupPhotoRow(localID: "one", cloudID: nil, created: Date(), added: nil, modified: Date(),
                                               kind: 1, subtypes: 0, favorite: false, hidden: false, burst: nil,
                                               burstPick: false, latitude: nil, longitude: nil, name: nil)])
        try store.setParts("one", [BackupPartRow(localID: "one", role: .original, name: "IMG_0001.HEIC")], account: account)
        try store.setFingerprint("one", .original, checksum: "sum", size: 10)
        try store.ensureBackupRows(account: account)
        try store.recordChecks(account: account, ["sum": (.absent, nil)])
        try store.setAnotherForm(account: account, "one", assetID: nil)
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private func step(file: URL? = nil) throws -> Int64 {
        try store.beginStep(account: account, "one", role: .original, kind: .upload, checksum: "sum", file: file?.path)
    }

    private func body(_ text: String) -> Data { Data(text.utf8) }

    func testCreatedPutsThePartInImmichAndRemovesTheBody() throws {
        let file = directory.appendingPathComponent("body")
        try Data("body".utf8).write(to: file)
        let id = try step(file: file)
        let answer = BackupAnswers.record(store: store, step: id, status: 201, body: body(#"{"id":"asset","status":"created"}"#), error: nil)
        XCTAssertEqual(answer?.outcome, .uploaded(assetID: "asset", created: true))
        XCTAssertEqual(try store.state(account: account, "one"), .backedUp)
        XCTAssertEqual(try store.remoteAssetID(account: account, checksum: "sum"), "asset")
        XCTAssertTrue(try store.uploadedByVerso(account: account, "one"))
        XCTAssertEqual(try store.assetsMade(account: account, "one"), ["asset"], "Verso made it: its date and place may be set")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "the body goes once its answer is recorded")
        XCTAssertNil(BackupAnswers.record(store: store, step: id, status: 200, body: body(#"{"id":"asset","status":"duplicate"}"#), error: nil),
                     "a step's answer is recorded once")
    }

    func testADuplicateAnswerCountsAsBackedUp() throws {
        let id = try step()
        let answer = BackupAnswers.record(store: store, step: id, status: 200, body: body(#"{"id":"earlier","status":"duplicate"}"#), error: nil)
        XCTAssertEqual(answer?.outcome, .uploaded(assetID: "earlier", created: false))
        XCTAssertEqual(try store.state(account: account, "one"), .backedUp)
        XCTAssertFalse(try store.uploadedByVerso(account: account, "one"), "nothing new was made")
        XCTAssertEqual(try store.assetsMade(account: account, "one"), [], "Immich had it: its date and place are left as they are")
    }

    /// Recovery asked Immich by the fingerprint before the upload's own answer came, and closed the step as a duplicate:
    /// the created answer after it makes the upload Verso's, so the photo is finished (stacked, dated) as one it made.
    func testACreatedAnswerAfterRecoveryMakesItVersosUpload() throws {
        let id = try step()
        try store.recordUploaded(account: account, checksum: "sum", assetID: "asset", trashed: false)
        XCTAssertTrue(try store.finishStep(id, result: "duplicate", assetID: "asset"), "recovery closes it first")
        try store.refreshState(account: account, "one")
        XCTAssertFalse(try store.uploadedByVerso(account: account, "one"))

        let created = body(#"{"id":"asset","status":"created"}"#)
        let answer = BackupAnswers.record(store: store, step: id, status: 201, body: created, error: nil)
        XCTAssertEqual(answer?.outcome, .uploaded(assetID: "asset", created: true))
        XCTAssertTrue(try store.uploadedByVerso(account: account, "one"))
        XCTAssertEqual(try store.assetsMade(account: account, "one"), ["asset"])
        XCTAssertEqual(try store.photosToFinish(account: account, limit: 10), ["one"], "its stack and metadata are done")
        XCTAssertNil(BackupAnswers.record(store: store, step: id, status: 201, body: created, error: nil), "said once")
    }

    func testADuplicateAnswerAfterRecoveryChangesNothing() throws {
        let id = try step()
        XCTAssertTrue(try store.finishStep(id, result: "duplicate", assetID: "earlier"))
        XCTAssertNil(BackupAnswers.record(store: store, step: id, status: 200, body: body(#"{"id":"earlier","status":"duplicate"}"#), error: nil))
        XCTAssertEqual(try store.assetsMade(account: account, "one"), [], "Immich had it: its date and place are left as they are")
    }

    /// A 403: both the upload and the duplicate check need the key's asset.upload, so it comes when that was taken away
    /// after the check, or from a proxy. Backing up stops once with the reason, rather than refusing every photo.
    func testNotAllowedStopsOnceWithImmichsReason() throws {
        let before = try store.state(account: account, "one")
        let refusal = body(#"{"message":"Missing required permission: asset.upload","error":"Forbidden","statusCode":403}"#)
        let first = BackupAnswers.record(store: store, step: try step(), status: 403, body: refusal, error: nil)
        XCTAssertEqual(first?.outcome, .notAllowed("Missing required permission: asset.upload"))
        XCTAssertEqual(try store.meta("stop.\(account)"), "notAllowed")
        XCTAssertEqual(try store.meta("stopReason.\(account)"), "Missing required permission: asset.upload")
        XCTAssertEqual(try store.state(account: account, "one"), before, "the photo is not refused: it goes once allowed")
        XCTAssertNil(BackupAnswers.record(store: store, step: try step(), status: 403, body: refusal, error: nil),
                     "the other uploads' same answer adds nothing")
    }

    /// Too large for the server or a proxy in front of it (nginx's limit, Cloudflare's 100 MB): this file needs a look,
    /// and the others go on, rather than a full server stopping everything for a day.
    func testTooLargeIsThisFilesRefusalNotAFullServer() throws {
        let answer = BackupAnswers.record(store: store, step: try step(), status: 413,
                                          body: body("<html>413 Request Entity Too Large</html>"), error: nil)
        if case .refused = answer?.outcome {} else { XCTFail("this file's refusal, not \(String(describing: answer?.outcome))") }
        XCTAssertNil(try store.meta("stop.\(account)"), "backing up goes on")
        XCTAssertEqual(try store.state(account: account, "one"), .needsLook)
        XCTAssertEqual(BackupAnswers.outcome(status: 507, body: Data(), error: nil), .serverFull, "a full disk is still one")
    }

    func testAFullServerStopsAndIsSaidOnce() throws {
        let first = BackupAnswers.record(store: store, step: try step(), status: 400,
                                         body: body(#"{"message":"Quota has been exceeded!"}"#), error: nil)
        XCTAssertEqual(first?.outcome, .serverFull)
        XCTAssertEqual(try store.meta("stop.\(account)"), "full")
        XCTAssertNil(BackupAnswers.record(store: store, step: try step(), status: 507, body: Data(), error: nil),
                     "the other uploads' same answer adds nothing")
        try store.setMeta("stop.\(account)", nil)
        XCTAssertNil(BackupAnswers.record(store: store, step: try step(), status: 507, body: Data(), error: nil),
                     "still full when tried again the next day: not said again")
    }

    func testARefusalNeedsALookAndAFailureIsTriedLater() throws {
        let refused = BackupAnswers.record(store: store, step: try step(), status: 400,
                                           body: body(#"{"message":"Unsupported file type"}"#), error: nil)
        XCTAssertEqual(refused?.outcome, .refused("Unsupported file type"))
        XCTAssertEqual(try store.state(account: account, "one"), .needsLook)
        XCTAssertEqual(try store.reason(account: account, "one"), "Immich did not take it: Unsupported file type")

        try store.clearFailures(account: account, ["one"])
        try store.refreshState(account: account, "one")
        let now = Date()
        let later = BackupAnswers.record(store: store, step: try step(), status: nil, body: Data(),
                                         error: URLError(.networkConnectionLost), now: now)
        if case .retryLater = later?.outcome {} else { XCTFail("tried again later") }
        XCTAssertEqual(try store.uploadCandidates(account: account, limit: 10, screenshots: true, now: now).count, 0)
        XCTAssertEqual(try store.uploadCandidates(account: account, limit: 10, screenshots: true,
                                                  now: now.addingTimeInterval(24 * 3600)).count, 1)
    }

    /// Immich down or out of reach: five failures in a row with none landing between pause backing up, for 15 minutes
    /// the first time, doubling; uploads then go a few at a time, and one landing ends it.
    func testAnOutagePausesUntilAnUploadLands() throws {
        let now = Date()
        var outcomes: [BackupAnswer.Outcome] = []
        for _ in 0..<BackupOutage.streak {
            outcomes.append(BackupAnswers.record(store: store, step: try step(), status: 502, body: Data(), error: nil, now: now)?.outcome ?? .cancelled)
        }
        XCTAssertEqual(outcomes, Array(repeating: .retryLater("bad gateway"), count: 4) + [.paused("bad gateway")])
        XCTAssertEqual(try store.meta("stop.\(account)"), "unreachable")
        XCTAssertEqual(try store.meta("stopReason.\(account)"), "bad gateway")
        XCTAssertEqual(try BackupOutage.pausedUntil(store: store, account: account)?.timeIntervalSince(now) ?? 0, 15 * 60, accuracy: 0.01)
        XCTAssertTrue(try BackupOutage.probing(store: store, account: account))
        XCTAssertEqual(BackupAnswers.record(store: store, step: try step(), status: 502, body: Data(), error: nil, now: now)?.outcome,
                       .retryLater("bad gateway"), "no new pause while one lasts")

        // Over (its time up, the network changed, Try Now): the next failure pauses at once, for twice as long.
        try BackupOutage.lift(store: store, account: account)
        let later = now.addingTimeInterval(20 * 60)
        XCTAssertEqual(BackupAnswers.record(store: store, step: try step(), status: 502, body: Data(), error: nil, now: later)?.outcome,
                       .paused("bad gateway"))
        XCTAssertEqual(try BackupOutage.pausedUntil(store: store, account: account)?.timeIntervalSince(later) ?? 0, 30 * 60, accuracy: 0.01)
        XCTAssertEqual(BackupOutage.pause(5), 4 * 3600)
        XCTAssertEqual(BackupOutage.pause(9), 4 * 3600, "at most 4 hours")

        _ = BackupAnswers.record(store: store, step: try step(), status: 201, body: body(#"{"id":"asset","status":"created"}"#), error: nil)
        XCTAssertNil(try store.meta("stop.\(account)"), "an upload landing ends it")
        XCTAssertNil(try store.meta("stopReason.\(account)"))
        XCTAssertFalse(try BackupOutage.probing(store: store, account: account))
    }

    /// Another stop comes first: a full server is not taken for an outage.
    func testAnOutageLeavesAnotherStopAsItIs() throws {
        try store.setMeta("stop.\(account)", "full")
        for _ in 0..<BackupOutage.streak {
            _ = BackupAnswers.record(store: store, step: try step(), status: 503, body: Data(), error: nil)
        }
        XCTAssertEqual(try store.meta("stop.\(account)"), "full")
    }

    /// Immich holds no asset under the fingerprint after Verso's upload made one: the bytes it took differ. The part no
    /// longer counts as sent, and the photo needs a look rather than going again on its own, once per Retry.
    func testAnUploadThatArrivedOtherwiseNeedsALook() throws {
        _ = BackupAnswers.record(store: store, step: try step(), status: 201, body: body(#"{"id":"asset","status":"created"}"#), error: nil)
        XCTAssertEqual(try store.state(account: account, "one"), .backedUp)
        try store.recordNotAsSent(account: account, "one", checksums: ["sum"], reason: "It arrived otherwise")
        XCTAssertEqual(try store.state(account: account, "one"), .needsLook)
        XCTAssertEqual(try store.reason(account: account, "one"), "It arrived otherwise")
        XCTAssertNil(try store.remoteAssetID(account: account, checksum: "sum"))
        XCTAssertEqual(try store.uploadCandidates(account: account, limit: 10, screenshots: true).count, 0, "not again on its own")
        XCTAssertEqual(try store.photosToFinish(account: account, limit: 10), [], "nor finished")

        try store.clearFailures(account: account, ["one"])
        try store.refreshState(account: account, "one")
        XCTAssertEqual(try store.state(account: account, "one"), .toUpload, "Retry sends it again")
    }

    /// One failure is most often a moment's: the first retry comes in half a minute, then 2 minutes, then 5 doubling.
    func testRetriesStartSoonAndGrow() {
        XCTAssertEqual(BackupBackoff.delay(attempt: 1), 30)
        XCTAssertEqual(BackupBackoff.delay(attempt: 2), 120)
        XCTAssertEqual(BackupBackoff.delay(attempt: 3), 300)
        XCTAssertEqual(BackupBackoff.delay(attempt: 4), 600)
        XCTAssertEqual(BackupBackoff.delay(attempt: 40), 24 * 3600, "at most a day")
    }

    /// A 502 from a proxy: the part is put off for half a minute, saying why.
    func testAFailedUploadSaysWhyItWaits() throws {
        let now = Date()
        _ = BackupAnswers.record(store: store, step: try step(), status: 502, body: Data(), error: nil, now: now)
        let part = try XCTUnwrap(try store.parts("one").first)
        XCTAssertEqual(part.retryAfter?.timeIntervalSince(now) ?? 0, 30, accuracy: 0.01)
        XCTAssertEqual(part.waitReason, "Immich didn't take it this time (bad gateway)")
    }

    func testOutcomes() {
        XCTAssertEqual(BackupAnswers.outcome(status: 401, body: Data(), error: nil), .unauthorized)
        XCTAssertEqual(BackupAnswers.outcome(status: 403, body: Data(), error: nil), .notAllowed("forbidden"))
        XCTAssertEqual(BackupAnswers.outcome(status: 503, body: Data(), error: nil), .retryLater("service unavailable"))
        XCTAssertEqual(BackupAnswers.outcome(status: nil, body: Data(), error: URLError(.cancelled)), .cancelled)
        XCTAssertEqual(BackupAnswers.outcome(status: 200, body: Data("{}".utf8), error: nil), .retryLater("an answer without an asset"))
    }
}
