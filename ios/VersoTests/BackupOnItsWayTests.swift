// Logic tests of what is on its way to Immich (ios/Verso/Backup/BackupOnItsWay.swift, the store's On Its Way queries in
// BackupStore.swift) and of where the Library places it (ios/Verso/Grid/TimelinePhoneMerge.swift), with no PhotoKit,
// no server and no views: which photos count as new since backing up was switched on, each tile's mark, the count
// under the Library's title, the photos the store lists for the Library and for On Its Way, the ones that go first,
// those that arrived, and the photos on their way placed among Immich's months by when each was taken.

import XCTest

final class BackupOnItsWayTests: XCTestCase {
    private var directory: URL!
    private var store: BackupStore!
    private let account = "https://immich.example/api|user"
    private let switchedOn = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("BackupOnItsWayTests-\(UUID().uuidString)")
        store = try BackupStore(file: directory.appendingPathComponent("backup.sqlite"))
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: Which photos are new

    func testAPhotoIsNewWhenItCameToThePhoneAfterBackingUpWasSwitchedOn() {
        let before = switchedOn.addingTimeInterval(-60)
        let after = switchedOn.addingTimeInterval(60)
        XCTAssertTrue(BackupOnItsWay.isNew(added: after, created: before, since: switchedOn),
                      "an old photo saved to the phone now is new: it came to the phone after")
        XCTAssertFalse(BackupOnItsWay.isNew(added: before, created: after, since: switchedOn),
                       "what came to the phone before is the first run's backlog")
        XCTAssertTrue(BackupOnItsWay.isNew(added: nil, created: after, since: switchedOn), "without a date added, the date taken")
        XCTAssertFalse(BackupOnItsWay.isNew(added: after, created: after, since: nil), "nothing is new before backing up started")
    }

    func testNewCountsFromSwitchingOnOrElseTheFirstRun() {
        let started = switchedOn.addingTimeInterval(3600)
        XCTAssertEqual(BackupOnItsWay.newSince(switchedOn: switchedOn, firstRunStarted: started), switchedOn)
        XCTAssertEqual(BackupOnItsWay.newSince(switchedOn: nil, firstRunStarted: started), started,
                       "a store kept from before the switch's date was written counts from the first run")
    }

    // MARK: Marks

    private func waiting(_ state: BackupPhotoState = .toUpload, video: Bool = false, uploading: Bool = false) -> BackupWaitingPhoto {
        BackupWaitingPhoto(localID: "one", created: switchedOn, added: switchedOn, isVideo: video, favorite: false,
                           state: state, uploading: uploading)
    }

    func testEachTileShowsWhereItStands() {
        let wifi = BackupConnection()
        XCTAssertEqual(BackupOnItsWay.mark(waiting(), progress: nil, connection: wifi, stopped: false), .waiting)
        XCTAssertEqual(BackupOnItsWay.mark(waiting(uploading: true), progress: 0.4, connection: wifi, stopped: false),
                       .uploading(0.4))
        XCTAssertEqual(BackupOnItsWay.mark(waiting(.needsLook), progress: nil, connection: wifi, stopped: false), .needsLook)
        XCTAssertEqual(BackupOnItsWay.mark(waiting(.unchecked), progress: nil, connection: wifi, stopped: false), .waiting,
                       "a new photo not checked yet waits")
        XCTAssertEqual(BackupOnItsWay.mark(waiting(uploading: true), progress: 0.4, connection: wifi, stopped: true), .needsLook,
                       "a stop waits for the person's answer, for every photo")
    }

    func testTheConnectionKeepsAPhotoBack() {
        let cellular = BackupConnection(onCellular: true, cellularPhotos: true)
        XCTAssertEqual(BackupOnItsWay.mark(waiting(), progress: nil, connection: cellular, stopped: false), .waiting,
                       "photos may use cellular")
        XCTAssertEqual(BackupOnItsWay.mark(waiting(video: true, uploading: true), progress: 0.1, connection: cellular,
                                           stopped: false), .waitingForConnection, "videos wait for Wi-Fi")
        XCTAssertEqual(BackupOnItsWay.mark(waiting(), progress: nil, connection: BackupConnection(constrained: true), stopped: false),
                       .waitingForConnection, "Low Data Mode")
        XCTAssertEqual(BackupOnItsWay.mark(waiting(), progress: nil, connection: BackupConnection(connected: false), stopped: false),
                       .waitingForConnection, "no connection")
    }

    func testTheLineSaysHowManyAreOnTheirWay() {
        XCTAssertEqual(BackupOnItsWay.line(going: 1), "Backing Up 1 Item…")
        XCTAssertEqual(BackupOnItsWay.line(going: 3), "Backing Up 3 Items…")
    }

    func testAGridIDNamesAPhotoOnThePhone() {
        let photo = waiting()
        XCTAssertEqual(BackupWaitingPhoto.localID(gridID: photo.gridID), "one")
        XCTAssertNil(BackupWaitingPhoto.localID(gridID: "8f0c4c4a-asset"), "Immich's asset IDs are not the phone's")
    }

    // MARK: The store's lists

    private func row(_ identifier: String, added: Date, created: Date? = nil, hidden: Bool = false,
                     kind: Int = 1) -> BackupPhotoRow {
        BackupPhotoRow(localID: identifier, cloudID: nil, created: created ?? added, added: added, modified: added, kind: kind,
                       subtypes: 0, favorite: false, hidden: hidden, burst: nil, burstPick: false, latitude: nil,
                       longitude: nil, name: nil)
    }

    /// A photo with one part, its fingerprint checked with Immich: `present` there or not.
    private func checked(_ identifier: String, present: Bool) throws {
        try store.setParts(identifier, [BackupPartRow(localID: identifier, role: .original, name: "\(identifier).HEIC")],
                           account: account)
        try store.setFingerprint(identifier, .original, checksum: "sum-\(identifier)", size: 100)
        try store.recordChecks(account: account, ["sum-\(identifier)": (present ? .present : .absent, present ? "asset-\(identifier)" : nil)])
        try store.setAnotherForm(account: account, identifier, assetID: nil)
    }

    /// The first run's backlog and the photos that came after switching on, in every state the lists tell apart.
    private func library() throws {
        let earlier = switchedOn.addingTimeInterval(-86_400)
        try store.upsertPhotos([
            row("backlog-going", added: earlier), row("backlog-unchecked", added: earlier.addingTimeInterval(10)),
            row("new-unchecked", added: switchedOn.addingTimeInterval(100)),
            row("new-going", added: switchedOn.addingTimeInterval(200), kind: 2),
            row("new-done", added: switchedOn.addingTimeInterval(300)),
            row("new-hidden", added: switchedOn.addingTimeInterval(400), hidden: true),
            row("new-gone", added: switchedOn.addingTimeInterval(500)),
            row("old-saved-now", added: switchedOn.addingTimeInterval(600), created: earlier.addingTimeInterval(-86_400)),
        ])
        try store.ensureBackupRows(account: account)
        try checked("backlog-going", present: false)
        try checked("new-going", present: false)
        try checked("new-done", present: true)
        try store.markGone(["new-gone"])
        try store.markSwitchedOn(account: account, now: switchedOn)
    }

    func testNothingIsOnItsWayBeforeTheFirstRunStarts() throws {
        try library()
        XCTAssertEqual(try store.waitingPhotos(account: account, onlyNew: true, screenshots: true, limit: 50), [])
        XCTAssertEqual(try store.waitingPhotos(account: account, onlyNew: false, screenshots: true, limit: 50), [])
        XCTAssertEqual(try store.newPhotosToSend(account: account, screenshots: true, limit: 20), [])
    }

    func testTheLibraryListsOnlyTheNewPhotosNotInImmich() throws {
        try library()
        try store.setMetaDate("firstRunStarted.\(account)", switchedOn.addingTimeInterval(3600))
        let new = try store.waitingPhotos(account: account, onlyNew: true, screenshots: true, limit: 50)
        XCTAssertEqual(new.map(\.localID), ["new-going", "new-unchecked", "old-saved-now"],
                       "newest first; not the backlog, nor what is in Immich, hidden or gone")
        XCTAssertEqual(new.first?.isVideo, true)
        XCTAssertEqual(new.first?.state, .toUpload)
        let all = try store.waitingPhotos(account: account, onlyNew: false, screenshots: true, limit: 50)
        XCTAssertEqual(all.map(\.localID), ["new-going", "new-unchecked", "backlog-going", "old-saved-now"],
                       "On Its Way: the backlog that goes too, but not its photos not checked yet, which may be in Immich")
        XCTAssertEqual(try store.goingCount(account: account, screenshots: true), 4,
                       "two to upload and two new ones not checked yet")
    }

    /// Hidden photos backed up into the Locked Folder count and go first as new ones do, but the Library and On Its
    /// Way never show them.
    func testHiddenPhotosGoButNeverShow() throws {
        try library()
        try store.setMetaDate("firstRunStarted.\(account)", switchedOn.addingTimeInterval(3600))
        store.hiddenIncluded = true
        XCTAssertEqual(try store.newPhotosToSend(account: account, screenshots: true, limit: 20),
                       ["new-hidden", "new-going", "new-unchecked", "old-saved-now"])
        XCTAssertEqual(try store.goingCount(account: account, screenshots: true), 5, "the hidden one too")
        XCTAssertFalse(try store.waitingPhotos(account: account, onlyNew: false, screenshots: true, limit: 50)
            .contains { $0.localID == "new-hidden" }, "never in the Library or On Its Way")
    }

    func testSwitchingOnAgainKeepsTheFirstDate() throws {
        try store.markSwitchedOn(account: account, now: switchedOn)
        try store.markSwitchedOn(account: account, now: switchedOn.addingTimeInterval(86_400))
        try store.setMetaDate("firstRunStarted.\(account)", switchedOn.addingTimeInterval(7 * 86_400))
        XCTAssertEqual(try store.newSince(account: account), switchedOn)
    }

    func testNewPhotosGoFirstAndAnUploadOnItsWayShows() throws {
        try library()
        try store.setMetaDate("firstRunStarted.\(account)", switchedOn.addingTimeInterval(3600))
        XCTAssertEqual(try store.newPhotosToSend(account: account, screenshots: true, limit: 20),
                       ["new-going", "new-unchecked", "old-saved-now"])
        _ = try store.beginStep(account: account, "new-going", role: .original, kind: .upload, checksum: "sum-new-going")
        XCTAssertEqual(try store.newPhotosToSend(account: account, screenshots: true, limit: 20), ["new-unchecked", "old-saved-now"],
                       "one already on its way is not sent again")
        let uploading = try store.waitingPhotos(account: account, onlyNew: true, screenshots: true, limit: 50)
        XCTAssertEqual(uploading.first { $0.localID == "new-going" }?.uploading, true)
        XCTAssertEqual(try store.openUploads(account: account).map(\.localID), ["new-going"])
    }

    func testAPhotoThatArrivedNamesTheAssetTheTimelineShows() throws {
        try library()
        try store.setMetaDate("firstRunStarted.\(account)", switchedOn.addingTimeInterval(3600))
        let step = try store.beginStep(account: account, "new-going", role: .original, kind: .upload, checksum: "sum-new-going")
        XCTAssertEqual(try store.arrivedAssets(account: account, ["new-going"]), [:], "not there yet")
        let answer = BackupAnswers.record(store: store, step: step, status: 201,
                                          body: Data(#"{"id":"made","status":"created"}"#.utf8), error: nil)
        XCTAssertEqual(answer?.outcome, .uploaded(assetID: "made", created: true))
        XCTAssertEqual(try store.arrivedAssets(account: account, ["new-going", "new-done"]), ["new-going": "made"],
                       "only what Verso uploaded arrived; a photo found in Immich was there already")
        XCTAssertFalse(try store.waitingPhotos(account: account, onlyNew: true, screenshots: true, limit: 50)
            .contains { $0.localID == "new-going" })
    }

    // MARK: Where the Library places them

    private let november = "2026-11-01T00:00:00.000Z"
    private let october = "2026-10-01T00:00:00.000Z"

    private func day(_ number: Int, month: Int = 11) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: 2026, month: month, day: number, hour: 12))!
    }

    private func phone(_ index: Int, _ date: Date) -> TimelinePhoneMerge.Phone {
        TimelinePhoneMerge.Phone(index: index, date: date, month: TimelinePhoneMerge.month(of: date, in: TimeZone(identifier: "UTC")!))
    }

    func testWithoutPhotosOnTheirWayTheMonthsStayAsTheyAre() {
        let months = [TimelinePhoneMerge.ModelMonth(section: 0, id: november, count: 3, dates: nil)]
        let merged = TimelinePhoneMerge.merge(months, phone: [], byDate: true)
        XCTAssertEqual(merged, [TimelinePhoneMerge.Month(section: 0, id: november, count: 3, slots: nil)])
    }

    func testAPhotoOnItsWayGoesAmongTheMonthsPhotosByWhenItWasTaken() {
        // The model's order: newest first.
        let months = [TimelinePhoneMerge.ModelMonth(section: 0, id: november, count: 3, dates: [day(20), day(10), day(5)]),
                      TimelinePhoneMerge.ModelMonth(section: 1, id: october, count: 2, dates: nil)]
        let merged = TimelinePhoneMerge.merge(months, phone: [phone(0, day(12)), phone(1, day(25))], byDate: true)
        XCTAssertEqual(merged[0].slots, [.phone(1), .model(0), .phone(0), .model(1), .model(2)],
                       "where Immich's photo will be once it arrives")
        XCTAssertEqual(merged[0].count, 5)
        XCTAssertNil(merged[1].slots, "a month without any keeps no list")
    }

    func testAMonthNotReadYetHasThemAtItsNewestEnd() {
        let months = [TimelinePhoneMerge.ModelMonth(section: 0, id: november, count: 2, dates: nil)]
        XCTAssertEqual(TimelinePhoneMerge.merge(months, phone: [phone(0, day(1))], byDate: true)[0].slots,
                       [.phone(0), .model(0), .model(1)])
        let read = [TimelinePhoneMerge.ModelMonth(section: 0, id: november, count: 2, dates: [day(20), day(10)])]
        XCTAssertEqual(TimelinePhoneMerge.merge(read, phone: [phone(0, day(1))], byDate: false)[0].slots,
                       [.phone(0), .model(0), .model(1)], "a timeline by date added has them at its newest end")
    }

    func testAMonthImmichHasNothingOfYetIsTheirOwn() {
        let months = [TimelinePhoneMerge.ModelMonth(section: 0, id: october, count: 2, dates: nil)]
        let merged = TimelinePhoneMerge.merge(months, phone: [phone(0, day(2)), phone(1, day(3, month: 9))], byDate: true)
        XCTAssertEqual(merged.map(\.id), ["2026-11-01T00:00:00.000Z", october, "2026-09-01T00:00:00.000Z"],
                       "newest first, each in its place")
        XCTAssertEqual(merged[0].section, nil)
        XCTAssertEqual(merged[0].slots, [.phone(0)])
        XCTAssertEqual(merged[1].slots, nil)
        XCTAssertEqual(merged[2].slots, [.phone(1)])
    }

    func testAPhotosMonthIsItsOwnClocks() {
        let lateOnTheLastDay = day(30).addingTimeInterval(11 * 3600 + 30 * 60) // 23:30 UTC on 30 November
        XCTAssertEqual(TimelinePhoneMerge.month(of: lateOnTheLastDay, in: TimeZone(identifier: "UTC")!), "2026-11")
        XCTAssertEqual(TimelinePhoneMerge.month(of: lateOnTheLastDay, in: TimeZone(identifier: "Europe/Copenhagen")!), "2026-12",
                       "taken after midnight in Copenhagen: December, as Immich files it")
    }
}
