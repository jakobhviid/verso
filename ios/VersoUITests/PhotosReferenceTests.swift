// Apple's Photos as the reference Verso matches, driven in the Simulator while the Mac records its screen, to measure
// what Photos does frame by frame rather than guess (ios/tools/live: a Live Photo made as the Camera makes one, added
// with `simctl addmedia`; the recording read with track.swift). It opens the newest photo, waits, swipes to the photo before it and back, waits,
// and holds the photo; the timings are what a recording is read against. It changes nothing.

import XCTest

final class PhotosReferenceTests: XCTestCase {
    @MainActor
    func testLivePhoto() throws {
        let photos = XCUIApplication(bundleIdentifier: "com.apple.mobileslideshow")
        photos.launch()
        // Photos asks to send notifications on its first start; the answer changes nothing measured here.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        if springboard.buttons["Don’t Allow"].waitForExistence(timeout: 3) { springboard.buttons["Don’t Allow"].tap() }
        for word in ["Continue", "Not Now", "OK"] where photos.buttons[word].waitForExistence(timeout: 1) {
            photos.buttons[word].tap()
        }
        Thread.sleep(forTimeInterval: 2)
        // The Live Photo whose label holds LIVE_LABEL (a date, from the run's environment), else the newest, at the
        // grid's end.
        let wanted = ProcessInfo.processInfo.environment["LIVE_LABEL"] ?? ""
        let lives = photos.images.matching(wanted.isEmpty ? NSPredicate(format: "label BEGINSWITH 'Live Photo'")
            : NSPredicate(format: "label BEGINSWITH 'Live Photo' AND label CONTAINS %@", wanted))
        if !lives.firstMatch.waitForExistence(timeout: 3) { photos.swipeDown() }
        guard lives.firstMatch.waitForExistence(timeout: 5), let tile = lives.allElementsBoundByIndex.last else {
            return XCTFail("the Live Photo in the grid")
        }
        keep("grid", photos)
        mark("open")
        tile.tap()
        Thread.sleep(forTimeInterval: 4)
        keep("opened", photos)
        let window = photos.windows.firstMatch
        mark("swipe away")
        window.swipeRight()
        Thread.sleep(forTimeInterval: 2)
        mark("swipe back")
        window.swipeLeft()
        Thread.sleep(forTimeInterval: 4)
        mark("hold")
        window.press(forDuration: 3.5)
        Thread.sleep(forTimeInterval: 2)
        keep("after the hold", photos)
    }

    /// A photo's details: the newest photo opened, its details pulled up, pushed further up twice, pulled back down a
    /// little, and the photo beside it swiped to with the details up; a screenshot after each, to see where the photo
    /// and the details go.
    @MainActor
    func testDetails() throws {
        let photos = XCUIApplication(bundleIdentifier: "com.apple.mobileslideshow")
        photos.launch()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        if springboard.buttons["Don’t Allow"].waitForExistence(timeout: 3) { springboard.buttons["Don’t Allow"].tap() }
        for word in ["Continue", "Not Now", "OK"] where photos.buttons[word].waitForExistence(timeout: 1) {
            photos.buttons[word].tap()
        }
        Thread.sleep(forTimeInterval: 2)
        let wanted = ProcessInfo.processInfo.environment["LIVE_LABEL"] ?? ""
        let candidates = photos.images.matching(wanted.isEmpty ? NSPredicate(value: true)
            : NSPredicate(format: "label CONTAINS %@", wanted))
        guard candidates.firstMatch.waitForExistence(timeout: 5), let tile = candidates.allElementsBoundByIndex.last else {
            return XCTFail("a photo in the grid")
        }
        mark("open")
        tile.tap()
        Thread.sleep(forTimeInterval: 3)
        keep("opened", photos)
        let window = photos.windows.firstMatch
        func drag(_ from: CGFloat, _ to: CGFloat, _ step: String) {
            mark(step)
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: from))
                .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: to)),
                       withVelocity: 500, thenHoldForDuration: 0.4)
            Thread.sleep(forTimeInterval: 2)
            keep(step, photos)
        }
        drag(0.7, 0.4, "details up")
        drag(0.8, 0.55, "pushed up")
        drag(0.8, 0.5, "pushed further")
        drag(0.8, 0.35, "pushed to the end")
        drag(0.3, 0.6, "pulled back down")
        mark("swipe to the next")
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.15))
            .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.15)),
                   withVelocity: 1500, thenHoldForDuration: 0)
        Thread.sleep(forTimeInterval: 2)
        keep("swiped to the next", photos)
    }

    /// Photos opening and closing, for how its bars come and go and how soon it takes a tap, in the steps
    /// ViewerResponsivenessTests takes in Verso: first one photo opened and closed at rest, for the recording; then
    /// Back at set times after a tile opens its photo, and another tile at set times after Back. A screenshot 2.5 s
    /// after each says whether it took the tap: the grid if Back closed it, a photo if the tile opened it.
    @MainActor
    func testOpenAndClose() throws {
        guard IdleWait.off else { throw XCTSkip("this XCTest waits for an idle app another way") }
        let photos = XCUIApplication(bundleIdentifier: "com.apple.mobileslideshow")
        photos.launch()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        if springboard.buttons["Don’t Allow"].waitForExistence(timeout: 3) { springboard.buttons["Don’t Allow"].tap() }
        Thread.sleep(forTimeInterval: 3)
        let window = photos.windows.firstMatch
        let first = window.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.7))
        let second = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
        let back = window.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 42, dy: 84))
        keep("grid", photos)
        mark("open at rest")
        first.tap()
        Thread.sleep(forTimeInterval: 2.5)
        keep("opened at rest", photos)
        mark("close at rest")
        back.tap()
        Thread.sleep(forTimeInterval: 2.5)
        for delay in [0.3, 0.45, 0.6, 0.8] {
            mark("open, Back \(delay) s after")
            first.tap()
            Thread.sleep(forTimeInterval: delay)
            mark("Back \(delay)")
            back.tap()
            Thread.sleep(forTimeInterval: 2.5)
            keep("Back \(delay) s after the open", photos)
            back.tap()
            Thread.sleep(forTimeInterval: 2)
        }
        for delay in [0.3, 0.45, 0.6, 0.8] {
            first.tap()
            Thread.sleep(forTimeInterval: 2.5)
            mark("Back, a tile \(delay) s after")
            back.tap()
            Thread.sleep(forTimeInterval: delay)
            mark("tile \(delay)")
            second.tap()
            Thread.sleep(forTimeInterval: 2.5)
            keep("tile \(delay) s after Back", photos)
            back.tap()
            Thread.sleep(forTimeInterval: 2)
        }
    }

    /// Photos' grid pinched between its zoom levels, open twice and closed twice, each step marked, to set a card page's
    /// pinch beside (CardPinchWalkTests).
    @MainActor
    func testGridPinch() throws {
        let photos = XCUIApplication(bundleIdentifier: "com.apple.mobileslideshow")
        photos.launch()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        if springboard.buttons["Don’t Allow"].waitForExistence(timeout: 3) { springboard.buttons["Don’t Allow"].tap() }
        Thread.sleep(forTimeInterval: 3)
        let grid = photos.scrollViews.firstMatch
        XCTAssertTrue(grid.waitForExistence(timeout: 10), "the grid shows")
        for step in ["close 1", "close 2", "open 1", "open 2"] {
            mark(step)
            grid.pinch(withScale: step.hasPrefix("open") ? 1.8 : 0.55, velocity: step.hasPrefix("open") ? 1.5 : -1.5)
            Thread.sleep(forTimeInterval: 2)
            keep(step, photos)
        }
    }

    /// Photos' grid opened by a pinch between two levels of square photos: zoomed out first with View Options' Zoom Out,
    /// as Photos ignores XCUITest's closing pinches, then pinched open slowly, and again quickly. Photos zooms out only
    /// with more photos than its rows fill, so it runs on a Simulator of its own with the lab's fixtures added
    /// (`SIMULATOR=<name> ios/tools/live/record.sh`), leaving the test device's library, which the backup walks read,
    /// as it is.
    @MainActor
    func testGridPinchOpenSquares() throws {
        let photos = XCUIApplication(bundleIdentifier: "com.apple.mobileslideshow")
        photos.launch()
        Thread.sleep(forTimeInterval: 3)
        let grid = photos.scrollViews.firstMatch
        XCTAssertTrue(grid.waitForExistence(timeout: 10), "the grid shows")
        for step in ["zoom out 1", "zoom out 2"] {
            zoomOut(photos)
            keep(step, photos)
        }
        for step in [("open slow", 1.5, 0.3), ("open again", 1.5, 0.3)] {
            mark(step.0)
            grid.pinch(withScale: step.1, velocity: step.2)
            Thread.sleep(forTimeInterval: 2)
            keep(step.0, photos)
        }
        zoomOut(photos)
        mark("open quick")
        grid.pinch(withScale: 1.5, velocity: 2)
        Thread.sleep(forTimeInterval: 2)
        keep("open quick", photos)
    }

    /// View Options' Zoom Out, in the menu of the button beside Select.
    @MainActor
    private func zoomOut(_ photos: XCUIApplication) {
        let candidates = ["Sort and Filter", "View Options", "More"]
        let menu = candidates.lazy.map { photos.buttons[$0] }.first { $0.exists && $0.isHittable }
        guard let menu else {
            print("RESULT no menu button")
            return
        }
        menu.tap()
        Thread.sleep(forTimeInterval: 1)
        // Zoom Out is in the menu's View Options.
        let viewOptions = photos.buttons["View Options"]
        if viewOptions.exists && viewOptions.isHittable {
            viewOptions.tap()
            Thread.sleep(forTimeInterval: 1)
        }
        let zoom = photos.buttons["Zoom Out"]
        if zoom.waitForExistence(timeout: 2) {
            zoom.tap()
        } else {
            print("RESULT no Zoom Out")
            photos.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.06)).tap()
        }
        Thread.sleep(forTimeInterval: 1.5)
        if photos.buttons["Zoom Out"].exists { photos.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.06)).tap() }
        Thread.sleep(forTimeInterval: 1)
    }

    /// When a step starts, in the test's log, to read the recording against.
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
