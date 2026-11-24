// Share, walked against a lab server (lab/immich-server/showcase.sh; never Immich's demo, as it makes a link): two
// photos selected and shared, the sheet timed from the tap; their originals saved to Files, On My iPhone, looked at in
// the Files app and deleted there (On My iPhone holds nothing else of the Simulator's); Copy; Create Link… for the
// two, with a password; Add to Link… for a third photo, from its long press; and the viewer's Share. The link it makes
// is deleted afterwards through the lab's API, by its description, "Share Walk". The server's address and key reach it
// only through the test run's environment (IMMICH_URL and IMMICH_API_KEY, as TEST_RUNNER_ variables), never as launch
// arguments:
//   tools/mac.sh <name> walk ShareWalkTests/testShare <env file> IMMICH_API_KEY_FULL

import XCTest

final class ShareWalkTests: XCTestCase {
    private let linkName = "Share Walk"

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    @MainActor
    func testShare() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let server = environment["IMMICH_URL"], let key = environment["IMMICH_API_KEY"] else {
            throw XCTSkip("needs a lab server: tools/mac.sh <name> walk ShareWalkTests <env file> <key variable>")
        }
        XCTAssertFalse(server.contains("demo.immich.app"), "never Immich's demo")
        let application = XCUIApplication()
        application.launchEnvironment = ["VERSO_SIGN_IN_SERVER": server, "VERSO_SIGN_IN_API_KEY": key]
        application.launch()
        XCTAssertTrue(application.buttons["Select"].waitForExistence(timeout: 60), "the Library shows once signed in")
        settle()

        // Two photos selected and shared: the sheet opens at once, its header saying how many.
        select(2, application)
        let shared = Date()
        application.buttons["Share"].firstMatch.tap()
        XCTAssertTrue(waitForShareSheet(application), "the share sheet opens")
        let seconds = Date().timeIntervalSince(shared)
        keep(String(format: "01 Share sheet for two, open after %.1f s", seconds), application)
        keepTree("01 Share sheet tree", application)
        XCTAssertLessThan(seconds, 3, "the sheet opens without downloading the originals")
        let header = application.otherElements["LP.CaptionBar.TopCaption"].firstMatch
        XCTAssertTrue(header.exists && header.label.hasPrefix("2 ") && header.label.hasSuffix(" Selected"),
                      "the header says two are selected")

        // Save to Files, into a folder of the walk's own On My iPhone.
        if tapAction("Save to Files", application) {
            saveToFiles(application)
        }
        settle()
        keep("06 After Save to Files", application)
        lookInFiles()
        application.activate()
        settle()

        // Copy, for the log: whether the originals download before the sheet says it is done.
        if application.buttons["Cancel"].firstMatch.exists { application.buttons["Cancel"].firstMatch.tap() }
        select(2, application)
        application.buttons["Share"].firstMatch.tap()
        if waitForShareSheet(application), tapAction("Copy", application) {
            Thread.sleep(forTimeInterval: 4)
            keep("09 After Copy of two", application)
        }

        // Create Link… for the two, with a description and a password.
        if application.buttons["Cancel"].firstMatch.exists { application.buttons["Cancel"].firstMatch.tap() }
        select(2, application)
        application.buttons["Share"].firstMatch.tap()
        if waitForShareSheet(application), tapAction("Create Link…", application) {
            let description = application.textFields["Description"].firstMatch
            XCTAssertTrue(description.waitForExistence(timeout: 10), "Create Link… shows the link form")
            description.tap()
            description.typeText(linkName)
            let password = application.secureTextFields["Password"].firstMatch
            password.tap()
            password.typeText("walk-2468")
            keep("10 Create Link form", application)
            application.buttons["Create"].firstMatch.tap()
            if waitForShareSheet(application) {
                settle()
                keep("11 The new link's share sheet", application)
                keepTree("11 The new link's share sheet tree", application)
                XCTAssertTrue(tapAction("Copy", application), "the link's sheet has Copy")
            } else {
                keep("11 No share sheet for the new link", application)
                XCTFail("the new link's address opens in a share sheet")
            }
            settle()
            keep("12 After Copy", application)
            XCTAssertFalse(application.navigationBars["New Link"].exists, "the form has closed")
        }

        // Add to Link… for a third photo, from its long press.
        if application.buttons["Cancel"].firstMatch.exists { application.buttons["Cancel"].firstMatch.tap() }
        let tiles = visibleTiles(application)
        guard tiles.count >= 3 else {
            XCTFail("three photos show")
            return
        }
        tiles[2].press(forDuration: 1.2)
        settle()
        let share = application.buttons["Share"].firstMatch
        if share.waitForExistence(timeout: 5) { share.tap() }
        if waitForShareSheet(application) {
            settle()
            keep("20 Share sheet for one", application)
            if tapAction("Add to Link…", application) {
                let row = application.buttons.matching(NSPredicate(format: "label CONTAINS %@", linkName)).firstMatch
                XCTAssertTrue(row.waitForExistence(timeout: 15), "Add to Link… lists the walk's link")
                keep("21 Add to Link", application)
                row.tap()
                if waitForShareSheet(application) {
                    settle()
                    keep("22 The link's share sheet after adding", application)
                    XCTAssertTrue(tapAction("Copy", application), "the link's sheet has Copy")
                } else {
                    keep("22 No share sheet after adding", application)
                    XCTFail("the link's address opens in a share sheet once the photo is added")
                }
                settle()
                keep("23 After adding", application)
                XCTAssertFalse(application.navigationBars["Add to Link"].exists, "Add to Link has closed")
            }
        }

        // The viewer's Share, for the photo shown.
        let tile = visibleTiles(application).first
        tile?.tap()
        settle()
        let viewerShare = application.buttons["Share"].firstMatch
        if viewerShare.waitForExistence(timeout: 10) {
            viewerShare.tap()
            if waitForShareSheet(application) {
                settle()
                keep("30 The viewer's share sheet", application)
                // Closed with a drag down on its header.
                let header = application.otherElements["LP.CaptionBar.TopCaption"].firstMatch
                if header.exists {
                    header.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                        .press(forDuration: 0.1, thenDragTo: application.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)))
                }
                settle()
            } else {
                XCTFail("the viewer's Share opens the share sheet")
            }
        }
        keep("31 The viewer after Share", application)
    }

    // MARK: Files

    /// The document picker, at On My iPhone, never Verso Drive's, and Save.
    @MainActor
    private func saveToFiles(_ application: XCUIApplication) {
        let save = application.buttons["Save"].firstMatch
        guard save.waitForExistence(timeout: 20) else {
            keep("02 No Save in the picker", application)
            keepTree("02 Picker tree", application)
            XCTFail("Save to Files shows the picker")
            return
        }
        settle()
        keep("02 Save to Files picker", application)
        let atOnMyPhone = application.navigationBars["On My iPhone"].exists
            || application.staticTexts["On My iPhone"].exists || application.staticTexts["On My iPhone is Empty"].exists
        if !atOnMyPhone {
            keepTree("03 Picker elsewhere tree", application)
            XCTFail("the picker opens at On My iPhone")
            application.buttons["Cancel"].firstMatch.tap()
            return
        }
        save.tap()
        let replace = application.buttons["Replace"].firstMatch
        if replace.waitForExistence(timeout: 3) { replace.tap() }
        let deadline = Date().addingTimeInterval(60)
        while save.exists && Date() < deadline { Thread.sleep(forTimeInterval: 0.5) }
        keep("05 Saved", application)
    }

    /// The Files app's On My iPhone: the originals under their names, then deleted.
    @MainActor
    private func lookInFiles() {
        let files = XCUIApplication(bundleIdentifier: "com.apple.DocumentsApp")
        files.launch()
        XCTAssertTrue(files.wait(for: .runningForeground, timeout: 15), "the Files app runs")
        let browse = files.tabBars.buttons["Browse"].firstMatch
        if browse.waitForExistence(timeout: 10) {
            browse.tap()
            browse.tap()
        }
        settle()
        let onMyPhone = files.cells.matching(NSPredicate(format: "label BEGINSWITH 'On My iPhone'")).firstMatch
        if onMyPhone.waitForExistence(timeout: 10) {
            onMyPhone.tap()
            settle()
        }
        let saved = files.collectionViews.cells.matching(NSPredicate(format: "identifier MATCHES[c] %@",
                                                                      ".*, (jpe?g|heic|png|gif|webp|dng|tiff?|mp4|mov|m4v)$"))
        _ = saved.firstMatch.waitForExistence(timeout: 10)
        keep("07 The originals in Files", files)
        keepTree("07 The originals in Files tree", files)
        XCTAssertEqual(saved.count, 2, "both originals are saved, under their own names")
        // Deleted again, one by one.
        var tries = 0
        while saved.count > 0 && tries < 4 {
            saved.firstMatch.press(forDuration: 1.2)
            let delete = files.buttons["Delete"].firstMatch
            if delete.waitForExistence(timeout: 5) { delete.tap() }
            settle()
            tries += 1
        }
        keep("08 The originals deleted", files)
        XCTAssertEqual(saved.count, 0, "the saved originals are deleted")
    }

    // MARK: The grid and the sheet

    /// Select, then the first photos in view.
    @MainActor
    private func select(_ count: Int, _ application: XCUIApplication) {
        application.buttons["Select"].firstMatch.tap()
        settle()
        for tile in visibleTiles(application).prefix(count) { tile.tap() }
        settle()
    }

    /// The system's share sheet, by the actions it offers.
    @MainActor
    private func waitForShareSheet(_ application: XCUIApplication) -> Bool {
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if application.navigationBars["UIActivityContentView"].exists { return true }
            if application.otherElements["LP.CaptionBar.TopCaption"].exists { return true }
            for name in ["Copy", "Save to Files"] where application.buttons[name].exists || application.cells[name].exists {
                return true
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return false
    }

    /// An action of the share sheet in front (a sheet under it may have one of the name too), after View More where
    /// it is not among the first.
    @MainActor
    private func tapAction(_ name: String, _ application: XCUIApplication) -> Bool {
        var action = hittable(name, application)
        if action == nil, let more = hittable("View More", application) {
            more.tap()
            settle()
            keep("View More for \(name)", application)
            action = hittable(name, application)
            var tries = 0
            while action == nil && tries < 3 {
                application.swipeUp()
                Thread.sleep(forTimeInterval: 1)
                action = hittable(name, application)
                tries += 1
            }
        }
        guard let action else {
            keep("Missing \(name)", application)
            keepTree("Missing \(name) tree", application)
            XCTFail("the share sheet has \(name)")
            return false
        }
        action.tap()
        settle()
        return true
    }

    @MainActor
    private func hittable(_ name: String, _ application: XCUIApplication) -> XCUIElement? {
        for query in [application.cells, application.buttons] {
            let matches = query.matching(NSPredicate(format: "label == %@", name))
            for index in 0..<matches.count {
                let element = matches.element(boundBy: index)
                if element.exists && element.isHittable { return element }
            }
        }
        return nil
    }

    /// The photos' tiles on screen, top to bottom, as VoiceOver names them.
    @MainActor
    private func visibleTiles(_ application: XCUIApplication) -> [XCUIElement] {
        let query = application.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Photo' OR label BEGINSWITH 'Video'"))
        let window = application.windows.firstMatch.frame
        return (0..<min(query.count, 60)).map { query.element(boundBy: $0) }
            .filter { $0.exists && $0.isHittable && $0.frame.minY > window.height * 0.12 && $0.frame.maxY < window.height * 0.92 }
            .sorted { ($0.frame.minY, $0.frame.minX) < ($1.frame.minY, $1.frame.minX) }
    }

    /// Lets pictures and transitions finish before a screenshot.
    private func settle() {
        Thread.sleep(forTimeInterval: 2)
    }

    @MainActor
    private func keep(_ name: String, _ application: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: application.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func keepTree(_ name: String, _ application: XCUIApplication) {
        let attachment = XCTAttachment(string: application.debugDescription)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
