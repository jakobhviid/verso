// A walk through a server with a certificate of its own (ARCHITECTURE.md, "A certificate of the server's own"), against
// a lab server behind a TLS proxy with a self-signed certificate (the lab-immich-server skill), never Immich's demo,
// keeping a screenshot of each place. The server's address, its admin's sign-in, the fingerprint the proxy's
// certificate has, and a video's and a photo's identifiers reach it only through the test run's environment, as
// TEST_RUNNER_ variables: IMMICH_URL, IMMICH_EMAIL, IMMICH_PASSWORD, IMMICH_CERT_SHA256, IMMICH_VIDEO, IMMICH_PHOTO.
//
// testTrustAtSignIn: signed out, the address asks about the certificate, with its fingerprint; Cancel keeps nothing;
// Trust goes on to the sign-in, then the Library, a photo, and a video that plays and seeks; the account's sheet shows
// the trusted certificate, and Forget asks again at once, which Trust answers.
// testChangedCertificate, once the proxy's certificate is replaced: the stronger question by itself, the banner with
// Check Certificate… after Cancel, and the library back after Trust. It ends signed out.

import XCTest

final class CertificateWalkTests: XCTestCase {
    private let environment = ProcessInfo.processInfo.environment

    private func value(_ name: String) throws -> String {
        guard let value = environment[name], !value.isEmpty else { throw XCTSkip("\(name) is not set for the walk") }
        return value
    }

    @MainActor
    func testTrustAtSignIn() throws {
        continueAfterFailure = true
        let (server, email, password) = (try value("IMMICH_URL"), try value("IMMICH_EMAIL"), try value("IMMICH_PASSWORD"))
        let fingerprint = try value("IMMICH_CERT_SHA256")
        let application = XCUIApplication()
        application.launchArguments = ["-signOut", "YES"]
        application.launch()
        let field = application.textFields["server"]
        XCTAssertTrue(field.waitForExistence(timeout: 30), "the welcome shows once signed out")
        clear(field)
        field.typeText(server)
        application.buttons["Continue"].tap()

        let trust = application.buttons["trustCertificate"]
        let question = application.buttons["closeCertificate"]
        XCTAssertTrue(question.waitForExistence(timeout: 30), "the server's certificate is asked about")
        settle()
        XCTAssertTrue(shows(application, "Trust This Server's Certificate?"))
        XCTAssertTrue(shows(application, String(fingerprint.prefix(23))), "the fingerprint the server's certificate has")
        XCTAssertTrue(shows(application, "Itself (self-signed)"))
        XCTAssertTrue(shows(application, "It was not made for"), "made for the server's name in the lab, not the tunnel's")
        keep("01 The question", application)
        application.swipeUp()
        settle()
        keep("02 The question, its buttons", application)

        application.buttons["cancelCertificate"].tap()
        settle()
        XCTAssertTrue(field.exists && !application.textFields["email"].exists, "Cancel keeps nothing, and signs in nowhere")
        keep("03 Cancelled", application)

        application.buttons["Continue"].tap()
        XCTAssertTrue(question.waitForExistence(timeout: 30), "asked again, as nothing was kept")
        application.swipeUp()
        trust.tap()
        let emailField = application.textFields["email"]
        XCTAssertTrue(emailField.waitForExistence(timeout: 30), "trusted, the server is found and its ways in show")
        settle()
        keep("04 Trusted, the sign-in", application)
        emailField.tap()
        emailField.typeText(email + "\n")
        application.secureTextFields["password"].typeText(password + "\n")
        XCTAssertTrue(application.buttons["Select"].waitForExistence(timeout: 60), "the Library shows once signed in")
        let notNow = application.buttons["Not Now"].firstMatch
        if notNow.waitForExistence(timeout: 5) { notNow.tap() }
        settle()
        keep("05 Library", application)

        // A photo and a video, opened by their identifiers, the certificate kept with the account.
        open(try value("IMMICH_PHOTO"), in: application)
        Thread.sleep(forTimeInterval: 3)
        keep("06 A photo", application)
        open(try value("IMMICH_VIDEO"), in: application)
        let position = application.descendants(matching: .any)["Playback Position"].firstMatch
        XCTAssertTrue(position.waitForExistence(timeout: 30), "the video's bar")
        let started = position.value as? String ?? ""
        Thread.sleep(forTimeInterval: 3)
        keep("07 The video playing", application)
        if !position.isHittable { application.windows.firstMatch.tap() }
        let playing = position.value as? String ?? ""
        XCTAssertNotEqual(started, playing, "the video plays: its position moves")
        position.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)).tap()
        Thread.sleep(forTimeInterval: 1)
        keep("08 The video sought near its end", application)
        print("WALK video position: started \(started), then \(playing), after seeking \(position.value as? String ?? "")")

        // The account's sheet: the certificate trusted, and Forget, which asks again at once.
        application.terminate()
        application.launchArguments = []
        application.launch()
        XCTAssertTrue(application.buttons["Select"].waitForExistence(timeout: 60), "signed in still")
        openAccount(application)
        let trusted = application.descendants(matching: .any)["trustedCertificate"].firstMatch
        scrollTo(trusted, in: application)
        XCTAssertTrue(trusted.exists, "the account's sheet shows the certificate trusted")
        keep("09 Account, the trusted certificate", application)
        application.buttons["Forget Certificate…"].firstMatch.tap()
        settle()
        keep("10 Forget, asked", application)
        application.buttons["Forget"].firstMatch.tap()
        XCTAssertTrue(question.waitForExistence(timeout: 30), "forgotten, the question comes again")
        settle()
        keep("11 After Forget, the question", application)
        application.swipeUp()
        trust.tap()
        settle()
        XCTAssertFalse(application.descendants(matching: .any)["certificateBanner"].firstMatch.waitForExistence(timeout: 10),
                       "trusted again, no banner")
        keep("12 Trusted again", application)
    }

    @MainActor
    func testChangedCertificate() throws {
        continueAfterFailure = true
        let fingerprint = try value("IMMICH_CERT_SHA256")
        let application = XCUIApplication()
        application.launch()
        let trust = application.buttons["trustCertificate"]
        let question = application.buttons["closeCertificate"]
        XCTAssertTrue(question.waitForExistence(timeout: 60), "the changed certificate is asked about by itself")
        settle()
        XCTAssertTrue(shows(application, "The Server's Certificate Changed"))
        XCTAssertTrue(shows(application, String(fingerprint.prefix(23))), "the new fingerprint")
        keep("13 Changed, the question", application)
        application.swipeUp()
        settle()
        keep("14 Changed, trusted until now", application)
        application.buttons["cancelCertificate"].tap()
        let banner = application.descendants(matching: .any)["certificateBanner"].firstMatch
        XCTAssertTrue(banner.waitForExistence(timeout: 15), "the banner says the certificate is not trusted")
        settle()
        keep("15 Changed, the banner", application)
        application.buttons["checkCertificate"].firstMatch.tap()
        XCTAssertTrue(question.waitForExistence(timeout: 30), "Check Certificate… asks again")
        application.swipeUp()
        trust.tap()
        XCTAssertTrue(banner.waitForNonExistence(timeout: 30), "trusted, the library connects again")
        Thread.sleep(forTimeInterval: 3)
        keep("16 Changed, trusted", application)
        application.terminate()
        application.launchArguments = ["-signOut", "YES"]
        application.launch()
        XCTAssertTrue(application.textFields["server"].waitForExistence(timeout: 30), "signed out at the end")
    }

    // MARK: Steps

    /// The photo `id`, shown in the Library and opened, in a launch of its own.
    @MainActor
    private func open(_ id: String, in application: XCUIApplication) {
        application.terminate()
        application.launchArguments = ["-showPhoto", id]
        application.launch()
        let tile = application.descendants(matching: .any)["photo-" + id]
        XCTAssertTrue(tile.waitForExistence(timeout: 60), "\(id) shows in the Library")
        Thread.sleep(forTimeInterval: 2)
        tile.tap()
        XCTAssertTrue(application.buttons["Back"].firstMatch.waitForExistence(timeout: 20), "it opens")
    }

    @MainActor
    private func openAccount(_ application: XCUIApplication) {
        let collections = application.tabBars.buttons["Collections"].firstMatch
        XCTAssertTrue(collections.waitForExistence(timeout: 10))
        collections.tap()
        settle()
        let account = application.buttons["Account"].firstMatch
        XCTAssertTrue(account.waitForExistence(timeout: 10))
        account.tap()
        settle()
    }

    @MainActor
    private func scrollTo(_ element: XCUIElement, in application: XCUIApplication) {
        for _ in 0..<12 where !(element.exists && element.isHittable) {
            application.swipeUp()
            Thread.sleep(forTimeInterval: 0.5)
        }
    }

    /// Whether a text containing `text` shows.
    @MainActor
    private func shows(_ application: XCUIApplication, _ text: String) -> Bool {
        application.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", text)).firstMatch.exists
            || application.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch.exists
    }

    @MainActor
    private func clear(_ field: XCUIElement) {
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()
        let text = field.value as? String ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: text.count + 2))
    }

    private func settle() {
        Thread.sleep(forTimeInterval: 1.5)
    }

    @MainActor
    private func keep(_ name: String, _ application: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: application.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
