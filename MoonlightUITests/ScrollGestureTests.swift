import XCTest

final class ScrollGestureTests: XCTestCase {
    @MainActor
    private func attach(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func closeMediaPicker(_ app: XCUIApplication) {
        let labels = ["Cancel", "取消", "Close", "关闭", "Dismiss"]
        let dismiss = app.buttons.matching(NSPredicate(format: "label IN %@ OR identifier IN %@", labels, labels)).firstMatch
        let shown = dismiss.waitForExistence(timeout: 8)
        if !shown { print(app.debugDescription); attach(app, name: "review-picker-failure") }
        XCTAssertTrue(shown, "The native media picker did not expose a dismiss control")
        if shown { dismiss.tap() }
    }
    @MainActor
    private func launch(discover: Bool, singleColumn: Bool = false, backgrounds: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--scroll-ui-tests"]
        if discover { app.launchArguments.append("--test-discover") }
        if singleColumn { app.launchArguments.append("--single-column") }
        if backgrounds { app.launchArguments.append("--background-ui-tests") }
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

        // A fast flick can move the original card outside the viewport. Begin
        // the reverse drag on a fully visible card, away from system bars.
        let viewport = app.scrollViews[discover ? "feed-scroll-discover" : "feed-scroll-home"].frame
        var reverseCard = card
        let cards = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "media-card-scroll-fixture-")).allElementsBoundByIndex
        for candidate in cards {
            if candidate.isHittable, candidate.frame.minY > viewport.minY + 10, candidate.frame.maxY < viewport.maxY - 76 {
                reverseCard = candidate; break
            }
        }
        print("Forward card before: \(before), after: \(card.frame); reverse card: \(reverseCard.frame); viewport: \(viewport)")
        let reverseStart = reverseCard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
        let reverseBefore = reverseCard.frame.minY
        reverseStart.press(forDuration: 0.01,
                           thenDragTo: reverseStart.withOffset(CGVector(dx: 0, dy: 100)),
                           withVelocity: velocity, thenHoldForDuration: 0.15)
        XCTAssertGreaterThan(reverseCard.frame.minY - reverseBefore, 30)
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
        attach(app, name: "review-source-sidebar")
    }

    @MainActor
    func testBackgroundImagesVideosAndEditorKeepCardScrolling() {
        let app = launch(discover: false, backgrounds: true)
        XCTAssertTrue(app.staticTexts["背景测试就绪"].waitForExistence(timeout: 20))
        app.buttons["我"].tap()
        app.buttons["settings-entry"].tap()
        app.buttons["backgrounds-entry"].tap()
        app.buttons["background-target-page.home"].tap()
        attach(app, name: "review-background-editor")
        let video = app.buttons["使用这个视频背景"].firstMatch
        for _ in 0..<5 { if video.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(video.isHittable)
        video.tap()
        let kind = app.staticTexts["background-media-kind"]
        for _ in 0..<5 { if kind.exists { break }; app.swipeDown() }
        XCTAssertTrue(kind.waitForExistence(timeout: 5))
        XCTAssertEqual(kind.label, "视频背景 · 静音循环", "The selected video was not applied")
        app.buttons["首页"].tap()
        let card = app.descendants(matching: .any).matching(identifier: "media-card-scroll-fixture-0").firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        let before = card.frame.minY
        let start = card.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
        start.press(forDuration: 0.01, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -130)), withVelocity: .slow, thenHoldForDuration: 0.15)
        XCTAssertGreaterThan(before - card.frame.minY, 40)
        XCTAssertFalse(app.buttons["打开全部操作"].exists)
        attach(app, name: "review-floating-tabs-video-background")
    }

    @MainActor
    func testProfileAvatarAndCoverOpenNativeMediaPicker() {
        let app = launch(discover: false)
        app.buttons["朋友圈"].tap()
        let avatar = app.buttons["更换朋友圈头像"]
        XCTAssertTrue(avatar.waitForExistence(timeout: 5))
        avatar.tap()
        attach(app, name: "review-profile-avatar-picker")
        closeMediaPicker(app)
        app.buttons["更换朋友圈横幅"].tap()
        attach(app, name: "review-profile-cover-picker")
        closeMediaPicker(app)
    }
}
