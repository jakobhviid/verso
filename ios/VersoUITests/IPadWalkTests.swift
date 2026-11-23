// A walk through Verso on an iPad, keeping a screenshot of each place to judge against iPadOS's own apps: the Library
// at its zoom levels, Years and Months, the viewer with a photo, a video, a Live Photo and the details, Albums and an
// album, People and a person, Collections and its pages, Search with its filters, the account's sheet and its pages,
// Backup, sharing, the menus, Select and the imports' pickers, each found and left with the hardware keyboard's
// commands where it has them (⌘A, the arrows, Esc, ⌘F, ⌘,); the list ⌘ held shows; the window made narrow, as Stage
// Manager and windowed apps make it; and Photos itself, the reference. Run on an iPad Simulator in portrait or in
// landscape (`WALK_ORIENTATION`, landscape or portrait), against a lab server whose address and full key reach it only
// through the test run's environment (IMMICH_URL and IMMICH_API_KEY, as TEST_RUNNER_ variables); it changes nothing
// there but a favourite it sets and takes back. The video and Live Photo it opens are named by their ids (`WALK_VIDEO`,
// `WALK_LIVE`, the showcase server's). `SIMULATOR="iPad Pro 13-inch (M5)" ios/tools/live/record.sh IPadWalkTests`
// runs it in portrait and brings the screenshots back.

import XCTest

final class IPadWalkTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    /// Every place, in the orientation the run asks for.
    @MainActor
    func testWalk() throws {
        let application = try launchSignedIn()
        let prefix = orientationPrefix
        let window = application.windows.firstMatch

        // The Library, at its default zoom, zoomed out to the densest and in to the fewest, and back.
        keep("\(prefix) 01 Library", application)
        window.pinch(withScale: 0.4, velocity: -1)
        settle()
        window.pinch(withScale: 0.3, velocity: -2)
        settle()
        keep("\(prefix) 02 Library zoomed out", application)
        window.pinch(withScale: 6, velocity: 4)
        settle()
        window.pinch(withScale: 4, velocity: 4)
        settle()
        keep("\(prefix) 03 Library zoomed in", application)
        window.pinch(withScale: 0.5, velocity: -1)
        settle()
        keep("\(prefix) 04 Library zoomed back", application)

        if tap(application.buttons["View Options"].firstMatch) {
            keep("\(prefix) 05 View Options", application)
            dismissMenu(application)
        }
        window.swipeDown()
        settle()
        keep("\(prefix) 06 Library scrolled back", application)
        application.typeKey("1", modifierFlags: .command)
        settle()
        keep("\(prefix) 07 Years by Command-1", application)
        application.typeKey("2", modifierFlags: .command)
        settle()
        keep("\(prefix) 08 Months by Command-2", application)
        application.typeKey("3", modifierFlags: .command)
        settle()
        tapTab(application, "Library")
        settle()

        // Select, Select All by ⌘A, then Esc, and a tile's long press.
        _ = tap(application.buttons["Select"].firstMatch)
        application.typeKey("a", modifierFlags: .command)
        settle()
        keep("\(prefix) 09 Select All by Command-A", application)
        application.typeKey(.escape, modifierFlags: [])
        settle()
        keep("\(prefix) 10 After Esc in Select", application)
        if application.buttons["Cancel"].exists { _ = tap(application.buttons["Cancel"].firstMatch) }
        if let tile = firstTile(application) {
            tile.press(forDuration: 1.2)
            settle()
            keep("\(prefix) 11 A tile's menu", application)
            dismissMenu(application)
        }

        // The viewer: a photo, the arrows, its More menu and details, Share, then Esc.
        if let tile = firstTile(application) {
            tile.tap()
            settle()
            keep("\(prefix) 12 Photo", application)
            application.typeKey(.leftArrow, modifierFlags: [])
            settle()
            keep("\(prefix) 13 Photo after the left arrow", application)
            application.typeKey(.rightArrow, modifierFlags: [])
            settle()
            if tap(application.buttons["More"].firstMatch) {
                keep("\(prefix) 14 Photo More", application)
                dismissMenu(application)
            }
            application.typeKey("i", modifierFlags: .command)
            settle()
            keep("\(prefix) 15 Photo details by Command-I", application)
            window.swipeUp()
            settle()
            keep("\(prefix) 16 Photo details further", application)
            application.typeKey("i", modifierFlags: .command)
            settle()
            if tap(application.buttons["Share"].firstMatch) {
                settle()
                keep("\(prefix) 17 Share", application)
                closeShareSheet(application)
            }
            closeViewer(application)
            keep("\(prefix) 18 After Esc in the viewer", application)
        }
        open(application, photo: environment("WALK_VIDEO"), name: "\(prefix) 19 Video")
        open(application, photo: environment("WALK_LIVE"), name: "\(prefix) 20 Live Photo")

        // Albums and an album.
        tapTab(application, "Albums")
        settle()
        keep("\(prefix) 21 Albums", application)
        let album = application.descendants(matching: .any)
            .matching(NSPredicate(format: "label == 'Japan 2019' OR label == 'Italy 2022'")).firstMatch
        if tap(album) {
            keep("\(prefix) 22 An album", application)
            if tap(application.buttons["Album"].firstMatch) {
                keep("\(prefix) 23 An album's menu", application)
                dismissMenu(application)
            }
            back(application)
        }

        // People and a person.
        tapTab(application, "People")
        settle()
        keep("\(prefix) 24 People", application)
        let person = application.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS 'Andersen' OR label CONTAINS 'Rembrandt'")).firstMatch
        if tap(person) {
            keep("\(prefix) 25 A person", application)
            back(application)
        }

        // Collections and its pages.
        tapTab(application, "Collections")
        settle()
        keep("\(prefix) 26 Collections", application)
        window.swipeUp()
        settle()
        keep("\(prefix) 27 Collections further", application)
        window.swipeUp()
        settle()
        keep("\(prefix) 28 Collections foot", application)
        var number = 30
        for page in ["Memories", "Places", "Map", "Shared Links", "Tags", "Folders", "Archive", "Recently Deleted",
                     "Duplicates", "Large Files", "Assign Location", "Partner Sharing"] {
            let link = application.buttons[page].firstMatch
            for _ in 0..<2 where !(link.exists && link.isHittable) {
                window.swipeDown()
                settle()
            }
            for _ in 0..<3 where !(link.exists && link.isHittable) {
                window.swipeUp()
                settle()
            }
            guard link.exists, link.isHittable else { continue }
            link.tap()
            settle()
            settle()
            keep("\(prefix) \(number) Collections \(page)", application)
            number += 1
            back(application)
        }

        // The account's sheet and its pages, by ⌘, (Settings…).
        application.typeKey(",", modifierFlags: .command)
        settle()
        keep("\(prefix) 50 Account by Command-comma", application)
        number = 51
        for page in ["Immich Features", "Password and Security", "Administration", "Verso Drive", "Back Up", "About Verso"] {
            let link = application.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", page)).firstMatch
            for _ in 0..<3 where !(link.exists && link.isHittable) {
                application.swipeUp()
                settle()
            }
            guard link.exists, link.isHittable else { continue }
            link.tap()
            settle()
            keep("\(prefix) \(number) Account \(page)", application)
            number += 1
            let back = application.navigationBars.buttons.firstMatch
            if back.exists, back.isHittable { back.tap() }
            settle()
        }
        closeSheet(application)

        // Collections' + menu and the imports' pickers.
        tapTab(application, "Collections")
        if tap(application.buttons["Add"].firstMatch) {
            keep("\(prefix) 60 Add menu", application)
            if tap(application.buttons["Import from Photos…"].firstMatch) {
                settle()
                keep("\(prefix) 61 Import from Photos", application)
                closeSheet(application)
            } else {
                dismissMenu(application)
            }
        }
        application.typeKey("i", modifierFlags: [.command, .shift])
        settle()
        settle()
        keep("\(prefix) 62 Import from Files by Shift-Command-I", application)
        closeSheet(application)

        // Search, by ⌘F, with words and its filters.
        tapTab(application, "Library")
        settle()
        application.typeKey("f", modifierFlags: .command)
        settle()
        keep("\(prefix) 70 Search by Command-F", application)
        let field = application.searchFields.firstMatch
        if field.exists, field.isHittable { field.tap() }
        application.typeText("dog\n")
        settle()
        settle()
        keep("\(prefix) 71 Search results", application)
        if tap(application.buttons["Filters"].firstMatch) {
            keep("\(prefix) 72 Search filters", application)
            closeSheet(application)
        }
    }

    /// Each tab's own page, for its title beside or under the tab bar, and a swipe up and down in the viewer for its
    /// details' panel.
    @MainActor
    func testTitles() throws {
        let application = try launchSignedIn()
        keep("T1 Library", application)
        for (index, tab) in ["Albums", "People", "Collections", "Search"].enumerated() {
            tapTab(application, tab)
            settle()
            keep("T\(index + 2) \(tab)", application)
        }
        tapTab(application, "Library")
        settle()
        if let tile = firstTile(application) {
            tile.tap()
            settle()
            application.windows.firstMatch.swipeUp()
            settle()
            keep("T6 Viewer swiped up", application)
            application.windows.firstMatch.swipeDown()
            settle()
            keep("T7 Viewer swiped down", application)
        }
    }

    /// The commands the keyboard has, as the list ⌘ held shows them, in the Library, in Select and in the viewer, and
    /// the viewer's keys; File's New Window, where iPadOS gives it.
    @MainActor
    func testCommands() throws {
        let application = try launchSignedIn()
        holdCommand(application, "80 Command held in the Library")
        application.typeKey("f", modifierFlags: .command)
        settle()
        keep("79 After Command-F", application)
        print("RESULT search field after Command-F: \(application.searchFields.firstMatch.exists)")
        tapTab(application, "Library")
        settle()
        if let tile = firstTile(application) {
            tile.tap()
            settle()
            holdCommand(application, "81 Command held in the viewer")
            application.typeKey(.rightArrow, modifierFlags: [])
            settle()
            keep("82 Viewer after the right arrow", application)
            application.typeKey("i", modifierFlags: .command)
            settle()
            keep("82 Viewer after Command-I", application)
            application.typeKey("i", modifierFlags: .command)
            settle()
            application.typeKey(".", modifierFlags: [])
            settle()
            keep("83 Viewer after a full stop", application)
            application.typeKey(".", modifierFlags: [])
            settle()
            application.typeKey(.delete, modifierFlags: .command)
            settle()
            keep("84 Viewer after Command-Delete", application)
            closeSheet(application)
            closeViewer(application)
        }
        _ = tap(application.buttons["Select"].firstMatch)
        application.typeKey("a", modifierFlags: .command)
        settle()
        holdCommand(application, "85 Command held in Select")
        application.typeKey(.escape, modifierFlags: [])
        settle()
        let before = application.windows.count
        application.typeKey("n", modifierFlags: .command)
        settle()
        settle()
        keep("86 After Command-N", application)
        print("RESULT windows before Command-N \(before), after \(application.windows.count)")
    }

    /// The window made narrow by its corner, as Stage Manager and windowed apps let it be, to a half and to a third of
    /// the screen: the Library, a photo, Albums and Collections at each width.
    @MainActor
    func testNarrowWindow() throws {
        let application = try launchSignedIn()
        let screen = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let size = screen.windows.firstMatch.frame.size
        for (name, fraction) in [("half", 0.5), ("third", 0.36)] {
            let window = application.windows.firstMatch.frame
            let corner = screen.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: window.maxX - 6, dy: window.maxY - 6))
            let target = screen.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: window.minX + size.width * fraction, dy: window.maxY - 6))
            corner.press(forDuration: 0.6, thenDragTo: target, withVelocity: .slow, thenHoldForDuration: 0.5)
            settle()
            settle()
            keep("90 \(name) Library", application)
            if let tile = firstTile(application) {
                tile.tap()
                settle()
                keep("91 \(name) Photo", application)
                closeViewer(application)
            }
            tapTab(application, "Albums")
            settle()
            keep("92 \(name) Albums", application)
            tapTab(application, "Collections")
            settle()
            keep("93 \(name) Collections", application)
            tapTab(application, "Library")
            settle()
        }
    }

    /// Photos itself, the reference: its library, a photo, its menu and its details, and the list ⌘ held shows.
    @MainActor
    func testPhotosReference() throws {
        XCUIDevice.shared.orientation = orientationPrefix == "L" ? .landscapeLeft : .portrait
        let photos = XCUIApplication(bundleIdentifier: "com.apple.mobileslideshow")
        photos.launch()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        settle()
        settle()
        for word in ["Don’t Allow", "Continue", "Not Now", "OK"] {
            if springboard.buttons[word].exists { springboard.buttons[word].tap() }
            if photos.buttons[word].exists { photos.buttons[word].tap() }
        }
        settle()
        keep("R1 Photos library", photos)
        let collections = photos.buttons["Collections"].firstMatch
        if collections.exists {
            collections.tap()
            settle()
            keep("R1 Photos Collections", photos)
            photos.windows.firstMatch.swipeUp()
            settle()
            keep("R1 Photos Collections further", photos)
            photos.buttons["Library"].firstMatch.tap()
            settle()
        }
        holdCommand(photos, "R2 Photos Command held")
        guard let tile = photos.images.allElementsBoundByIndex.last(where: { $0.isHittable }) else {
            return XCTFail("a photo in Photos' grid")
        }
        tile.press(forDuration: 1.2)
        settle()
        keep("R3 Photos tile menu", photos)
        // Beside the menu, where Photos' few photos leave the grid empty.
        photos.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.8)).tap()
        settle()
        tile.tap()
        settle()
        keep("R4 Photos photo", photos)
        holdCommand(photos, "R5 Photos Command held in a photo")
        photos.windows.firstMatch.swipeUp()
        settle()
        keep("R6 Photos details", photos)
    }

    // MARK: Helpers

    /// ⌘ held a moment, which shows the commands the keyboard has here.
    @MainActor
    private func holdCommand(_ application: XCUIApplication, _ name: String) {
        XCUIElement.perform(withKeyModifiers: .command) {
            Thread.sleep(forTimeInterval: 2.5)
            keep(name, application)
        }
        settle()
    }

    private var orientationPrefix: String {
        environment("WALK_ORIENTATION") == "landscape" ? "L" : "P"
    }

    private func environment(_ name: String) -> String? {
        ProcessInfo.processInfo.environment[name].flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Verso Dev signed in to the lab server from the run's environment, in the Library, turned as the run asks.
    @MainActor
    private func launchSignedIn() throws -> XCUIApplication {
        let environment = ProcessInfo.processInfo.environment
        guard let server = environment["IMMICH_URL"], let key = environment["IMMICH_API_KEY"] else {
            throw XCTSkip("needs a lab server: IMMICH_URL and IMMICH_API_KEY in the run's environment")
        }
        XCTAssertFalse(server.contains("demo.immich.app"), "never Immich's demo")
        XCUIDevice.shared.orientation = orientationPrefix == "L" ? .landscapeLeft : .portrait
        let application = XCUIApplication()
        application.launchEnvironment = ["VERSO_SIGN_IN_SERVER": server, "VERSO_SIGN_IN_API_KEY": key]
        application.launch()
        // View Options, as Select goes into the bar's overflow on an iPad mini in portrait.
        XCTAssertTrue(application.buttons["View Options"].waitForExistence(timeout: 60), "the Library shows once signed in")
        settle()
        return application
    }

    /// Opens a photo by its id, scrolling back to its tile, keeps the viewer and its details, then closes it.
    @MainActor
    private func open(_ application: XCUIApplication, photo id: String?, name: String) {
        guard let id else { return }
        tapTab(application, "Library")
        settle()
        let tile = application.descendants(matching: .any)["photo-" + id].firstMatch
        for _ in 0..<15 where !(tile.exists && tile.isHittable) {
            application.windows.firstMatch.swipeDown()
            Thread.sleep(forTimeInterval: 0.8)
        }
        guard tile.exists, tile.isHittable else { return XCTFail("\(name): its tile is not found") }
        tile.tap()
        settle()
        keep(name, application)
        application.windows.firstMatch.swipeUp()
        settle()
        keep(name + " details", application)
        closeViewer(application)
        tapTab(application, "Library")
    }

    /// Esc, and where the viewer still shows (its controls hidden), a tap to bring them and Back.
    @MainActor
    private func closeViewer(_ application: XCUIApplication) {
        application.typeKey(.escape, modifierFlags: [])
        settle()
        guard application.otherElements["Viewer"].exists else { return }
        keep("Viewer still open after Esc", application)
        let back = application.buttons["Back"].firstMatch
        if !back.isHittable {
            application.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            settle()
        }
        if back.isHittable { back.tap() }
        settle()
    }

    /// The first photo tile in view and hittable.
    @MainActor
    private func firstTile(_ application: XCUIApplication) -> XCUIElement? {
        let tiles = application.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'photo-'"))
        return tiles.allElementsBoundByIndex.prefix(80).last { $0.isHittable }
    }

    /// Taps a tab of the tab bar at the top, by its name.
    @MainActor
    private func tapTab(_ application: XCUIApplication, _ name: String) {
        let inBar = application.tabBars.buttons[name].firstMatch
        if inBar.exists, inBar.isHittable { inBar.tap(); return }
        let button = application.buttons[name].firstMatch
        if button.exists, button.isHittable { button.tap() }
    }

    @MainActor
    @discardableResult
    private func tap(_ element: XCUIElement) -> Bool {
        guard element.waitForExistence(timeout: 4), element.isHittable else { return false }
        element.tap()
        settle()
        return true
    }

    @MainActor
    private func back(_ application: XCUIApplication) {
        let button = application.navigationBars.buttons.firstMatch
        if button.exists, button.isHittable { button.tap() }
        settle()
    }

    /// Closes a menu: Esc, and where it still shows, a tap beside it, which the menu takes.
    @MainActor
    private func dismissMenu(_ application: XCUIApplication) {
        application.typeKey(.escape, modifierFlags: [])
        settle()
        guard application.collectionViews.matching(identifier: "Menu").firstMatch.exists
            || application.buttons["Copy"].exists || application.buttons["Sort by Date Captured"].exists
            || application.buttons["Rename"].exists else { return }
        application.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.98)).tap()
        settle()
    }

    /// Closes a sheet: its Close or Cancel button, else Esc.
    @MainActor
    private func closeSheet(_ application: XCUIApplication) {
        for name in ["Close", "Cancel", "Done"] {
            let button = application.buttons[name].firstMatch
            if button.exists, button.isHittable {
                button.tap()
                settle()
                return
            }
        }
        application.typeKey(.escape, modifierFlags: [])
        settle()
    }

    @MainActor
    private func closeShareSheet(_ application: XCUIApplication) {
        let close = application.otherElements["ActivityListView"].buttons["Close"].firstMatch
        if close.exists {
            close.tap()
        } else {
            application.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        settle()
    }

    /// Lets thumbnails and transitions finish before a screenshot.
    private func settle() {
        Thread.sleep(forTimeInterval: 2)
    }

    @MainActor
    private func keep(_ name: String, _ application: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
