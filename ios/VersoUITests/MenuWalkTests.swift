// A walk through the one menu of photo actions (PhotoActionsMenu) as a person opens it, keeping a screenshot of each
// place: a long press on a photo in the Library and each of its submenus (Add To, Move To, Adjust Info), a selection of
// two with the selection's bar, its "..." and its Add To, a long press on a selected photo, a photo in an album of the
// account's own and in one shared with it (where the demo has one), in the Archive, and in a search's results. It signs
// Verso Dev in to Immich's demo with the launch arguments, as TourTests does, and only reads there: every menu is
// closed with a tap beside it and no action is chosen, so nothing on the server changes.

import XCTest

final class MenuWalkTests: XCTestCase {
    @MainActor
    func testMenus() throws {
        continueAfterFailure = true
        let application = XCUIApplication()
        // Albums and the Archive in the tab bar, for this launch alone.
        application.launchArguments = ["-tabBarChoices", "albums,archive", "-signInServer", "https://demo.immich.app",
                                       "-signInEmail", "demo@immich.app", "-signInPassword", "demo"]
        application.launch()
        XCTAssertTrue(application.buttons["Select"].waitForExistence(timeout: 45), "the Library shows once signed in")
        settle()

        // The Library: a long press on its newest photo, at the bottom, and each submenu in place.
        if let tile = lastTile(application) {
            XCTAssertTrue(openMenu(on: tile, application), "a long press opens the menu")
            keep("01 Library long press", application)
            for (number, submenu) in [(2, "Add To"), (3, "Move To"), (4, "Adjust Info")] {
                if openSubmenu(submenu, application) {
                    keep(String(format: "%02d Library %@", number, submenu), application)
                    if submenu == "Adjust Info", openSubmenu("Rating", application) {
                        keep("05 Library Rating", application)
                    }
                }
                close(application)
                if submenu != "Adjust Info" { _ = openMenu(on: tile, application) }
            }
        } else {
            XCTFail("the Library shows photos")
        }

        // A selection of two: the selection's bar, its "...", its Add To, and a long press on one of them.
        application.buttons["Select"].firstMatch.tap()
        settle()
        let tiles = visibleTiles(application)
        if tiles.count >= 2 {
            tiles[tiles.count - 1].tap()
            tiles[tiles.count - 2].tap()
            settle()
            keep("06 Selection of two", application)
            let more = application.buttons["More"].firstMatch
            if more.waitForExistence(timeout: 5) {
                more.tap()
                settle()
                keep("07 Selection More", application)
                if openSubmenu("Move To", application) { keep("08 Selection More Move To", application) }
                close(application)
            }
            let addTo = application.buttons["Add To"].firstMatch
            if addTo.exists {
                addTo.tap()
                settle()
                keep("09 Selection Add To", application)
                close(application)
            }
            if openMenu(on: tiles[tiles.count - 1], application) {
                keep("10 Long press on a selected photo", application)
                if openSubmenu("Adjust Info", application) { keep("11 Selected Adjust Info", application) }
                close(application)
            }
        }
        let cancel = application.buttons["Cancel"].firstMatch
        if cancel.exists { cancel.tap() }
        settle()

        // An album of the account's own, then one shared with it, where the demo has one.
        let albumsTab = application.tabBars.buttons["Albums"].firstMatch
        if albumsTab.waitForExistence(timeout: 10) {
            albumsTab.tap()
            settle()
            if openFirstAlbum(application) {
                keep("12 Album page", application)
                if let tile = firstTile(application), openMenu(on: tile, application) {
                    keep("13 Album long press", application)
                    close(application)
                }
                goBack(application)
            }
            if chooseAlbumFilter("Shared with Me", application) {
                if openFirstAlbum(application) {
                    keep("14 Shared album page", application)
                    if let tile = firstTile(application), openMenu(on: tile, application) {
                        keep("15 Shared album long press", application)
                        close(application)
                    }
                    goBack(application)
                } else {
                    keep("14 No album shared with the demo", application)
                }
                _ = chooseAlbumFilter("All", application)
            }
        }

        // The Archive: Move To offers the Library alone.
        let archiveTab = application.tabBars.buttons["Archive"].firstMatch
        if archiveTab.waitForExistence(timeout: 5) {
            archiveTab.tap()
            settle()
            keep("16 Archive", application)
            if let tile = lastTile(application), openMenu(on: tile, application) {
                keep("17 Archive long press", application)
                if openSubmenu("Move To", application) { keep("18 Archive Move To", application) }
                close(application)
            }
        }

        // A search's results: Show in All Photos.
        let searchTab = application.tabBars.buttons["Search"].firstMatch
        if searchTab.waitForExistence(timeout: 5) {
            searchTab.tap()
            settle()
            let field = application.searchFields.firstMatch
            if field.waitForExistence(timeout: 10) {
                field.tap()
                field.typeText("beach\n")
                Thread.sleep(forTimeInterval: 4)
                keep("19 Search results", application)
                if let tile = firstTile(application), openMenu(on: tile, application) {
                    keep("20 Search result long press", application)
                    close(application)
                }
            }
        }
    }

    // MARK: Steps

    /// The photos' tiles on screen, top to bottom, as VoiceOver names them.
    @MainActor
    private func visibleTiles(_ application: XCUIApplication) -> [XCUIElement] {
        let query = application.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Photo' OR label BEGINSWITH 'Video'"))
        let window = application.windows.firstMatch.frame
        return (0..<min(query.count, 60)).map { query.element(boundBy: $0) }
            .filter { $0.exists && $0.isHittable && $0.frame.minY > window.height * 0.15 && $0.frame.maxY < window.height * 0.9 }
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

    @MainActor
    private func lastTile(_ application: XCUIApplication) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if let tile = visibleTiles(application).last { return tile }
            Thread.sleep(forTimeInterval: 1)
        }
        return nil
    }

    /// A long press on a tile; whether its menu came.
    @MainActor
    private func openMenu(on tile: XCUIElement, _ application: XCUIApplication) -> Bool {
        guard tile.exists else { return false }
        tile.press(forDuration: 1.2)
        let came = ["Copy", "Share", "Restore"].contains { application.buttons[$0].firstMatch.waitForExistence(timeout: 2) }
        settle()
        return came
    }

    /// A submenu opened in place within the menu shown; whether it was there.
    @MainActor
    private func openSubmenu(_ title: String, _ application: XCUIApplication) -> Bool {
        let item = application.buttons[title].firstMatch
        guard item.waitForExistence(timeout: 3), item.isHittable else { return false }
        item.tap()
        settle()
        return true
    }

    /// Closes the menu or submenu shown with a tap beside it, choosing nothing.
    @MainActor
    private func close(_ application: XCUIApplication) {
        application.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)).tap()
        settle()
    }

    @MainActor
    private func goBack(_ application: XCUIApplication) {
        let back = application.navigationBars.buttons.element(boundBy: 0)
        if back.exists { back.tap() }
        settle()
    }

    /// The first album's page in Albums; whether it opened.
    @MainActor
    private func openFirstAlbum(_ application: XCUIApplication) -> Bool {
        // A card, by its size: the year sections' headers are buttons too.
        let buttons = application.collectionViews.firstMatch.buttons
        let deadline = Date().addingTimeInterval(10)
        var album: XCUIElement?
        while album == nil && Date() < deadline {
            album = (0..<min(buttons.count, 30)).map { buttons.element(boundBy: $0) }
                .first { $0.exists && $0.isHittable && $0.frame.height > 100 }
            if album == nil { Thread.sleep(forTimeInterval: 1) }
        }
        guard let album else { return false }
        album.tap()
        let opened = application.buttons["Album"].waitForExistence(timeout: 15)
        settle()
        return opened
    }

    /// Albums' All, Mine or Shared with Me, pulled down into view above the cards; whether it was there.
    @MainActor
    private func chooseAlbumFilter(_ title: String, _ application: XCUIApplication) -> Bool {
        let scroll = application.collectionViews.firstMatch
        scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
            .press(forDuration: 0.05, thenDragTo: scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)),
                   withVelocity: .slow, thenHoldForDuration: 0.2)
        settle()
        let filter = application.buttons[title].firstMatch
        guard filter.waitForExistence(timeout: 3) else { return false }
        filter.tap()
        settle()
        return true
    }

    /// Lets thumbnails and transitions finish before a screenshot.
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
