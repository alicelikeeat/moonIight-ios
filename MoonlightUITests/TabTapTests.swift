import XCTest

final class TabTapTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_Hans"]
        app.launch()
    }

    func testEveryTabButtonDoesSomething() {
        let home = tab("首页")
        XCTAssertTrue(home.waitForExistence(timeout: 12))
        XCTAssertTrue(home.isHittable, "首页标签被挡住了")

        let jump = app.buttons["home.discover"]
        XCTAssertTrue(jump.waitForExistence(timeout: 5))
        XCTAssertTrue(jump.isHittable, "首页的去发现点不到")
        jump.tap()
        XCTAssertTrue(discoverVisible(), "去发现之后没有出现发现页\n\(app.debugDescription)")

        let discoverTab = tab("发现")
        XCTAssertTrue(discoverTab.isHittable)
        discoverTab.tap()
        let search = app.buttons["discover.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        XCTAssertTrue(search.isHittable, "发现页的搜索点不到")
        search.tap()
        let busy = app.descendants(matching: .any)["discover.busy"]
        let failed = app.descendants(matching: .any)["discover.error"]
        XCTAssertTrue(busy.waitForExistence(timeout: 6) || failed.waitForExistence(timeout: 3), "点了搜索没有开始查找")

        let capture = tab("拍摄")
        XCTAssertTrue(capture.waitForExistence(timeout: 5))
        XCTAssertTrue(capture.isHittable, "拍摄标签点不到")
        capture.tap()
        XCTAssertTrue(app.staticTexts["把此刻留下来"].waitForExistence(timeout: 5))
        let compose = app.buttons["capture.compose"]
        XCTAssertTrue(compose.waitForExistence(timeout: 5))
        XCTAssertTrue(compose.isHittable, "发朋友圈点不到")
        compose.tap()
        XCTAssertTrue(app.staticTexts["发动态"].waitForExistence(timeout: 5), "发朋友圈没有打开发动态")
        app.buttons["取消"].tap()

        let moments = tab("朋友圈")
        XCTAssertTrue(moments.waitForExistence(timeout: 5))
        XCTAssertTrue(moments.isHittable, "朋友圈标签点不到")
        moments.tap()
        let demo = app.buttons["moments.demo"]
        XCTAssertTrue(demo.waitForExistence(timeout: 5))
        XCTAssertTrue(demo.isHittable, "载入示例点不到")
        demo.tap()
        XCTAssertTrue(app.staticTexts["阿月"].waitForExistence(timeout: 5), "载入示例后没有出现好友")

        let me = tab("我")
        XCTAssertTrue(me.waitForExistence(timeout: 5))
        XCTAssertTrue(me.isHittable, "我的标签点不到")
        me.tap()
        let settings = app.buttons["me.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        XCTAssertTrue(settings.isHittable, "设置点不到")
        settings.tap()
        let settingsPage = app.descendants(matching: .any)["settings.root"]
        XCTAssertTrue(
            settingsPage.waitForExistence(timeout: 5)
                || app.staticTexts["外观"].waitForExistence(timeout: 2)
                || app.staticTexts["主题"].waitForExistence(timeout: 2)
                || app.staticTexts["月光 1.0 · iOS"].waitForExistence(timeout: 2),
            "设置页没有出现\n\(app.debugDescription)"
        )
        let done = app.buttons["settings.done"]
        if done.waitForExistence(timeout: 2) { done.tap() }

        home.tap()
        XCTAssertTrue(app.buttons["home.discover"].waitForExistence(timeout: 5) || app.staticTexts["还没有内容"].waitForExistence(timeout: 2))
    }

    func testV1EntryPoints() {
        openSettings()
        openSheet("settings.skins", root: "skins.root", done: "skins.done", expect: ["29 个按键"])
        openSheet("settings.icons", root: "icons.root", done: "icons.done", expect: ["墨色", "素纸", "新月"])
        openSheet("settings.autoplay", root: "moment.autoplay", done: "autoplay.done", expect: ["全部", "指定", "关闭"])
        XCTAssertTrue(app.descendants(matching: .any)["settings.backdrop"].waitForExistence(timeout: 4), "没有首页背景入口")
        openSheet("settings.focus", root: "focus.editor", done: "focus.done")
        let trash = app.descendants(matching: .any)["settings.trash"]
        XCTAssertTrue(trash.waitForExistence(timeout: 4))
        if trash.isHittable { trash.tap() } else { trash.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
        XCTAssertTrue(app.descendants(matching: .any)["trash.root"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["最近删除是空的"].waitForExistence(timeout: 3) || app.descendants(matching: .any)["trash.empty"].exists)
        app.buttons["trash.done"].tap()
        let refresh = app.switches["后台刷新公开源"]
        let refreshId = app.descendants(matching: .any)["settings.refresh"]
        XCTAssertTrue(refresh.waitForExistence(timeout: 4) || refreshId.waitForExistence(timeout: 2), "没有后台刷新开关\n\(app.debugDescription)")

        let drop = app.switches["水滴选择"]
        let dropId = app.descendants(matching: .any)["settings.drop"]
        if !(drop.waitForExistence(timeout: 2) || dropId.waitForExistence(timeout: 1)) {
            app.swipeUp()
        }
        XCTAssertTrue(drop.waitForExistence(timeout: 3) || dropId.waitForExistence(timeout: 2), "没有水滴选择开关\n\(app.debugDescription)")
        if drop.exists, let value = drop.value as? String {
            XCTAssertEqual(value, "0", "水滴选择应该默认关闭")
        }

        let lens = app.switches["底栏滑块"]
        let lensId = app.descendants(matching: .any)["settings.tabLens"]
        if !(lens.waitForExistence(timeout: 2) || lensId.waitForExistence(timeout: 1)) {
            app.swipeUp()
        }
        XCTAssertTrue(lens.waitForExistence(timeout: 3) || lensId.waitForExistence(timeout: 2), "没有底栏滑块开关\n\(app.debugDescription)")
        if lens.exists, let value = lens.value as? String {
            XCTAssertEqual(value, "1", "底栏滑块应该默认打开")
        }

        app.buttons["settings.done"].tap()
        let library = app.buttons["me.library"]
        XCTAssertTrue(library.waitForExistence(timeout: 5))
        library.tap()
        let downloads = app.buttons["下载"]
        XCTAssertTrue(downloads.waitForExistence(timeout: 5))
        downloads.tap()
        XCTAssertTrue(app.descendants(matching: .any)["library.downloads"].waitForExistence(timeout: 5), "我的下载没有出现\n\(app.debugDescription)")
        app.buttons["library.multi"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["library.picking"].waitForExistence(timeout: 4), "多选没有进入选择\n\(app.debugDescription)")
    }

    func testRecordFromTheRing() {
        let jump = app.buttons["home.discover"]
        XCTAssertTrue(jump.waitForExistence(timeout: 12))
        jump.press(forDuration: 1.1)
        let more = app.buttons["ring.more"]
        XCTAssertTrue(more.waitForExistence(timeout: 5), "长按没有打开圆环上的更多\n\(app.debugDescription)")
        more.tap()
        let record = app.buttons["录屏"]
        let recordId = app.descendants(matching: .any)["more.record"]
        XCTAssertTrue(
            record.waitForExistence(timeout: 5) || recordId.waitForExistence(timeout: 2),
            "更多里没有录屏\n\(app.debugDescription)"
        )
        if record.exists { record.tap() } else { recordId.tap() }
        let pill = app.descendants(matching: .any)["record.pill"]
        let denied = app.staticTexts["这台设备现在不能录屏"]
        XCTAssertTrue(
            pill.waitForExistence(timeout: 4) || denied.waitForExistence(timeout: 3),
            "录屏没有开始，也没有说明这台设备不能录\n\(app.debugDescription)"
        )
        if pill.exists, app.buttons["停止"].exists { app.buttons["停止"].tap() }
    }

    private func openSettings() {
        let me = tab("我")
        XCTAssertTrue(me.waitForExistence(timeout: 12))
        me.tap()
        let settings = app.buttons["me.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()
        XCTAssertTrue(app.descendants(matching: .any)["settings.root"].waitForExistence(timeout: 5))
    }

    private func openSheet(_ button: String, root: String, done: String, expect: [String] = []) {
        let opener = app.descendants(matching: .any)[button]
        XCTAssertTrue(opener.waitForExistence(timeout: 5), "找不到 \(button)\n\(app.debugDescription)")
        if opener.isHittable { opener.tap() } else { opener.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
        XCTAssertTrue(app.descendants(matching: .any)[root].waitForExistence(timeout: 5), "\(root) 没有出现\n\(app.debugDescription)")
        for text in expect {
            let label = app.staticTexts[text]
            let button = app.buttons[text]
            XCTAssertTrue(label.waitForExistence(timeout: 3) || button.waitForExistence(timeout: 2), "缺少 \(text)\n\(app.debugDescription)")
        }
        let close = app.buttons[done]
        XCTAssertTrue(close.waitForExistence(timeout: 3), "找不到 \(done)\n\(app.debugDescription)")
        close.tap()
    }

    /// A short drag is a scroll, not a long-press, so the ring stays closed and the tab does not change.
    func testQuickDragDoesNotOpenTheRing() {
        let home = tab("首页")
        XCTAssertTrue(home.waitForExistence(timeout: 12))
        XCTAssertTrue(app.buttons["home.discover"].waitForExistence(timeout: 5))
        let window = app.windows.firstMatch
        let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
        let end = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.62))
        start.press(forDuration: 0.05, thenDragTo: end)
        XCTAssertFalse(app.descendants(matching: .any)["ring.root"].waitForExistence(timeout: 1), "快速滑动弹出了圆环")
        XCTAssertTrue(home.isSelected, "快速滑动把底栏换了页")
        XCTAssertTrue(app.buttons["home.discover"].isHittable, "快速滑动之后首页按钮不在了")
    }

    func testCameraSheetStaysUsable() {
        let capture = tab("拍摄")
        XCTAssertTrue(capture.waitForExistence(timeout: 12))
        capture.tap()
        let photo = app.buttons["capture.photo"]
        XCTAssertTrue(photo.waitForExistence(timeout: 5))
        photo.tap()
        let root = app.descendants(matching: .any)["camera.root"]
        XCTAssertTrue(root.waitForExistence(timeout: 5), "拍照没有打开相机\n\(app.debugDescription)")
        let shutter = app.descendants(matching: .any)["camera.shutter"]
        let missing = app.staticTexts["这台设备没有相机"]
        let library = app.descendants(matching: .any)["camera.library"]
        XCTAssertTrue(
            shutter.waitForExistence(timeout: 3) || missing.waitForExistence(timeout: 2),
            "相机既没有快门，也没有说明这台设备没有相机\n\(app.debugDescription)"
        )
        if missing.exists {
            let album = app.buttons["从相册选照片"]
            let albumText = app.staticTexts["从相册选照片"]
            XCTAssertTrue(
                library.waitForExistence(timeout: 2) || album.waitForExistence(timeout: 2) || albumText.waitForExistence(timeout: 1),
                "没有相机时不能改从相册选\n\(app.debugDescription)"
            )
        }
        app.buttons["camera.close"].tap()
    }

    /// Dragging on the system tab bar changes tabs and never opens the ring, even if the press is slow.
    func testDragOnTabBarSwitchesWithoutRing() {
        let home = tab("首页")
        XCTAssertTrue(home.waitForExistence(timeout: 12))
        let discover = tab("发现")
        XCTAssertTrue(discover.waitForExistence(timeout: 5))

        let far = tab("朋友圈")
        home.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.2, thenDragTo: far.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)))
        XCTAssertFalse(app.descendants(matching: .any)["ring.root"].exists, "拖动底栏弹出了圆环")
        XCTAssertTrue(waitUntil(timeout: 4) { !self.tab("首页").isSelected }, "拖动底栏没有换页\n\(app.debugDescription)")

        if !home.isSelected { home.tap() }
        XCTAssertTrue(app.buttons["home.discover"].waitForExistence(timeout: 5) || home.isSelected)
        home.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 1.0)
        XCTAssertFalse(app.descendants(matching: .any)["ring.root"].exists, "按在底栏上弹出了圆环")
        if app.buttons["取消"].exists { app.buttons["取消"].tap() }
    }

    /// A long-press that starts in the content keeps the tab bar from switching, even when the finger ends on it.
    func testLongPressDragOverTabBarDoesNotSwitch() {
        let home = tab("首页")
        XCTAssertTrue(home.waitForExistence(timeout: 12))
        XCTAssertTrue(app.buttons["home.discover"].waitForExistence(timeout: 5))
        let window = app.windows.firstMatch
        let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.32))
        let end = tab("发现").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.85, thenDragTo: end)
        let switched = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isSelected == true"), object: tab("发现"))
        XCTAssertEqual(XCTWaiter.wait(for: [switched], timeout: 1.5), .timedOut, "长按内容后划过底栏却换了页")
        XCTAssertTrue(home.isSelected)
        XCTAssertFalse(app.buttons["discover.search"].exists)
    }

    /// 水滴选择: releasing on a ring button near the bottom fires it and does not switch tabs.
    func testDropletReleaseNearTheBottom() {
        app.terminate()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_Hans", "-MoonlightDrop"]
        app.launch()
        let home = tab("首页")
        XCTAssertTrue(home.waitForExistence(timeout: 12))
        XCTAssertTrue(app.buttons["home.discover"].waitForExistence(timeout: 5))
        let window = app.windows.firstMatch
        let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.74))
        start.press(forDuration: 1.6)
        let filter = app.descendants(matching: .any)["ring.筛选"]
        XCTAssertTrue(filter.waitForExistence(timeout: 4), "长按没有出现筛选\n\(app.debugDescription)")
        let frame = filter.frame
        let bounds = window.frame
        let nx = (frame.midX - bounds.minX) / bounds.width
        let ny = (frame.midY - bounds.minY) / bounds.height
        XCTAssertGreaterThan(ny, 0.45, "筛选不在屏幕下半部，测不到靠近底栏的松手")
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.06, dy: 0.08)).tap()
        let again = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.74))
        let dest = window.coordinate(withNormalizedOffset: CGVector(dx: nx, dy: ny))
        again.press(forDuration: 1.6, thenDragTo: dest)
        let local = app.buttons["本地"]
        let online = app.buttons["在线"]
        let reshuffle = app.staticTexts["已重新洗牌"]
        XCTAssertTrue(
            local.waitForExistence(timeout: 4) || online.waitForExistence(timeout: 2) || reshuffle.waitForExistence(timeout: 2),
            "水滴松手没有触发靠近底部的圆环按键\n\(app.debugDescription)"
        )
        XCTAssertTrue(home.isSelected, "水滴松手时底栏把页面换了")
        XCTAssertFalse(tab("发现").isSelected)
    }

    func testImmersiveChrome() {
        app.terminate()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_Hans", "-MoonlightImmersive"]
        app.launch()
        let playing = app.descendants(matching: .any)["home.playing"]
        XCTAssertTrue(playing.waitForExistence(timeout: 15), "沉浸测试没有进入播放页\n\(app.debugDescription)")
        let home = tab("首页")
        XCTAssertTrue(waitUntil(timeout: 8) { !home.exists || !home.isHittable }, "播放时底栏还在\n\(app.debugDescription)")
        playing.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).tap()
        XCTAssertTrue(waitUntil(timeout: 4) { home.exists && home.isHittable }, "点一下没有把底栏请回来\n\(app.debugDescription)")
        XCTAssertTrue(waitUntil(timeout: 5) { !home.exists || !home.isHittable }, "安静之后底栏没有再消失\n\(app.debugDescription)")
    }

    /// The same control must both accept a short tap and a long-press that opens the ring.
    func testTapAndLongPressCoexist() {
        let jump = app.buttons["home.discover"]
        XCTAssertTrue(jump.waitForExistence(timeout: 12))
        XCTAssertTrue(jump.isHittable, "去发现点不到")

        jump.tap()
        XCTAssertTrue(discoverVisible(), "短按去发现没有打开发现页\n\(app.debugDescription)")

        let home = tab("首页")
        home.tap()
        XCTAssertTrue(jump.waitForExistence(timeout: 5))
        XCTAssertTrue(jump.isHittable, "回到首页后去发现不在了")

        jump.press(forDuration: 1.1)
        let ring = app.descendants(matching: .any)["ring.root"]
        let filter = app.staticTexts["筛选"]
        XCTAssertTrue(
            ring.waitForExistence(timeout: 4) || filter.waitForExistence(timeout: 2),
            "长按同一个按钮没有打开圆环\n\(app.debugDescription)"
        )

        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.1)).tap()
        XCTAssertTrue(jump.waitForExistence(timeout: 4))
        jump.tap()
        XCTAssertTrue(discoverVisible(), "长按之后短按失效了\n\(app.debugDescription)")
    }

    private func tab(_ title: String) -> XCUIElement {
        let bar = app.tabBars.buttons[title]
        if bar.exists { return bar }
        let button = app.buttons[title]
        if button.exists { return button }
        return bar
    }

    private func waitUntil(timeout: TimeInterval, _ check: @escaping () -> Bool) -> Bool {
        let exp = expectation(description: "condition")
        let timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { timer in
            if check() {
                exp.fulfill()
                timer.invalidate()
            }
        }
        let result = XCTWaiter.wait(for: [exp], timeout: timeout)
        timer.invalidate()
        return result == .completed
    }

    private func discoverVisible() -> Bool {
        let search = app.buttons["discover.search"]
        if search.waitForExistence(timeout: 6), search.isHittable { return true }
        let root = app.descendants(matching: .any)["discover.root"]
        return root.waitForExistence(timeout: 2) && root.isHittable
    }
}
