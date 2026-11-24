// Whether the viewer takes a tap as soon as the photo has landed, opening and closing: Back at set times after a tile
// opens its photo, and another tile at set times after Back, which is never lost (ARCHITECTURE.md, "The viewer on the
// iPhone"). XCUITest waits for an idle app before every event, which
// waits the zoom out and hides what a person meets, so this bundle switches that wait off (a private method of
// XCTest's; the tests skip where it is missing). Immich's demo, read only; with the screen recorded, the REFERENCE marks
// find each tap in the recording:
//   ios/tools/live/record.sh ViewerResponsivenessTests

import ObjectiveC
import XCTest

final class ViewerResponsivenessTests: XCTestCase {
    /// Seconds after the tap that opens or closes; UIKit's zoom declares 0.34 s.
    private static let delays: [TimeInterval] = [0.3, 0.45, 0.6, 0.8, 1.0, 1.3]


    override func setUpWithError() throws {
        continueAfterFailure = true
        guard IdleWait.off else { throw XCTSkip("this XCTest waits for an idle app another way") }
    }

    /// One photo opened and closed at rest, for the recording: how the controls come and go, against Photos'
    /// (PhotosReferenceTests.testOpenAndClose).
    @MainActor
    func testOpenAndCloseAtRest() throws {
        let application = launch()
        let window = application.windows.firstMatch
        mark("open at rest")
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.7)).tap()
        Thread.sleep(forTimeInterval: 2.5)
        mark("close at rest")
        window.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 42, dy: 84)).tap()
        Thread.sleep(forTimeInterval: 2.5)
    }

    /// A drag down closes the viewer into the tile, and a short one lets the photo spring back, as in Photos.
    @MainActor
    func testDragDownToClose() throws {
        let application = launch()
        let window = application.windows.firstMatch
        let viewer = application.descendants(matching: .any)["Viewer"].firstMatch
        let tile = window.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.7))
        tile.tap()
        XCTAssertTrue(viewer.waitForExistence(timeout: 10), "a photo opens from its tile")
        Thread.sleep(forTimeInterval: 1.5)
        let middle = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
        mark("short drag")
        middle.press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)),
                     withVelocity: 200, thenHoldForDuration: 0.3)
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertTrue(viewer.exists, "a short drag lets the photo spring back")
        mark("long drag")
        middle.press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.8)),
                     withVelocity: 600, thenHoldForDuration: 0.1)
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertFalse(viewer.exists, "a long drag down closes the viewer")
    }

    /// A pinch below the photo's fitted size closes the viewer into the tile, as in Photos and on the Mac. (A pinch small
    /// enough to grow back is under what XCUITest can make on a photo this size.)
    @MainActor
    func testPinchToClose() throws {
        let application = launch()
        let window = application.windows.firstMatch
        let viewer = application.descendants(matching: .any)["Viewer"].firstMatch
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.7)).tap()
        XCTAssertTrue(viewer.waitForExistence(timeout: 10), "a photo opens from its tile")
        Thread.sleep(forTimeInterval: 1.5)
        // On the photo, so neither finger lands on a bar.
        let photo = application.images["Viewer Photo"].firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 5), "the photo shows")
        mark("pinch")
        photo.pinch(withScale: 0.45, velocity: -1.5)
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertFalse(viewer.exists, "a pinch to under 0.8 of the photo closes the viewer")
    }

    /// A photo opened, then Back pressed where it stands: the viewer closes.
    @MainActor
    func testBackRightAfterOpen() throws {
        let application = launch()
        let window = application.windows.firstMatch
        let tile = window.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.7))
        let back = application.buttons["Back"].firstMatch
        let viewer = application.descendants(matching: .any)["Viewer"].firstMatch
        tile.tap()
        XCTAssertTrue(back.waitForExistence(timeout: 10), "a photo opens from its tile")
        Thread.sleep(forTimeInterval: 1.5)
        let backPlace = window.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: back.frame.midX, dy: back.frame.midY))
        back.tap()
        Thread.sleep(forTimeInterval: 2)
        for delay in Self.delays {
            mark("open, Back \(delay) s after")
            tile.tap()
            Thread.sleep(forTimeInterval: delay)
            mark("Back \(delay)")
            backPlace.tap()
            Thread.sleep(forTimeInterval: 2.5)
            let closed = !viewer.exists
            print("RESULT Back \(delay) s after the open: \(closed ? "closed" : "lost")")
            // Back shows as the photo lands, 0.45 s after the zoom starts; a tap takes about 0.4 s to be sent here.
            if delay >= 0.45 { XCTAssertTrue(closed, "Back \(delay) s after the open closes the viewer") }
            if !closed { closeViewer(application) }
        }
    }

    /// Back, then another photo's tile: that photo opens.
    @MainActor
    func testTileRightAfterClose() throws {
        let application = launch()
        let window = application.windows.firstMatch
        let first = window.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.7))
        let second = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
        let back = application.buttons["Back"].firstMatch
        let viewer = application.descendants(matching: .any)["Viewer"].firstMatch
        for delay in Self.delays {
            first.tap()
            XCTAssertTrue(back.waitForExistence(timeout: 10), "a photo opens from its tile")
            Thread.sleep(forTimeInterval: 1.5)
            mark("Back, a tile \(delay) s after")
            back.tap()
            Thread.sleep(forTimeInterval: delay)
            mark("tile \(delay)")
            second.tap()
            let opened = until(3) { back.exists }
            Thread.sleep(forTimeInterval: 1)
            let showing = viewer.exists
            print("RESULT tile \(delay) s after Back: "
                  + (showing ? "opened, Back after \(opened.map { String(format: "%.2f s", $0) } ?? "?")" : "lost"))
            // Tapped while the last photo still closes, it opens once that has closed.
            XCTAssertTrue(showing, "a tile tapped \(delay) s after Back opens its photo")
            if showing { closeViewer(application) }
            Thread.sleep(forTimeInterval: 1.5)
        }
    }

    @MainActor
    private func launch() -> XCUIApplication {
        let application = XCUIApplication()
        application.launchArguments = ["-signInServer", "https://demo.immich.app",
                                       "-signInEmail", "demo@immich.app", "-signInPassword", "demo"]
        application.launch()
        XCTAssertTrue(application.buttons["Select"].waitForExistence(timeout: 60), "the Library shows once signed in")
        // Its photos in, as the first tap needs a tile under it.
        let tiles = application.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'photo-'"))
        XCTAssertTrue(tiles.firstMatch.waitForExistence(timeout: 30), "the Library's photos show")
        Thread.sleep(forTimeInterval: 3)
        return application
    }

    /// Closes a viewer left open, its controls brought back first if a tap hid them.
    @MainActor
    private func closeViewer(_ application: XCUIApplication) {
        let back = application.buttons["Back"].firstMatch
        if !back.exists {
            application.windows.firstMatch.tap()
            Thread.sleep(forTimeInterval: 1)
        }
        if back.exists { back.tap() }
        Thread.sleep(forTimeInterval: 2)
    }

    /// Seconds until the condition holds, polled, or nil after the timeout.
    @MainActor
    private func until(_ timeout: TimeInterval, _ condition: () -> Bool) -> TimeInterval? {
        let start = Date.now
        while Date.now.timeIntervalSince(start) < timeout {
            if condition() { return Date.now.timeIntervalSince(start) }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return nil
    }

    private func mark(_ step: String) {
        print("REFERENCE \(step) at \(Date.now.timeIntervalSince1970)")
    }
}

/// XCUITest's wait for an idle app before each event, switched off for the run (a private method of XCTest's), so a
/// tap lands when a person's would, also while something animates.
enum IdleWait {
    static let off: Bool = {
        guard let process = NSClassFromString("XCUIApplicationProcess") else { return false }
        if let method = class_getInstanceMethod(process, NSSelectorFromString("waitForQuiescenceIncludingAnimationsIdle:isPreEvent:")) {
            let skip: @convention(block) (AnyObject, Bool, Bool) -> Void = { _, _, _ in }
            method_setImplementation(method, imp_implementationWithBlock(skip))
            return true
        }
        if let method = class_getInstanceMethod(process, NSSelectorFromString("waitForQuiescenceIncludingAnimationsIdle:")) {
            let skip: @convention(block) (AnyObject, Bool) -> Void = { _, _ in }
            method_setImplementation(method, imp_implementationWithBlock(skip))
            return true
        }
        return false
    }()
}
