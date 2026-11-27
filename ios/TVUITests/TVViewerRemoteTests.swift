import XCTest

/// The viewer on the Apple TV, driven with the Siri Remote's buttons (XCUIRemote), against Immich's demo: a video opens
/// in tvOS's own player, which has the remote whole (its transport bar, scrubbing, its panels), and Menu comes back to
/// the viewer at the video, where left and right step on. Each step keeps a screenshot, for looking at what the remote
/// reached.
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

    func testAVideoPlaysInTheSystemsPlayerWithTheRemoteWhole() throws {
        let application = XCUIApplication()
        application.launchArguments = ["-signInServer", "https://demo.immich.app", "-signInAccessToken", try demoToken(),
                                       "-tvOpenVideo", "YES"]
        application.launch()
        let play = application.descendants(matching: .any)["Play Video"]
        XCTAssert(play.waitForExistence(timeout: 60), "the viewer opens at a video, with its play sign")
        Thread.sleep(forTimeInterval: 2)
        keep("1 the viewer at a video")

        press(.select, "2 the system's player, playing", settle: 4)
        press(.down, "3 down: the player's panel")
        press(.up, "4 up: back from the panel")
        press(.select, "5 select: paused, the transport bar")
        press(.right, "6 right: scrubbed forward, still in the player")
        press(.left, "7 left: scrubbed back, still in the player")
        press(.up, "8 up: the transport bar's buttons")
        // Menu steps back a layer at a time, as any player on the TV: from the buttons to the transport bar, the bar
        // hidden, then the player closed, and the viewer is back at the video.
        var presses = 0
        repeat {
            XCUIRemote.shared.press(.menu)
            presses += 1
        } while !play.waitForExistence(timeout: 2) && presses < 4
        XCTAssert(play.exists, "Menu comes back to the viewer at the video")
        XCTAssert(application.exists && application.state == .runningForeground, "and the app stays open")
        keep("9 back in the viewer at the video")
        press(.right, "10 right: the next photo or video")
    }
}
