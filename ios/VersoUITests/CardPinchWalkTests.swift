// A card page's pinch between card sizes, recorded to set beside Photos' grid pinch between zoom levels
// (PhotosReferenceTests.testGridPinch): Albums on Immich's demo, read only, from the smallest size pinched open two
// sizes, each step marked for the recording, and left at the smallest.
//   ios/tools/live/record.sh CardPinchWalkTests

import XCTest

final class CardPinchWalkTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    @MainActor
    func testAlbumsPinch() throws {
        let application = XCUIApplication()
        application.launchArguments = ["-tabBarChoices", "albums,people", "-signInServer", "https://demo.immich.app",
                                       "-signInEmail", "demo@immich.app", "-signInPassword", "demo"]
        application.launch()
        XCTAssertTrue(application.buttons["Select"].waitForExistence(timeout: 45), "the Library shows once signed in")
        let albumsTab = application.tabBars.buttons["Albums"].firstMatch
        XCTAssertTrue(albumsTab.waitForExistence(timeout: 10), "Albums is in the tab bar")
        albumsTab.tap()
        Thread.sleep(forTimeInterval: 4)
        let page = application.collectionViews.firstMatch
        // To the smallest size with View Options' Zoom Out, which zooms about the middle of the view (a pinch closing
        // from fingers this far apart lands a finger on a bar).
        let title = application.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.06))
        let zoomOut = application.buttons["Zoom Out"].firstMatch
        for step in ["zoom out 1", "zoom out 2", "zoom out 3", "zoom out 4"] {
            let viewOptions = application.buttons["View Options"].firstMatch
            guard viewOptions.waitForExistence(timeout: 5) else { break }
            viewOptions.tap()
            Thread.sleep(forTimeInterval: 1)
            let more = zoomOut.exists && zoomOut.isEnabled
            if more {
                mark(step)
                zoomOut.tap()
                Thread.sleep(forTimeInterval: 2)
            }
            // The menu stays open after a Zoom Out; a tap on the title closes it.
            if zoomOut.exists {
                title.tap()
                Thread.sleep(forTimeInterval: 1)
            }
            if !more { break }
        }
        XCTAssertFalse(zoomOut.exists, "View Options is closed")
        keep("smallest", application)
        for step in ["open 1", "open 2"] {
            mark(step)
            page.pinch(withScale: 1.8, velocity: 1.5)
            Thread.sleep(forTimeInterval: 2)
            keep(step, application)
        }
        // The card size back at the smallest, the default, as AlbumsWalkTests leaves it and expects it.
        for _ in 0..<4 {
            application.buttons["View Options"].firstMatch.tap()
            Thread.sleep(forTimeInterval: 1)
            let more = zoomOut.exists && zoomOut.isEnabled
            if more {
                zoomOut.tap()
                Thread.sleep(forTimeInterval: 1.5)
            }
            if zoomOut.exists {
                title.tap()
                Thread.sleep(forTimeInterval: 1)
            }
            if !more { break }
        }
    }

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
