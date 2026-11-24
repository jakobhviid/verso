// A real iPhone Live Photo in Verso's viewer, on Immich's public demo, read only: one of its iPhone 15 Live Photos,
// opened by its identifier (`-showPhoto`, which shows it in the Library as Show in All Photos does), then the steps
// PhotosReferenceTests takes in Photos with the same Live Photo: wait, swipe to the photo before it and back, hold it.
// A recording of each (ios/tools/live/record.sh) is read against the other with track.swift. And the LIVE badge as
// one switch for all Live Photos, kept on the device, with its notice. The demo's photos only show here; nothing is
// changed there.

import XCTest

final class LiveRealWalkTests: XCTestCase {
    /// The demo's Live Photo of fireworks, taken with an iPhone 15 on 2 November 2024, whose movie marks its key photo.
    private static let livePhoto = "75b02044-4bed-4252-993e-44fb76dad79c"
    /// Another of its iPhone 15 Live Photos, whose trimmed movie keeps its mark at the start.
    private static let trimmedLivePhoto = "4384a38c-a619-4f93-89a6-d8537cfca3ec"

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    @MainActor
    func testRealLivePhoto() throws {
        let id = ProcessInfo.processInfo.environment["LIVE_PHOTO_ID"] ?? Self.livePhoto
        let application = open(id)
        if (application.buttons["viewer.live"].value as? String) == "Off" { application.buttons["viewer.live"].tap() }
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
    }

    /// Switched off on one Live Photo, the badge reads OFF on another too, after a relaunch; switched on, LIVE. Each
    /// switch says so in a moment's notice, which the walk cannot catch: a tap waits for the app to go idle, about as
    /// long as the notice shows.
    @MainActor
    func testOneSwitchForAll() throws {
        let first = open(Self.livePhoto)
        let badge = first.buttons["viewer.live"].firstMatch
        if (badge.value as? String) == "Off" {
            badge.tap()
            Thread.sleep(forTimeInterval: 2.5)
        }
        keep("on", first)
        badge.tap()
        XCTAssertEqual(badge.value as? String, "Off", "the badge switches Live Photos off")
        keep("switched off, the notice", first)
        Thread.sleep(forTimeInterval: 2.5)
        XCTAssertFalse(first.descendants(matching: .any)["Live Photos off"].exists, "the notice goes after a moment")
        keep("off", first)
        first.terminate()

        let second = open(Self.trimmedLivePhoto)
        let badgeAgain = second.buttons["viewer.live"].firstMatch
        XCTAssertEqual(badgeAgain.value as? String, "Off", "another Live Photo reads OFF too, kept on the device")
        badgeAgain.tap()
        XCTAssertEqual(badgeAgain.value as? String, "On", "the badge switches Live Photos on")
        keep("switched on, the notice", second)
    }

    /// Verso Dev signed in to Immich's demo, the photo `id` shown in the Library and opened.
    @MainActor
    private func open(_ id: String) -> XCUIApplication {
        let application = XCUIApplication()
        application.launchArguments = ["-signInServer", "https://demo.immich.app", "-signInEmail", "demo@immich.app",
                                       "-signInPassword", "demo", "-showPhoto", id]
        application.launch()
        let tile = application.descendants(matching: .any)["photo-" + id]
        XCTAssertTrue(tile.waitForExistence(timeout: 60), "the Live Photo shows in the Library")
        Thread.sleep(forTimeInterval: 2)
        mark("open")
        tile.tap()
        XCTAssertTrue(application.buttons["viewer.live"].waitForExistence(timeout: 20), "it opens as a Live Photo")
        return application
    }

    /// A screenshot kept with the run's results.
    @MainActor
    private func keep(_ name: String, _ application: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: application.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// When a step starts, in the test's log, to read a recording against.
    private func mark(_ step: String) {
        print("REFERENCE \(step) at \(Date.now.timeIntervalSince1970)")
    }
}
