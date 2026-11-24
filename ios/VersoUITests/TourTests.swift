// A walk through Verso as a person takes it, keeping a screenshot of each place: the Library, its View Options, a
// photo, its "..." menu, its details, Collections and the account. It signs Verso Dev in to Immich's demo with the
// launch arguments a script uses (AppModel.followLaunchArguments). The screenshots stay in the test's result bundle:
//   xcodebuild test -only-testing:VersoUITests/TourTests -resultBundlePath build/tour.xcresult ...
//   xcrun xcresulttool export attachments --path build/tour.xcresult --output-path build/tour

import XCTest

final class TourTests: XCTestCase {
    @MainActor
    func testTour() throws {
        continueAfterFailure = true
        let application = XCUIApplication()
        application.launchArguments = ["-signInServer", "https://demo.immich.app",
                                       "-signInEmail", "demo@immich.app", "-signInPassword", "demo"]
        application.launch()

        XCTAssertTrue(application.buttons["Select"].waitForExistence(timeout: 45), "the Library shows once signed in")
        settle()
        keep("01 Library", application)

        let viewOptions = application.buttons["View Options"].firstMatch
        if viewOptions.waitForExistence(timeout: 5) {
            viewOptions.tap()
            settle()
            keep("02 Library View Options", application)
            tapTitleArea(application)
        }

        // The newest photos are at the bottom of the Library, above the tab bar.
        application.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.72)).tap()
        let back = application.buttons["Back"].firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 15), "a photo opens from its tile")
        settle()
        keep("03 Photo", application)

        let more = application.buttons["More"].firstMatch
        if more.waitForExistence(timeout: 5) {
            more.tap()
            settle()
            keep("04 Photo More", application)
            tapTitleArea(application)
        }

        application.windows.firstMatch.swipeUp()
        settle()
        keep("05 Photo Details", application)
        application.windows.firstMatch.swipeUp()
        settle()
        keep("06 Photo Details Further", application)
        application.windows.firstMatch.swipeDown()
        settle()
        if back.exists { back.tap() }

        let collections = application.tabBars.buttons["Collections"].firstMatch
        if collections.waitForExistence(timeout: 10) {
            collections.tap()
            settle()
            keep("07 Collections", application)
            let account = application.buttons["Account"].firstMatch
            if account.waitForExistence(timeout: 5) {
                account.tap()
                settle()
                keep("08 Account", application)
            }
        }
    }

    /// Lets thumbnails and transitions finish before a screenshot.
    private func settle() {
        Thread.sleep(forTimeInterval: 2.5)
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
