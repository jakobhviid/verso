// A photo's details in Verso's viewer, in the steps PhotosReferenceTests.testDetails takes in Photos, on Immich's demo,
// read only: a photo with a place (the iPhone 15's fireworks in Fulham) shown in the Library and opened, its details
// pulled up, pushed further up twice, pulled back down a little, and the photo beside it swiped to with the details
// up; a screenshot after each, to set beside Photos'.
//   ios/tools/live/record.sh DetailsWalkTests

import XCTest

final class DetailsWalkTests: XCTestCase {
    private static let photo = "75b02044-4bed-4252-993e-44fb76dad79c"

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    @MainActor
    func testDetails() throws {
        let application = XCUIApplication()
        application.launchArguments = ["-signInServer", "https://demo.immich.app", "-signInEmail", "demo@immich.app",
                                       "-signInPassword", "demo", "-showPhoto", Self.photo]
        application.launch()
        let tile = application.descendants(matching: .any)["photo-" + Self.photo]
        XCTAssertTrue(tile.waitForExistence(timeout: 60), "the photo shows in the Library")
        Thread.sleep(forTimeInterval: 2)
        tile.tap()
        XCTAssertTrue(application.buttons["Back"].firstMatch.waitForExistence(timeout: 15), "the photo opens")
        Thread.sleep(forTimeInterval: 2)
        keep("opened", application)
        let window = application.windows.firstMatch
        func drag(_ from: CGFloat, _ to: CGFloat, _ step: String, holding: TimeInterval = 0.4) {
            mark(step)
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: from))
                .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: to)),
                       withVelocity: 500, thenHoldForDuration: holding)
            Thread.sleep(forTimeInterval: 2)
            keep(step, application)
        }
        drag(0.7, 0.4, "details up")
        // Pushed partway and held: the cards and the photo stay where the finger is.
        drag(0.8, 0.7, "pushed and held", holding: 2)
        drag(0.7, 0.8, "back to rest")
        // Held where each kind of drag ends: on the photo, past the cards' end, past their top.
        drag(0.2, 0.1, "photo pushed and held", holding: 2)
        drag(0.85, 0.2, "past the end and held", holding: 2)
        drag(0.5, 0.75, "back to the top")
        drag(0.5, 0.58, "past the top and held", holding: 2)
        drag(0.8, 0.55, "pushed up")
        drag(0.8, 0.5, "pushed further")
        drag(0.8, 0.35, "pushed to the end")
        drag(0.3, 0.6, "pulled back down")
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.15))
            .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.15)),
                   withVelocity: 1500, thenHoldForDuration: 0)
        Thread.sleep(forTimeInterval: 2)
        keep("swiped to the next", application)
    }

    /// When a step starts, in the test's log, to read the recording against.
    private func mark(_ step: String) {
        print("REFERENCE \(step) at \(Date.now.timeIntervalSince1970)")
    }

    /// A screenshot kept with the run's results.
    @MainActor
    private func keep(_ name: String, _ application: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: application.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
