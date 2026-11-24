// Walks through four of the maintainer's fixes from trying Verso on an iPhone, keeping a screenshot of each step: the
// map pinched and panned over its pins and a pin opening its photos; the card pages' pinch and Zoom In and Zoom Out,
// with the card under the fingers kept in place; the Archive as a tab of the tab bar; and Newest at the Top. Each signs
// Verso Dev in to Immich's demo as TourTests does and only reads there: the tab bar and the newest end are this
// device's settings, and each walk puts them back to their defaults, since the Simulator is shared.

import XCTest

final class PolishWalkTests: XCTestCase {
    /// The map in the tab bar for this run alone (the launch arguments' defaults), opened at the start.
    @MainActor
    func testMapPinchOverPins() throws {
        continueAfterFailure = true
        let application = launch(extra: ["-tabBarChoices", "places", "-startTab", "places"])
        let pins = application.buttons.matching(NSPredicate(format: "label ENDSWITH ' photos' OR label == '1 photo'"))
        XCTAssertTrue(pins.firstMatch.waitForExistence(timeout: 30), "the map shows its pins")
        settle()
        keep("01 Map", application)

        // A pinch whose fingers start on a pin zooms the map.
        let pin = pins.firstMatch
        let before = pin.frame
        pin.pinch(withScale: 3, velocity: 2)
        settle()
        keep("02 Map pinched over a pin", application)
        let after = pins.firstMatch.exists ? pins.firstMatch.frame : .zero
        XCTAssertNotEqual(before, after, "the pins moved: the map zoomed")

        // A pan that starts on a pin moves the map.
        if pins.firstMatch.exists {
            let start = pins.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: -120, dy: 80)), withVelocity: .default,
                        thenHoldForDuration: 0.1)
            settle()
            keep("03 Map panned from a pin", application)
        }

        // A tap on a pin opens its photos.
        let tapped = pins.allElementsBoundByIndex.first { $0.isHittable }
        XCTAssertNotNil(tapped, "a pin is in view")
        tapped?.tap()
        XCTAssertTrue(application.buttons["Select"].waitForExistence(timeout: 15), "a pin opens its photos")
        settle()
        keep("04 A pin's photos", application)

        // Back on the map, the same pin opens its photos again.
        application.navigationBars.buttons.element(boundBy: 0).tap()
        settle()
        let again = pins.allElementsBoundByIndex.first { $0.isHittable }
        again?.tap()
        XCTAssertTrue(application.buttons["Select"].waitForExistence(timeout: 15), "a pin opens its photos again")
        settle()
        keep("05 A pin's photos again", application)
    }

    /// Albums from covers to cards to one card a row and back, by pinches and by Zoom In and Zoom Out: the card under
    /// the pinch keeps its place each time.
    @MainActor
    func testCardPinch() throws {
        continueAfterFailure = true
        let application = launch()
        let albumsTab = application.tabBars.buttons["Albums"].firstMatch
        XCTAssertTrue(albumsTab.waitForExistence(timeout: 10), "Albums is in the tab bar")
        albumsTab.tap()
        settle()
        zoomOutFully(application)
        settle()
        keep("10 Albums covers", application)

        pinchCard(application, scale: 2.2, name: "11 Cards after a pinch out")
        pinchCard(application, scale: 2.2, name: "12 One card a row after a pinch out")
        pinchCard(application, scale: 0.4, name: "13 Cards after a pinch in")
        pinchCard(application, scale: 0.4, name: "14 Covers after a pinch in")

        // Zoom In and Zoom Out in View Options keep the card in the middle of the view.
        let middle = cardNearMiddle(application)
        let middleLabel = middle?.label
        let middleFrame = middle?.frame
        if openViewOptions(application) {
            application.buttons["Zoom In"].firstMatch.tap()
            settle()
            keep("15 Cards after Zoom In", application)
            if let middleLabel, let middleFrame {
                let now = card(named: middleLabel, application)
                XCTAssertTrue(now.map { $0.frame.minY < middleFrame.maxY && $0.frame.maxY > middleFrame.minY } ?? false,
                              "Zoom In keeps the middle card in view where it was")
            }
        }
        if openViewOptions(application) {
            application.buttons["Zoom Out"].firstMatch.tap()
            settle()
            keep("16 Covers after Zoom Out", application)
        }
        zoomOutFully(application)
    }

    /// The Archive put in the tab bar in Customize, as a tab with its own place, left out of Collections; then the tab
    /// bar back as it was.
    @MainActor
    func testArchiveTab() throws {
        continueAfterFailure = true
        let application = launch()
        let window = application.windows.firstMatch
        let collections = application.tabBars.buttons["Collections"].firstMatch
        XCTAssertTrue(collections.waitForExistence(timeout: 10), "Collections is in the tab bar")

        openCustomize(application)
        keep("20 Customize", application)
        // From the default bar, Albums alone, whatever an earlier run left.
        setTick(application, "People", shown: false)
        setTick(application, "Archive", shown: true)
        keep("21 Customize with the Archive", application)
        application.buttons["Done"].firstMatch.tap()
        settle()
        keep("21 Collections without the Archive", application)
        // Back at Collections' top, the whole tab bar.
        window.swipeDown()
        window.swipeDown()
        settle()
        keep("21 Tab bar with the Archive", application)

        let archiveTab = application.tabBars.buttons["Archive"].firstMatch
        XCTAssertTrue(archiveTab.waitForExistence(timeout: 5), "the Archive is a tab")
        archiveTab.tap()
        settle()
        keep("22 Archive tab", application)
        window.swipeDown()
        settle()
        window.swipeDown()
        settle()
        keep("23 Archive scrolled back", application)
        let scrolledBack = screenshotOfContent(application)

        application.tabBars.buttons["Library"].firstMatch.tap()
        settle()
        archiveTab.tap()
        settle()
        keep("24 Archive tab again, where it was", application)
        XCTAssertEqual(scrolledBack, screenshotOfContent(application), "the Archive keeps its place between tabs")

        // A tap on the tab shown goes to its newest photos.
        archiveTab.tap()
        settle()
        archiveTab.tap()
        settle()
        keep("25 Archive tab tapped", application)

        collections.tap()
        settle()
        var listed = false
        for screen in 0..<5 {
            keep("26 Collections without the Archive \(screen)", application)
            let archiveRow = application.scrollViews.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Archive'")).firstMatch
            if archiveRow.exists { listed = true }
            if application.buttons["Customize"].isHittable { break }
            window.swipeUp()
            settle()
        }
        XCTAssertFalse(listed, "Collections leaves out the Archive while the tab bar holds it")

        // The tab bar's default again: Albums alone.
        openCustomize(application)
        setTick(application, "Archive", shown: false)
        keep("27 Customize back to Albums", application)
        application.buttons["Done"].firstMatch.tap()
        settle()
        window.swipeDown()
        window.swipeDown()
        settle()
        XCTAssertTrue(application.tabBars.buttons["Albums"].exists, "Albums is still in the tab bar")
        XCTAssertFalse(application.tabBars.buttons["Archive"].exists, "the Archive has left the tab bar")
        keep("28 Tab bar as it was", application)
    }

    /// Newest at the Top: the Library opens and lands at the top, the tab bar shrinks scrolling down, Years, Months and
    /// All come once scrolled away, and Years and Months have the newest at the top; then Newest at the Bottom again.
    @MainActor
    func testNewestAtTop() throws {
        continueAfterFailure = true
        let application = launch()
        let window = application.windows.firstMatch
        keep("30 Newest at the bottom", application)

        chooseNewestEnd(application, "Newest at the Top")
        keep("31 Newest at the top", application)
        XCTAssertTrue(application.staticTexts.matching(NSPredicate(format: "label ENDSWITH ' Items'")).firstMatch.exists,
                      "the count is under the title at the newest end")

        // The viewer pages in the grid's order: from the newest, at the top left, to the one beside it.
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.2)).tap()
        let back = application.buttons["Back"].firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 15), "a photo opens from its tile")
        settle()
        keep("31 The newest photo", application)
        window.swipeLeft()
        settle()
        keep("31 The photo beside it", application)
        if back.exists { back.tap() }
        settle()

        window.swipeUp()
        settle()
        keep("32 Scrolled down, away from the newest", application)
        XCTAssertTrue(application.buttons["Years"].exists, "Years, Months and All come once scrolled away")
        drag(window, from: 0.5, to: 0.6)
        settle()
        keep("33 A little back up", application)
        window.swipeDown()
        settle()
        window.swipeDown()
        settle()
        keep("34 Back at the top", application)
        XCTAssertFalse(application.buttons["Years"].exists, "Years, Months and All go at the newest end")

        // A filter lands at the newest end, at the top.
        window.swipeUp()
        settle()
        openViewOptions(application)
        tap(application, "Favorites")
        settle()
        keep("35 Favorites, at the top", application)
        window.swipeUp()
        settle()
        openViewOptions(application)
        tap(application, "All Items")
        settle()
        keep("36 All Items again, at the top", application)

        // A tap on the Library tab returns to the top.
        window.swipeUp()
        settle()
        window.swipeUp()
        settle()
        keep("37 Scrolled down again", application)
        let library = application.tabBars.buttons["Library"].firstMatch
        library.tap()
        settle()
        keep("38 Shrunk tab tapped", application)
        library.tap()
        settle()
        keep("39 Library tab tapped, at the top", application)

        // Years and Months, the newest at the top.
        window.swipeUp()
        settle()
        choose(application, "Years")
        keep("40 Years, newest at the top", application)
        choose(application, "Months")
        keep("41 Months, newest at the top", application)
        choose(application, "All")
        keep("42 All again", application)

        chooseNewestEnd(application, "Newest at the Bottom")
        keep("43 Newest at the bottom again", application)
        window.swipeDown()
        settle()
        keep("44 Scrolled back up", application)
        XCTAssertTrue(application.buttons["Years"].exists, "scrolled up, back in time, Years, Months and All come")
    }

    // MARK: Helpers

    @MainActor
    private func launch(extra: [String] = []) -> XCUIApplication {
        let application = XCUIApplication()
        application.launchArguments = ["-signInServer", "https://demo.immich.app",
                                       "-signInEmail", "demo@immich.app", "-signInPassword", "demo"] + extra
        application.launch()
        XCTAssertTrue(application.tabBars.buttons["Library"].waitForExistence(timeout: 45), "signed in")
        settle()
        return application
    }

    /// Pinches the album card nearest the middle of the view, and checks it is under the pinch's point afterwards.
    @MainActor
    private func pinchCard(_ application: XCUIApplication, scale: CGFloat, name: String) {
        guard let target = cardNearMiddle(application) else {
            XCTFail("no card to pinch before \(name)")
            return
        }
        let label = target.label
        let frame = target.frame
        let point = CGPoint(x: frame.midX, y: frame.midY)
        target.pinch(withScale: scale, velocity: scale > 1 ? 2 : -2)
        keep(name + " (at once)", application)
        settle()
        keep(name, application)
        let moved = card(named: label, application)
        XCTAssertNotNil(moved, "\(label) is still in view after \(name)")
        if let moved {
            let now = moved.frame
            XCTAssertTrue(now.insetBy(dx: -8, dy: -8).contains(CGPoint(x: now.midX, y: point.y)),
                          "\(label) stays under the pinch: it was at \(point.y), it is now \(now.minY)...\(now.maxY)")
        }
    }

    /// The album card nearest the middle of the window, not a section's header.
    @MainActor
    private func cardNearMiddle(_ application: XCUIApplication) -> XCUIElement? {
        let middle = application.windows.firstMatch.frame.midY
        let cards = application.collectionViews.firstMatch.buttons.allElementsBoundByIndex.filter { element in
            let value = element.value as? String ?? ""
            // A card with a name to find it by again: an untitled album's label is only its count.
            return element.isHittable && value != "Collapsed" && value != "Expanded" && !cardNames(element.label).isEmpty
        }
        return cards.min { abs($0.frame.midY - middle) < abs($1.frame.midY - middle) }
    }

    /// The album card with the name a label has, as a cover ("Shared publicly, Name, 12") or a card ("Name"): the
    /// parts of the labels, between commas, share the name.
    @MainActor
    private func card(named label: String, _ application: XCUIApplication) -> XCUIElement? {
        let wanted = cardNames(label)
        return application.collectionViews.firstMatch.buttons.allElementsBoundByIndex.first { element in
            !cardNames(element.label).isDisjoint(with: wanted)
        }
    }

    /// The parts of a card's label that name it, without its counts and its sharing.
    private func cardNames(_ label: String) -> Set<String> {
        Set(label.components(separatedBy: ", ").filter { part in
            !part.isEmpty && Int(part.replacingOccurrences(of: ",", with: "")) == nil && !part.hasPrefix("Shared")
        })
    }

    @MainActor
    @discardableResult
    private func openViewOptions(_ application: XCUIApplication) -> Bool {
        let viewOptions = application.buttons["View Options"].firstMatch
        guard viewOptions.waitForExistence(timeout: 5) else { return false }
        viewOptions.tap()
        settle()
        return true
    }

    /// Zoom Out from View Options until the cards are at the page's smallest.
    @MainActor
    private func zoomOutFully(_ application: XCUIApplication) {
        for _ in 0..<5 {
            guard openViewOptions(application) else { return }
            let zoomOut = application.buttons["Zoom Out"].firstMatch
            guard zoomOut.exists, zoomOut.isEnabled else {
                tapTitleArea(application)
                return
            }
            zoomOut.tap()
            settle()
        }
    }

    /// The Library's View Options, its View Options submenu, and Newest at the Bottom or at the Top in it.
    @MainActor
    private func chooseNewestEnd(_ application: XCUIApplication, _ end: String) {
        openViewOptions(application)
        let submenu = application.buttons.matching(NSPredicate(format: "label == 'View Options'")).allElementsBoundByIndex
            .last { $0.isHittable }
        submenu?.tap()
        settle()
        keep("View Options submenu for \(end)", application)
        tap(application, end)
        settle()
    }

    /// Collections' Customize, at the foot of its page.
    @MainActor
    private func openCustomize(_ application: XCUIApplication) {
        application.tabBars.buttons["Collections"].firstMatch.tap()
        settle()
        let customize = application.buttons["Customize"].firstMatch
        for _ in 0..<6 where !(customize.exists && customize.isHittable) {
            application.windows.firstMatch.swipeUp()
            settle()
        }
        customize.tap()
        settle()
    }

    /// Ticks a page in Customize's Tab Bar section, or takes its tick away.
    @MainActor
    private func setTick(_ application: XCUIApplication, _ page: String, shown: Bool) {
        let tick = application.buttons.matching(NSPredicate(format: "label == %@ AND (value == 'Shown' OR value == 'Hidden')", page))
            .firstMatch
        XCTAssertTrue(tick.waitForExistence(timeout: 5), "\(page) has a tick in Customize")
        guard (tick.value as? String == "Shown") != shown else { return }
        tick.tap()
        settle()
    }

    /// Chooses a segment of Years, Months and All.
    @MainActor
    private func choose(_ application: XCUIApplication, _ segment: String) {
        let button = application.buttons[segment].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5), "\(segment) is offered")
        button.tap()
        settle()
        // All at the newest end shows no picker.
        if button.exists, !button.isSelected {
            button.tap()
            settle()
        }
    }

    /// Taps a control by its name: a button, a menu's toggle, or a text.
    @MainActor
    private func tap(_ application: XCUIApplication, _ name: String) {
        for query in [application.buttons, application.switches, application.staticTexts] {
            let element = query[name].firstMatch
            if element.exists {
                element.tap()
                return
            }
        }
        XCTFail("no control named \(name)")
    }

    /// A finger dragged slowly from one point of the window to another, as fractions of its height.
    @MainActor
    private func drag(_ window: XCUIElement, from start: CGFloat, to end: CGFloat) {
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: start))
            .press(forDuration: 0.01, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: end)),
                   withVelocity: XCUIGestureVelocity(250), thenHoldForDuration: 0.3)
    }

    /// What the window's grid shows, for comparing two moments: the labels of the photos in view.
    @MainActor
    private func screenshotOfContent(_ application: XCUIApplication) -> [String] {
        application.collectionViews.firstMatch.buttons.allElementsBoundByIndex.prefix(40).filter(\.isHittable).map(\.label)
    }

    /// Closes a menu by a tap where nothing else answers: the title's area.
    @MainActor
    private func tapTitleArea(_ application: XCUIApplication) {
        application.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.06)).tap()
        settle()
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
