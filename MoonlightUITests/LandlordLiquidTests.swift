import XCTest

final class LandlordLiquidTests: XCTestCase {
    @MainActor private func openTable(_ app: XCUIApplication) {
        XCTAssertTrue(app.buttons["navigation-me"].waitForExistence(timeout: 20)); app.buttons["navigation-me"].tap()
        let entrance = app.buttons["me-treasure-map"]
        XCTAssertTrue(entrance.waitForExistence(timeout: 8)); entrance.tap()
        let mode = app.buttons["treasure-landlord-mode"]
        XCTAssertTrue(mode.waitForExistence(timeout: 8)); mode.tap()
        XCTAssertTrue(app.buttons["landlord-seat-0"].waitForExistence(timeout: 12))
    }
    @MainActor private func launch() -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(); app.launchArguments = ["--scroll-ui-tests", "--landlord-liquid-ui-tests"]
        app.launch(); openTable(app); return app
    }
    @MainActor private func probe(_ app: XCUIApplication) -> String {
        app.staticTexts["landlord-liquid-probe"].value as? String ?? ""
    }
    @MainActor private func wait(_ app: XCUIApplication, timeout: TimeInterval = 25, _ condition: @escaping (String) -> Bool) {
        let p = NSPredicate { _, _ in condition(self.probe(app)) }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: p, object: nil)], timeout: timeout), .completed, probe(app))
    }
    @MainActor private func settings(_ app: XCUIApplication) {
        app.buttons["landlord-table-menu"].tap(); app.buttons["牌面、明牌与角色"].tap()
        XCTAssertTrue(app.buttons["landlord-reveal-all"].waitForExistence(timeout: 5))
    }
    @MainActor private func done(_ app: XCUIApplication) { app.navigationBars.buttons["完成"].firstMatch.tap() }
    @MainActor private func snapshot(_ app: XCUIApplication, _ name: String) {
        let item = XCTAttachment(screenshot: app.screenshot()); item.name = name; item.lifetime = .keepAlways; add(item)
    }
    @MainActor func testVisibilityInspectionAndBothOrientations() {
        let app = launch()
        for seat in 0..<3 { XCTAssertTrue(app.buttons["landlord-seat-\(seat)"].exists) }
        XCTAssertTrue(app.staticTexts["landlord-hidden-hand-1"].exists)
        let initial = probe(app)
        snapshot(app, "landlord-portrait")
        settings(app); app.buttons["landlord-reveal-all"].tap(); done(app)
        XCTAssertTrue(app.staticTexts["landlord-visible-hand-1"].waitForExistence(timeout: 5))
        app.buttons["landlord-seat-1"].tap()
        let inspected = app.descendants(matching: .any).matching(identifier: "landlord-inspected-card").firstMatch
        XCTAssertTrue(inspected.waitForExistence(timeout: 5)); XCTAssertNotEqual(inspected.label, "已遮挡的牌")
        app.switches["landlord-inspection-reveal"].tap()
        XCTAssertEqual(inspected.label, "已遮挡的牌")
        XCTAssertEqual(probe(app), initial, "Inspection pauses the round")
        done(app)
        for direction in [UIDeviceOrientation.landscapeLeft, .landscapeRight] {
            XCUIDevice.shared.orientation = direction
            let layout = app.descendants(matching: .any).matching(identifier: "landlord-liquid-layout").firstMatch
            let landscape = NSPredicate(format: "value == %@", "横屏")
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: landscape, object: layout)], timeout: 12), .completed)
            XCTAssertEqual(probe(app), initial)
            XCTAssertTrue(app.buttons["landlord-bid-3"].isHittable)
            snapshot(app, "landlord-\(direction.rawValue)")
        }
        XCUIDevice.shared.orientation = .portrait
    }
    @MainActor func testWildCompleteGameFullDeckAndRestart() {
        let app = launch(); settings(app)
        let wild = app.switches["landlord-next-wild"]
        if !wild.isHittable { app.swipeUp() }
        wild.tap()
        app.buttons["landlord-settings-new-game"].tap()
        let confirm = app.buttons["开始新一局"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 6)); confirm.tap()
        wait(app) { $0.contains("wild=7") && $0.contains("phase=bidding") }
        app.buttons["landlord-bid-3"].tap()
        app.switches["landlord-auto"].tap()
        wait(app, timeout: 90) { $0.contains("phase=finished") && $0.contains("valid=1") }
        let final = probe(app)
        app.buttons["landlord-all-cards"].tap()
        XCTAssertTrue(app.scrollViews["landlord-full-deck"].waitForExistence(timeout: 5))
        snapshot(app, "landlord-full-deck")
        done(app)
        app.buttons["landlord-expand"].tap(); app.buttons["landlord-arrange"].tap()
        snapshot(app, "landlord-wild-finished")
        app.terminate()
        app.launchArguments.append("--landlord-resume-ui-tests")
        app.launch(); openTable(app)
        wait(app) { $0 == final }
    }
}
