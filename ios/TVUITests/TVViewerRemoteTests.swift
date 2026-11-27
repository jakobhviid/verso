import XCTest

/// The viewer on the Apple TV, driven with the Siri Remote's buttons (XCUIRemote), against Immich's demo: a video plays
/// at once in the viewer, play/pause pauses it, a click or up brings tvOS's own controls over it (scrubbing, the
/// panels), Menu leaves them for the video playing on, and left and right step on. Each step keeps a screenshot, for
/// looking at what the remote reached.
final class TVViewerRemoteTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// A session on Immich's demo, which makes no API keys, for the development build's sign-in.
    private func demoToken() throws -> String {
        var request = URLRequest(url: URL(string: "https://demo.immich.app/api/auth/login")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(#"{"email":"demo@immich.app","password":"demo"}"#.utf8)
        let done = expectation(description: "signed in to the demo")
        var token: String?
        URLSession.shared.dataTask(with: request) { data, _, _ in
            token = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["accessToken"] as? String
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 30)
        return try XCTUnwrap(token, "the demo's sign-in")
    }

    private func keep(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func press(_ button: XCUIRemote.Button, _ name: String, settle: TimeInterval = 1.5) {
        XCUIRemote.shared.press(button)
        Thread.sleep(forTimeInterval: settle)
        keep(name)
    }

    func testAVideoPlaysAtOnceWithTheSystemsControlsOnAClick() throws {
        let application = XCUIApplication()
        // All Photos filtered to its videos, and Manage Photos on (a key that is never used), so a video's menu is
        // there, as on a TV that turned it on.
        application.launchArguments = ["-signInServer", "https://demo.immich.app", "-signInAccessToken", try demoToken(),
                                       "-tvPlace", "library", "-tvFilterVideos", "YES", "-tvChangeKey", "unused"]
        application.launch()
        XCTAssert(application.collectionViews.cells.firstMatch.waitForExistence(timeout: 60), "the videos' grid")
        Thread.sleep(forTimeInterval: 3)
        // From the sidebar to the Filter menu, down to the first video, and a click opens it, as a person goes.
        press(.right, "0a right, to the header")
        press(.down, "0b down, to the first video")
        XCUIRemote.shared.press(.select)
        let viewer = application.descendants(matching: .any)["Viewer"]
        let controls = application.otherElements["Video Player"]
        XCTAssert(viewer.waitForExistence(timeout: 10), "the viewer opens at the video")
        Thread.sleep(forTimeInterval: 4)
        keep("1 the video playing in the viewer")
        press(.playPause, "2 play/pause: paused, with the play sign")
        press(.playPause, "3 play/pause: playing on")

        // The clickpad's middle brings tvOS's controls over the video, the photo's menu beside it notwithstanding.
        XCUIRemote.shared.press(.select)
        XCTAssert(controls.waitForExistence(timeout: 5), "the click brings the system's controls")
        Thread.sleep(forTimeInterval: 2)
        keep("4 the system's controls, playing on")
        press(.down, "5 down: the controls' panel")
        press(.up, "6 up: back from the panel")
        press(.right, "7 right: scrubbed forward, in the controls")
        press(.left, "8 left: scrubbed back, in the controls")
        // Menu steps back a layer at a time, as any player on the TV, and the video plays on in the viewer.
        var presses = 0
        repeat {
            XCUIRemote.shared.press(.menu)
            presses += 1
            Thread.sleep(forTimeInterval: 1.5)
        } while controls.exists && presses < 4
        XCTAssertFalse(controls.exists, "Menu leaves the controls")
        XCTAssert(viewer.exists && application.state == .runningForeground, "for the viewer, the app still open")
        keep("9 back in the viewer, the video playing on")

        // Up brings the controls too.
        XCUIRemote.shared.press(.up)
        XCTAssert(controls.waitForExistence(timeout: 5), "up brings the system's controls")
        keep("10 up: the controls")
        presses = 0
        repeat {
            XCUIRemote.shared.press(.menu)
            presses += 1
            Thread.sleep(forTimeInterval: 1.5)
        } while controls.exists && presses < 4
        XCTAssertFalse(controls.exists, "Menu leaves the controls again")
        // Left and right step on from a video, as from a photo.
        // Its picture slides in, and the video starts once it lies still.
        XCUIRemote.shared.press(.right)
        Thread.sleep(forTimeInterval: 0.15)
        keep("11a right: the next video's picture sliding in")
        Thread.sleep(forTimeInterval: 1.5)
        keep("11b right: the next video, playing")
        XCTAssert(viewer.exists, "still in the viewer")
        press(.left, "12 left: back to the first", settle: 3)
    }

    /// The grid moved through with the remote: right and down along the tiles, up back to the Filter menu, a photo
    /// opened and closed again, the focus back on its tile.
    func testTheGridMovesWithTheRemote() throws {
        let application = XCUIApplication()
        application.launchArguments = ["-signInServer", "https://demo.immich.app", "-signInAccessToken", try demoToken(),
                                       "-tvPlace", "library"]
        application.launch()
        let filter = application.buttons.containing(.staticText, identifier: "Filter").firstMatch
        XCTAssert(filter.waitForExistence(timeout: 60), "the Library's Filter menu")
        Thread.sleep(forTimeInterval: 4)
        keep("g1 the Library")
        press(.right, "g2 right, into the photos")
        press(.down, "g3 down")
        press(.right, "g4 right")
        press(.right, "g5 right")
        press(.down, "g6 down")
        press(.up, "g7 up")
        // Up from the arch, which is not under the Filter menu, comes to it (the header is a focus area): seen in the
        // screenshot, as tvOS tells no focus of a menu's button.
        press(.up, "g8 up, to the Filter menu")
        press(.down, "g10 down, back into the photos")
        press(.select, "g11 a photo opened", settle: 3)
        press(.menu, "g12 closed, the focus on its tile", settle: 3)
    }

    /// The Filter menu's choices one after another, and the grid has photos after each: every combination of Favorites
    /// and Videos, on and off again.
    func testEveryFilterLeavesPhotosInTheGrid() throws {
        let application = XCUIApplication()
        application.launchArguments = ["-signInServer", "https://demo.immich.app", "-signInAccessToken", try demoToken(),
                                       "-tvPlace", "library"]
        application.launch()
        let photos = application.collectionViews["Photos"].cells
        XCTAssert(photos.firstMatch.waitForExistence(timeout: 60), "the Library's grid")
        Thread.sleep(forTimeInterval: 3)
        press(.right, "f0 right, to the Filter menu")
        // Favorites is the menu's first choice, Videos its second.
        let steps: [(downs: Int, name: String)] = [(0, "favorites on"), (1, "videos on too"), (0, "favorites off"),
                                                   (1, "videos off"), (1, "videos on"), (0, "favorites on too"),
                                                   (1, "videos off"), (0, "favorites off")]
        for (number, step) in steps.enumerated() {
            XCUIRemote.shared.press(.select)
            Thread.sleep(forTimeInterval: 1)
            for _ in 0..<step.downs { XCUIRemote.shared.press(.down) }
            XCUIRemote.shared.press(.select)
            Thread.sleep(forTimeInterval: 1)
            // Photos, or none where the demo has none (it has no favorite videos), never a failure.
            let shown = photos.firstMatch.waitForExistence(timeout: 30) || application.staticTexts["No Photos"].exists
            Thread.sleep(forTimeInterval: 2)
            keep("f\(number + 1) \(step.name)")
            XCTAssert(shown, "photos in the grid, or none, with \(step.name)")
            XCTAssertFalse(application.staticTexts["Can't Load Photos"].exists, "no failure with \(step.name)")
        }
    }
}
