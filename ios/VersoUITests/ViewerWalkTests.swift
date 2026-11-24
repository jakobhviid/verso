// A walk through the viewer's place names, editing, rating and stack, keeping a screenshot of each, read-only on
// Immich's demo: the newest photos there include a stack of three at Monterosso al Mare, whose cover the walk opens.
// The photo's title names Immich's place; its stack's sheet opens and closes; the editor opens, turns and crops the
// picture on screen alone, and is cancelled, so nothing is written; the details show the rating where the demo
// account has ratings on, and the map; the account's sheet shows Look Up Place Names with Apple Maps. A second walk
// switches that on for its launch alone (a launch argument, which no setting keeps) and keeps the title Apple names.
//   xcodebuild test -only-testing:VersoUITests/ViewerWalkTests -resultBundlePath build/walk.xcresult ...

import XCTest

final class ViewerWalkTests: XCTestCase {
    /// Signed in to the demo, the Library three a row, where the photo opened near its newest end is a few photos from
    /// the one this walk looks for.
    private static let signIn = ["-signInServer", "https://demo.immich.app",
                                 "-signInEmail", "demo@immich.app", "-signInPassword", "demo", "-grid.zoom", "0"]

    @MainActor
    func testViewerWalk() throws {
        continueAfterFailure = true
        let application = XCUIApplication()
        application.launchArguments = Self.signIn
        application.launch()
        openNewestStack(application)
        let title = application.buttons["Photo Title"].firstMatch
        XCTAssertTrue(title.label.contains("Monterosso al Mare"), "the title names Immich's place: \(title.label)")
        keep("01 Photo with Immich's place", application)

        let stack = application.buttons["Stack"].firstMatch
        if stack.waitForExistence(timeout: 5) {
            stack.tap()
            settle()
            keep("02 Stack", application)
            let close = application.buttons["Close"].firstMatch
            if close.waitForExistence(timeout: 5) { close.tap() }
            settle()
        } else {
            XCTFail("the stacked photo shows its stack's badge")
        }

        let edit = application.buttons["Edit"].firstMatch
        if edit.waitForExistence(timeout: 5), edit.isEnabled {
            edit.tap()
            settle()
            keep("03 Edit", application)
            application.buttons["Rotate Right"].firstMatch.tap()
            settle()
            keep("04 Edit turned", application)
            // The crop frame's left side, along the picture's left edge, dragged in.
            let window = application.windows.firstMatch
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.055, dy: 0.5))
                .press(forDuration: 0.2, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)))
            settle()
            keep("05 Edit cropped", application)
            application.buttons["Cancel Edit"].firstMatch.tap()
            settle()
            keep("06 Edit cancelled", application)
        } else {
            XCTFail("Edit opens the editor for the demo's own photo")
        }

        application.windows.firstMatch.swipeUp()
        settle()
        keep("07 Details with the rating", application)
        application.windows.firstMatch.swipeUp()
        settle()
        keep("08 Details further", application)
        application.windows.firstMatch.swipeDown()
        settle()
        application.windows.firstMatch.swipeDown()
        settle()
        let back = application.buttons["Back"].firstMatch
        if back.exists { back.tap() }
        settle()

        let collections = application.tabBars.buttons["Collections"].firstMatch
        if collections.waitForExistence(timeout: 10) {
            collections.tap()
            settle()
            let account = application.buttons["Account"].firstMatch
            if account.waitForExistence(timeout: 5) {
                account.tap()
                settle()
                let setting = application.switches["Look Up Place Names with Apple Maps"].firstMatch
                for _ in 0..<6 where !(setting.exists && setting.isHittable) {
                    application.swipeUp()
                }
                settle()
                XCTAssertTrue(setting.exists, "the account's sheet has the setting")
                XCTAssertEqual(setting.value as? String, "0", "the setting is off by default")
                keep("09 Account with the setting", application)
            }
        }
    }

    @MainActor
    func testApplePlaceNames() throws {
        continueAfterFailure = true
        let application = XCUIApplication()
        application.launchArguments = Self.signIn + ["-viewer.lookUpPlaceNames", "YES"]
        application.launch()
        openNewestStack(application)
        // Apple's maps answer once the photo has shown for a moment.
        Thread.sleep(forTimeInterval: 5)
        keep("10 Photo with Apple's place", application)
    }

    /// The Library, a photo near its newest end, then the photos beside it until the one taken on 27 April 2025: the
    /// stack at Monterosso al Mare on the demo. A busy demo server gets a few more tries.
    @MainActor
    private func openNewestStack(_ application: XCUIApplication) {
        XCTAssertTrue(application.buttons["Select"].waitForExistence(timeout: 45), "the Library shows once signed in")
        settle()
        let tryAgain = application.buttons["Try Again"].firstMatch
        for _ in 0..<3 where tryAgain.exists {
            Thread.sleep(forTimeInterval: 10)
            tryAgain.tap()
            settle()
        }
        application.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.72)).tap()
        XCTAssertTrue(application.buttons["Back"].firstMatch.waitForExistence(timeout: 15), "a photo opens from its tile")
        settle()
        let title = application.buttons["Photo Title"].firstMatch
        let window = application.windows.firstMatch
        // Newer photos are to the right, older to the left.
        for step in 0..<12 where !title.label.contains("27 April 2025") {
            if step < 4 { window.swipeLeft() } else { window.swipeRight() }
            Thread.sleep(forTimeInterval: 1.5)
        }
        XCTAssertTrue(title.label.contains("27 April 2025"), "the stacked photo of 27 April 2025 is found")
        settle()
    }

    /// Lets pictures and transitions finish before a screenshot.
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
