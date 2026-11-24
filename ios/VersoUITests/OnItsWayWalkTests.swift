// A walk through a new photo on its way to Immich against a lab server (never Immich's demo, which may not be written
// to), keeping a screenshot of each place. The server's address and an API key reach it only through the test run's
// environment, as in BackupWalkTests, whose first run must have started backing up for the walk's account before:
//   tools/mac.sh <name> walk BackupWalkTests/testFirstRun <env file> <key variable>
//   tools/mac.sh <name> walk OnItsWayWalkTests/testNewPhotoOnItsWay <env file> <key variable>
//   tools/mac.sh <name> walk OnItsWayWalkTests/testNewestAtTheTop <env file> <key variable>
//   tools/mac.sh <name> walk OnItsWayWalkTests/testNewPhotosGoAtOnce <env file> <key variable>
//   tools/mac.sh <name> walk OnItsWayWalkTests/testSelecting <env file> <key variable>
// Verso Dev launches holding its uploads for a while (VERSO_BACKUP_HOLD), so the photos on their way can be seen before
// they arrive. While it is open, the walk puts a CC0 photo with today's date into the Simulator's library through
// PhotoKit, from its own bundle (Fixtures/OnItsWayWalk.jpg: "Cryptocoryne walkeri" by Hannob, CC0, the lab's fixture
// 010, made smaller): the Library shows it at once with its mark, On Its Way on the Backup page has it, it opens from
// the phone and its share sheet comes up (and is cancelled), and once its upload lands Immich's photo is in its place.
// The second walk does it with Newest at the Top, favourites one photo and deletes another from the phone (iOS asks),
// and puts Newest at the Bottom back. The third holds nothing and times how long a new photo takes to be in Immich:
// one taken while Verso was in the background, from when it comes to the foreground, and one taken while it is open.
// The fourth selects a photo on its way with one of Immich's: Favorite favourites Immich's and leaves the other out
// with a word, and Share takes both.
// Each removes the photos it put in the library, switches backing up off and signs Verso Dev out, also when a step
// fails (a teardown block), so the shared Simulator keeps none of it; testRemoveLeftWalkPhotos removes any a run cut
// short by other means left behind (the walk's photo, taken today, by its size and name).

import ImageIO
import Photos
import UniformTypeIdentifiers
import XCTest

final class OnItsWayWalkTests: XCTestCase {
    /// How long Verso Dev holds its uploads after launching, in seconds.
    private let hold = 110.0
    /// The photos the walk put into the library, by their local identifiers.
    private var added: [String] = []
    /// The walk chose Newest at the Top and has not put Newest at the Bottom back yet.
    private var newestAtTheTop = false

    @MainActor
    func testNewPhotoOnItsWay() throws {
        let application = try launchSignedIn()
        switchOn(application)
        try addPhoto(application)
        let tile = phoneTile(application)
        XCTAssertTrue(tile.waitForExistence(timeout: 30), "the new photo shows in the Library at once")
        settle()
        keep("02 The new photo in the Library", application)

        let line = application.buttons["Backup Line"].firstMatch
        XCTAssertTrue(line.waitForExistence(timeout: 10), "the line under the title says it is on its way")
        keep("03 The line: \(line.label)", application)
        // From the account's sheet: once the grid scrolls, a tap on the line under the title is the navigation bar's,
        // which scrolls the grid instead.
        openBackupPage(application)
        let waiting = application.descendants(matching: .any).matching(identifier: "On Its Way Tile").firstMatch
        XCTAssertTrue(waiting.waitForExistence(timeout: 15), "On Its Way has it")
        keep("04 On Its Way", application)

        waiting.tap()
        settle()
        XCTAssertTrue(application.descendants(matching: .any)["Phone Photo"].firstMatch.waitForExistence(timeout: 10),
                      "it opens from the phone")
        keep("05 Opened from the phone", application)
        application.buttons["Share"].firstMatch.tap()
        XCTAssertTrue(waitForShareSheet(application), "the share sheet comes up with the phone's copy")
        settle()
        keep("06 Share sheet", application)
        closeShareSheet(application)
        settle()
        keep("07 Share sheet cancelled", application)
        application.buttons["Back"].firstMatch.tap()
        settle()
        let back = application.navigationBars.buttons.element(boundBy: 0)
        if back.exists { back.tap(); settle() }
        closeSheet(application)
        application.tabBars.buttons["Library"].firstMatch.tap()
        settle()
        keep("08 The Library while it waits", application)

        XCTAssertTrue(waitUntilGone(tile, timeout: hold + 120), "its upload lands and Immich's photo takes its place")
        settle()
        keep("09 Arrived: Immich's photo in its place", application)
    }

    @MainActor
    func testNewPhotosGoAtOnce() throws {
        let application = try launchSignedIn(holding: false)
        switchOn(application)
        let tile = phoneTile(application)

        // Away long enough for iOS to suspend Verso; the photo goes as it comes forward. The times are compared with
        // when Immich got each photo, through its API, after the walk.
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 30)
        try addPhoto(application)
        Thread.sleep(forTimeInterval: 10)
        application.activate()
        let cameForward = Self.clock.string(from: Date())
        Thread.sleep(forTimeInterval: 1)
        keep("02 Came forward at \(cameForward)", application)
        XCTAssertTrue(waitUntilGone(tile, timeout: 60), "a photo taken while Verso was away goes as it comes forward")
        settle()
        keep("03 The photo taken away is in Immich", application)

        try addPhoto(application)
        let taken = Self.clock.string(from: Date())
        keep("04 Taken while open at \(taken)", application)
        XCTAssertTrue(waitUntilGone(tile, timeout: 60), "a photo taken while Verso is open goes at once")
        settle()
        keep("05 The photo taken while open is in Immich", application)
    }

    /// A time in UTC to the millisecond, as Immich's API gives it.
    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    @MainActor
    func testSelecting() throws {
        let application = try launchSignedIn()
        switchOn(application)
        try addPhoto(application)
        let tile = phoneTile(application)
        XCTAssertTrue(tile.waitForExistence(timeout: 30), "the new photo shows in the Library at once")
        application.buttons["Select"].firstMatch.tap()
        settle()
        // The photo on its way, by its top (the selection's bar covers the grid's foot), and Immich's photo above it.
        tile.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)).tap()
        tile.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: -0.5)).tap()
        settle()
        keep("02 Selected: \(application.navigationBars.firstMatch.identifier)", application)
        application.buttons["Favorite"].firstMatch.tap()
        let notice = application.descendants(matching: .any)["Grid Notice"].firstMatch
        XCTAssertTrue(notice.waitForExistence(timeout: 5), "Favorite leaves the photo on its way out, and says so")
        keep("03 Favorite: \(notice.label)", application)
        settle()
        application.buttons["Share"].firstMatch.tap()
        XCTAssertTrue(waitForShareSheet(application), "Share takes both")
        settle()
        keep("04 Sharing both", application)
        closeShareSheet(application)
        settle()
        if application.buttons["Cancel"].firstMatch.exists { application.buttons["Cancel"].firstMatch.tap() }
        settle()
        keep("05 Done selecting", application)
        XCTAssertTrue(waitUntilGone(tile, timeout: hold + 120), "it arrives")
        settle()
        keep("06 Arrived", application)
    }

    @MainActor
    func testNewestAtTheTop() throws {
        let application = try launchSignedIn()
        switchOn(application)
        chooseNewestEnd(application, "Newest at the Top")
        keep("02 Newest at the Top", application)
        try addPhoto(application)
        try addPhoto(application)
        let tiles = application.descendants(matching: .any).matching(identifier: "Phone Tile")
        let deadline = Date().addingTimeInterval(30)
        while tiles.count < 2 && Date() < deadline { Thread.sleep(forTimeInterval: 1) }
        XCTAssertEqual(tiles.count, 2, "both new photos show at the top")
        settle()
        keep("03 Two new photos at the top", application)

        tiles.firstMatch.tap()
        settle()
        keep("04 Opened from the Library", application)
        application.buttons["Favorite"].firstMatch.tap()
        settle()
        keep("05 Favorite tapped", application)
        tapSystemAlert(["Modify", "Allow"], timeout: 3)
        settle()
        keep("06 Favorite", application)
        application.swipeLeft()
        settle()
        keep("07 The other photo", application)
        application.buttons["Delete"].firstMatch.tap()
        settle()
        keep("08 iOS asks", application)
        XCTAssertTrue(tapSystemAlert(["Delete"], timeout: 10), "iOS asks before the photo is deleted from the phone")
        settle()
        keep("09 Deleted from the phone", application)
        if application.buttons["Back"].firstMatch.exists { application.buttons["Back"].firstMatch.tap() }
        settle()
        keep("10 The Library with one on its way", application)
        XCTAssertEqual(tiles.count, 1, "the deleted photo is gone from the Library and never uploads")

        XCTAssertTrue(waitUntilGone(tiles.firstMatch, timeout: hold + 120), "the other one arrives in its place")
        settle()
        keep("11 Arrived at the top", application)
        chooseNewestEnd(application, "Newest at the Bottom")
        keep("12 Newest at the Bottom again", application)
    }

    /// Removes the walk's photos a run cut short left in the Simulator's library: taken today, the walk's size, under
    /// the walk's names.
    @MainActor
    func testRemoveLeftWalkPhotos() throws {
        try allowPhotos()
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "creationDate >= %@", Calendar.current.startOfDay(for: Date()) as NSDate)
        let today = PHAsset.fetchAssets(with: .image, options: options)
        var left: [String] = []
        today.enumerateObjects { asset, _, _ in
            let name = PHAssetResource.assetResources(for: asset).first?.originalFilename ?? ""
            if asset.pixelWidth == 768, asset.pixelHeight == 1024,
               name.range(of: #"^IMG_\d{4}\.JPG$"#, options: .regularExpression) != nil {
                left.append(asset.localIdentifier)
            }
        }
        added = left
        removeAdded()
        let attachment = XCTAttachment(string: "removed \(left.count) of the walk's photos left in the library")
        attachment.name = "Removed \(left.count)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: Steps

    /// Verso Dev signed in to the lab server from the run's environment, holding its uploads for a while.
    @MainActor
    private func launchSignedIn(holding: Bool = true) throws -> XCUIApplication {
        let environment = ProcessInfo.processInfo.environment
        guard let server = environment["IMMICH_URL"], let key = environment["IMMICH_API_KEY"] else {
            throw XCTSkip("needs a lab server: tools/mac.sh <name> walk OnItsWayWalkTests <env file> <key variable>")
        }
        XCTAssertFalse(server.contains("demo.immich.app"), "never Immich's demo")
        let application = XCUIApplication()
        application.launchEnvironment = ["VERSO_SIGN_IN_SERVER": server, "VERSO_SIGN_IN_API_KEY": key]
        if holding { application.launchEnvironment["VERSO_BACKUP_HOLD"] = String(Int(hold)) }
        application.launch()
        // Run however the walk ends, a failed step included.
        addTeardownBlock { @MainActor in self.finish(application) }
        XCTAssertTrue(application.buttons["Select"].waitForExistence(timeout: 60), "the Library shows once signed in")
        settle()
        keep("01 Library", application)
        return application
    }

    /// Backing up switched on on the Backup page, from the account's sheet, then back to the Library.
    @MainActor
    private func switchOn(_ application: XCUIApplication) {
        openBackupPage(application)
        let turnOn = application.buttons["Turn On Backup"].firstMatch
        if turnOn.waitForExistence(timeout: 5) {
            turnOn.tap()
            tapSystemAlert(["Allow"], timeout: 3)
            settle()
        }
        let deadline = Date().addingTimeInterval(10)
        while turnOn.exists && Date() < deadline { Thread.sleep(forTimeInterval: 0.5) }
        XCTAssertFalse(turnOn.exists, "backing up is on")
        let back = application.navigationBars.buttons.element(boundBy: 0)
        if back.exists { back.tap(); settle() }
        closeSheet(application)
        application.tabBars.buttons["Library"].firstMatch.tap()
        settle()
    }

    /// Puts the walk's CC0 photo into the Simulator's library through PhotoKit, taken now, as a photo just taken.
    @MainActor
    private func addPhoto(_ application: XCUIApplication) throws {
        try allowPhotos()
        let data = try Self.photoTakenNow()
        let done = expectation(description: "added")
        let made = Made()
        Self.create(data) { identifier in
            made.identifier = identifier
            done.fulfill()
        }
        wait(for: [done], timeout: 20)
        added.append(try XCTUnwrap(made.identifier, "the photo was added"))
    }

    /// What PhotoKit made, told from its own queue.
    private final class Made: @unchecked Sendable {
        var identifier: String?
    }

    /// PhotoKit's change blocks and answers run on its own queues, away from the main actor.
    private nonisolated static func create(_ data: Data, done: @escaping @Sendable (String?) -> Void) {
        let made = Made()
        PHPhotoLibrary.shared().performChanges {
            let options = PHAssetResourceCreationOptions()
            options.originalFilename = "IMG_\(Int.random(in: 1000...9999)).JPG"
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .photo, data: data, options: options)
            request.creationDate = Date()
            made.identifier = request.placeholderForCreatedAsset?.localIdentifier
        } completionHandler: { _, _ in
            done(made.identifier)
        }
    }

    private nonisolated static func delete(_ identifiers: [String], done: @escaping @Sendable () -> Void) {
        PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil))
        } completionHandler: { _, _ in
            done()
        }
    }

    private nonisolated static func requestAccess(done: @escaping @Sendable () -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { _ in done() }
    }

    /// The walk's photo with today's date and time in its metadata, in this time zone, as the camera writes it.
    private static func photoTakenNow() throws -> Data {
        let url = try XCTUnwrap(Bundle(for: OnItsWayWalkTests.self).url(forResource: "OnItsWayWalk", withExtension: "jpg"))
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        let now = Date()
        let stamp = formatter.string(from: now)
        let seconds = TimeZone.current.secondsFromGMT(for: now)
        let offset = String(format: "%@%02d:%02d", seconds < 0 ? "-" : "+", abs(seconds) / 3600, abs(seconds) % 3600 / 60)
        let exif: [CFString: Any] = [kCGImagePropertyExifDateTimeOriginal: stamp, kCGImagePropertyExifDateTimeDigitized: stamp,
                                     kCGImagePropertyExifOffsetTimeOriginal: offset, kCGImagePropertyExifOffsetTime: offset]
        let properties: [CFString: Any] = [kCGImagePropertyExifDictionary: exif,
                                           kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFDateTime: stamp],
                                           kCGImageDestinationLossyCompressionQuality: 0.88]
        CGImageDestinationAddImageFromSource(destination, source, 0, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return output as Data
    }

    /// The walk's own access to the photo library, to add its photos and remove them after.
    @MainActor
    private func allowPhotos() throws {
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) != .authorized else { return }
        let asked = expectation(description: "asked")
        Self.requestAccess { asked.fulfill() }
        tapSystemAlert(["Allow Full Access", "Allow Access to All Photos", "Allow"], timeout: 10)
        tapSystemAlert(["Allow Full Access"], timeout: 3)
        wait(for: [asked], timeout: 20)
        XCTAssertEqual(PHPhotoLibrary.authorizationStatus(for: .readWrite), .authorized, "the walk may add and remove photos")
    }

    /// Removes the photos the walk put into the library that are still there.
    @MainActor
    private func removeAdded() {
        let identifiers = added
        guard PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil).count > 0 else { return }
        let done = expectation(description: "removed")
        Self.delete(identifiers) { done.fulfill() }
        tapSystemAlert(["Delete"], timeout: 10)
        wait(for: [done], timeout: 20)
        added = []
    }

    /// The Backup page, from the account's sheet in Collections.
    @MainActor
    private func openBackupPage(_ application: XCUIApplication) {
        application.tabBars.buttons["Collections"].firstMatch.tap()
        settle()
        application.buttons["Account"].firstMatch.tap()
        settle()
        let page = application.buttons["Backup Page"].firstMatch
        var tries = 0
        while !(page.exists && page.isHittable) && tries < 8 {
            application.swipeUp()
            tries += 1
        }
        page.tap()
        settle()
    }

    /// Chooses which end the newest photos are at, in the Library's View Options, under its own View Options.
    @MainActor
    private func chooseNewestEnd(_ application: XCUIApplication, _ choice: String, required: Bool = true) {
        application.buttons["View Options"].firstMatch.tap()
        settle()
        // The menu's own View Options, below the toolbar's button of that name.
        let named = application.descendants(matching: .any).matching(NSPredicate(format: "label == 'View Options'"))
        let rows = (0..<named.count).map { named.element(boundBy: $0) }.filter { $0.exists && $0.isHittable }
        rows.max { $0.frame.minY < $1.frame.minY }?.tap()
        settle()
        for query in [application.buttons, application.switches, application.staticTexts] {
            let element = query[choice].firstMatch
            if element.waitForExistence(timeout: 3) {
                element.tap()
                settle()
                newestAtTheTop = choice == "Newest at the Top"
                return
            }
        }
        if required { XCTFail("no \(choice) in View Options") }
    }

    @MainActor
    private func phoneTile(_ application: XCUIApplication) -> XCUIElement {
        application.descendants(matching: .any).matching(identifier: "Phone Tile").firstMatch
    }

    /// The system's share sheet, by the actions it offers for a photo.
    @MainActor
    private func waitForShareSheet(_ application: XCUIApplication) -> Bool {
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if application.navigationBars["UIActivityContentView"].exists { return true }
            for name in ["Copy", "Save Image", "Save to Files"] where application.buttons[name].exists || application.cells[name].exists {
                return true
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return false
    }

    @MainActor
    private func closeShareSheet(_ application: XCUIApplication) {
        let bar = application.navigationBars["UIActivityContentView"]
        if bar.exists, bar.buttons.count > 0 {
            bar.buttons.element(boundBy: bar.buttons.count - 1).tap()
            return
        }
        let close = application.buttons["Close"].firstMatch
        if close.exists && close.isHittable {
            close.tap()
            return
        }
        // The sheet dragged down by its top, as a finger closes it. A swipe across the whole window starts on the photo
        // above the sheet and drags the viewer closed with it (iOS 27's sheet has no Close button).
        application.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.64))
            .press(forDuration: 0.05, thenDragTo: application.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)),
                   withVelocity: .fast, thenHoldForDuration: 0)
    }

    /// Closes the sheet over the Library: the Backup page's, or the account's.
    @MainActor
    private func closeSheet(_ application: XCUIApplication) {
        let close = application.buttons["Close"].firstMatch
        if close.waitForExistence(timeout: 3) {
            close.tap()
            settle()
        }
    }

    /// Taps the first of these buttons on a system alert, if one comes within the time; whether one did.
    @discardableResult
    @MainActor
    private func tapSystemAlert(_ labels: [String], timeout: TimeInterval) -> Bool {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            for label in labels {
                let button = springboard.alerts.buttons[label].firstMatch
                if button.exists {
                    button.tap()
                    return true
                }
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return false
    }

    @MainActor
    private func waitUntilGone(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !element.exists { return true }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return !element.exists
    }

    /// Signs Verso Dev out by the launch argument, which switches backing up off too, then removes the walk's photos.
    @MainActor
    private func finish(_ application: XCUIApplication) {
        // Newest at the Bottom again, the Simulator's as the walk found it, where a step failed before it was put back.
        if newestAtTheTop {
            let back = application.buttons["Back"].firstMatch
            if back.exists && back.isHittable { back.tap() }
            chooseNewestEnd(application, "Newest at the Bottom", required: false)
        }
        application.terminate()
        // Signed out first, which switches backing up off, whatever becomes of removing the photos after.
        let cleaning = XCUIApplication()
        cleaning.launchArguments = ["-signOut", "YES"]
        cleaning.launch()
        Thread.sleep(forTimeInterval: 10)
        keep("13 Signed out", cleaning)
        cleaning.terminate()
        removeAdded()
    }

    private func settle() {
        Thread.sleep(forTimeInterval: 2.5)
    }

    @MainActor
    private func keep(_ name: String, _ application: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: application.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
