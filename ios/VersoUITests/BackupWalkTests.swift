// A walk through backing the iPhone up against a lab server (never Immich's demo, which may not be written to),
// keeping a screenshot of each place. The server's address and an API key reach it only through the test run's
// environment (IMMICH_URL and IMMICH_API_KEY, as TEST_RUNNER_ variables), and the app gets them in its own
// environment (AppModel.signInFromEnvironment), never as launch arguments:
//   tools/mac.sh <name> photos <folder of photos>                      the Simulator's library, and full access for Verso Dev
//   tools/mac.sh <name> walk BackupWalkTests/testFirstRun <env file> <key variable>
//   (look at the server through its API)
//   tools/mac.sh <name> walk BackupWalkTests/testSecondRun <env file> <key variable>
// The first run opens the Backup page from the Library's card where it shows (else from the account's sheet), switches
// backing up on there, waits for the tally, opens In Immich in Another Form, says Start and waits until everything is
// backed up. The second launches afresh and says Back Up Now, which must find
// everything in Immich and send nothing. Each ends with backing up switched off and Verso Dev signed out, so the shared
// Simulator keeps neither the key nor a backup that another walk's sign-in could start.

import XCTest

final class BackupWalkTests: XCTestCase {
    @MainActor
    func testFirstRun() throws {
        let application = try launchSignedIn()
        defer { finish(application) }
        openBackup(application, switchingOn: true)
        // The first run is once an account: one whose first run happened goes on with Back Up Now (testSecondRun).
        let backUpNow = application.buttons["Back Up Now"]
        let deadline = Date().addingTimeInterval(240)
        var ready = false
        while Date() < deadline && !ready && !backUpNow.exists {
            ready = waitForHeadline(application, "Ready to back up", timeout: 2)
        }
        if !ready && backUpNow.exists {
            throw XCTSkip("this account's first run happened already: testSecondRun, or a fresh lab server")
        }
        XCTAssertTrue(ready, "the first run's tally, before anything goes")
        keep("03 First run's tally", application)
        let anotherForm = application.buttons.containing(NSPredicate(format: "label BEGINSWITH 'In Immich in Another Form'")).firstMatch
        if anotherForm.waitForExistence(timeout: 3) {
            anotherForm.tap()
            settle()
            keep("04 In Immich in another form", application)
            application.navigationBars.buttons.firstMatch.tap()
            settle()
        }
        let start = application.buttons["Start"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        start.tap()
        settle()
        keep("05 Started", application)
        XCTAssertTrue(waitForHeadline(application, "Backed up", timeout: 300), "every photo backed up")
        keep("06 Backed up", application)
        closeSheets(application)
        keep("07 Library after", application)
    }

    @MainActor
    func testSecondRun() throws {
        let application = try launchSignedIn()
        defer { finish(application) }
        openBackup(application, switchingOn: true)
        let backUpNow = application.buttons["Back Up Now"]
        XCTAssertTrue(backUpNow.waitForExistence(timeout: 120), "backing up goes on from the first run")
        keep("08 Second run", application)
        backUpNow.tap()
        settle()
        XCTAssertTrue(waitForHeadline(application, "Backed up", timeout: 240), "nothing left to send")
        keep("09 Second run backed up", application)
        closeSheets(application)
        keep("09 Library after the second run", application)
    }

    /// Immich's public demo is never backed up to: switched on there, the Backup page says so, and nothing is read
    /// from the library for it or sent. Only reads the demo, as the other walks do.
    @MainActor
    func testNotForTheDemo() throws {
        let application = XCUIApplication()
        application.launchArguments = ["-signInServer", "https://demo.immich.app",
                                       "-signInEmail", "demo@immich.app", "-signInPassword", "demo"]
        application.launch()
        defer { finish(application) }
        XCTAssertTrue(application.buttons["Select"].waitForExistence(timeout: 45), "the Library shows once signed in")
        openBackup(application, switchingOn: true)
        XCTAssertTrue(waitForHeadline(application, "Not for Immich's demo", timeout: 20), "the demo is never backed up to")
        keep("11 Not for the demo", application)
    }

    // MARK: Steps

    /// Verso Dev signed in to the lab server from the run's environment.
    @MainActor
    private func launchSignedIn() throws -> XCUIApplication {
        let environment = ProcessInfo.processInfo.environment
        guard let server = environment["IMMICH_URL"], let key = environment["IMMICH_API_KEY"] else {
            throw XCTSkip("needs a lab server: tools/mac.sh <name> walk BackupWalkTests <env file> <key variable>")
        }
        XCTAssertFalse(server.contains("demo.immich.app"), "never Immich's demo")
        let application = XCUIApplication()
        application.launchEnvironment = ["VERSO_SIGN_IN_SERVER": server, "VERSO_SIGN_IN_API_KEY": key]
        application.launch()
        XCTAssertTrue(application.buttons["Select"].waitForExistence(timeout: 60), "the Library shows once signed in")
        settle()
        keep("01 Library", application)
        return application
    }

    /// The Backup page, from the Library's card where it shows (a first sign-in), else from the account's sheet, and
    /// backing up switched on there.
    @MainActor
    private func openBackup(_ application: XCUIApplication, switchingOn: Bool) {
        let setUp = application.buttons["Set Up"].firstMatch
        if setUp.waitForExistence(timeout: 3) {
            keep("02 Library's card", application)
            setUp.tap()
            settle()
        } else {
            let collections = application.tabBars.buttons["Collections"].firstMatch
            XCTAssertTrue(collections.waitForExistence(timeout: 10))
            collections.tap()
            settle()
            let account = application.buttons["Account"].firstMatch
            XCTAssertTrue(account.waitForExistence(timeout: 10))
            account.tap()
            settle()
            let page = application.buttons["Backup Page"].firstMatch
            scrollTo(page, in: application)
            page.tap()
            settle()
        }
        // Every walk ends signed out by the launch argument, which in Verso Dev switches backing up off too. A walk cut
        // short before its sign-out leaves it on (the page's top offers no Turn On Backup): switched off here, at the
        // page's foot, so this walk starts as it expects.
        let turnOn = application.buttons["Turn On Backup"].firstMatch
        let turnOff = application.buttons["Turn Off Backup"].firstMatch
        let isOn = !turnOn.waitForExistence(timeout: 5) && !waitForHeadline(application, "Not for Immich's demo", timeout: 1)
        if isOn {
            print("note: backing up was left on by an earlier walk, and is switched off first")
            scrollTo(turnOff, in: application)
            turnOff.tap()
            settle()
            let confirm = application.buttons.matching(identifier: "Turn Off Backup")
            confirm.element(boundBy: confirm.count - 1).tap()
            settle()
        }
        keep("02 Backup page, off", application)
        if switchingOn && turnOn.waitForExistence(timeout: 5) {
            turnOn.tap()
            allowNotifications()
            settle()
        }
    }

    /// Signs Verso Dev out by the launch argument, which switches backing up off too, so the shared Simulator keeps
    /// neither the key nor a backup.
    @MainActor
    private func finish(_ application: XCUIApplication) {
        application.terminate()
        let cleaning = XCUIApplication()
        cleaning.launchArguments = ["-signOut", "YES"]
        cleaning.launch()
        Thread.sleep(forTimeInterval: 10)
        keep("10 Signed out", cleaning)
        cleaning.terminate()
    }

    /// The Backup page's head, which reads as one element beginning with its headline.
    @MainActor
    private func waitForHeadline(_ application: XCUIApplication, _ headline: String, timeout: TimeInterval) -> Bool {
        let text = application.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", headline)).firstMatch
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if text.exists { return true }
            Thread.sleep(forTimeInterval: 2)
        }
        return text.exists
    }

    /// The system's question about notifications, asked as backing up is switched on.
    @MainActor
    private func allowNotifications() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.alerts.buttons["Allow"].firstMatch
        if allow.waitForExistence(timeout: 5) { allow.tap() }
    }

    @MainActor
    private func scrollTo(_ element: XCUIElement, in application: XCUIApplication) {
        var tries = 0
        while !(element.exists && element.isHittable) && tries < 8 {
            application.swipeUp()
            tries += 1
        }
    }

    /// Back from the Backup page to the account's sheet, and the sheet closed.
    @MainActor
    private func closeSheets(_ application: XCUIApplication) {
        let back = application.navigationBars.buttons.element(boundBy: 0)
        if back.exists { back.tap(); settle() }
        let close = application.buttons["Close"].firstMatch
        if close.waitForExistence(timeout: 3) { close.tap(); settle() }
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
