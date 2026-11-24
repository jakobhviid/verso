// A Live Photo in Verso's viewer, walked against a lab server whose newest photo is a Live Photo of today, made as the
// Camera makes one (ios/tools/live/make-pair.swift: three seconds of a lab video, its key photo at 2.0 s), in the steps
// PhotosReferenceTests takes in Photos with the same Live Photo, so a recording of each (ios/tools/live/record.sh) is
// read against the other (track.swift): open it and wait, swipe to the photo before it and back, hold it; then switch LIVE off, swipe away
// and back and hold it again; then relaunch, where OFF is kept, and switch it on, which plays nothing. The server's
// address and key reach it only through the test run's environment (IMMICH_URL and IMMICH_API_KEY, as TEST_RUNNER_
// variables), never as launch arguments.

import XCTest

final class LiveWalkTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    @MainActor
    func testLivePhoto() throws {
        let application = try launchSignedIn()
        mark("open")
        openTodaysPhoto(application)
        let badge = application.buttons["viewer.live"].firstMatch
        XCTAssertTrue(badge.waitForExistence(timeout: 15), "the Live Photo has its LIVE badge")
        if (badge.value as? String) == "Off" { badge.tap() }
        Thread.sleep(forTimeInterval: 4)
        let window = application.windows.firstMatch
        mark("swipe away")
        window.swipeRight()
        Thread.sleep(forTimeInterval: 2)
        mark("swipe back")
        window.swipeLeft()
        Thread.sleep(forTimeInterval: 4)
        mark("hold")
        window.press(forDuration: 3.5)
        Thread.sleep(forTimeInterval: 2)

        badge.tap()
        XCTAssertEqual(badge.value as? String, "Off", "the badge switches it off")
        mark("off, swipe away")
        window.swipeRight()
        Thread.sleep(forTimeInterval: 2)
        mark("off, swipe back")
        window.swipeLeft()
        Thread.sleep(forTimeInterval: 4)
        mark("off, hold")
        window.press(forDuration: 3.5)
        Thread.sleep(forTimeInterval: 2)

        application.terminate()
        let again = try launchSignedIn()
        openTodaysPhoto(again)
        let badgeAgain = again.buttons["viewer.live"].firstMatch
        XCTAssertTrue(badgeAgain.waitForExistence(timeout: 15))
        XCTAssertEqual(badgeAgain.value as? String, "Off", "off is kept on the device")
        mark("switch on")
        badgeAgain.tap()
        XCTAssertEqual(badgeAgain.value as? String, "On", "the badge switches it on")
        Thread.sleep(forTimeInterval: 4)
        keep("switched on", again)
    }

    /// Verso Dev signed in to the lab server from the run's environment, in the Library.
    @MainActor
    private func launchSignedIn() throws -> XCUIApplication {
        let environment = ProcessInfo.processInfo.environment
        guard let server = environment["IMMICH_URL"], let key = environment["IMMICH_API_KEY"] else {
            throw XCTSkip("needs a lab server: IMMICH_URL and IMMICH_API_KEY in the run's environment")
        }
        XCTAssertFalse(server.contains("demo.immich.app"), "never Immich's demo")
        let application = XCUIApplication()
        application.launchEnvironment = ["VERSO_SIGN_IN_SERVER": server, "VERSO_SIGN_IN_API_KEY": key]
        application.launch()
        XCTAssertTrue(application.buttons["Select"].waitForExistence(timeout: 60), "the Library shows once signed in")
        Thread.sleep(forTimeInterval: 2)
        return application
    }

    /// The Library's photo taken today: the motion photo, its newest.
    @MainActor
    private func openTodaysPhoto(_ application: XCUIApplication) {
        let today = Date.now.formatted(.dateTime.day().month(.wide).year())
        let tile = application.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Photo' AND label CONTAINS %@", today)).firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 20), "today's photo is in the Library (\(today))")
        tile.tap()
        XCTAssertTrue(application.buttons["Photo Title"].firstMatch.waitForExistence(timeout: 15), "the photo opens")
    }

    /// When a step starts, in the test's log, to read a recording against.
    private func mark(_ step: String) {
        print("REFERENCE \(step) at \(Date.now.timeIntervalSince1970)")
    }

    @MainActor
    private func keep(_ name: String, _ application: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: application.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
