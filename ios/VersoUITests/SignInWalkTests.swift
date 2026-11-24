// A walk through signing in as a person takes it, keeping a screenshot of each state of the sign-in pages: the
// welcome as it opens and emptied, a wrong address and its error, Immich's demo found with its ways in, a wrong
// password and its error, the email and password typed, the API key's section opened, the other appearance,
// landscape, and the largest text; each time it then signs in to the demo with its password and sees the Library,
// turning down iOS's offer to save the password. It launches Verso Dev signed out (`-signOut YES`,
// AppModel.followLaunchArguments), only reads on the demo, and leaves Verso Dev signed in there, as the other walks
// expect, with the Simulator in the appearance and orientation it found.

import XCTest

final class SignInWalkTests: XCTestCase {
    @MainActor
    func testSignInWalk() throws {
        continueAfterFailure = true
        let device = XCUIDevice.shared
        let appearance = device.appearance
        defer {
            device.appearance = appearance
            device.orientation = .portrait
        }

        let application = XCUIApplication()
        application.launchArguments = ["-signOut", "YES"]
        application.launch()
        let server = application.textFields["server"]
        XCTAssertTrue(server.waitForExistence(timeout: 30), "the welcome shows once signed out")
        settle()
        keep("01 Welcome", application)

        clear(server)
        settle()
        keep("02 Empty, the address field in focus", application)

        server.typeText("photos.example.invalid")
        application.buttons["Continue"].tap()
        let problem = application.descendants(matching: .any)["problem"].firstMatch
        XCTAssertTrue(problem.waitForExistence(timeout: 30), "a wrong address says so under the field")
        settle()
        keep("03 Wrong address", application)

        clear(server)
        server.typeText("https://demo.immich.app\n") // Return continues
        let email = application.textFields["email"]
        XCTAssertTrue(email.waitForExistence(timeout: 30), "the demo is found and its ways in show")
        settle()
        keep("04 Demo found", application)

        email.tap()
        email.typeText("demo@immich.app\n") // Return moves on to the password
        let password = application.secureTextFields["password"]
        password.typeText("not-the-password\n") // Return signs in
        XCTAssertTrue(problem.waitForExistence(timeout: 30), "a wrong password says so under the fields")
        settle()
        keep("05 Wrong password", application)
        clear(password)
        password.typeText("demo")
        settle()
        keep("05 Email and password typed", application)

        application.buttons["apiKeyDisclosure"].tap()
        settle()
        let apiKey = application.secureTextFields["apiKey"]
        XCTAssertTrue(apiKey.waitForExistence(timeout: 5), "the disclosure opens the API key's section")
        XCTAssertTrue(apiKey.value(forKey: "hasKeyboardFocus") as? Bool ?? false, "the API key's field takes the focus")
        keep("06 API key open", application)

        device.appearance = appearance == .light ? .dark : .light
        settle()
        keep("07 Sign in, the other appearance", application)
        back(application)
        keep("08 Welcome, the other appearance", application)
        device.appearance = appearance

        device.orientation = .landscapeLeft
        settle()
        keep("09 Welcome, landscape", application, wholeScreen: true)
        application.buttons["Continue"].tap()
        XCTAssertTrue(email.waitForExistence(timeout: 30), "the demo is found again")
        settle()
        keep("10 Sign in, landscape", application, wholeScreen: true)
        device.orientation = .portrait
        settle()

        signIn(application)
        keep("11 Library", application)

        // The largest text: the same pages, launched at Accessibility XXXL.
        application.terminate()
        application.launchArguments = ["-signOut", "YES",
                                       "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        application.launch()
        XCTAssertTrue(server.waitForExistence(timeout: 30), "the welcome shows once signed out")
        settle()
        keep("12 Largest text, welcome", application)
        application.windows.firstMatch.swipeUp()
        settle()
        keep("13 Largest text, welcome scrolled", application)
        application.buttons["Continue"].tap()
        XCTAssertTrue(email.waitForExistence(timeout: 30), "the demo is found")
        settle()
        keep("14 Largest text, sign in", application)
        application.windows.firstMatch.swipeUp()
        settle()
        keep("15 Largest text, sign in scrolled", application)

        signIn(application)
        keep("16 Library", application)
    }

    /// Signs in to the demo with its password, typed as a person types it, Return signing in from the password.
    @MainActor
    private func signIn(_ application: XCUIApplication) {
        let email = application.textFields["email"]
        if !email.isHittable { application.windows.firstMatch.swipeDown() }
        clear(email)
        email.typeText("demo@immich.app\n")
        application.secureTextFields["password"].typeText("demo\n")
        XCTAssertTrue(application.buttons["Select"].waitForExistence(timeout: 45), "the Library shows once signed in")
        settle()
        let notNow = application.buttons["Not Now"].firstMatch
        if notNow.waitForExistence(timeout: 5) { notNow.tap() }
        settle()
    }

    /// Empties a field: a tap at its end, then as many deletes as it has characters.
    @MainActor
    private func clear(_ field: XCUIElement) {
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()
        let text = field.value as? String ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: text.count + 2))
    }

    @MainActor
    private func back(_ application: XCUIApplication) {
        let back = application.navigationBars.buttons["Back"].firstMatch
        if back.exists { back.tap() } else { application.navigationBars.buttons.firstMatch.tap() }
        settle()
    }

    /// Lets transitions finish before a screenshot.
    private func settle() {
        Thread.sleep(forTimeInterval: 1.5)
    }

    /// Keeps a screenshot of the app, or of the whole screen, which comes out the right way round in landscape where
    /// the app's own is turned.
    @MainActor
    private func keep(_ name: String, _ application: XCUIApplication, wholeScreen: Bool = false) {
        let attachment = XCTAttachment(screenshot: wholeScreen ? XCUIScreen.main.screenshot() : application.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
