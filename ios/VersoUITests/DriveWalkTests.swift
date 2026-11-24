// A walk through Verso Drive in the Files app, keeping a screenshot of each place: the drive's page in the account's
// sheet, Files' Browse with the drive's location and its Turn On, its top folders, a month of photos, a photo in Files'
// preview (its original read through the extension, mac/FileProvider), the page again once the location is on, and
// Show in Files. It signs Verso Dev in to Immich's demo and switches the drive on with the launch arguments
// (AppModel.followLaunchArguments), and only reads there: nothing is uploaded, renamed or deleted. It starts and ends
// with the drive switched off, so nothing an earlier run left counts, and the library's location is gone afterwards.
// Off, iOS still lists a location of the extension's own (its default domain, while Verso has none), which holds no
// library: the walk keeps what Files shows there. Every tap waits for its element first, so a step that fails leaves
// the rest, and the switching off, to run.
//
// The Simulator shows the root's Upload alone: its fileproviderd cannot make a read-only folder, which it locks
// ("cannotSetMetadata", Operation not permitted, in the log for each section), so there the sections are an expected
// failure, and the walk lists folders and opens a photo only where they show (on a phone).

import XCTest

final class DriveWalkTests: XCTestCase {
    @MainActor
    func testDriveInFiles() throws {
        continueAfterFailure = true
        let verso = XCUIApplication()
        let files = XCUIApplication(bundleIdentifier: "com.apple.DocumentsApp")
        let browse = files.tabBars.buttons["Browse"].firstMatch
        let location = files.cells.matching(NSPredicate(format: "label CONTAINS %@", "Verso")).firstMatch

        // Off: no library in Files.
        switchOff(verso)
        files.launch() // afresh, with nothing a run before left open
        lookWhileOff(files, browse: browse, location: location, keeping: "00 Files, the drive off")

        verso.launchArguments = ["-versoDrive", "on", "-signInServer", "https://demo.immich.app",
                                 "-signInEmail", "demo@immich.app", "-signInPassword", "demo"]
        verso.launch()
        XCTAssertTrue(verso.buttons["Select"].waitForExistence(timeout: 45), "the Library shows once signed in")

        // The account's sheet: Verso Drive under On This iPhone, switched on, and its page.
        tap(verso.tabBars.buttons["Collections"].firstMatch, "Collections is in the tab bar")
        tap(verso.buttons["Account"].firstMatch, "the account's picture is in Collections' bar")
        openDrivePage(verso, keeping: "01 Account sheet, Verso Drive")
        settle()
        keep("02 Verso Drive page, the location waiting", verso)

        // Files' Browse: the drive's location, which waits to be turned on the first time.
        files.activate()
        XCTAssertTrue(files.wait(for: .runningForeground, timeout: 15), "the Files app runs")
        if browse.waitForExistence(timeout: 10) {
            browse.tap()
            browse.tap()
        }
        settle()
        keep("03 Files Browse", files)
        if tap(location, "Files lists Verso Drive's location under Browse") {
            let turnOn = files.buttons["Turn On"].firstMatch
            if turnOn.waitForExistence(timeout: 5) {
                keep("04 Files asks to turn the location on", files)
                turnOn.tap()
            }
        }

        // The top folders: the sections and Upload.
        XCTAssertTrue(item(named: "Upload", in: files).waitForExistence(timeout: 60), "the drive's root lists Upload")
        let photos = item(named: "Photos", in: files)
        _ = photos.waitForExistence(timeout: 10)
        settle()
        keep("05 Verso Drive root", files)
        keepTree("05 Verso Drive root tree", files)
        expectingReadOnlyFoldersMissingInTheSimulator {
            for section in ["Photos", "Albums", "People", "Places"] {
                XCTAssertTrue(item(named: section, in: files).exists, "the drive's root lists \(section)")
            }
        }

        // Photos: a year, a month and its photos, down to the first file.
        var photo: XCUIElement?
        if photos.exists {
            photos.tap()
            for depth in 0..<4 {
                let file = firstFile(in: files)
                let folder = firstDateFolder(in: files)
                let listed = Date()
                while !file.exists, !folder.exists, Date().timeIntervalSince(listed) < 45 {
                    Thread.sleep(forTimeInterval: 1)
                }
                settle()
                keep(String(format: "06 Photos level %d", depth), files)
                if file.exists {
                    photo = file
                    break
                }
                guard folder.exists else { break }
                folder.tap()
            }
            keepTree("07 a folder of photos tree", files)
        }
        if photos.exists { XCTAssertNotNil(photo, "a folder of photos lists its files") }

        // A photo in Files' preview: its original comes through the extension.
        if let photo {
            photo.tap()
            Thread.sleep(forTimeInterval: 12)
            keep("08 a photo in Files' preview", files)
            keepTree("08 a photo in Files' preview tree", files)
        }

        // Back in Verso: the location is on, with its status, and Show in Files opens Files at it.
        verso.activate()
        settle()
        if !verso.switches["Verso Drive"].exists {
            keep("09 back in Verso, the page closed", verso)
            if !verso.navigationBars["Account"].exists {
                tap(verso.tabBars.buttons["Collections"].firstMatch, "Collections is in the tab bar")
                tap(verso.buttons["Account"].firstMatch, "the account's picture is in Collections' bar")
            }
            openDrivePage(verso, keeping: nil)
        }
        let showInFiles = verso.buttons["Show in Files"].firstMatch
        XCTAssertTrue(showInFiles.waitForExistence(timeout: 20), "the page offers Show in Files once the location is on")
        settle()
        keep("09 Verso Drive page, the location on", verso)
        if showInFiles.exists {
            showInFiles.tap()
            XCTAssertTrue(files.wait(for: .runningForeground, timeout: 15), "Show in Files opens the Files app")
            settle()
            if files.state == .runningForeground { keep("10 Show in Files", files) }
        }

        // Switched off with the launch argument: the library's location goes.
        switchOff(verso)
        files.activate()
        lookWhileOff(files, browse: browse, location: location, keeping: "11 Files, switched off")
    }

    /// Files while the drive is off: Browse, and the location iOS lists for the extension, if any, which holds no
    /// library.
    @MainActor
    private func lookWhileOff(_ files: XCUIApplication, browse: XCUIElement, location: XCUIElement, keeping name: String) {
        if browse.waitForExistence(timeout: 10) {
            browse.tap()
            browse.tap() // a second tap goes back to Browse's top
        }
        settle()
        keep("\(name), Browse", files)
        guard location.exists else { return }
        location.tap()
        Thread.sleep(forTimeInterval: 6)
        keep("\(name), its location", files)
        XCTAssertFalse(item(named: "Upload", in: files).exists, "off, Files shows no library")
        let cancel = files.alerts.buttons["Cancel"].firstMatch
        if cancel.exists { cancel.tap() }
        if browse.exists {
            browse.tap()
            browse.tap()
        }
    }

    /// The Simulator cannot make the drive's read-only folders (above): what checks them is an expected failure there,
    /// and holds on a phone.
    @MainActor
    private func expectingReadOnlyFoldersMissingInTheSimulator(_ checks: () -> Void) {
        #if targetEnvironment(simulator)
        let options = XCTExpectedFailure.Options()
        options.isStrict = false
        XCTExpectFailure("the Simulator's fileproviderd cannot lock a read-only folder as it makes it", options: options,
                         failingBlock: checks)
        #else
        checks()
        #endif
    }

    /// Switch the drive off with the launch argument, as a script does, and give Verso the moment it takes.
    @MainActor
    private func switchOff(_ verso: XCUIApplication) {
        verso.launchArguments = ["-versoDrive", "off"]
        verso.launch()
        _ = verso.buttons["Select"].waitForExistence(timeout: 30)
        Thread.sleep(forTimeInterval: 5)
    }

    /// From the account's sheet, its Verso Drive row (scrolled to) and the drive's page.
    @MainActor
    private func openDrivePage(_ verso: XCUIApplication, keeping name: String?) {
        let driveRow = verso.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Verso Drive")).firstMatch
        _ = verso.navigationBars["Account"].waitForExistence(timeout: 10)
        for _ in 0..<6 where !(driveRow.exists && driveRow.isHittable) { verso.swipeUp() }
        settle()
        if let name { keep(name, verso) }
        tap(driveRow, "the account's sheet has Verso Drive")
        XCTAssertTrue(verso.switches["Verso Drive"].waitForExistence(timeout: 10), "the drive's page has its switch")
    }

    /// Tap an element once it shows, or record that it did not.
    @MainActor
    @discardableResult
    private func tap(_ element: XCUIElement, _ claim: String) -> Bool {
        guard element.waitForExistence(timeout: 15) else {
            XCTFail(claim)
            return false
        }
        element.tap()
        return true
    }

    // Files names a listing's cell by the item's name and its kind or extension: "Photos, Folder", "<name>, jpg".

    /// A folder of a Files listing, by its name.
    @MainActor
    private func item(named name: String, in files: XCUIApplication) -> XCUIElement {
        files.collectionViews.cells.matching(NSPredicate(format: "identifier == %@", "\(name), Folder")).firstMatch
    }

    /// The first year, month or day folder of the listing in front.
    @MainActor
    private func firstDateFolder(in files: XCUIApplication) -> XCUIElement {
        files.collectionViews.cells.matching(NSPredicate(format: "identifier MATCHES %@", "^[0-9]{2}.*, Folder$")).firstMatch
    }

    /// The first photo or video of the listing in front.
    @MainActor
    private func firstFile(in files: XCUIApplication) -> XCUIElement {
        files.collectionViews.cells.matching(NSPredicate(format: "identifier MATCHES[c] %@",
                                                         ".*, (jpe?g|heic|png|gif|webp|dng|tiff?|mp4|mov|m4v)$")).firstMatch
    }

    /// Lets listings, thumbnails and transitions finish before a screenshot.
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

    /// The accessibility tree, to see what Files offers where a step did not find it.
    @MainActor
    private func keepTree(_ name: String, _ application: XCUIApplication) {
        let attachment = XCTAttachment(string: application.debugDescription)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
