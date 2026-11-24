// The photo grid's pinch between zoom levels, recorded to set beside Photos' (PhotosReferenceTests.testGridPinchSteps):
// the Library on Immich's demo, read only, pinched slowly and quickly, in and out, each step marked for the recording;
// the photo under the fingers stays under them, and the grid is left at the zoom level it was at, which the other walks
// keep.
//   ios/tools/live/record.sh GridPinchWalkTests

import XCTest

final class GridPinchWalkTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    @MainActor
    func testPinches() throws {
        let application = XCUIApplication()
        application.launchArguments = ["-signInServer", "https://demo.immich.app",
                                       "-signInEmail", "demo@immich.app", "-signInPassword", "demo"]
        application.launch()
        let tiles = application.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'photo-'"))
        XCTAssertTrue(tiles.firstMatch.waitForExistence(timeout: 45), "the Library's photos show once signed in")
        Thread.sleep(forTimeInterval: 3)
        let grid = application.collectionViews.firstMatch
        XCTAssertTrue(grid.exists, "the photo grid is a collection view")
        // Back in time, away from the newest end, where a zoomed-out grid has photos enough below the one under the
        // fingers to keep it there.
        for _ in 0..<6 { grid.swipeDown(velocity: .fast) }
        Thread.sleep(forTimeInterval: 3)
        keep("start", application)
        let startColumns = columns(application, grid: grid)
        let steps: [(name: String, scale: CGFloat, velocity: CGFloat)] = [
            // Open first, to the large tiles XCUITest can close a pinch on (to about 0.7; on a small tile, less).
            ("open slow", 1.5, 0.3), ("close slow", 0.72, -0.2), ("open fast", 1.5, 2), ("close fast", 0.72, -3),
            ("open far", 3, 2),
        ]
        for step in steps {
            let before = columns(application, grid: grid)
            let middle = tileNearMiddle(application, grid: grid)
            let target = pinchTarget(closing: step.scale < 1, middle: middle, application, grid: grid)
            mark(step.name)
            target.pinch(withScale: step.scale, velocity: step.velocity)
            Thread.sleep(forTimeInterval: 2)
            keep(step.name, application)
            let after = columns(application, grid: grid)
            print("RESULT \(step.name): \(before) to \(after) a row")
            XCTAssertTrue(step.scale < 1 ? after > before : after < before,
                          "\(step.name) changes the zoom level: \(before) to \(after) a row")
            if let middle {
                let tile = tileFrames(application).first { $0.identifier == middle.identifier }
                XCTAssertNotNil(tile, "the photo under the fingers is in view after \(step.name)")
                if let frame = tile?.frame {
                    XCTAssertLessThan(abs(frame.midY - middle.frame.midY), max(frame.height, middle.frame.height),
                                      "the photo under the fingers stays under them: \(middle.frame) to \(frame)")
                }
            }
        }
        // Back to the level it was at, one level a pinch.
        for _ in 0..<6 {
            let now = columns(application, grid: grid)
            if now == startColumns || now == 0 { break }
            let target = pinchTarget(closing: now < startColumns, middle: tileNearMiddle(application, grid: grid),
                                     application, grid: grid)
            target.pinch(withScale: now < startColumns ? 0.72 : 1.5, velocity: now < startColumns ? -0.3 : 0.3)
            Thread.sleep(forTimeInterval: 1.5)
        }
        XCTAssertEqual(columns(application, grid: grid), startColumns, "the grid is left at the level it was at")
    }

    /// What a pinch is made on: a closing pinch on the photo in the middle, as one on the whole grid starts with the
    /// fingers on the bars; an opening one on the grid, as XCUITest opens a pinch only so far beyond what it is made
    /// on, and a small tile allows little.
    @MainActor
    private func pinchTarget(closing: Bool, middle: (identifier: String, frame: CGRect)?, _ application: XCUIApplication,
                             grid: XCUIElement) -> XCUIElement {
        guard closing, let middle else { return grid }
        return application.descendants(matching: .any)[middle.identifier]
    }

    /// The tile nearest the middle of the grid, where XCUITest's pinch is.
    @MainActor
    private func tileNearMiddle(_ application: XCUIApplication, grid: XCUIElement) -> (identifier: String, frame: CGRect)? {
        let middle = CGPoint(x: grid.frame.midX, y: grid.frame.midY)
        return tileFrames(application).min { first, second in
            hypot(first.frame.midX - middle.x, first.frame.midY - middle.y)
                < hypot(second.frame.midX - middle.x, second.frame.midY - middle.y)
        }
    }

    /// How many tiles are in the row nearest the middle of the grid.
    @MainActor
    private func columns(_ application: XCUIApplication, grid: XCUIElement) -> Int {
        guard let middle = tileNearMiddle(application, grid: grid) else { return 0 }
        return tileFrames(application).filter { abs($0.frame.midY - middle.frame.midY) < 2 }.count
    }

    /// The tiles on the screen, from one snapshot of the app rather than a query for each.
    @MainActor
    private func tileFrames(_ application: XCUIApplication) -> [(identifier: String, frame: CGRect)] {
        guard let snapshot = try? application.snapshot() else { return [] }
        let screen = application.windows.firstMatch.frame
        var found: [(identifier: String, frame: CGRect)] = []
        func walk(_ element: XCUIElementSnapshot) {
            if element.identifier.hasPrefix("photo-") {
                if screen.contains(CGPoint(x: element.frame.midX, y: element.frame.midY)) {
                    found.append((element.identifier, element.frame))
                }
                return
            }
            element.children.forEach(walk)
        }
        walk(snapshot)
        return found
    }

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
