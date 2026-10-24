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
        let home = app.buttons["tab.home"]
        XCTAssertTrue(home.waitForExistence(timeout: 12))
        XCTAssertTrue(home.isHittable, "首页标签被挡住了")

        let jump = app.buttons["home.discover"]
        XCTAssertTrue(jump.waitForExistence(timeout: 5))
        XCTAssertTrue(jump.isHittable, "首页的去发现点不到")
        jump.tap()

        let search = app.buttons["discover.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 6), "去发现之后没有出现发现页")
        let discoverTab = app.buttons["tab.discover"]
        XCTAssertTrue(discoverTab.isHittable)
        discoverTab.tap()
        XCTAssertTrue(search.isHittable, "发现页的搜索点不到")
        search.tap()
        let busy = app.descendants(matching: .any)["discover.busy"]
        let failed = app.descendants(matching: .any)["discover.error"]
        XCTAssertTrue(busy.waitForExistence(timeout: 6) || failed.waitForExistence(timeout: 3), "点了搜索没有开始查找")

        let capture = app.buttons["tab.capture"]
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

        let moments = app.buttons["tab.moments"]
        XCTAssertTrue(moments.waitForExistence(timeout: 5))
        XCTAssertTrue(moments.isHittable, "朋友圈标签点不到")
        moments.tap()
        let demo = app.buttons["moments.demo"]
        XCTAssertTrue(demo.waitForExistence(timeout: 5))
        XCTAssertTrue(demo.isHittable, "载入示例点不到")
        demo.tap()
        XCTAssertTrue(app.staticTexts["阿月"].waitForExistence(timeout: 5), "载入示例后没有出现好友")

        let me = app.buttons["tab.me"]
        XCTAssertTrue(me.waitForExistence(timeout: 5))
        XCTAssertTrue(me.isHittable, "我的标签点不到")
        me.tap()
        let settings = app.buttons["me.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        XCTAssertTrue(settings.isHittable, "设置点不到")
        settings.tap()
        XCTAssertTrue(
            app.staticTexts["主题"].waitForExistence(timeout: 5) || app.buttons["主题"].waitForExistence(timeout: 2),
            "设置页没有出现"
        )

        home.tap()
        XCTAssertTrue(app.buttons["home.discover"].waitForExistence(timeout: 5) || app.staticTexts["还没有内容"].waitForExistence(timeout: 2))
    }
}
