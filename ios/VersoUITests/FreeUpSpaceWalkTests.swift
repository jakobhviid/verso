// A walk through Free Up Space against a lab server (never Immich's demo), keeping a screenshot of each place: the
// Backup page's Space on This iPhone with Always Keep, Keep on This iPhone chosen (and the question on what deleting
// means, the first time), the Library's card, its Review opening the review itself, each photo checked with Immich,
// Delete, and iOS's own question answered Don't Allow, after which nothing has changed; then Forever again, and the
// Library's card for a phone short of space, leading to Space on This iPhone. Nothing is ever deleted. The server's
// address and an API key reach it only through the test run's environment, as for BackupWalkTests; the photos are aged
// by when they were taken (VERSO_FREE_UP_BY_TAKEN), as a Simulator's were all added lately, the cards come for a few
// megabytes (VERSO_FREE_UP_WORTH) whatever an earlier run said to them (VERSO_FREE_UP_CARDS_AFRESH), and the phone
// counts as short of space (VERSO_LOW_ON_SPACE). It needs the account backed up, as BackupWalkTests leaves it.

import XCTest

final class FreeUpSpaceWalkTests: XCTestCase {
    @MainActor
    func testReviewAndDontAllow() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let server = environment["IMMICH_URL"], let key = environment["IMMICH_API_KEY"] else {
            throw XCTSkip("needs a lab server: tools/mac.sh <name> walk FreeUpSpaceWalkTests <env file> <key variable>")
        }
        XCTAssertFalse(server.contains("demo.immich.app"), "never Immich's demo")
        let application = XCUIApplication()
        application.launchEnvironment = ["VERSO_SIGN_IN_SERVER": server, "VERSO_SIGN_IN_API_KEY": key,
                                         "VERSO_FREE_UP_BY_TAKEN": "1", "VERSO_FREE_UP_WORTH": "1",
                                         "VERSO_FREE_UP_CARDS_AFRESH": "1", "VERSO_LOW_ON_SPACE": "1"]
        application.launch()
        defer { finish(application) }
        XCTAssertTrue(application.buttons["Select"].waitForExistence(timeout: 60), "the Library shows once signed in")
        settle()

        openBackup(application)
        let backUpNow = application.buttons["Back Up Now"].firstMatch
        XCTAssertTrue(backUpNow.waitForExistence(timeout: 180), "backing up goes on from its first run")
        XCTAssertTrue(waitForLabel(application, "Backed up", timeout: 240), "everything in Immich")
        keep("01 Backup page", application)

        // Keep on This iPhone: 1 Month, asking first what deleting means where it was not yet understood.
        let keepPicker = application.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Keep on This iPhone'")).firstMatch
        scrollTo(keepPicker, in: application)
        XCTAssertTrue(application.buttons["Always Keep"].firstMatch.exists, "what stays, by its name")
        keep("02 Space on This iPhone", application)
        keepPicker.tap()
        settle()
        application.buttons["1 Month"].firstMatch.tap()
        settle()
        let understood = application.buttons["Keep 1 Month on This iPhone"].firstMatch
        if understood.waitForExistence(timeout: 3) {
            keep("03 What deleting means", application)
            understood.tap()
            settle()
        }
        XCTAssertTrue(application.buttons["Review and Free Up"].firstMatch.waitForExistence(timeout: 60),
                      "photos old enough to free, safe in Immich")
        keep("04 Ready to free", application)

        // The Library's card, whose Review opens the review itself.
        closeSheets(application)
        application.tabBars.buttons["Library"].firstMatch.tap()
        settle()
        let reviewOnCard = application.buttons["Review"].firstMatch
        XCTAssertTrue(reviewOnCard.waitForExistence(timeout: 30), "the card says what is ready to free")
        keep("05 The Library's card", application)
        reviewOnCard.tap()

        // The review: what Always Keep keeps, each photo checked with Immich, then Delete, which iOS asks about.
        let delete = application.buttons["Delete from This iPhone"].firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 30))
        XCTAssertTrue(application.buttons["Change Always Keep"].firstMatch.exists, "what stays, said on the review")
        let deadline = Date().addingTimeInterval(120)
        while !delete.isEnabled && Date() < deadline { Thread.sleep(forTimeInterval: 1) }
        XCTAssertTrue(delete.isEnabled, "every photo checked")
        keep("06 The review", application)
        let label = delete.label
        delete.tap()
        XCTAssertTrue(tapSystemAlert(["Don't Allow", "Don’t Allow"], timeout: 30), "iOS asks before anything is deleted")
        settle()
        keep("07 After Don't Allow", application)
        XCTAssertTrue(delete.waitForExistence(timeout: 10), "still on the review: nothing deleted")
        XCTAssertEqual(delete.label, label, "the same photos, all still here")

        // Forever again, as the walk found it.
        application.navigationBars.buttons.element(boundBy: 0).tap()
        settle()
        scrollTo(keepPicker, in: application)
        keepPicker.tap()
        settle()
        application.buttons["Forever"].firstMatch.tap()
        settle()
        keep("08 Forever again", application)

        // Forever on a phone short of space: the Library's card, leading to Space on This iPhone.
        closeSheets(application)
        let freeUpOnCard = application.buttons["Free Up Space"].firstMatch
        XCTAssertTrue(freeUpOnCard.waitForExistence(timeout: 30), "the card says the phone is short of space")
        keep("09 Short of space", application)
        freeUpOnCard.tap()
        settle()
        XCTAssertTrue(waitForLabel(application, "This iPhone is short of space", timeout: 10), "said where the period is chosen")
        keep("10 Space on This iPhone", application)
        closeSheets(application)
    }

    // MARK: Steps

    /// The Backup page from the account's sheet, backing up switched on there if it was off.
    @MainActor
    private func openBackup(_ application: XCUIApplication) {
        application.tabBars.buttons["Collections"].firstMatch.tap()
        settle()
        application.buttons["Account"].firstMatch.tap()
        settle()
        let page = application.buttons["Backup Page"].firstMatch
        scrollTo(page, in: application)
        page.tap()
        settle()
        let turnOn = application.buttons["Turn On Backup"].firstMatch
        if turnOn.waitForExistence(timeout: 5) {
            turnOn.tap()
            _ = tapSystemAlert(["Allow"], timeout: 5)
            settle()
        }
    }

    /// Back from the Backup page where it was pushed, and its sheet closed.
    @MainActor
    private func closeSheets(_ application: XCUIApplication) {
        let back = application.navigationBars.buttons.element(boundBy: 0)
        if back.exists && back.label != "Close" { back.tap(); settle() }
        let close = application.buttons["Close"].firstMatch
        if close.waitForExistence(timeout: 3) { close.tap(); settle() }
    }

    /// Signs Verso Dev out by the launch argument, which switches backing up off too.
    @MainActor
    private func finish(_ application: XCUIApplication) {
        application.terminate()
        let cleaning = XCUIApplication()
        cleaning.launchArguments = ["-signOut", "YES"]
        cleaning.launch()
        Thread.sleep(forTimeInterval: 10)
        cleaning.terminate()
    }

    @MainActor
    private func waitForLabel(_ application: XCUIApplication, _ label: String, timeout: TimeInterval) -> Bool {
        let text = application.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", label)).firstMatch
        return text.waitForExistence(timeout: timeout)
    }

    @MainActor
    private func scrollTo(_ element: XCUIElement, in application: XCUIApplication) {
        var tries = 0
        while !(element.exists && element.isHittable) && tries < 8 {
            application.swipeUp()
            tries += 1
        }
    }

    @MainActor
    private func tapSystemAlert(_ labels: [String], timeout: TimeInterval) -> Bool {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            for label in labels {
                for source in [springboard, XCUIApplication()] {
                    let button = source.alerts.buttons[label].firstMatch
                    if button.exists {
                        button.tap()
                        return true
                    }
                }
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return false
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
