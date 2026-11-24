// A walk through the Library as a person takes it, keeping a screenshot of each state of its top and bottom bars: the
// newest end, scrolled back with Years, Months and All beside the shrunk tab bar, a tap on the shrunk tab and on the
// tab again, Years and Months, a month's photo opening All at it, View Options with Captured by Me, a filter and the
// sort changed and back, and selecting. It signs Verso Dev in to Immich's demo as TourTests does, and only reads there:
// the filters and the sort are this device's, and Library View, which writes partners' "Show in timeline", is never
// touched. It leaves the Library as it found it, All Items by the date captured in All, since the Simulator is shared.

import XCTest

final class LibraryWalkTests: XCTestCase {
    @MainActor
    func testLibraryWalk() throws {
        continueAfterFailure = true
        let application = XCUIApplication()
        application.launchArguments = ["-signInServer", "https://demo.immich.app",
                                       "-signInEmail", "demo@immich.app", "-signInPassword", "demo"]
        application.launch()
        XCTAssertTrue(application.buttons["Select"].waitForExistence(timeout: 45), "the Library shows once signed in")
        let window = application.windows.firstMatch
        settle()
        keep("01 Newest end", application)

        drag(window, from: 0.4, to: 0.55)
        settle()
        keep("02 Dragged back a little", application)
        window.swipeDown()
        settle()
        keep("02 Scrolled back", application)
        drag(window, from: 0.6, to: 0.48)
        settle()
        keep("03 A little forward", application)
        window.swipeUp()
        settle()
        keep("04 Flung forward", application)

        window.swipeDown()
        settle()
        let library = application.tabBars.buttons["Library"].firstMatch
        library.tap()
        settle()
        keep("05 Shrunk tab tapped", application)
        library.tap()
        settle()
        keep("06 Library tab tapped again", application)

        window.swipeDown()
        settle()
        choose(application, "Years")
        keep("07 Years", application)
        window.swipeDown()
        settle()
        keep("08 Years scrolled back", application)
        choose(application, "Months")
        keep("09 Months", application)
        window.swipeDown()
        settle()
        keep("09 Months scrolled back", application)
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.45)).tap()
        settle()
        keep("10 A month's photo picked", application)
        application.tabBars.buttons["Library"].firstMatch.tap()
        settle()
        keep("11 Library tab tapped after the month", application)

        window.swipeDown()
        settle()
        application.buttons["View Options"].firstMatch.tap()
        settle()
        keep("12 View Options", application)
        tap(application, "Favorites")
        settle()
        keep("13 Favorites", application)
        application.buttons["View Options"].firstMatch.tap()
        settle()
        tap(application, "All Items")
        settle()
        keep("14 All Items again", application)

        window.swipeDown()
        settle()
        application.buttons["View Options"].firstMatch.tap()
        settle()
        tap(application, "Added")
        settle()
        keep("15 Added", application)
        application.buttons["View Options"].firstMatch.tap()
        settle()
        tap(application, "Captured")
        settle()
        keep("16 Captured again", application)

        application.buttons["View Options"].firstMatch.tap()
        settle()
        tap(application, "Captured by Me")
        settle()
        keep("17 Captured by Me", application)
        application.buttons["View Options"].firstMatch.tap()
        settle()
        keep("17 Captured by Me checked", application)
        tap(application, "All Items")
        settle()

        application.buttons["Select"].firstMatch.tap()
        settle()
        drag(window, from: 0.4, to: 0.4, fromX: 0.15, toX: 0.85)
        settle()
        keep("18 Selecting", application)
        application.buttons["Cancel"].firstMatch.tap()
        settle()
        keep("19 Done selecting", application)
    }

    /// A page pushed onto a tab keeps its title large, under the back button, as the photos scroll under it.
    @MainActor
    func testPushedPageTitle() throws {
        continueAfterFailure = true
        let application = XCUIApplication()
        application.launchArguments = ["-signInServer", "https://demo.immich.app",
                                       "-signInEmail", "demo@immich.app", "-signInPassword", "demo"]
        application.launch()
        XCTAssertTrue(application.buttons["Select"].waitForExistence(timeout: 45), "the Library shows once signed in")
        let window = application.windows.firstMatch
        application.tabBars.buttons["Collections"].firstMatch.tap()
        settle()
        var page: XCUIElement?
        for _ in 0..<4 {
            page = ["Archive", "Recently Deleted", "Large Files"].lazy.map { application.buttons[$0].firstMatch }
                .first { $0.exists && $0.isHittable }
            if page != nil { break }
            window.swipeUp()
            settle()
        }
        guard let page else {
            keep("20 No page to push", application)
            return XCTFail("Collections offers none of Archive, Recently Deleted, Large Files")
        }
        let name = page.label
        page.tap()
        settle()
        keep("20 A page pushed", application)
        // Archive and Recently Deleted open at their newest photos at the bottom, Large Files at the top.
        if name == "Large Files" { window.swipeUp() } else { window.swipeDown() }
        settle()
        keep("21 A page pushed scrolled", application)
        application.navigationBars.buttons.firstMatch.tap()
        settle()
        let library = application.tabBars.buttons["Library"].firstMatch
        if library.exists { library.tap() }
    }

    /// Chooses a segment of Years, Months and All, and records whether it took a second tap.
    @MainActor
    private func choose(_ application: XCUIApplication, _ segment: String) {
        let button = application.buttons[segment].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5), "\(segment) is offered")
        button.tap()
        settle()
        if !button.isSelected {
            keep("\(segment) not chosen by the first tap", application)
            button.tap()
            settle()
        }
        XCTAssertTrue(button.isSelected, "\(segment) is chosen")
    }

    /// Taps a control by its name: a button, a menu's toggle, or a segment.
    @MainActor
    private func tap(_ application: XCUIApplication, _ name: String) {
        for query in [application.buttons, application.switches, application.staticTexts] {
            let element = query[name].firstMatch
            if element.exists {
                element.tap()
                return
            }
        }
        XCTFail("no control named \(name)")
    }

    /// A finger dragged slowly from one point of the window to another, as fractions of its size.
    @MainActor
    private func drag(_ window: XCUIElement, from start: CGFloat, to end: CGFloat, fromX: CGFloat = 0.5, toX: CGFloat = 0.5) {
        window.coordinate(withNormalizedOffset: CGVector(dx: fromX, dy: start))
            .press(forDuration: 0.01, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: toX, dy: end)),
                   withVelocity: XCUIGestureVelocity(250), thenHoldForDuration: 0.3)
    }

    /// Lets thumbnails and transitions finish before a screenshot.
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
