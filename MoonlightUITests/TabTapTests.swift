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
                || app.staticTexts["月光 0.3.1 · iOS"].waitForExistence(timeout: 2),
            "设置页没有出现\n\(app.debugDescription)"
        )
        let done = app.buttons["settings.done"]
        if done.waitForExistence(timeout: 2) { done.tap() }

        home.tap()
        XCTAssertTrue(app.buttons["home.discover"].waitForExistence(timeout: 5) || app.staticTexts["还没有内容"].waitForExistence(timeout: 2))
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

    private func discoverVisible() -> Bool {
        let search = app.buttons["discover.search"]
        if search.waitForExistence(timeout: 6), search.isHittable { return true }
        let root = app.descendants(matching: .any)["discover.root"]
        return root.waitForExistence(timeout: 2) && root.isHittable
    }
}
