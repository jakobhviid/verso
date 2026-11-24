// The Shared Links page's cards, walked against a lab server, whose admin has a link to an album and one to chosen
// photos (lab/immich-server/showcase.sh; Immich's demo has none): each card opened, the cards one size up, and a
// card's long press, after which a card still opens. It only looks. The server's address and key reach it only through the test
// run's environment (IMMICH_URL and IMMICH_API_KEY, as TEST_RUNNER_ variables), never as launch arguments:
//   tools/mac.sh <name> walk SharedLinksWalkTests <env file> IMMICH_API_KEY_FULL

import XCTest

final class SharedLinksWalkTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    @MainActor
    func testCards() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let server = environment["IMMICH_URL"], let key = environment["IMMICH_API_KEY"] else {
            throw XCTSkip("needs a lab server: tools/mac.sh <name> walk SharedLinksWalkTests <env file> <key variable>")
        }
        XCTAssertFalse(server.contains("demo.immich.app"), "never Immich's demo")
        let application = XCUIApplication()
        // Shared Links in the tab bar, for this launch alone.
        application.launchArguments = ["-tabBarChoices", "sharedLinks"]
        application.launchEnvironment = ["VERSO_SIGN_IN_SERVER": server, "VERSO_SIGN_IN_API_KEY": key]
        application.launch()
        XCTAssertTrue(application.buttons["Select"].waitForExistence(timeout: 60), "the Library shows once signed in")

        let tab = application.tabBars.buttons["Shared Links"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 10), "Shared Links is in the tab bar")
        tab.tap()
        settle()
        // The cards at their smallest, as an earlier run may have left them larger.
        let options = application.buttons["View Options"].firstMatch
        XCTAssertTrue(options.waitForExistence(timeout: 10))
        for _ in 0..<4 {
            options.tap()
            let zoomOut = application.buttons["Zoom Out"].firstMatch
            guard zoomOut.waitForExistence(timeout: 5), zoomOut.isEnabled else {
                application.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)).tap()
                break
            }
            zoomOut.tap()
            settle()
        }
        settle()
        keep("01 Shared Links, smallest", application)

        // Each card opens what its link shares: an album's link the album, a link to chosen photos the link's page.
        let cards = application.buttons.matching(NSPredicate(format: "value CONTAINS 'Anyone' OR value CONTAINS 'Visitors'"))
        XCTAssertTrue(cards.firstMatch.waitForExistence(timeout: 10), "the links show as cards")
        XCTAssertGreaterThanOrEqual(cards.count, 2, "both links show as cards")
        for index in 0..<min(cards.count, 2) {
            let card = cards.element(boundBy: index)
            let name = card.label
            let frame = card.frame
            card.tap()
            settle()
            keep("0\(2 + index) \(name) opened, tapped at \(Int(frame.midX)),\(Int(frame.midY)) in \(Int(frame.width))x\(Int(frame.height))", application)
            let back = application.navigationBars.buttons.element(boundBy: 0)
            if back.exists { back.tap() }
            settle()
        }

        // One size up, through View Options' Zoom In.
        if options.waitForExistence(timeout: 5) {
            options.tap()
            let zoomIn = application.buttons["Zoom In"].firstMatch
            if zoomIn.waitForExistence(timeout: 5) {
                keep("04 View Options", application)
                zoomIn.tap()
            }
            settle()
            keep("05 Shared Links, one size up", application)
        }

        // A card's long press.
        XCTAssertTrue(application.buttons["Share Link"].firstMatch.waitForExistence(timeout: 10), "a card has Share Link")
        cards.element(boundBy: 0).press(forDuration: 1.2)
        settle()
        keep("06 A card's long press", application)
        // A tap on the dimmed page beside the menu closes it (the status bar's top does not).
        application.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.6)).tap()
        settle()
        keep("07 The long press closed", application)

        // A card still opens after a long press: a tap where it shows.
        let first = cards.element(boundBy: 0)
        let name = first.label
        first.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).tap()
        settle()
        keep("08 \(name) opened after a long press", application)
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
