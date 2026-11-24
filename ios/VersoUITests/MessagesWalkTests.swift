// A walk through Verso in Messages (ios/Messages), keeping a screenshot of each place: a conversation, Messages' apps,
// Verso Dev's picker compact, then expanded on its albums, an album, Recents and a search, a photo put into the
// message field, the Original toggle, and an original put there. It signs Verso Dev in to Immich's demo with the launch
// arguments first (AppModel.followLaunchArguments), so the picker signs in with the app's account, and only reads
// there. Nothing is sent: each photo is taken out of the field again with Messages' own remove button. Every tap
// waits for its element first, so a step that fails leaves the rest to run.
//
// What Messages shows, as the Simulator's iOS 27 has it: the conversation's "+" beside the field is labelled "add";
// it opens a menu of Messages' apps, one cell each, identified by the extension's bundle identifier, a new app after
// Apple's further down the list; and a photo in the field is a button identified "Sticker", with "Remove app from
// message" beside it.

import XCTest

final class MessagesWalkTests: XCTestCase {
    @MainActor
    func testPickerInMessages() throws {
        continueAfterFailure = true
        let verso = XCUIApplication()
        verso.launchArguments = ["-signInServer", "https://demo.immich.app",
                                 "-signInEmail", "demo@immich.app", "-signInPassword", "demo"]
        verso.launch()
        XCTAssertTrue(verso.buttons["Select"].waitForExistence(timeout: 45), "the Library shows once signed in")

        let messages = XCUIApplication(bundleIdentifier: "com.apple.MobileSMS")
        messages.launch()
        XCTAssertTrue(messages.wait(for: .runningForeground, timeout: 15), "Messages runs")
        openConversation(messages)
        removeFromField(messages) // whatever an earlier run left there
        settle()
        keep("01 a conversation", messages)

        openPicker(messages)
        let photo = messages.descendants(matching: .any).matching(identifier: "picker.photo").firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 45), "the compact picker shows the library's newest photos")
        settle()
        keep("03 the picker, compact", messages)

        // Expanded: Albums asks Messages for the expanded picker on its Albums section.
        if tap(messages.buttons["Albums"].firstMatch, "the compact picker has Albums") {
            let album = messages.descendants(matching: .any).matching(identifier: "picker.album").firstMatch
            XCTAssertTrue(album.waitForExistence(timeout: 30), "the expanded picker lists the albums")
            settle()
            keep("04 the picker, expanded on Albums", messages)
            if album.exists {
                album.tap()
                _ = photo.waitForExistence(timeout: 30)
                settle()
                keep("05 an album's photos", messages)
                let back = messages.navigationBars.buttons.firstMatch
                if back.exists { back.tap() }
            }
            if tap(messages.segmentedControls.buttons["Recents"].firstMatch, "the expanded picker has Recents") {
                _ = photo.waitForExistence(timeout: 30)
                settle()
                keep("06 the picker, expanded on Recents", messages)
            }
            // A search by meaning, which the demo's server has.
            let search = messages.searchFields.firstMatch
            if tap(search, "the expanded picker has a search field") {
                search.typeText("mountain\n")
                Thread.sleep(forTimeInterval: 6)
                XCTAssertTrue(photo.exists, "the search finds photos")
                keep("07 a search", messages)
            }
        }

        // Back to compact (a drag down on the expanded picker). A photo into the message field: its tile checked, the
        // photo in the field.
        messages.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12))
            .press(forDuration: 0.05, thenDragTo: messages.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)))
        settle()
        let inField = messages.otherElements["MessageEntryView"].buttons["Sticker"].firstMatch
        let photos = messages.descendants(matching: .any).matching(identifier: "picker.photo")
        if tap(photos.element(boundBy: 0), "the compact picker has photos") {
            XCTAssertTrue(inField.waitForExistence(timeout: 30), "the message field holds the photo")
            settle()
            keep("08 a photo in the message field", messages)
            removeFromField(messages)
        }
        // Its original, with Original on at the picker's top, and Original off again afterwards.
        let originalToggle = messages.switches["picker.original"].firstMatch
        let originalButton = messages.buttons["picker.original"].firstMatch
        let toggle = originalToggle.exists ? originalToggle : originalButton
        if toggle.waitForExistence(timeout: 10), photo.waitForExistence(timeout: 10) {
            toggle.tap()
            settle()
            keep("09 Original on", messages)
            photo.tap()
            XCTAssertTrue(inField.waitForExistence(timeout: 60), "the message field holds the original")
            settle()
            keep("10 an original in the message field", messages)
            removeFromField(messages)
            if toggle.waitForExistence(timeout: 10) { toggle.tap() }
        } else {
            XCTFail("the picker has an Original toggle at its top")
            keep("09 no Original toggle", messages)
        }
        settle()
        keep("11 the field emptied", messages)
    }

    /// Signed out of Verso Dev, the picker says to open it, and its button does. Verso Dev is signed in again
    /// afterwards, as the Simulator was.
    @MainActor
    func testSignedOut() throws {
        continueAfterFailure = true
        let verso = XCUIApplication()
        verso.launchArguments = ["-signOut", "YES"]
        verso.launch()
        Thread.sleep(forTimeInterval: 5) // the sign-out, as the launch arguments ask

        let messages = XCUIApplication(bundleIdentifier: "com.apple.MobileSMS")
        messages.launch()
        XCTAssertTrue(messages.wait(for: .runningForeground, timeout: 15), "Messages runs")
        openConversation(messages)
        openPicker(messages)
        let open = messages.buttons["Open Verso Dev"].firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 30), "signed out, the picker offers to open Verso Dev")
        settle()
        keep("12 the picker, signed out", messages)
        if open.exists {
            open.tap()
            XCTAssertTrue(verso.wait(for: .runningForeground, timeout: 15), "Open Verso Dev opens the app")
            settle()
            keep("13 Verso Dev, opened from the picker", verso)
        }

        verso.launchArguments = ["-signInServer", "https://demo.immich.app",
                                 "-signInEmail", "demo@immich.app", "-signInPassword", "demo"]
        verso.launch()
        XCTAssertTrue(verso.buttons["Select"].waitForExistence(timeout: 45), "Verso Dev is signed in again")
    }

    /// The first conversation in the list (the Simulator has one), or a new one to its Kate Bell when there is none.
    @MainActor
    private func openConversation(_ messages: XCUIApplication) {
        if messages.otherElements["MessageEntryView"].exists { return }
        let conversation = messages.cells.firstMatch
        if conversation.waitForExistence(timeout: 10) {
            conversation.tap()
            return
        }
        let compose = messages.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@ OR identifier CONTAINS[c] %@",
                                                            "Compose", "Compose")).firstMatch
        guard tap(compose, "Messages offers a new message") else { return }
        let recipient = messages.textFields.firstMatch
        if recipient.waitForExistence(timeout: 10) {
            recipient.typeText("Kate")
            let suggestion = messages.staticTexts["Kate Bell"].firstMatch
            if suggestion.waitForExistence(timeout: 10) { suggestion.tap() }
        }
    }

    /// Messages' apps, then Verso Dev among them, scrolled to (or under More, where a release has it).
    @MainActor
    private func openPicker(_ messages: XCUIApplication) {
        let apps = messages.buttons.matching(NSPredicate(format: "label ==[c] %@", "add")).firstMatch
        guard tap(apps, "the conversation has Messages' apps button") else { return }
        settle()
        keep("02 Messages' apps", messages)
        let verso = messages.cells.matching(NSPredicate(format: "identifier ENDSWITH %@ OR label == %@",
                                                        ":dev.hviid.Verso.Dev.Messages", "Verso Dev")).firstMatch
        let more = messages.cells.matching(NSPredicate(format: "label == %@", "More")).firstMatch
        let first = messages.cells.firstMatch
        for _ in 0..<8 where !(verso.exists && verso.isHittable) {
            if more.exists, more.isHittable, !verso.exists {
                more.tap()
                settle()
                continue
            }
            guard first.exists else { break }
            first.swipeUp()
            Thread.sleep(forTimeInterval: 1)
        }
        settle()
        keep("02 Messages' apps, Verso Dev among them", messages)
        tap(verso, "Messages lists Verso Dev among its apps")
    }

    /// Takes a photo out of the message field with Messages' own button, so nothing waits there to be sent.
    @MainActor
    private func removeFromField(_ messages: XCUIApplication) {
        let remove = messages.buttons["Remove app from message"].firstMatch
        for _ in 0..<5 where remove.waitForExistence(timeout: 2) {
            remove.tap()
            Thread.sleep(forTimeInterval: 1)
        }
    }

    /// Tap an element once it shows, or record that it did not.
    @MainActor
    @discardableResult
    private func tap(_ element: XCUIElement, _ claim: String) -> Bool {
        guard element.waitForExistence(timeout: 15) else {
            XCTFail(claim)
            return false
        }
        element.tap()
        return true
    }

    /// Lets thumbnails and transitions finish before a screenshot.
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
