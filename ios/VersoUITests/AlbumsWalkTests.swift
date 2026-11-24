// A walk through the card pages as a person takes it, keeping a screenshot of each place: Albums at the smallest card
// size and two larger ones (a pinch, then View Options' Zoom In), its year sections, the search and All / Mine / Shared
// with Me pulled down into view, an album's page with its header and its comments, People at two sizes and a person's
// page, Memories, and Places' countries. It signs Verso Dev in to Immich's demo with the launch arguments, as TourTests
// does, and only reads there: it changes nothing on the server. It leaves the card size at the smallest, the default,
// as it found it.

import XCTest

final class AlbumsWalkTests: XCTestCase {
    @MainActor
    func testCardPages() throws {
        continueAfterFailure = true
        let application = XCUIApplication()
        // People in the tab bar beside Albums, for this launch alone (the default bar holds Albums alone).
        application.launchArguments = ["-tabBarChoices", "albums,people", "-signInServer", "https://demo.immich.app",
                                       "-signInEmail", "demo@immich.app", "-signInPassword", "demo"]
        application.launch()
        XCTAssertTrue(application.buttons["Select"].waitForExistence(timeout: 45), "the Library shows once signed in")

        // Albums, at the smallest size: Photos' covers, in year sections.
        let albumsTab = application.tabBars.buttons["Albums"].firstMatch
        XCTAssertTrue(albumsTab.waitForExistence(timeout: 10), "Albums is in the tab bar")
        albumsTab.tap()
        settle()
        zoomOutFully(application)
        chooseYearSections(application)
        keep("01 Albums covers", application)

        // Pulled down: the search field and All / Mine / Shared with Me come into view.
        let scroll = application.collectionViews.firstMatch
        let start = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        let end = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.2)
        settle()
        keep("02 Albums pulled down", application)
        XCTAssertTrue(application.textFields["Search Albums"].exists, "the search field shows once pulled down")
        let mine = application.buttons["Mine"].firstMatch
        if mine.exists {
            mine.tap()
            settle()
            keep("03 Albums Mine", application)
            application.buttons["All"].firstMatch.tap()
            settle()
        }
        let search = application.textFields["Search Albums"].firstMatch
        if search.exists {
            search.tap()
            search.typeText("Ci")
            settle()
            keep("03 Albums search", application)
            application.buttons["Clear"].firstMatch.tap()
            search.typeText("\n")
            settle()
        }

        // A pinch out: the Mac's cards, two to a row. It changes the size, and opens no card.
        scroll.pinch(withScale: 2, velocity: 1)
        settle()
        XCTAssertFalse(application.buttons["Album"].exists, "a pinch on the cards opens none of them")
        keep("04 Albums cards after a pinch", application)

        // View Options' Zoom In: one card to a row.
        if openViewOptions(application) {
            keep("05 Albums View Options", application)
            let zoomIn = application.buttons["Zoom In"].firstMatch
            if zoomIn.exists && zoomIn.isEnabled { zoomIn.tap() } else { tapTitleArea(application) }
            settle()
        }
        keep("06 Albums large cards", application)

        // An album's page, one shared with people where the demo has one.
        let shared = application.buttons.matching(NSPredicate(format: "value CONTAINS[c] 'shared with'")).firstMatch
        let anyAlbum = application.buttons.matching(NSPredicate(format: "value CONTAINS[c] 'item' OR label CONTAINS[c] 'April'")).firstMatch
        let album = shared.exists ? shared : anyAlbum
        if album.waitForExistence(timeout: 5) {
            album.tap()
            XCTAssertTrue(application.buttons["Album"].waitForExistence(timeout: 15), "the album's page opens")
            settle()
            keep("07 Album page", application)
            // Its comments and likes, only looked at.
            let comments = application.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'comment'")).firstMatch
            if comments.exists {
                comments.tap()
                settle()
                keep("08 Album comments", application)
                let done = application.buttons["Done"].firstMatch
                if done.exists { done.tap() } else { application.swipeDown() }
                settle()
            }
            application.navigationBars.buttons.element(boundBy: 0).tap()
            settle()
        }

        // People at the size the albums left, then at the smallest.
        let peopleTab = application.tabBars.buttons["People"].firstMatch
        if peopleTab.waitForExistence(timeout: 5) {
            peopleTab.tap()
            settle()
            keep("09 People larger", application)
            zoomOutFully(application)
            settle()
            keep("10 People smallest", application)
            let person = application.collectionViews.firstMatch.buttons.firstMatch
            if person.waitForExistence(timeout: 5) {
                person.tap()
                settle()
                keep("11 Person page", application)
                application.navigationBars.buttons.element(boundBy: 0).tap()
                settle()
            }
        }

        // Memories, from Collections.
        let collections = application.tabBars.buttons["Collections"].firstMatch
        if collections.waitForExistence(timeout: 5) {
            collections.tap()
            settle()
            keep("12 Collections", application)
            let memories = application.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Memories'")).firstMatch
            if memories.waitForExistence(timeout: 5) {
                memories.tap()
                settle()
                keep("13 Memories", application)
            }
        }

        // Places by name: the countries as the Mac's cards.
        if collections.exists {
            collections.tap()
            settle()
            let places = application.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Places'")).firstMatch
            if places.waitForExistence(timeout: 5) {
                places.tap()
                settle()
                let byName = application.buttons["Places"].firstMatch
                if byName.waitForExistence(timeout: 5) {
                    byName.tap()
                    settle()
                    keep("14 Places", application)
                }
            }
        }

        // The card size back at the smallest, the default.
        albumsTab.tap()
        settle()
        zoomOutFully(application)
    }

    /// The search of People and of Albums, hidden at rest and pulled down into view (CardGrid's `finder`).
    @MainActor
    func testPullDownSearch() throws {
        continueAfterFailure = true
        let application = XCUIApplication()
        // People in the tab bar beside Albums, for this launch alone (the default bar holds Albums alone).
        application.launchArguments = ["-tabBarChoices", "albums,people", "-signInServer", "https://demo.immich.app",
                                       "-signInEmail", "demo@immich.app", "-signInPassword", "demo"]
        application.launch()
        XCTAssertTrue(application.buttons["Select"].waitForExistence(timeout: 45), "the Library shows once signed in")
        for (number, tab, field) in [(1, "People", "Search People"), (3, "Albums", "Search Albums")] {
            let button = application.tabBars.buttons[tab].firstMatch
            guard button.waitForExistence(timeout: 10) else { continue }
            button.tap()
            settle()
            keep("0\(number) \(tab) at rest", application)
            XCTAssertFalse(application.textFields[field].isHittable, "the search field is hidden at rest")
            let scroll = application.collectionViews.firstMatch
            scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
                .press(forDuration: 0.05, thenDragTo: scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)),
                       withVelocity: .slow, thenHoldForDuration: 0.2)
            settle()
            keep("0\(number + 1) \(tab) pulled down", application)
            XCTAssertTrue(application.textFields[field].isHittable, "the search field shows once pulled down")
        }
    }

    /// Lets thumbnails and transitions finish before a screenshot.
    private func settle() {
        Thread.sleep(forTimeInterval: 2.5)
    }

    /// Opens the page's View Options; false where the page has none.
    @MainActor
    private func openViewOptions(_ application: XCUIApplication) -> Bool {
        let viewOptions = application.buttons["View Options"].firstMatch
        guard viewOptions.waitForExistence(timeout: 5) else { return false }
        viewOptions.tap()
        settle()
        return true
    }

    /// Sections by year, from View Options' Sections, the default where nothing else was chosen.
    @MainActor
    private func chooseYearSections(_ application: XCUIApplication) {
        guard openViewOptions(application) else { return }
        let sections = application.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Sections'")).firstMatch
        guard sections.exists else {
            tapTitleArea(application)
            return
        }
        sections.tap()
        settle()
        let year = application.buttons["Year"].firstMatch
        if year.exists { year.tap() } else { tapTitleArea(application) }
        settle()
    }

    /// Zoom Out from View Options until the cards are at the page's smallest.
    @MainActor
    private func zoomOutFully(_ application: XCUIApplication) {
        for _ in 0..<5 {
            guard openViewOptions(application) else { return }
            let zoomOut = application.buttons["Zoom Out"].firstMatch
            guard zoomOut.exists, zoomOut.isEnabled else {
                tapTitleArea(application)
                return
            }
            zoomOut.tap()
            settle()
        }
    }

    /// Closes a menu by a tap where nothing else answers: the title's area.
    @MainActor
    private func tapTitleArea(_ application: XCUIApplication) {
        application.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.06)).tap()
        settle()
    }

    @MainActor
    private func keep(_ name: String, _ application: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: application.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
