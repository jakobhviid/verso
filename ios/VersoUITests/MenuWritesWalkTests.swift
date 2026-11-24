// The photo menu's actions that write, walked against a lab server (never Immich's demo, which may not be written to),
// as a throwaway user of the walk's own with four photos, an album and a tag (walk/server.py beside the agents'
// copies prepares it and removes it after): Save to Photos into the Simulator's own library, Copy, Add To an album, a
// new shared album shared with the walk's second user, a tag, a rating, Adjust Date & Time for two photos at once,
// Move To the Archive and back to the Library, and Hide, then Unhide from the Locked Folder, whose PIN the walk sets.
// The server's address reaches it only through the test run's environment, and the user's email and password with it
// (IMMICH_API_KEY holds "<email> <password>"), which the app gets in its own environment (AppModel.signInFromEnvironment),
// never as launch arguments, as a session of its own is what Hide and the Locked Folder need:
//   tools/mac.sh <name> walk MenuWritesWalkTests <walk env file> MENU_WALK_LOGIN
// What changed is checked through Immich's API after the walk (server.py check). The photo saved into the Simulator's
// library is removed again, and Verso Dev signed out, however the walk ends.
//
// The second walk, after `server.py arrange-archive` has put menu-03 and an archived menu-04 in an album of their own,
// only looks: the menu goes by the photo, not the page, so in the album the archived photo has Show in Archive and Move
// To offering the Library alone, the other Show in All Photos and Move To offering the Archive alone, and Show in
// Archive opens the Archive at it:
//   tools/mac.sh <name> walk MenuWritesWalkTests/testArchivedByThePhoto <walk env file> MENU_WALK_LOGIN

import Photos
import XCTest

final class MenuWritesWalkTests: XCTestCase {
    /// The photos the walk saved into the Simulator's library, by their local identifiers.
    private var saved: [String] = []

    @MainActor
    func testWrites() throws {
        continueAfterFailure = true
        let application = try launchSignedIn()
        var tiles = visibleTiles(application)
        XCTAssertEqual(tiles.count, 4, "the walk's four photos show, menu-01 at the top")
        guard tiles.count == 4 else { return }

        // Save to Photos: the original into the Simulator's own library, with one word when it is done.
        choose(["Save to Photos"], on: tiles[0], application)
        XCTAssertTrue(waitForNotice("Saved to Photos", application, allowing: true), "Save to Photos says it is done")
        keep("02 Saved to Photos", application)
        try findSaved()

        // Copy, with its word.
        choose(["Copy"], on: tiles[3], application)
        XCTAssertTrue(waitForNotice("Copied", application), "Copy says it is done")
        keep("03 Copied", application)

        // Add To, Album…: the walk's album.
        choose(["Add To", "Album…"], on: tiles[0], application)
        let album = application.buttons.matching(NSPredicate(format: "label CONTAINS 'Menu Walk Album'")).firstMatch
        if album.waitForExistence(timeout: 10) {
            keep("04 Album sheet", application)
            album.tap()
            XCTAssertTrue(waitForNotice("Added to", application), "the photo goes into the album")
            keep("05 Added to the album", application)
        } else {
            XCTFail("Album… lists the walk's album")
        }

        // Add To, New Shared Album…: made with the photo, then its sharing, with the walk's second user added.
        choose(["Add To", "New Shared Album…"], on: tiles[1], application)
        let title = application.textFields["Title"].firstMatch
        if title.waitForExistence(timeout: 10) {
            title.typeText("Menu Walk Shared")
            keep("06 New Shared Album", application)
            application.buttons["Next"].firstMatch.tap()
            let addPeople = application.buttons["Add People"].firstMatch
            XCTAssertTrue(addPeople.waitForExistence(timeout: 15), "its sharing opens once it is made")
            settle()
            keep("07 Its sharing", application)
            addPeople.tap()
            settle()
            let friend = application.buttons.matching(NSPredicate(format: "label CONTAINS 'Menu Walk Friend'")).firstMatch
            if friend.waitForExistence(timeout: 10) {
                friend.tap()
                application.buttons["Add"].firstMatch.tap()
                settle()
                keep("08 Shared with the friend", application)
            } else {
                XCTFail("Add People lists the walk's second user")
            }
            application.buttons["Done"].firstMatch.tap()
            settle()
        } else {
            XCTFail("New Shared Album… asks for a name")
        }

        // Add To, Tag…: the walk's tag.
        choose(["Add To", "Tag…"], on: tiles[0], application)
        let tag = application.buttons.matching(NSPredicate(format: "label CONTAINS 'Menu Walk'")).firstMatch
        if tag.waitForExistence(timeout: 10) {
            keep("09 Tag sheet", application)
            tag.tap()
            XCTAssertTrue(waitForNotice("Tagged", application), "the photo gets the tag")
            keep("10 Tagged", application)
        } else {
            XCTFail("Tag… lists the walk's tag")
        }

        // Adjust Info, Rating: four stars.
        choose(["Adjust Info", "Rating"], on: tiles[1], application)
        keep("11 Rating", application)
        let four = application.buttons.matching(NSPredicate(format: "label == '4 Stars' OR label == '★★★★☆'")).firstMatch
        if four.waitForExistence(timeout: 5) { four.tap() } else { XCTFail("Rating has the stars") }
        settle()

        // Adjust Date & Time for two: the earliest shown, moved a day later, and the other with it.
        application.buttons["Select"].firstMatch.tap()
        settle()
        tiles = visibleTiles(application)
        tiles[2].tap()
        tiles[3].tap()
        settle()
        application.buttons["More"].firstMatch.tap()
        settle()
        tapItem("Adjust Info", application)
        tapItem("Adjust Date & Time", application)
        let dayAfter = application.buttons.matching(NSPredicate(format: "label CONTAINS '16 May' OR label CONTAINS 'May 16'")).firstMatch
        if dayAfter.waitForExistence(timeout: 10) {
            keep("12 Adjust Date & Time for two", application)
            dayAfter.tap()
            settle()
            keep("13 A day later", application)
            application.buttons["Adjust"].firstMatch.tap()
            Thread.sleep(forTimeInterval: 4)
            // Through the lab's tunnel the bridge's pooled connections, idle while the sheet is open, are closed under
            // its requests ("connection closed before message completed", every time): Adjust again, as a person
            // would, until a fresh connection takes it.
            let failed = application.alerts.buttons["OK"].firstMatch
            var tries = 0
            while failed.exists && tries < 4 {
                tries += 1
                keep("13 Adjust failed \(tries)", application)
                failed.tap()
                settle()
                application.buttons["Adjust"].firstMatch.tap()
                Thread.sleep(forTimeInterval: 4)
            }
            if failed.exists {
                XCTFail("Adjust Date & Time saves")
                failed.tap()
                settle()
            }
        } else {
            keep("12 No day to choose", application)
            XCTFail("the date picker shows the earliest photo's month")
            if application.buttons["Cancel"].firstMatch.exists { application.buttons["Cancel"].firstMatch.tap() }
        }
        // The sheet closed, and the selection ended, however the step went.
        let cancel = application.buttons["Cancel"].firstMatch
        for _ in 0..<2 where cancel.exists && cancel.isHittable {
            cancel.tap()
            settle()
        }
        keep("14 After the date", application)

        // Move To the Archive, then from the Archive back to the Library.
        tiles = visibleTiles(application)
        if let newest = tiles.last {
            choose(["Move To", "Archive"], on: newest, application)
            settle()
            keep("15 Moved to the Archive", application)
        }
        application.tabBars.buttons["Archive"].firstMatch.tap()
        settle()
        if let archived = visibleTiles(application).last {
            keep("16 The Archive", application)
            choose(["Move To", "Library"], on: archived, application)
            settle()
            keep("17 Back to the Library", application)
        } else {
            XCTFail("the Archive has the photo")
        }
        application.tabBars.buttons["Library"].firstMatch.tap()
        settle()

        // Hide, then Unhide from the Locked Folder, whose PIN the walk sets up.
        // menu-03, which is in no album: Immich takes a photo out of its albums as it goes into the Locked Folder.
        tiles = visibleTiles(application)
        if tiles.count >= 3 {
            choose(["Hide"], on: tiles[2], application)
            settle()
            keep("18 Hidden", application)
            XCTAssertEqual(visibleTiles(application).count, tiles.count - 1, "the hidden photo leaves the Library")
        }
        unhideFromLockedFolder(application)
    }

    @MainActor
    func testArchivedByThePhoto() throws {
        continueAfterFailure = true
        let application = try launchSignedIn(tabs: "albums")
        application.tabBars.buttons["Albums"].firstMatch.tap()
        settle()
        let album = application.buttons.matching(NSPredicate(format: "label CONTAINS 'Menu Walk Trip'")).firstMatch
        guard album.waitForExistence(timeout: 15) else {
            keep("02 No album", application)
            XCTFail("Albums has the walk's album with an archived photo")
            return
        }
        album.tap()
        settle()
        keep("02 The album", application)
        let archived = application.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Photo' AND label CONTAINS 'June'")).firstMatch
        let other = application.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Photo' AND label CONTAINS 'May'")).firstMatch
        XCTAssertTrue(archived.waitForExistence(timeout: 15), "the album shows its archived photo")
        choose([], on: archived, application)
        XCTAssertTrue(application.buttons["Show in Archive"].exists, "an archived photo in an album has Show in Archive")
        XCTAssertFalse(application.buttons["Show in All Photos"].exists, "and not Show in All Photos")
        keep("03 Archived photo in the album", application)
        tapItem("Move To", application)
        XCTAssertTrue(application.buttons["Library"].exists, "an archived photo moves to the Library")
        XCTAssertFalse(application.buttons["Archive"].exists, "and is not offered the Archive it is in")
        keep("04 Its Move To: the Library", application)
        close(application)
        choose([], on: other, application)
        XCTAssertTrue(application.buttons["Show in All Photos"].exists, "a photo in the library has Show in All Photos")
        XCTAssertFalse(application.buttons["Show in Archive"].exists, "and not Show in Archive")
        keep("05 Photo in the library, in the album", application)
        tapItem("Move To", application)
        XCTAssertTrue(application.buttons["Archive"].exists, "a photo in the library moves to the Archive")
        XCTAssertFalse(application.buttons["Library"].exists, "and is not offered the Library it is in")
        keep("06 Its Move To: the Archive", application)
        close(application)
        choose(["Show in Archive"], on: archived, application)
        Thread.sleep(forTimeInterval: 3)
        keep("07 Show in Archive opens the Archive", application)
        if let inArchive = firstTile(application) {
            choose([], on: inArchive, application)
            XCTAssertFalse(application.buttons["Show in Archive"].exists, "the Archive's own photo has no Show in Archive")
            keep("08 The photo in the Archive", application)
            tapItem("Move To", application)
            keep("09 Its Move To in the Archive", application)
            close(application)
        } else {
            XCTFail("the Archive shows the photo")
        }
    }

    // MARK: Steps

    /// Closes the menu shown with a tap beside it, choosing nothing.
    @MainActor
    private func close(_ application: XCUIApplication) {
        application.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)).tap()
        settle()
    }

    /// Verso Dev signed in to the lab server as the walk's user, from the run's environment.
    @MainActor
    private func launchSignedIn(tabs: String = "albums,archive") throws -> XCUIApplication {
        let environment = ProcessInfo.processInfo.environment
        guard let server = environment["IMMICH_URL"], let login = environment["IMMICH_API_KEY"] else {
            throw XCTSkip("needs a lab server: tools/mac.sh <name> walk MenuWritesWalkTests <env file> MENU_WALK_LOGIN")
        }
        XCTAssertFalse(server.contains("demo.immich.app"), "never Immich's demo")
        let parts = login.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { throw XCTSkip("MENU_WALK_LOGIN holds the walk user's email and password") }
        let application = XCUIApplication()
        application.launchArguments = ["-tabBarChoices", tabs]
        application.launchEnvironment = ["VERSO_SIGN_IN_SERVER": server, "VERSO_SIGN_IN_EMAIL": parts[0],
                                         "VERSO_SIGN_IN_PASSWORD": parts[1]]
        application.launch()
        addTeardownBlock { @MainActor in self.finish(application) }
        XCTAssertTrue(application.buttons["Select"].waitForExistence(timeout: 60), "the Library shows once signed in")
        settle()
        keep("01 Library", application)
        return application
    }

    /// A long press on a tile, then each item in turn, the submenus opening in place.
    @MainActor
    private func choose(_ path: [String], on tile: XCUIElement, _ application: XCUIApplication) {
        tile.press(forDuration: 1.2)
        settle()
        for item in path { tapItem(item, application) }
    }

    @MainActor
    private func tapItem(_ title: String, _ application: XCUIApplication) {
        let item = application.buttons[title].firstMatch
        if item.waitForExistence(timeout: 5) {
            item.tap()
            settle()
        } else {
            keep("Missing \(title)", application)
            XCTFail("the menu has \(title)")
        }
    }

    /// The Locked Folder from Collections, its PIN set up, and the hidden photo brought back with Unhide.
    @MainActor
    private func unhideFromLockedFolder(_ application: XCUIApplication) {
        application.tabBars.buttons["Collections"].firstMatch.tap()
        settle()
        let row = application.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Locked Folder'")).firstMatch
        var tries = 0
        while !(row.exists && row.isHittable) && tries < 8 {
            application.swipeUp()
            tries += 1
        }
        guard row.exists else {
            XCTFail("Collections has the Locked Folder")
            return
        }
        row.tap()
        settle()
        let pin = application.secureTextFields["Six-digit PIN"].firstMatch
        if pin.waitForExistence(timeout: 10) {
            pin.tap()
            pin.typeText("135790")
            let confirm = application.secureTextFields["Confirm PIN"].firstMatch
            if confirm.exists {
                confirm.tap()
                confirm.typeText("135790")
            }
            keep("19 Locked Folder PIN", application)
            let unlock = application.buttons.matching(NSPredicate(format: "label == 'Set PIN and Unlock' OR label == 'Unlock'")).firstMatch
            unlock.tap()
            settle()
        }
        guard let hidden = firstTile(application) else {
            keep("20 Locked Folder empty", application)
            XCTFail("the Locked Folder has the hidden photo")
            return
        }
        keep("20 Locked Folder", application)
        choose(["Unhide"], on: hidden, application)
        settle()
        keep("21 Unhidden", application)
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

    @MainActor
    private func firstTile(_ application: XCUIApplication) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if let tile = visibleTiles(application).first { return tile }
            Thread.sleep(forTimeInterval: 1)
        }
        return nil
    }

    /// The word at the grid's foot, once it begins so; `allowing`, the system's question to add to the photo library
    /// is answered meanwhile, if it comes (Verso Dev may have been allowed before).
    @MainActor
    private func waitForNotice(_ beginning: String, _ application: XCUIApplication, allowing: Bool = false) -> Bool {
        let notice = application.descendants(matching: .any)["Grid Notice"].firstMatch
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.buttons["Allow"].firstMatch
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if notice.exists, notice.label.hasPrefix(beginning) { return true }
            if allowing, allow.exists { allow.tap() }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return false
    }

    /// The photo Save to Photos made, found in the Simulator's library by its name, to remove after.
    @MainActor
    private func findSaved() throws {
        try allowPhotos()
        let found = PHAsset.fetchAssets(with: .image, options: nil)
        var named: [String] = []
        found.enumerateObjects { asset, _, _ in
            if PHAssetResource.assetResources(for: asset).contains(where: { $0.originalFilename == "menu-01.jpg" }) {
                named.append(asset.localIdentifier)
            }
        }
        saved = named
        XCTAssertEqual(named.count, 1, "the original is in the Simulator's library once")
        let attachment = XCTAttachment(string: "saved: \(named.count) named menu-01.jpg")
        attachment.name = "Saved in the library"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// The walk's own access to the photo library, to find what it saved and remove it after.
    @MainActor
    private func allowPhotos() throws {
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) != .authorized else { return }
        let asked = expectation(description: "asked")
        Self.requestAccess { asked.fulfill() }
        tapSystemAlert(["Allow Full Access", "Allow Access to All Photos", "Allow"], timeout: 10)
        tapSystemAlert(["Allow Full Access"], timeout: 3)
        wait(for: [asked], timeout: 20)
    }

    private nonisolated static func requestAccess(done: @escaping @Sendable () -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { _ in done() }
    }

    private nonisolated static func delete(_ identifiers: [String], done: @escaping @Sendable () -> Void) {
        PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil))
        } completionHandler: { _, _ in
            done()
        }
    }

    /// Removes what the walk saved into the library, then signs Verso Dev out by the launch argument.
    @MainActor
    private func finish(_ application: XCUIApplication) {
        application.terminate()
        if !saved.isEmpty, PHAsset.fetchAssets(withLocalIdentifiers: saved, options: nil).count > 0 {
            let done = expectation(description: "removed")
            Self.delete(saved) { done.fulfill() }
            tapSystemAlert(["Delete"], timeout: 10)
            wait(for: [done], timeout: 20)
        }
        let cleaning = XCUIApplication()
        cleaning.launchArguments = ["-signOut", "YES"]
        cleaning.launch()
        Thread.sleep(forTimeInterval: 10)
        keep("22 Signed out", cleaning)
        cleaning.terminate()
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

    private func settle() {
        Thread.sleep(forTimeInterval: 1.5)
    }

    @MainActor
    private func keep(_ name: String, _ application: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: application.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
