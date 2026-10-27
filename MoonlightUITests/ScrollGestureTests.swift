import XCTest

final class ScrollGestureTests: XCTestCase {
    @MainActor
    private func launch(discover: Bool, singleColumn: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--scroll-ui-tests"]
        if discover { app.launchArguments.append("--test-discover") }
        if singleColumn { app.launchArguments.append("--single-column") }
        app.launch()
        let card = app.descendants(matching: .any).matching(identifier: "media-card-scroll-fixture-0").firstMatch
        let exists = card.waitForExistence(timeout: 15)
        if !exists { print(app.debugDescription) }
        XCTAssertTrue(exists)
        return app
    }

    @MainActor
    private func assertCardScrolls(discover: Bool, singleColumn: Bool = false,
                                   velocity: XCUIGestureVelocity) {
        let app = launch(discover: discover, singleColumn: singleColumn)
        let card = app.descendants(matching: .any).matching(identifier: "media-card-scroll-fixture-0").firstMatch
        XCTAssertTrue(card.isHittable)
        let before = card.frame.minY
        // Both endpoints begin within the card's visible image area. This
        // reproduces the reported failure instead of swiping through a gap.
        let start = card.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
        let end = start.withOffset(CGVector(dx: 0, dy: -130))
        start.press(forDuration: 0.01, thenDragTo: end,
                    withVelocity: velocity, thenHoldForDuration: 0.15)
        XCTAssertGreaterThan(before - card.frame.minY, 40)
        XCTAssertFalse(app.buttons["关闭"].exists, "Scrolling opened the player")
        XCTAssertFalse(app.buttons["打开全部操作"].exists, "Scrolling opened the long-press ring")

        // Reverse direction from the same card to detect a stuck recognizer.
        let reverseStart = card.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.65))
        let reverseBefore = card.frame.minY
        reverseStart.press(forDuration: 0.01,
                           thenDragTo: reverseStart.withOffset(CGVector(dx: 0, dy: 100)),
                           withVelocity: velocity, thenHoldForDuration: 0.15)
        XCTAssertGreaterThan(card.frame.minY - reverseBefore, 30)
        XCTAssertFalse(app.buttons["打开全部操作"].exists)
        XCTAssertFalse(app.buttons["关闭"].exists)
    }

    @MainActor func testHomeFastCardScroll() { assertCardScrolls(discover: false, velocity: .fast) }
    @MainActor func testHomeSlowCardScroll() { assertCardScrolls(discover: false, velocity: .slow) }
    @MainActor func testDiscoverTwoColumnFastCardScroll() { assertCardScrolls(discover: true, velocity: .fast) }
    @MainActor func testDiscoverTwoColumnSlowCardScroll() { assertCardScrolls(discover: true, velocity: .slow) }
    @MainActor func testDiscoverSingleColumnCardScroll() {
        assertCardScrolls(discover: true, singleColumn: true, velocity: .slow)
    }

    @MainActor
    func testStationaryHoldOpensRingAndReleaseKeepsItOpen() {
        let app = launch(discover: true)
        app.descendants(matching: .any).matching(identifier: "media-card-scroll-fixture-0").firstMatch.press(forDuration: 0.7)
        XCTAssertTrue(app.buttons["打开全部操作"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["关闭"].exists, "Long press also triggered playback")
        // Dismiss outside the ring, then verify a later card scroll is usable.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.15)).tap()
        XCTAssertFalse(app.buttons["打开全部操作"].exists)
        let card = app.descendants(matching: .any).matching(identifier: "media-card-scroll-fixture-0").firstMatch
        let before = card.frame.minY
        let start = card.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
        start.press(forDuration: 0.01, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -130)))
        XCTAssertGreaterThan(before - card.frame.minY, 40)
    }

    @MainActor
    func testShortTapStillOpensPlayer() {
        let app = launch(discover: true)
        app.descendants(matching: .any).matching(identifier: "media-card-scroll-fixture-0").firstMatch.tap()
        XCTAssertTrue(app.buttons["关闭"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["打开全部操作"].exists)
    }

    @MainActor
    func testSourceSwitchPersistsAndSidebarScrolls() {
        let app = launch(discover: true)
        app.buttons["discover-sources"].tap()
        let scroll = app.scrollViews["source-sidebar-scroll"]
        let toggle = app.switches["source-toggle-peertube"]
        for _ in 0..<5 { if toggle.isHittable { break }; scroll.swipeUp() }
        XCTAssertTrue(toggle.isHittable)
        if toggle.value as? String != "1" { toggle.tap() }
        app.terminate()
        app.launch()
        app.buttons["discover-sources"].tap()
        for _ in 0..<5 { if toggle.isHittable { break }; scroll.swipeUp() }
        XCTAssertEqual(toggle.value as? String, "1")
    }
}
