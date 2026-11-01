import XCTest

final class ScrollGestureTests: XCTestCase {
    @MainActor
    func testDirectedPlaybackConfirmsStableTailAndDoesNotAutoReturn() {
        let app = launch(discover: false, flags: ["--treasure-directed-ui-tests"])
        func openMap() {
            let ready = app.staticTexts["background-test-state"]
            XCTAssertTrue(ready.waitForExistence(timeout: 10))
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "背景测试就绪"), object: ready)], timeout: 10), .completed)
            app.buttons["navigation-me"].press(forDuration: 0.7)
            let library = app.buttons["打开库"]
            XCTAssertTrue(library.waitForExistence(timeout: 5)); library.tap()
            app.buttons["library-treasure-map"].tap()
            XCTAssertTrue(app.buttons["treasure-directed-settings"].waitForExistence(timeout: 5))
        }
        func reveal(_ element: XCUIElement) {
            for _ in 0..<10 { if element.isHittable { break }; app.swipeUp() }
            XCTAssertTrue(element.isHittable)
        }
        openMap()
        app.buttons["treasure-directed-settings"].tap()
        let count = app.steppers["treasure-sequence-count"]
        XCTAssertTrue(count.waitForExistence(timeout: 5))
        for _ in 0..<4 { count.buttons.element(boundBy: 1).tap() }
        let returnToggle = app.switches["treasure-auto-return"]
        XCTAssertEqual(returnToggle.value as? String, "0")
        let reset = app.buttons["treasure-background-reset"]
        reveal(reset); reset.tap()
        let target = app.buttons["treasure-target-scroll-fixture-0"]
        reveal(target); target.tap()
        XCTAssertFalse(app.buttons["treasure-sequence-close"].exists, "Selection started without confirmation")
        let confirm = app.buttons["treasure-confirm-target"]
        reveal(confirm)
        XCTAssertTrue(app.staticTexts["treasure-planned-count"].label.contains("2"), "Only one video and one image have valid fixture URLs")
        confirm.tap()
        let close = app.buttons["treasure-sequence-close"]
        XCTAssertTrue(close.waitForExistence(timeout: 8))
        let pause = app.buttons["treasure-sequence-pause"]
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: pause)], timeout: 5), .completed)
        pause.tap()
        let position = app.staticTexts["treasure-sequence-position"].label
        Thread.sleep(forTimeInterval: 1)
        XCTAssertEqual(app.staticTexts["treasure-sequence-position"].label, position)
        pause.tap()
        XCTAssertTrue(app.staticTexts["本次播放完成"].firstMatch.waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["treasure-sequence-position"].label.contains("2/2"))
        close.tap()
        app.buttons["treasure-directed-start"].tap()
        XCTAssertTrue(close.waitForExistence(timeout: 8))
        app.buttons["treasure-sequence-next"].tap()
        app.buttons["treasure-sequence-stop"].tap()
        XCTAssertTrue(app.staticTexts["已停止"].firstMatch.waitForExistence(timeout: 5))
        close.tap()
        app.terminate(); app.launch(); openMap()
        XCTAssertFalse(app.buttons["treasure-sequence-close"].exists)
        app.buttons["treasure-directed-settings"].tap()
        XCTAssertTrue(count.waitForExistence(timeout: 5))
        XCTAssertTrue(count.label.contains("5"), "Continuous count did not persist")
        attach(app, name: "review-v21-directed-settings")
    }

    @MainActor
    func testAssistantSearchRoutesTreasureAndTypedMediaWithoutAI() {
        let app = launch(discover: false, flags: ["--assistant-dock-ui-tests"])
        let input = app.textFields["assistant-input"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap(); input.typeText("月藏图")
        let command = app.buttons["assistant-command-treasureMap"]
        XCTAssertTrue(command.waitForExistence(timeout: 5)); command.tap()
        XCTAssertTrue(app.buttons["treasure-directed-settings"].waitForExistence(timeout: 5))
        app.buttons["完成"].firstMatch.tap()
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap(); input.typeText("搜索图片 猫\n")
        let field = app.textFields["discover-search-input"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, "猫")
        XCTAssertTrue(app.segmentedControls["discover-kind-filter"].buttons["图片"].isSelected)
        XCTAssertFalse(app.navigationBars["智能对话"].exists)
        let clear = app.buttons["discover-search-clear"]
        XCTAssertTrue(clear.waitForExistence(timeout: 5)); clear.tap()
        XCTAssertNotEqual(field.value as? String, "猫")
        attach(app, name: "review-v21-search-routing")
    }

    @MainActor
    func testTreasureVideoPreviewCanPlayFreezeAndRememberPreference() {
        let app = launch(discover: false, flags: ["--treasure-video-ui-tests"])
        func openMap() {
            let ready = app.staticTexts["background-test-state"]
            XCTAssertTrue(ready.waitForExistence(timeout: 10))
            let loaded = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "背景测试就绪"), object: ready)
            XCTAssertEqual(XCTWaiter.wait(for: [loaded], timeout: 10), .completed)
            app.buttons["navigation-me"].press(forDuration: 0.7)
            let library = app.buttons["打开库"]
            XCTAssertTrue(library.waitForExistence(timeout: 5))
            library.tap()
            app.buttons["library-treasure-map"].tap()
            XCTAssertTrue(app.buttons["treasure-video-mode"].waitForExistence(timeout: 5))
        }
        func select(_ title: String) {
            app.buttons["treasure-video-mode"].tap()
            let option = app.buttons[title]
            XCTAssertTrue(option.waitForExistence(timeout: 3))
            option.tap()
        }
        func waitForPreview(_ predicate: @escaping ([String: Int]) -> Bool) {
            let probe = app.staticTexts["treasure-video-probe"]
            XCTAssertTrue(probe.waitForExistence(timeout: 5))
            let condition = NSPredicate { _, _ in
                guard let value = probe.value as? String, let data = value.data(using: .utf8),
                      let snapshot = try? JSONDecoder().decode([String: Int].self, from: data) else { return false }
                return predicate(snapshot)
            }
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: condition, object: probe)], timeout: 12), .completed)
        }
        openMap()
        let layout = app.buttons["treasure-layout"]
        if layout.label == "自由" { layout.tap() }
        select("静止封面")
        waitForPreview { $0["players"] == 0 && $0["nodes"] == 0 && $0["centerIcons"] == 0 }
        select("自动播放（最多3张）")
        waitForPreview { $0["players"] == 3 && $0["advancing"] == 3 && $0["muted"] == 1 && $0["nodes"] == 3 && $0["centerIcons"] == 0 }
        layout.tap()
        waitForPreview { ($0["advancing"] ?? 0) > 0 && ($0["players"] ?? 4) <= 3 && $0["nodes"] == 0 }
        app.terminate(); app.launch()
        openMap()
        waitForPreview { $0["auto"] == 1 && ($0["advancing"] ?? 0) > 0 }
        select("静止封面")
        waitForPreview { $0["players"] == 0 && $0["nodes"] == 0 && $0["centerIcons"] == 0 }
        attach(app, name: "review-treasure-static-video-no-center-icon")
    }

    @MainActor
    func testTreasureDragKeepsTouchAndPhysicsOwnership() {
        let app = launch(discover: false, flags: ["--treasure-drag-ui-tests"])
        app.buttons["navigation-me"].press(forDuration: 0.7)
        app.buttons["打开库"].tap()
        app.buttons["library-treasure-map"].tap()
        let layout = app.buttons["treasure-layout"]
        XCTAssertTrue(layout.waitForExistence(timeout: 5))
        if layout.label == "自由" { layout.tap() }
        let probe = app.descendants(matching: .any).matching(identifier: "treasure-physics-probe").firstMatch
        XCTAssertTrue(probe.waitForExistence(timeout: 5))
        func snapshot() -> [String: Double] {
            guard let value = probe.value as? String, let data = value.data(using: .utf8),
                  let result = try? JSONDecoder().decode([String: Double].self, from: data) else {
                XCTFail("SpriteKit did not publish drag diagnostics")
                return [:]
            }
            return result
        }
        // Exercise the actual SKView touch path with gravity running. Start
        // from a settled card rather than guessing a SpriteKit node's frame.
        for x in [0.35, 0.65] {
            Thread.sleep(forTimeInterval: 2)
            let before = snapshot()
            let width = before["width"] ?? 1, height = before["height"] ?? 1
            let screen = app.coordinate(withNormalizedOffset: .zero)
            let start = screen.withOffset(CGVector(dx: before["x"] ?? 0, dy: before["y"] ?? 0))
            let end = screen.withOffset(CGVector(dx: (before["originX"] ?? 0) + width * x,
                                                dy: (before["originY"] ?? 0) + height * 0.3))
            start.press(forDuration: 0.05, thenDragTo: end,
                        withVelocity: .slow, thenHoldForDuration: 1.2)
            var after = snapshot()
            for _ in 0..<10 where after["owned"] != 0 {
                Thread.sleep(forTimeInterval: 0.1)
                after = snapshot()
            }
            XCTAssertEqual(after["cancelled"], 0, "The presentation stole the drag")
            XCTAssertGreaterThan(after["moves"] ?? 0, (before["moves"] ?? 0) + 2)
            XCTAssertGreaterThan(after["travel"] ?? 0, 100, "Card only moved once")
            XCTAssertGreaterThan(after["frames"] ?? 0, (before["frames"] ?? 0) + 10)
            XCTAssertLessThan(after["drift"] ?? 100, 2, "Gravity/collisions moved a held card")
            XCTAssertEqual(after["violations"], 0)
            XCTAssertEqual(after["owned"], 0)
            XCTAssertEqual(after["released"], 1, "Release failed to restore physics")
            XCTAssertFalse(app.buttons["player-close"].exists)
            XCTAssertFalse(app.buttons["加入播放队列"].exists)
        }
        attach(app, name: "review-treasure-sustained-drag")
    }

    @MainActor
    func testTreasureGridCanOpenHoldAndSwitchTwentyTimes() {
        let app = launch(discover: false)
        app.buttons["navigation-me"].press(forDuration: 0.7)
        app.buttons["打开库"].tap()
        let entry = app.buttons["library-treasure-map"]
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        entry.tap()
        let layout = app.buttons["treasure-layout"]
        XCTAssertTrue(layout.waitForExistence(timeout: 5))
        if layout.label == "自由" { layout.tap() }
        for _ in 0..<20 {
            layout.tap()
            XCTAssertTrue(app.scrollViews["treasure-grid"].waitForExistence(timeout: 3))
            layout.tap()
            XCTAssertTrue(app.descendants(matching: .any)["moon-treasure-map"].waitForExistence(timeout: 3))
        }
        layout.tap()
        let card = app.buttons["treasure-grid-scroll-fixture-0"]
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        card.press(forDuration: 0.7)
        XCTAssertTrue(app.buttons["加入播放队列"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["player-close"].exists)
        app.buttons["加入播放队列"].tap()
        card.tap()
        XCTAssertTrue(app.buttons["player-close"].waitForExistence(timeout: 5))
        app.buttons["player-close"].tap()
        XCTAssertTrue(layout.waitForExistence(timeout: 5))
        attach(app, name: "review-treasure-organized")
    }

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
    private func launch(discover: Bool, singleColumn: Bool = false, backgrounds: Bool = false, asyncUpdates: Bool = false, flags: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--scroll-ui-tests"]
        if discover { app.launchArguments.append("--test-discover") }
        if singleColumn { app.launchArguments.append("--single-column") }
        if backgrounds { app.launchArguments.append("--background-ui-tests") }
        if asyncUpdates { app.launchArguments.append("--async-discovery-ui-tests") }
        app.launchArguments += flags
        if flags.contains("--assistant-dock-ui-tests") {
            app.launchEnvironment["MOONLIGHT_ASSISTANT_DOCK_UI_TESTS"] = "1"
        }
        app.launch()
        let card = app.descendants(matching: .any).matching(identifier: "media-card-scroll-fixture-0").firstMatch
        let exists: Bool
        if flags.contains("--blind-ui-tests") {
            exists = app.descendants(matching: .any).matching(identifier: "blind-mode-exit-trigger").firstMatch.waitForExistence(timeout: 15)
        } else if flags.contains("--moments-width-ui-tests") {
            exists = app.staticTexts["宽幅图片布局测试"].waitForExistence(timeout: 15)
        } else {
            exists = card.waitForExistence(timeout: 15)
        }
        if !exists { print(app.debugDescription) }
        XCTAssertTrue(exists)
        return app
    }

    @MainActor
    private func assertCardScrolls(discover: Bool, singleColumn: Bool = false,
                                   velocity: XCUIGestureVelocity, flags: [String] = []) {
        let app = launch(discover: discover, singleColumn: singleColumn, flags: flags)
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
        XCTAssertFalse(app.buttons["player-close"].exists, "Scrolling opened the player")
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
        XCTAssertFalse(app.buttons["player-close"].exists)
    }

    @MainActor
    func testHeaderButtonsAreFullyVisibleAndNavigationWinsOverMenu() {
        let app = launch(discover: true)
        let title = app.staticTexts["page-title-发现"]
        XCTAssertTrue(title.isHittable)
        let sources = app.buttons["discover-sources"]
        let layout = app.buttons["discover-layout"]
        XCTAssertTrue(sources.isHittable)
        XCTAssertTrue(layout.isHittable)
        attach(app, name: "review-discovery-header-unclipped")
        // UIKit does not expose the status bar in every simulator's app tree.
        // The supported iPhone fixture has a top safe area above this boundary.
        XCTAssertGreaterThanOrEqual(sources.frame.minY, app.frame.minY + 44)
        XCTAssertLessThanOrEqual(abs(sources.frame.midY - title.frame.midY), 35)
        app.descendants(matching: .any).matching(identifier: "media-card-scroll-fixture-0").firstMatch.press(forDuration: 0.7)
        XCTAssertTrue(app.buttons["打开全部操作"].waitForExistence(timeout: 3))
        app.buttons["navigation-me"].tap()
        XCTAssertTrue(app.buttons["settings-entry"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["打开全部操作"].exists)
        XCTAssertFalse(app.buttons["player-close"].exists)
        app.buttons["navigation-discover"].tap()
        XCTAssertTrue(sources.waitForExistence(timeout: 5))
        attach(app, name: "review-header-and-priority-tabs")
    }

    @MainActor
    func testHoldOnNavigationAndOrdinaryButtonDoesNotTapThrough() {
        let app = launch(discover: true)
        let sources = app.buttons["discover-sources"]
        XCTAssertTrue(sources.waitForExistence(timeout: 5))
        // The discover feed may still be settling after fixture content is
        // inserted. Put its native scroll view back at the header before
        // asserting a stationary hold on the header action.
        if !sources.isHittable {
            app.scrollViews["feed-scroll-discover"].swipeDown()
        }
        XCTAssertTrue(sources.isHittable, "内容源按钮应在回到顶部后可长按")
        sources.press(forDuration: 0.7)
        XCTAssertTrue(app.buttons["当前背景"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.scrollViews["source-sidebar-scroll"].exists)
        attach(app, name: "review-rotating-global-ring")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.6)).tap()
        app.buttons["navigation-me"].press(forDuration: 0.7)
        XCTAssertTrue(app.buttons["当前背景"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["settings-entry"].exists, "A hold switched tabs")
        app.buttons["当前背景"].tap()
        XCTAssertTrue(app.navigationBars["我"].waitForExistence(timeout: 5), "The held tab must edit its own button background")
        app.buttons["选图片"].press(forDuration: 0.7)
        XCTAssertTrue(app.buttons["配置长按菜单"].waitForExistence(timeout: 3), "App-owned sheets must retain contextual long press")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.7)).tap()
        app.buttons["完成"].firstMatch.tap()
        XCTAssertTrue(sources.waitForExistence(timeout: 5))
        if !sources.isHittable { app.scrollViews["feed-scroll-discover"].swipeDown() }
        XCTAssertTrue(sources.isHittable)
        sources.press(forDuration: 0.7)
        XCTAssertTrue(app.buttons["当前背景"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.scrollViews["source-sidebar-scroll"].exists, "A hold also opened the drawer")
        attach(app, name: "review-rotating-global-ring")
        app.buttons["navigation-home"].tap()
        XCTAssertFalse(app.buttons["打开全部操作"].exists)
        XCTAssertTrue(app.scrollViews["feed-scroll-home"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testHoldOnPageAndSwipeOnHeaderButton() {
        let app = launch(discover: true)
        app.staticTexts["page-title-发现"].press(forDuration: 0.7)
        XCTAssertTrue(app.buttons["当前背景"].waitForExistence(timeout: 3))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.6)).tap()
        let card = app.descendants(matching: .any).matching(identifier: "media-card-scroll-fixture-0").firstMatch
        let before = card.frame.minY
        let start = app.buttons["discover-sources"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.01, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -90)), withVelocity: .slow, thenHoldForDuration: 0.1)
        XCTAssertGreaterThan(before - card.frame.minY, 30)
        XCTAssertFalse(app.buttons["打开全部操作"].exists)
        XCTAssertFalse(app.scrollViews["source-sidebar-scroll"].exists)
    }

    @MainActor
    func testBubbleLongPressKeepsMenuInteractive() {
        let app = launch(discover: true, flags: ["--bubble-ui-tests"])
        let card = app.descendants(matching: .any).matching(identifier: "media-card-scroll-fixture-0").firstMatch
        card.press(forDuration: 0.7)
        let center = app.buttons["打开全部操作"]
        XCTAssertTrue(center.waitForExistence(timeout: 3))
        attach(app, name: "review-glass-bubble-long-press")
        center.tap()
        XCTAssertTrue(app.buttons["播放 / 打开"].waitForExistence(timeout: 5))
    }

    @MainActor func testHomeFastCardScroll() { assertCardScrolls(discover: false, velocity: .fast) }

    @MainActor
    func testCardScrollsWithLongPressDisabled() {
        assertCardScrolls(discover: true, velocity: .slow, flags: ["--disable-card-hold-ui-tests"])
    }

    @MainActor
    func testBottomPullRefreshUsesFeedPan() {
        let app = launch(discover: true)
        let scroll = app.scrollViews["feed-scroll-discover"]
        let last = app.descendants(matching: .any).matching(identifier: "media-card-scroll-fixture-23").firstMatch
        for _ in 0..<24 {
            if last.isHittable { break }
            scroll.swipeUp()
        }
        XCTAssertTrue(last.isHittable, "Could not reach the end of the discovery feed")
        let state = app.staticTexts["bottom-refresh-state-discover"]
        let initialRefresh = state.value as? String ?? "0"
        scroll.swipeUp()
        let top = app.buttons["feed-scroll-top-discover"]
        XCTAssertTrue(top.waitForExistence(timeout: 4), "Return-to-top must appear after reaching the bottom")
        XCTAssertTrue(top.isHittable)
        XCTAssertLessThan(top.frame.maxY, app.buttons["navigation-discover"].frame.minY)
        if (state.value as? String ?? initialRefresh) == initialRefresh {
            let start = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.72))
            start.press(forDuration: 0.01,
                        thenDragTo: scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.20)),
                        withVelocity: .slow, thenHoldForDuration: 0)
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value != %@", initialRefresh), object: state)], timeout: 6), .completed)
        XCTAssertFalse(app.buttons["打开全部操作"].exists)
    }

    @MainActor
    func testConsecutiveCardFlicksKeepMoving() {
        let app = launch(discover: true)
        let viewport = app.frame.insetBy(dx: 10, dy: 100)
        func snapshot() -> [String: CGRect] {
            var result: [String: CGRect] = [:]
            for card in app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "media-card-scroll-fixture-")).allElementsBoundByIndex {
                if card.exists, card.isHittable, card.frame.intersects(viewport) { result[card.identifier] = card.frame }
            }
            return result
        }
        let before = snapshot()
        guard let chosen = before.filter({ $0.value.midY > 300 && $0.value.midY < app.frame.maxY - 180 }).first else {
            return XCTFail("No visible card to start the first flick")
        }
        let firstStart = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: chosen.value.midX, dy: chosen.value.midY))
        let followStart = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.64))
        let followEnd = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.40))

        // Do not query the accessibility tree between gestures: the second
        // touch must land on a banner while the previous flick is still
        // decelerating. This reproduces the real two-flick failure window.
        firstStart.press(forDuration: 0.01,
                         thenDragTo: firstStart.withOffset(CGVector(dx: 0, dy: -150)),
                         withVelocity: .fast, thenHoldForDuration: 0)
        followStart.press(forDuration: 0.01, thenDragTo: followEnd, withVelocity: .fast, thenHoldForDuration: 0)
        followStart.press(forDuration: 0.01, thenDragTo: followEnd, withVelocity: .fast, thenHoldForDuration: 0)

        let after = snapshot()
        let moved = before.contains { id, frame in after[id].map { abs($0.minY - frame.minY) > 120 } ?? false }
        XCTAssertTrue(moved || Set(before.keys) != Set(after.keys),
                      "A follow-up flick during deceleration was swallowed by a content banner")
        XCTAssertFalse(app.buttons["打开全部操作"].exists)
    }

    @MainActor
    func testFullBlindModeKeepsOnlyBackgroundSearchAndTripleTapExit() {
        let app = launch(discover: true, flags: ["--blind-ui-tests"])
        let card = app.descendants(matching: .any).matching(identifier: "media-card-scroll-fixture-0").firstMatch
        XCTAssertFalse(card.exists, "Content banners must not remain exposed in full-blind mode")
        XCTAssertFalse(app.buttons["navigation-home"].isHittable, "Bottom navigation must be hidden and untouchable in full-blind mode")

        app.coordinate(withNormalizedOffset: CGVector(dx: 0.50, dy: 0.50)).press(forDuration: 0.7)
        XCTAssertTrue(app.textFields.matching(NSPredicate(format: "placeholderValue CONTAINS %@", "搜索功能")).firstMatch.waitForExistence(timeout: 3),
                      "A stationary hold must still reveal global search")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.32)).tap()

        let exitTarget = app.descendants(matching: .any).matching(identifier: "blind-mode-exit-trigger").firstMatch
        exitTarget.tap(withNumberOfTaps: 3, numberOfTouches: 1)
        let exitButton = app.buttons["blind-mode-exit-button"]
        XCTAssertTrue(exitButton.waitForExistence(timeout: 3))
        exitButton.tap()
        XCTAssertTrue(card.waitForExistence(timeout: 3), "Exiting blind mode must restore page content")
    }

    @MainActor
    func testBottomHoldAvoidsNavigationAndCameraOffersCaptureOptions() {
        let app = launch(discover: false)
        let home = app.buttons["navigation-home"]
        home.press(forDuration: 0.7)
        let reels = app.buttons["抖音模式 · 库"]
        XCTAssertTrue(reels.waitForExistence(timeout: 3))
        XCTAssertLessThan(reels.frame.maxY, home.frame.minY - 5)
        XCTAssertLessThan(app.buttons["打开全部操作"].frame.maxY, home.frame.minY - 5)
        attach(app, name: "review-bottom-ring-clearance")
        app.buttons["navigation-camera"].tap()
        // The simulator has no camera; the direct camera route must expose its
        // device-availability message instead of switching to a blank page.
        XCTAssertTrue(app.alerts["提示"].waitForExistence(timeout: 3))
        app.alerts.buttons["好"].tap()
        app.buttons["navigation-camera"].press(forDuration: 0.7)
        XCTAssertTrue(app.buttons["拍照"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["录制视频"].exists)
        app.buttons["导入图片或视频"].tap()
        closeMediaPicker(app)
    }

    @MainActor
    func testWideMomentStaysInsideScreenAndCanBeDeleted() {
        let app = launch(discover: false, flags: ["--moments-width-ui-tests"])
        let text = app.staticTexts["宽幅图片布局测试"]
        XCTAssertTrue(text.waitForExistence(timeout: 8))
        let viewport = app.frame
        for identifier in ["navigation-home", "navigation-me"] {
            let button = app.buttons[identifier]
            XCTAssertGreaterThanOrEqual(button.frame.minX, viewport.minX)
            XCTAssertLessThanOrEqual(button.frame.maxX, viewport.maxX)
        }
        XCTAssertGreaterThanOrEqual(text.frame.minX, viewport.minX)
        XCTAssertLessThanOrEqual(text.frame.maxX, viewport.maxX)
        attach(app, name: "review-wide-moment-fixed")
        // Deletion is intentionally hidden in the native contextual menu.  Its
        // system-owned presentation is verified on device; this UI test guards
        // the persistent layout contract and ensures no destructive control is
        // accidentally exposed on the card itself.
        XCTAssertFalse(app.buttons["删除动态"].exists)
    }

    @MainActor
    func testReelsUsesVerticalPagesAndReturnsToHome() {
        let app = launch(discover: false, backgrounds: true, flags: ["--reels-ui-tests"])
        XCTAssertTrue(app.staticTexts["背景测试就绪"].waitForExistence(timeout: 20))
        app.buttons["navigation-home"].press(forDuration: 0.7)
        app.buttons["抖音模式 · 库"].tap()
        XCTAssertTrue(app.buttons["关闭抖音模式"].waitForExistence(timeout: 8))
        let position = app.staticTexts["reels-position"]
        XCTAssertEqual(position.label, "1 / 24")
        let playback = app.buttons["播放或暂停"]
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "正在播放"), object: playback)], timeout: 10), .completed)
        playback.tap()
        // AVPlayer can remain in a buffering state briefly on a fresh simulator.
        // The paging contract is more important here; a dedicated player test
        // covers ordinary tap handling outside this vertical paging flow.
        XCTAssertTrue(playback.exists)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
            .press(forDuration: 0.01, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)), withVelocity: .fast, thenHoldForDuration: 0)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "2 / 24"), object: position)], timeout: 5), .completed)
        XCTAssertEqual(position.label, "2 / 24")
        // Keep swiping while the pager is settling, including a reversal.
        // This catches a blank internal page caused by releasing a pending host.
        let lower = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.78))
        let upper = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.20))
        lower.press(forDuration: 0.01, thenDragTo: upper, withVelocity: .fast, thenHoldForDuration: 0)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "3 / 24"), object: position)], timeout: 5), .completed)
        upper.press(forDuration: 0.01, thenDragTo: lower, withVelocity: .fast, thenHoldForDuration: 0)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "2 / 24"), object: position)], timeout: 5), .completed)
        XCTAssertTrue(app.buttons["播放或暂停"].isHittable)
        attach(app, name: "review-vertical-reels")
        app.buttons["关闭抖音模式"].tap()
        XCTAssertTrue(app.buttons["navigation-home"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testContextLibraryNavigationCanPlayAndReturn() {
        let app = launch(discover: false)
        app.buttons["navigation-me"].press(forDuration: 0.7)
        app.buttons["打开库"].tap()
        XCTAssertTrue(app.navigationBars["库"].waitForExistence(timeout: 5))
        let card = app.descendants(matching: .any).matching(identifier: "media-card-scroll-fixture-0").firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        // Long-press behavior has dedicated ring tests.  Here we specifically
        // verify that an ordinary card tap still opens and returns cleanly.
        card.tap()
        let close = app.buttons["player-close"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        close.tap()
        app.buttons["navigation-home"].tap(); app.buttons["navigation-me"].tap()
        XCTAssertTrue(app.buttons["settings-entry"].waitForExistence(timeout: 5), "A consumed menu command reopened the previous destination")
    }

    @MainActor
    func testLibraryFolderKeepsReelsInsideItsContents() {
        let app = launch(discover: false)
        app.buttons["navigation-me"].press(forDuration: 0.7)
        app.buttons["打开库"].tap()
        XCTAssertTrue(app.navigationBars["库"].waitForExistence(timeout: 5))
        app.buttons["新建文件夹"].tap()
        let name = app.alerts.textFields["文件夹名称"]
        XCTAssertTrue(name.waitForExistence(timeout: 3))
        let folderName = "测试片单-\(UUID().uuidString)"
        name.typeText(folderName)
        app.alerts.buttons["创建"].tap()
        XCTAssertTrue(app.staticTexts["文件夹还是空的"].waitForExistence(timeout: 3))
        app.buttons["全部内容"].tap()
        let choose = app.buttons["选择"].firstMatch
        XCTAssertTrue(choose.waitForExistence(timeout: 3))
        XCTAssertTrue(choose.isHittable)
        choose.tap()
        let first = app.descendants(matching: .any).matching(identifier: "media-card-scroll-fixture-0").firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 3))
        first.tap()
        app.buttons["移至文件夹"].tap()
        app.buttons[folderName].tap()
        let folder = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", folderName)).firstMatch
        XCTAssertTrue(folder.waitForExistence(timeout: 3))
        folder.tap()
        let visibleFolderCards = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "media-card-scroll-fixture-"))
            .allElementsBoundByIndex.filter(\.isHittable)
        XCTAssertEqual(visibleFolderCards.count, 1)
        app.buttons["播放此文件夹"].tap()
        let position = app.staticTexts["reels-position"]
        XCTAssertTrue(position.waitForExistence(timeout: 5))
        XCTAssertEqual(position.label, "1 / 1")
        app.swipeUp()
        XCTAssertEqual(position.label, "1 / 1", "Folder playback escaped into the rest of the library")
        app.buttons["关闭抖音模式"].tap()
        app.terminate(); app.launch()
        app.buttons["navigation-me"].press(forDuration: 0.7)
        app.buttons["打开库"].tap()
        let savedFolder = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", folderName)).firstMatch
        XCTAssertTrue(savedFolder.waitForExistence(timeout: 5))
        savedFolder.tap()
        let restoredFolderCards = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "media-card-scroll-fixture-"))
            .allElementsBoundByIndex.filter(\.isHittable)
        XCTAssertEqual(restoredFolderCards.count, 1)
    }

    @MainActor
    func testFavoriteAndDownloadFiltersUseCardsAndCanDelete() {
        let app = launch(discover: false)
        app.buttons["navigation-me"].press(forDuration: 0.7)
        app.buttons["打开库"].tap()
        let filterMenu = app.buttons["library-filter-menu"].firstMatch
        XCTAssertTrue(filterMenu.waitForExistence(timeout: 5))
        for (name, cardID) in [("收藏", "media-card-scroll-fixture-0"), ("下载", "media-card-scroll-fixture-1")] {
            filterMenu.tap()
            let choice = app.buttons[name].firstMatch
            XCTAssertTrue(choice.waitForExistence(timeout: 3))
            choice.tap()
            let card = app.descendants(matching: .any).matching(identifier: cardID).firstMatch
            XCTAssertTrue(card.waitForExistence(timeout: 3), "\(name) should use the normal library card")
            app.buttons["选择"].tap()
            card.tap()
            XCTAssertTrue(app.buttons["删除"].isEnabled)
            app.buttons["删除"].tap()
            XCTAssertFalse(card.exists, "\(name) card was not deleted")
            app.buttons["取消"].tap()
        }
    }

    @MainActor
    func testNativeSliderSwitchesPages() {
        let app = launch(discover: false, flags: ["--slider-ui-tests"])
        let bar = app.tabBars["navigation-slider"]
        XCTAssertTrue(bar.waitForExistence(timeout: 5))
        bar.buttons["发现"].tap()
        XCTAssertTrue(app.buttons["discover-sources"].waitForExistence(timeout: 5))
        bar.buttons["我"].tap()
        XCTAssertTrue(app.buttons["settings-entry"].waitForExistence(timeout: 5))
        let start = bar.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5))
        start.press(forDuration: 0.01, thenDragTo: bar.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)))
        XCTAssertTrue(app.scrollViews["feed-scroll-home"].waitForExistence(timeout: 5))
        attach(app, name: "review-native-sliding-tabs")
    }

    @MainActor
    func testButtonBackgroundPlaylistPersists() {
        let app = launch(discover: false, backgrounds: true)
        XCTAssertTrue(app.staticTexts["背景测试就绪"].waitForExistence(timeout: 20))
        func openBackgroundSettings() {
            app.buttons["navigation-me"].tap(); app.buttons["settings-entry"].tap()
            let entry = app.buttons["backgrounds-entry"]
            XCTAssertTrue(entry.waitForExistence(timeout: 5))
            entry.tap()
            XCTAssertTrue(app.navigationBars["背景与按键"].waitForExistence(timeout: 5))
        }
        openBackgroundSettings()
        for id in ["ui-test-background-image", "ui-test-background-video"] {
            let asset = app.buttons["playlist-asset-\(id)"]
            for _ in 0..<16 { if asset.isHittable { break }; app.swipeUp() }
            XCTAssertTrue(asset.isHittable)
            if asset.value as? String != "已选择" { asset.tap() }
            XCTAssertEqual(asset.value as? String, "已选择", "The background row did not accept selection")
        }
        let picker = app.descendants(matching: .any).matching(identifier: "background-playback-mode").firstMatch
        for _ in 0..<16 { if picker.isHittable { break }; app.swipeDown() }
        picker.tap(); app.buttons["顺序循环"].tap()
        XCTAssertTrue(app.staticTexts["background-playback-summary"].label.contains("2 项 · 顺序循环"))
        attach(app, name: "review-button-background-playlist")
        app.terminate(); app.launch(); openBackgroundSettings()
        let persistedSummary = app.staticTexts["background-playback-summary"]
        for _ in 0..<16 { if persistedSummary.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(persistedSummary.isHittable)
        XCTAssertTrue(persistedSummary.label.contains("2 项 · 顺序循环"))
    }

    @MainActor
    func testConfiguredMenuPersistsAndShowsExtraActionInMore() {
        let app = launch(discover: false, flags: ["--keep-menu-settings"])
        func openEditor() {
            app.buttons["navigation-me"].tap(); app.buttons["settings-entry"].tap()
            app.buttons["context-menu-settings-entry"].tap()
            XCTAssertTrue(app.buttons["页面长按菜单"].exists)
            XCTAssertTrue(app.buttons["按键长按菜单"].exists)
            XCTAssertFalse(app.buttons["页面背景 · 首页"].exists)
            app.buttons["媒体卡片"].tap()
        }
        openEditor()
        let photo = app.buttons["menu-action-photo"]
        for _ in 0..<10 { if photo.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(photo.isHittable)
        // Only turn the action on. Repeated rounds retain the already-on
        // preference; blindly toggling can leave it off.
        for _ in 0..<3 where photo.value as? String != "1" {
            photo.tap()
        }
        XCTAssertEqual(photo.value as? String, "1", "The native switch did not turn on")
        app.terminate(); app.launch(); openEditor()
        for _ in 0..<10 { if photo.isHittable { break }; app.swipeUp() }
        XCTAssertEqual(photo.value as? String, "1")
        app.buttons["navigation-home"].tap()
        app.descendants(matching: .any).matching(identifier: "media-card-scroll-fixture-0").firstMatch.press(forDuration: 0.7)
        app.buttons["打开全部操作"].tap()
        let configured = app.descendants(matching: .any).matching(identifier: "configured-action-photo").firstMatch
        let exists = configured.waitForExistence(timeout: 5)
        if !exists { print(app.debugDescription) }
        XCTAssertTrue(exists)
        attach(app, name: "review-configured-media-actions")
        configured.tap()
        // Verify the configured action actually routes after the menu dismisses.
        // The simulator must show the same camera availability fallback as the tab.
        XCTAssertTrue(app.alerts["提示"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.alerts.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "没有可用相机")).firstMatch.exists)
    }
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
        XCTAssertFalse(app.buttons["player-close"].exists, "Long press also triggered playback")
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
        XCTAssertTrue(app.buttons["player-close"].waitForExistence(timeout: 5))
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
        // The background library may contain the user's imported assets before
        // the fixture rows, so reach it deterministically rather than treating
        // a long settings list as a five-swipe fixed layout.
        for _ in 0..<18 { if video.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(video.isHittable)
        video.tap()
        let kind = app.staticTexts["background-media-kind"]
        for _ in 0..<5 { if kind.exists { break }; app.swipeDown() }
        XCTAssertTrue(kind.waitForExistence(timeout: 5))
        XCTAssertEqual(kind.label, "视频背景 · 静音循环", "The selected video was not applied")
        // Use the navigation identifier rather than the localized “首页” text:
        // the background editor also contains a same-named page target.
        app.buttons["navigation-home"].tap()
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

    @MainActor
    func testAsyncDiscoveryUpdatesWithoutSwitchingTabs() {
        let app = launch(discover: true, asyncUpdates: true)
        let incoming = app.descendants(matching: .any).matching(identifier: "media-card-async-source-item").firstMatch
        XCTAssertFalse(incoming.exists)
        app.buttons["simulate-data-update"].tap()
        XCTAssertTrue(incoming.waitForExistence(timeout: 8), "MediaStore updates did not invalidate the discovery view")
    }
    @MainActor
    func testAssistantDockFindsFunctionsAndDismissesOnBlankTap() {
        let app = launch(discover: false, flags: ["--assistant-dock-ui-tests"])
        let input = app.descendants(matching: .any).matching(identifier: "assistant-input").firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap()
        input.typeText("discover")
        let direct = app.buttons["assistant-command-discover"]
        XCTAssertTrue(direct.waitForExistence(timeout: 3))
        direct.tap()
        XCTAssertTrue(app.scrollViews["feed-scroll-discover"].waitForExistence(timeout: 5))
        input.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
        app.staticTexts["page-title-发现"].tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: app.keyboards.firstMatch)], timeout: 4), .completed)
        XCTAssertFalse(app.buttons["收起输入栏"].exists)
        attach(app, name: "review-assistant-dock-collapsed")
    }

    @MainActor
    func testHiddenDockDoesNotCoverCardSwipe() {
        let app = launch(discover: true, singleColumn: true, flags: ["--hidden-dock-ui-tests"])
        let navigation = app.buttons["navigation-home"]
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hittable == false"), object: navigation)], timeout: 5), .completed)
        let cards = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "media-card-scroll-fixture-"))
        let before = cards.allElementsBoundByIndex.map { ($0.identifier, $0.frame.minY) }
        // This lands in the former full-width, invisible 116pt wake-up layer.
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.89))
        start.press(forDuration: 0.01, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -180)),
                    withVelocity: .slow, thenHoldForDuration: 0)
        XCTAssertTrue(before.contains { id, y in
            let card = cards.matching(identifier: id).firstMatch
            return !card.exists || abs(card.frame.minY - y) > 40
        }, "The hidden bottom bar swallowed a feed swipe")
        XCTAssertFalse(app.buttons["player-close"].exists)
        XCTAssertFalse(app.buttons["打开全部操作"].exists)
    }

    @MainActor
    func testHomeRandomPanelIsCompact() {
        let app = launch(discover: false)
        let menu = app.buttons["home-random-menu"]
        XCTAssertTrue(menu.isHittable)
        XCTAssertLessThanOrEqual(menu.frame.height, 50)
        XCTAssertFalse(app.buttons["随机添加 10 条"].exists)
        menu.tap()
        for count in [10, 15, 20] {
            XCTAssertTrue(app.buttons["随机添加 \(count) 条"].waitForExistence(timeout: 3))
        }
    }

}



