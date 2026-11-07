import XCTest

final class ScrollGestureTests: XCTestCase {
    @MainActor
    func testRPGUnindexedRecoveryPreservesConstructionAndRewardReceipt() {
        let app=launch(discover:false,flags:["--rpg-ui-tests","--rpg-reset-world","--rpg-recovery-ui-tests"])
        app.buttons["navigation-me"].tap();app.buttons["me-rpg-entrance"].tap()
        let recovery=app.buttons["rpg-recover-recover-target"]
        XCTAssertTrue(recovery.waitForExistence(timeout:12));recovery.tap()
        let reward=NSPredicate(format:"label CONTAINS %@","月晶 7")
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:reward,object:app.staticTexts["rpg-combat-stats"])],timeout:12),.completed)
        XCTAssertEqual(app.staticTexts["rpg-placed-count"].value as? String,"1")
        app.buttons["rpg-tools"].tap()
        let story=app.buttons["rpg-story"];guard revealListControl(story,in:app) else{return};story.tap()
        XCTAssertTrue(app.staticTexts["rpg-story-ended"].waitForExistence(timeout:8))
        app.buttons["rpg-story-back"].tap();app.buttons["rpg-tools-close"].tap();app.buttons["rpg-close"].tap()
        XCTAssertTrue(app.buttons["me-rpg-entrance"].waitForExistence(timeout:8));app.buttons["me-rpg-entrance"].tap()
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:reward,object:app.staticTexts["rpg-combat-stats"])],timeout:12),.completed)
        XCTAssertEqual(app.staticTexts["rpg-placed-count"].value as? String,"1")
        XCTAssertFalse(recovery.exists);attach(app,name:"review-rpg-p9-unindexed-recovery")
    }

    @MainActor
    func testRPGSearchOpensStoryEditorAndDiagnosticsDirectly() {
        let app=launch(discover:false,flags:["--assistant-dock-ui-tests","--rpg-ui-tests","--rpg-reset-world"])
        let routes=[("剧情编辑器","rpgEditor","rpg-story-title","rpg-editor-back"),("序章","rpgStory","rpg-story-text","rpg-story-back"),("沙盒运行诊断","rpgDiagnostics","rpg-diagnostics-report","rpg-diagnostics-back")]
        for (query,command,target,back) in routes {
            let input=app.textFields["assistant-input"];XCTAssertTrue(input.waitForExistence(timeout:6));input.tap();input.typeText(query)
            let result=app.buttons["assistant-command-"+command];XCTAssertTrue(result.waitForExistence(timeout:6));result.tap()
            XCTAssertTrue(app.descendants(matching:.any).matching(identifier:target).firstMatch.waitForExistence(timeout:12))
            app.buttons[back].tap();app.buttons["rpg-tools-close"].tap();app.buttons["rpg-close"].tap()
        }
        XCTAssertFalse(app.navigationBars["智能对话"].exists)
    }

    @MainActor
    func testRPGSideCombatAndDiagnostics() {
        let app=launch(discover:false,flags:["--rpg-ui-tests","--rpg-reset-world"])
        app.buttons["navigation-me"].tap();app.buttons["me-rpg-entrance"].tap()
        XCTAssertTrue(app.buttons["rpg-tools"].waitForExistence(timeout:8));app.buttons["rpg-tools"].tap()
        app.segmentedControls["rpg-mode"].buttons["创造"].tap();app.buttons["rpg-temple"].tap();app.buttons["rpg-tools-close"].tap()
        app.buttons["rpg-perspective"].tap()
        let side=NSPredicate{_,_ in (app.staticTexts["rpg-projection-evidence"].value as? String ?? "").hasPrefix("side:")}
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:side,object:app)],timeout:10),.completed)
        app.buttons["rpg-tools"].tap()
        let training=app.buttons["rpg-training"];guard revealListControl(training,in:app) else{return};training.tap();app.buttons["rpg-tools-close"].tap()
        app.buttons["rpg-skill"].tap();app.buttons["rpg-attack"].tap()
        let reward=NSPredicate(format:"label CONTAINS %@","月晶 1")
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:reward,object:app.staticTexts["rpg-combat-stats"])],timeout:10),.completed)
        app.buttons["rpg-perspective"].tap()
        app.buttons["rpg-tools"].tap()
        let diagnostics=app.buttons["rpg-diagnostics"];guard revealListControl(diagnostics,in:app) else{return};diagnostics.tap()
        let report=app.staticTexts["rpg-diagnostics-report"];XCTAssertTrue(report.waitForExistence(timeout:8))
        XCTAssertTrue(report.label.contains("p95") && report.label.contains("待验证"));attach(app,name:"review-rpg-p10-diagnostics")
    }

    @MainActor
    func testRPGAuthoredCutsceneProducesFramesAndResumesMuted() {
        let app=launch(discover:false,flags:["--rpg-ui-tests","--rpg-reset-world","--rpg-media-ui-tests","--treasure-wall-ui-tests"])
        let ready=app.staticTexts["background-test-state"];XCTAssertTrue(ready.waitForExistence(timeout:15))
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:NSPredicate(format:"label == %@","背景测试就绪"),object:ready)],timeout:20),.completed)
        app.buttons["navigation-me"].tap();app.buttons["me-rpg-entrance"].tap()
        XCTAssertTrue(app.buttons["rpg-tools"].waitForExistence(timeout:8));app.buttons["rpg-tools"].tap()
        let editor=app.buttons["rpg-story-editor"];guard revealListControl(editor,in:app) else{return};editor.tap()
        let node=app.buttons["rpg-edit-node-media"];guard revealListControl(node,in:app) else{return};node.tap()
        let picker=app.buttons["rpg-node-media"];guard revealListControl(picker,in:app) else{return};picker.tap()
        let video=app.buttons["Scroll fixture 0"];XCTAssertTrue(video.waitForExistence(timeout:6));video.tap()
        let loop=app.switches["rpg-node-loop"];guard revealListControl(loop,in:app) else{return};if loop.value as? String == "0"{loop.tap()}
        let apply=app.buttons["rpg-node-apply"];XCTAssertTrue(apply.waitForExistence(timeout:6));apply.tap()
        let preview=app.buttons["rpg-story-preview"];guard revealListControl(preview,in:app) else{return};preview.tap()
        XCTAssertTrue(app.buttons["rpg-preview-next"].waitForExistence(timeout:8));app.buttons["rpg-preview-next"].tap()
        XCTAssertTrue(app.buttons["rpg-preview-choice-watch"].waitForExistence(timeout:6));app.buttons["rpg-preview-choice-watch"].tap()
        let probe=app.staticTexts["rpg-cutscene-probe"]
        func values()->[String:Int]{
            Dictionary((probe.value as? String ?? "").split(separator:";").compactMap{item in let p=item.split(separator:"=");guard p.count==2,let n=Int(p[1]) else{return nil};return(String(p[0]),n)},uniquingKeysWith:{a,_ in a})
        }
        let active=NSPredicate{_,_ in let v=values();return (v["frames"] ?? 0)>0 && (v["players"] ?? 99)<=1 && (v["global"] ?? 99)<=1}
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:active,object:probe)],timeout:25),.completed)
        let frames=values()["frames"] ?? 0
        XCUIDevice.shared.press(.home);app.activate()
        let resumed=NSPredicate{_,_ in let v=values();return (v["frames"] ?? 0)>frames && v["muted"]==1 && (v["global"] ?? 99)<=1}
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:resumed,object:probe)],timeout:25),.completed)
        attach(app,name:"review-rpg-p10-authored-video")
        app.buttons["rpg-preview-close"].tap()
    }

    @MainActor
    func testRPGStoryEditorCanPreviewAndPublishBranch() {
        let app=launch(discover:false,flags:["--rpg-ui-tests","--rpg-reset-world"])
        app.buttons["navigation-me"].tap();app.buttons["me-rpg-entrance"].tap()
        XCTAssertTrue(app.buttons["rpg-tools"].waitForExistence(timeout:8));app.buttons["rpg-tools"].tap()
        let editor=app.buttons["rpg-story-editor"];guard revealListControl(editor,in:app) else{return};editor.tap()
        let title=app.textFields["rpg-story-title"];XCTAssertTrue(title.waitForExistence(timeout:8));title.tap();title.typeText(" UI\n")
        let validate=app.buttons["rpg-story-validate"];guard revealListControl(validate,in:app) else{return};validate.tap()
        let preview=app.buttons["rpg-story-preview"];guard revealListControl(preview,in:app) else{return};preview.tap()
        XCTAssertTrue(app.buttons["rpg-preview-next"].waitForExistence(timeout:8));app.buttons["rpg-preview-next"].tap()
        XCTAssertTrue(app.buttons["rpg-preview-choice-watch"].waitForExistence(timeout:6));app.buttons["rpg-preview-choice-watch"].tap()
        XCTAssertTrue(app.staticTexts["rpg-preview-text"].label.contains("字幕"));app.buttons["rpg-preview-next"].tap()
        XCTAssertTrue(app.staticTexts["rpg-preview-ended"].waitForExistence(timeout:6));app.buttons["rpg-preview-close"].tap()
        let publish=app.buttons["rpg-story-publish"];guard revealListControl(publish,in:app) else{return};publish.tap()
        let status=app.staticTexts["rpg-editor-status"];XCTAssertTrue(status.waitForExistence(timeout:8))
        XCTAssertTrue(status.label.contains("已保存"));attach(app,name:"review-rpg-p8-editor")
        app.buttons["rpg-editor-back"].tap()
        let story=app.buttons["rpg-story"];guard revealListControl(story,in:app) else{return};story.tap()
        let custom=app.buttons.matching(NSPredicate(format:"label CONTAINS %@"," UI")).firstMatch
        guard revealListControl(custom,in:app) else{return};custom.tap()
        let intro=NSPredicate(format:"label CONTAINS %@","你的故事从这里开始")
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:intro,object:app.staticTexts["rpg-story-text"])],timeout:8),.completed)
    }

    @MainActor
    func testRPGStoryChoicePersistsAndWaitsForRealWorldEvent() {
        let app = launch(discover:false,flags:["--rpg-ui-tests","--rpg-reset-world"])
        app.buttons["navigation-me"].tap(); app.buttons["me-rpg-entrance"].tap()
        XCTAssertTrue(app.buttons["rpg-tools"].waitForExistence(timeout:8)); app.buttons["rpg-tools"].tap()
        let story = app.buttons["rpg-story"]
        guard revealListControl(story,in:app) else { return }; story.tap()
        XCTAssertTrue(app.staticTexts["rpg-story-text"].waitForExistence(timeout:8))
        XCTAssertTrue(app.staticTexts["rpg-story-text"].label.contains("月核破碎"))
        app.buttons["rpg-story-next"].tap()
        let help = app.buttons["rpg-story-choice-help"]
        XCTAssertTrue(help.waitForExistence(timeout:8)); help.tap()
        let gathered = NSPredicate(format:"label CONTAINS %@","收集第一份材料")
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:gathered,object:app.staticTexts["rpg-story-text"])],timeout:10),.completed)
        app.buttons["rpg-story-next"].tap()
        XCTAssertTrue(app.staticTexts["rpg-story-text"].label.contains("收集第一份材料"))
        app.buttons["rpg-story-back"].tap(); app.buttons["rpg-tools-close"].tap(); app.buttons["rpg-close"].tap()
        XCTAssertTrue(app.buttons["me-rpg-entrance"].waitForExistence(timeout:6)); app.buttons["me-rpg-entrance"].tap()
        XCTAssertTrue(app.buttons["rpg-tools"].waitForExistence(timeout:8)); app.buttons["rpg-tools"].tap()
        guard revealListControl(app.buttons["rpg-story"],in:app) else { return }; app.buttons["rpg-story"].tap()
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:gathered,object:app.staticTexts["rpg-story-text"])],timeout:10),.completed)
        attach(app,name:"review-rpg-p7-story")
    }

    @MainActor
    func testRPGCombatRewardsPersistWithoutDuplicateDrop() {
        let app = launch(discover:false,flags:["--rpg-ui-tests","--rpg-reset-world"])
        app.buttons["navigation-me"].tap(); app.buttons["me-rpg-entrance"].tap()
        XCTAssertTrue(app.buttons["rpg-tools"].waitForExistence(timeout:8)); app.buttons["rpg-tools"].tap()
        let training = app.buttons["rpg-training"]
        guard revealListControl(training,in:app) else { return }; training.tap()
        app.buttons["rpg-tools-close"].tap()
        app.buttons["rpg-skill"].tap(); app.buttons["rpg-attack"].tap()
        let stats = app.staticTexts["rpg-combat-stats"]
        let reward = NSPredicate(format:"label CONTAINS %@","月晶 1")
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:reward,object:stats)],timeout:10),.completed)
        attach(app,name:"review-rpg-p6-combat")
        app.buttons["rpg-close"].tap()
        XCTAssertTrue(app.buttons["me-rpg-entrance"].waitForExistence(timeout:6)); app.buttons["me-rpg-entrance"].tap()
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:reward,object:app.staticTexts["rpg-combat-stats"])],timeout:10),.completed)
        app.buttons["rpg-attack"].tap()
        XCTAssertTrue(app.staticTexts["rpg-combat-stats"].label.contains("月晶 1"))
    }

    @MainActor
    func testRPGMediaFramesBudgetLoopAndBackground() {
        let app=launch(discover:false,flags:["--rpg-ui-tests","--rpg-reset-world","--rpg-media-ui-tests","--treasure-wall-ui-tests"])
        let ready=app.staticTexts["background-test-state"]
        XCTAssertTrue(ready.waitForExistence(timeout:15))
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:NSPredicate(format:"label == %@","背景测试就绪"),object:ready)],timeout:20),.completed)
        app.buttons["navigation-me"].tap();app.buttons["me-rpg-entrance"].tap()
        XCTAssertTrue(app.buttons["rpg-tools"].waitForExistence(timeout:8));app.buttons["rpg-tools"].tap()
        func media(_ id:String,_ index:Int) {
            let entrance=app.buttons[id]
            guard revealListControl(entrance,in:app) else{return};entrance.tap()
            let item=app.buttons["rpg-pick-scroll-fixture-\(index)"]
            guard revealListControl(item,in:app) else{return};item.tap()
            XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:NSPredicate(format:"label CONTAINS %@","Scroll fixture \(index)"),object:app.staticTexts["rpg-current-media"])],timeout:10),.completed)
            app.buttons["rpg-media-back"].tap()
        }
        media("rpg-media-player",0);media("rpg-media-background",11)
        app.buttons["rpg-tools-close"].tap()
        let probe=app.staticTexts["rpg-media-probe"]
        func waitMedia(_ condition:@escaping ([String:Int])->Bool) {
            let predicate=NSPredicate{_,_ in
                let pairs=(probe.value as? String ?? "").split(separator:";").compactMap{item->(String,Int)? in
                    let pair=item.split(separator:"=",maxSplits:1);guard pair.count==2,let number=Int(pair[1]) else{return nil};return(String(pair[0]),number)
                }
                return condition(Dictionary(pairs,uniquingKeysWith:{first,_ in first}))
            }
            let result=XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:predicate,object:probe)],timeout:25)
            if result != .completed { print("RPG_MEDIA_TIMEOUT: \(probe.value as? String ?? "missing")");print(app.debugDescription) }
            XCTAssertEqual(result,.completed)
        }
        waitMedia{($0["frames"] ?? 0)>0 && ($0["posters"] ?? 0)>0 && ($0["advancing"] ?? 0)>0 && ($0["global"] ?? 99)<=2 && $0["muted"]==1}
        XCUIDevice.shared.press(.home);app.activate()
        waitMedia{($0["advancing"] ?? 0)>0 && $0["muted"]==1}
        app.buttons["rpg-tools"].tap()
        let player=app.buttons["rpg-media-player"];guard revealListControl(player,in:app) else{return};player.tap()
        let loop=app.switches["rpg-binding-loop"]
        guard revealListControl(loop,in:app) else{return};if loop.value as? String=="1"{loop.tap()}
        XCTAssertEqual(loop.value as? String,"0")
        app.buttons["rpg-media-back"].tap();app.buttons["rpg-tools-close"].tap()
        waitMedia{($0["completed"] ?? 0)>0 && $0["players"]==0}
        attach(app,name:"review-rpg-p5-media")
        app.buttons["rpg-close"].tap()
        XCTAssertTrue(app.buttons["me-library"].waitForExistence(timeout:5))
    }

    @MainActor
    func testRPGSharedEntityAndSafeDualProjection() {
        let app = launch(discover:false,flags:["--rpg-ui-tests","--rpg-reset-world"])
        app.buttons["navigation-me"].tap(); app.buttons["me-rpg-entrance"].tap()
        XCTAssertTrue(app.buttons["rpg-tools"].waitForExistence(timeout:8)); app.buttons["rpg-tools"].tap()
        app.segmentedControls["rpg-mode"].buttons["创造"].tap()
        app.buttons["rpg-temple"].tap(); app.buttons["rpg-choose-mapped"].tap()
        app.buttons["rpg-tools-close"].tap(); app.buttons["rpg-place"].tap()
        let evidence = app.staticTexts["rpg-projection-evidence"]
        let hasShared = NSPredicate { _,_ in (evidence.value as? String ?? "").contains("placed:") }
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:hasShared,object:evidence)],timeout:15),.completed)
        let top = evidence.value as? String ?? ""
        app.buttons["rpg-perspective"].tap()
        let side = NSPredicate { _,_ in (evidence.value as? String ?? "").hasPrefix("side:") }
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:side,object:evidence)],timeout:10),.completed)
        XCTAssertEqual((evidence.value as? String ?? "").dropFirst(5),top.dropFirst(8))
        attach(app,name:"review-rpg-p4-side")
        app.buttons["rpg-move-0-1"].tap()
        app.buttons["rpg-close"].tap()
        XCTAssertTrue(app.buttons["me-library"].waitForExistence(timeout:5))
    }

    @MainActor
    func testRPGBuildUndoSaveAndReopen() {
        let app = launch(discover: false, flags: ["--rpg-ui-tests", "--rpg-reset-world"])
        app.buttons["navigation-me"].tap(); app.buttons["me-rpg-entrance"].tap()
        XCTAssertTrue(app.buttons["rpg-tools"].waitForExistence(timeout: 8)); app.buttons["rpg-tools"].tap()
        let mode = app.segmentedControls["rpg-mode"]
        XCTAssertTrue(mode.waitForExistence(timeout: 8)); mode.buttons["创造"].tap()
        app.buttons["rpg-choose-site"].tap(); app.buttons["rpg-tools-close"].tap()
        app.buttons["rpg-place"].tap()
        let count = app.staticTexts["rpg-placed-count"]
        func waitCount(_ value: String) {
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value),object:count)],timeout:15),.completed)
        }
        waitCount("1"); app.buttons["rpg-undo"].tap(); waitCount("0")
        app.buttons["rpg-redo"].tap(); waitCount("1")
        app.buttons["rpg-close"].tap()
        app.buttons["me-rpg-entrance"].tap(); waitCount("1")
        attach(app,name:"review-rpg-p3-persisted-build")
        app.buttons["rpg-close"].tap()
    }

    /// Glass lab: each experimental mode switches what renders (B one merged
    /// native glass layer, C one native glass per nearest cell, A the drawn
    /// texture), and a timed sample records a result. Functional only:
    /// simulator frame rates say nothing about iPhone performance.
    /// An element by identifier, whatever type the system exposes it as
    /// (glass containers can report buttons as other types).
    @MainActor
    private func waitForAny(_ id: String, in app: XCUIApplication, timeout: TimeInterval, _ name: String) -> XCUIElement {
        let element = app.descendants(matching: .any).matching(identifier: id).firstMatch
        if !element.waitForExistence(timeout: timeout) {
            attach(app, name: "review-missing-" + id)
            print("Missing \(id):\n" + app.debugDescription)
            XCTFail(name)
        }
        return element
    }

    /// Scrolls until the element is on screen (lists build rows lazily).
    @MainActor
    private func reveal(_ id: String, in app: XCUIApplication, _ name: String) -> XCUIElement {
        let element = app.descendants(matching: .any).matching(identifier: id).firstMatch
        for _ in 0..<12 where !(element.exists && element.isHittable) { app.swipeUp() }
        if !element.exists { attach(app, name: "review-missing-" + id); XCTFail(name) }
        return element
    }

    /// AI Asset Director end to end (the 月光水晶城 scenario): import five
    /// mixed assets, let them be analysed, run the real CC0 evaluation, hand
    /// the results to the World Director and build the town with them.
    @MainActor
    func testAssetDirectorFeedsTheGoldenCity() {
        let app = launch(discover: false, flags: ["--rpg-ui-tests", "--rpg-reset-world", "--asset-director-fixtures"])
        app.buttons["navigation-me"].tap(); app.buttons["me-rpg-entrance"].tap()
        let enter = app.buttons["rpg-glass-world"]
        XCTAssertTrue(enter.waitForExistence(timeout: 15))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: enter)], timeout: 20), .completed)
        enter.tap()
        waitForAny("glass3d-settings", in: app, timeout: 40, "the 3D world opens").tap()
        reveal("glass3d-asset-director", in: app, "the ⋯ panel offers the Asset Director").tap()
        waitForAny("asset-director-import-fixtures", in: app, timeout: 10, "the test-asset import").tap()

        // Every asset analysed (none queued or running), within two minutes.
        let status = waitForAny("asset-director-status", in: app, timeout: 10, "status counts")
        let settled = NSPredicate(format: "value CONTAINS 'queued=0 analysing=0' AND NOT (value CONTAINS 'ready=0 review=0')")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: settled, object: status)], timeout: 120), .completed, "analysis finishes: \(status.value ?? "")")
        print("Asset Director status: \(status.value ?? "")")
        for name in ["castle-reference", "glass-material", "fountain", "house-model", "person-model"] {
            let row = app.descendants(matching: .any).matching(identifier: "asset-row-" + name).firstMatch
            print("Asset Director row \(name): exists=\(row.exists) category=\(row.value as? String ?? "?")")
        }
        attach(app, name: "review-asset-director-analysed")

        // The real accuracy check on the bundled CC0 files.
        reveal("asset-director-evaluate", in: app, "the evaluation button").tap()
        let evaluation = app.descendants(matching: .any).matching(identifier: "asset-director-evaluation").firstMatch
        for _ in 0..<40 where !evaluation.exists { sleep(3); if !evaluation.exists { app.swipeUp() } }
        XCTAssertTrue(evaluation.exists, "the evaluation reports")
        print("Asset Director evaluation: \(evaluation.value ?? "")")
        attach(app, name: "review-asset-director-evaluation")

        // Hand the analysed assets to the World Director.
        for _ in 0..<12 { app.swipeDown() }
        reveal("asset-director-use-all-for-director", in: app, "send to the World Director").tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "asset-director-picks").firstMatch.waitForExistence(timeout: 5))
        waitForAny("asset-director-done", in: app, timeout: 5, "close the library").tap()
        waitForAny("glass3d-generate", in: app, timeout: 10, "the World Director button").tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "world-director-smart-assets").firstMatch.waitForExistence(timeout: 10) ||
                      reveal("world-director-smart-assets", in: app, "the director lists the analysed assets").exists)
        for _ in 0..<12 { app.swipeDown() }
        reveal("world-director-theme-crystalKingdom", in: app, "the crystal-city theme").tap()
        reveal("world-director-generate", in: app, "generate").tap()
        let apply = app.descendants(matching: .any).matching(identifier: "world-director-apply-0").firstMatch
        for _ in 0..<60 where !apply.exists { sleep(3) }
        XCTAssertTrue(apply.exists, "a town candidate is ready")
        let usage = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '素材「' OR label BEGINSWITH 'Asset “'"))
        print("Asset Director usage lines: \(usage.count) — " + usage.allElementsBoundByIndex.prefix(6).map(\.label).joined(separator: " | "))
        XCTAssertGreaterThanOrEqual(usage.count, 1, "the run lists how the imported assets were used")
        attach(app, name: "review-asset-director-candidate")
        reveal("world-director-apply-0", in: app, "apply").tap()
        sleep(6)
        attach(app, name: "review-asset-director-town-3d")
        waitForAny("glass3d-perspective-switch", in: app, timeout: 10, "the view switch").tap()
        sleep(3)
        attach(app, name: "review-asset-director-town-pixel")
    }

    /// Widget taps are moonlight:// links: each one lands where it says,
    /// including straight into the 3D world from another page.
    @MainActor
    func testWidgetLinksOpenTheWorld() throws {
        guard #available(iOS 16.4, *) else { throw XCTSkip("XCUIApplication.open needs iOS 16.4") }
        let app = launch(discover: false, flags: ["--rpg-ui-tests", "--rpg-reset-world"])
        app.open(URL(string: "moonlight://search")!)
        XCTAssertTrue(app.scrollViews["feed-scroll-discover"].waitForExistence(timeout: 10), "search opens 发现")
        app.open(URL(string: "moonlight://world3d")!)
        _ = waitForAny("glass3d-settings", in: app, timeout: 40, "world3d opens the 3D world")
        attach(app, name: "review-widget-link-world3d")
        waitForAny("glass3d-close", in: app, timeout: 5, "the 3D world has a back button").tap()
        XCTAssertTrue(app.buttons["rpg-glass-world"].waitForExistence(timeout: 10), "closing it leaves the sandbox open")
        app.open(URL(string: "moonlight://sandbox")!)
        XCTAssertTrue(app.buttons["rpg-glass-world"].waitForExistence(timeout: 10), "sandbox stays in the sandbox")
    }

    /// The 3D world end to end: place 月光水晶城, check the Xbox-style HUD,
    /// and make sure both the 3D and the pixel view actually draw something.
    /// Saves a screenshot of each view for visual review.
    @MainActor
    func testGlass3DGoldenCityBothViews() {
        let app = launch(discover: false, flags: ["--rpg-ui-tests", "--rpg-reset-world"])
        app.buttons["navigation-me"].tap(); app.buttons["me-rpg-entrance"].tap()
        let enter = app.buttons["rpg-glass-world"]
        XCTAssertTrue(enter.waitForExistence(timeout: 15))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: enter)], timeout: 20), .completed)
        enter.tap()
        waitForAny("glass3d-settings", in: app, timeout: 40, "the 3D world opens").tap()
        waitForAny("glass3d-place-town", in: app, timeout: 5, "the ⋯ panel offers 月光水晶城").tap()

        // Face buttons follow the controller: attack on X, jump on A, dodge on B, skill on Y.
        for (id, cap) in [("glass3d-attack", "X"), ("glass3d-jump", "A"), ("glass3d-roll", "B"), ("glass3d-skill", "Y")] {
            let button = waitForAny(id, in: app, timeout: 10, "\(id) on the HUD")
            XCTAssertTrue(button.label.hasSuffix("· " + cap), "\(id) is labelled with its Xbox button: \(button.label)")
        }
        XCTAssertTrue(app.descendants(matching: .any)["glass3d-look-stick"].exists)

        sleep(4) // let the town's meshes build and the camera settle
        let spatial = app.screenshot()
        attach(app, name: "review-glass3d-golden-3d")
        XCTAssertGreaterThanOrEqual(colourVariety(spatial.image), 6, "the 3D view draws the town")

        waitForAny("glass3d-perspective-switch", in: app, timeout: 5, "the view switch").tap()
        sleep(3)
        let pixel = app.screenshot()
        attach(app, name: "review-glass3d-golden-pixel")
        XCTAssertGreaterThanOrEqual(colourVariety(pixel.image), 6, "the pixel view draws the town, not a blank screen")

        waitForAny("glass3d-perspective-switch", in: app, timeout: 5, "the view switch").tap()
        sleep(2)
        attach(app, name: "review-glass3d-golden-3d-again")
    }

    /// Distinct colours (quantised to 3 bits per channel) on a 16×16 grid
    /// over the middle of the screen, away from the HUD. A blank view gives 1–2.
    private func colourVariety(_ image: UIImage) -> Int {
        guard let cg = image.cgImage else { return 0 }
        let width = cg.width, height = cg.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return 0 }
        var colours = Set<Int>()
        for gy in 0..<16 { for gx in 0..<16 {
            let x = width / 5 + (width * 3 / 5) * gx / 15
            let y = height / 4 + (height / 2) * gy / 15
            let i = (min(height - 1, y) * width + min(width - 1, x)) * 4
            colours.insert(Int(pixels[i] >> 5) << 6 | Int(pixels[i + 1] >> 5) << 3 | Int(pixels[i + 2] >> 5))
        } }
        return colours.count
    }

    @MainActor
    func testRPGGlassLabModesAndSample() {
        let app = launch(discover: false, flags: ["--rpg-ui-tests", "--rpg-reset-world", "--glass-lab-ui-tests", "--glass-sample-short"])
        app.buttons["navigation-me"].tap(); app.buttons["me-rpg-entrance"].tap()
        let tools = app.buttons["rpg-tools"]
        XCTAssertTrue(tools.waitForExistence(timeout: 10))
        let state = app.staticTexts["rpg-glass-state"]
        func waitState(_ fragment: String, _ timeout: TimeInterval = 10, _ line: UInt = #line) {
            let result = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", fragment), object: state)], timeout: timeout)
            XCTAssertEqual(result, .completed, "glass state \(state.value ?? "nil") lacks \(fragment)", line: line)
        }
        func choose(_ mode: String, nearest: String? = nil) {
            tools.tap()
            let diagnostics = app.buttons["rpg-diagnostics"]
            guard revealListControl(diagnostics, in: app) else { return }
            diagnostics.tap()
            let button = app.buttons["rpg-glass-mode-" + mode]
            XCTAssertTrue(button.waitForExistence(timeout: 5)); button.tap()
            if let nearest {
                let picker = app.segmentedControls["rpg-glass-nearest"]
                XCTAssertTrue(picker.waitForExistence(timeout: 5)); picker.buttons[nearest].tap()
            }
            app.buttons["rpg-diagnostics-back"].tap(); app.buttons["rpg-tools-close"].tap()
        }
        let grid = app.descendants(matching: .any)["rpg-grid-glass"]

        choose("nativeMerged")
        waitState("render=nativeMerged")
        XCTAssertTrue(grid.waitForExistence(timeout: 5))
        XCTAssertTrue((grid.value as? String ?? "").hasPrefix("merged:"), "B is one merged glass layer: \(grid.value ?? "nil")")
        attach(app, name: "review-glass-lab-b-merged")

        choose("nativeNearest", nearest: "64")
        waitState("render=nativeNearest:64")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "nearest:64"), object: grid)], timeout: 5), .completed)
        attach(app, name: "review-glass-lab-c-nearest-64")

        choose("texture")
        waitState("render=texture")
        XCTAssertFalse(grid.waitForExistence(timeout: 2), "A is drawn by SpriteKit, no native glass views")
        attach(app, name: "review-glass-lab-a-texture")

        tools.tap()
        let diagnostics = app.buttons["rpg-diagnostics"]
        guard revealListControl(diagnostics, in: app) else { return }
        diagnostics.tap()
        let run = app.buttons["rpg-glass-run"]
        XCTAssertTrue(run.waitForExistence(timeout: 5)); run.tap()
        XCTAssertTrue(app.staticTexts["rpg-glass-sample"].waitForExistence(timeout: 8), "sample runs on the uncovered world")
        waitState("samples=1", 30)

        choose("selected")
        waitState("render=selected")
        app.buttons["rpg-close"].tap()
    }

    /// Task C: the app opens into the most recent world in landscape with
    /// the bottom bar hidden; the prologue is skippable without touching the
    /// world; the control center pauses input and returns the world as it
    /// was; leaving goes to portrait pages and coming back neither reloads
    /// the world nor replays the prologue.
    @MainActor
    func testSandboxLaunchControlCenterAndPortraitPages() {
        let app = XCUIApplication()
        app.launchArguments = ["--scroll-ui-tests", "--rpg-ui-tests", "--rpg-reset-world", "--sandbox-launch-ui-tests",
                               "--sandbox-landscape-ui-tests", "--prologue-ui-tests"]
        app.launch()
        let orientation = app.descendants(matching: .any)["app-orientation"]
        func waitOrientation(_ value: String, _ line: UInt = #line) {
            let result = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: orientation)], timeout: 10)
            XCTAssertEqual(result, .completed, "layout is \(orientation.value ?? "nil"), expected \(value)", line: line)
        }
        func waitGone(_ element: XCUIElement, _ line: UInt = #line) {
            let result = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)], timeout: 6)
            XCTAssertEqual(result, .completed, "\(element) still on screen", line: line)
        }
        let prologue = app.descendants(matching: .any)["world-prologue"]
        XCTAssertTrue(prologue.waitForExistence(timeout: 25), "world prologue after launch")
        attach(app, name: "review-sandbox-prologue")
        prologue.tap()
        waitGone(prologue)
        waitOrientation("landscape")
        let count = app.staticTexts["rpg-placed-count"]
        XCTAssertEqual(count.value as? String, "0", "skipping the prologue must not build")
        XCTAssertFalse(app.buttons["navigation-home"].exists && app.buttons["navigation-home"].isHittable, "bottom bar hidden in the sandbox")
        let position = app.staticTexts["rpg-position"]
        XCTAssertTrue(position.waitForExistence(timeout: 5))
        let startPosition = position.label
        attach(app, name: "review-sandbox-landscape")

        let menu = app.buttons["rpg-menu"]
        menu.tap()
        let center = app.descendants(matching: .any)["world-control-center"]
        XCTAssertTrue(center.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["world-title"].label.hasPrefix("原世界 · Seed"))
        for id in ["world-nav-home", "world-nav-discover", "world-nav-camera", "world-nav-moments", "world-nav-me",
                   "world-fn-build", "world-fn-story", "world-fn-media", "world-fn-settings", "world-fn-app-settings", "world-create"] {
            XCTAssertTrue(app.buttons[id].exists, "control center entry \(id)")
        }
        XCTAssertFalse(app.buttons["rpg-move-1-0"].exists, "world controls are shielded while the center is open")
        attach(app, name: "review-world-control-center")
        app.buttons["world-continue"].tap()
        waitGone(center)
        XCTAssertTrue(app.buttons["rpg-move-1-0"].waitForExistence(timeout: 5))
        XCTAssertEqual(position.label, startPosition, "world unchanged after the control center")

        menu.tap()
        XCTAssertTrue(center.waitForExistence(timeout: 5))
        app.buttons["world-nav-discover"].tap()
        XCTAssertTrue(app.buttons["discover-sources"].waitForExistence(timeout: 10))
        waitOrientation("portrait")
        XCTAssertTrue(app.buttons["navigation-sandbox"].waitForExistence(timeout: 5))
        app.buttons["home-segment-recommend"].tap()
        XCTAssertTrue(app.scrollViews["feed-scroll-home"].waitForExistence(timeout: 5))
        attach(app, name: "review-home-recommend-discover")

        app.buttons["navigation-sandbox"].tap()
        XCTAssertTrue(menu.waitForExistence(timeout: 10))
        waitOrientation("landscape")
        XCTAssertFalse(prologue.waitForExistence(timeout: 2), "prologue does not replay when returning")
        XCTAssertEqual(position.label, startPosition, "returning resumes the same world")
        app.buttons["rpg-close"].tap()
        XCTAssertTrue(app.scrollViews["feed-scroll-home"].waitForExistence(timeout: 10), "完成 returns to the last page")
        waitOrientation("portrait")
    }

    /// A world saved by a newer app version cannot open: instead of a blank
    /// or endless loading screen the sandbox explains and offers a new world.
    @MainActor
    func testSandboxLoadFailureOffersNewWorld() {
        let app = XCUIApplication()
        app.launchArguments = ["--scroll-ui-tests", "--rpg-ui-tests", "--rpg-reset-world", "--sandbox-launch-ui-tests", "--rpg-future-world-ui-tests"]
        app.launch()
        let create = app.buttons["world-load-create"]
        XCTAssertTrue(create.waitForExistence(timeout: 25))
        XCTAssertTrue(app.staticTexts["world-load-failed"].exists)
        XCTAssertTrue(app.buttons["world-load-retry"].exists)
        attach(app, name: "review-sandbox-load-failure")
        create.tap()
        let chunks = app.staticTexts["rpg-loaded-chunks"]
        let loaded = NSPredicate { _, _ in (Int(chunks.value as? String ?? "0") ?? 0) > 0 }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: loaded, object: chunks)], timeout: 20), .completed)
        XCTAssertFalse(create.exists)
        XCTAssertEqual(app.staticTexts["rpg-placed-count"].value as? String, "0")
    }

    /// Cell content MVP: one block gets a number, an edit is cancelled, an
    /// icon is applied and undone, the selection glass follows the camera,
    /// delete and undo, and the content survives closing and reopening.
    @MainActor
    func testRPGCellContentEditorGlassAndReopen() {
        let app = launch(discover: false, flags: ["--rpg-ui-tests", "--rpg-reset-world"])
        app.buttons["navigation-me"].tap(); app.buttons["me-rpg-entrance"].tap()
        XCTAssertTrue(app.buttons["rpg-tools"].waitForExistence(timeout: 8)); app.buttons["rpg-tools"].tap()
        let mode = app.segmentedControls["rpg-mode"]
        XCTAssertTrue(mode.waitForExistence(timeout: 8)); mode.buttons["创造"].tap()
        app.buttons["rpg-choose-site"].tap(); app.buttons["rpg-tools-close"].tap()
        app.buttons["rpg-place"].tap()
        let count = app.staticTexts["rpg-placed-count"]
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "1"), object: count)], timeout: 15), .completed)
        let content = app.staticTexts["rpg-cell-content"]
        func waitContent(_ value: String, _ line: UInt = #line) {
            let result = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: content)], timeout: 15)
            XCTAssertEqual(result, .completed, "cell content \(content.value ?? "nil") != \(value)", line: line)
        }
        waitContent("empty")

        let glass = app.descendants(matching: .any)["rpg-selection-glass"]
        XCTAssertTrue(glass.waitForExistence(timeout: 8))
        XCTAssertEqual(glass.value as? String, "native", "iOS 26 simulator uses native Liquid Glass")
        XCTAssertGreaterThan(glass.frame.width, 20)

        let kind = app.segmentedControls["rpg-cell-kind"]
        let confirm = app.buttons["rpg-cell-confirm"]
        app.buttons["rpg-edit-cell"].tap()
        XCTAssertTrue(kind.waitForExistence(timeout: 8)); kind.buttons["数字"].tap()
        let field = app.textFields["rpg-cell-value"]
        XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 6) + "42")
        let preview = app.descendants(matching: .any)["rpg-cell-preview"]
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "number:42"), object: preview)], timeout: 5), .completed)
        attach(app, name: "review-rpg-cell-editor-number")
        confirm.tap()
        waitContent("number:42")

        app.buttons["rpg-edit-cell"].tap()
        XCTAssertTrue(kind.waitForExistence(timeout: 8)); kind.buttons["文字"].tap()
        app.buttons["rpg-cell-cancel"].tap()
        waitContent("number:42")

        app.buttons["rpg-edit-cell"].tap()
        XCTAssertTrue(kind.waitForExistence(timeout: 8)); kind.buttons["图标"].tap()
        app.buttons["rpg-cell-symbol-moon.stars.fill"].tap(); confirm.tap()
        waitContent("icon:moon.stars.fill")
        attach(app, name: "review-rpg-cell-icon-glass")
        app.buttons["rpg-undo"].tap()
        waitContent("number:42")

        // Moving the player moves the camera; the glass must stay on the
        // selected cell, so its on-screen position shifts.
        let start = glass.frame
        var followed = false
        for direction in ["rpg-move-1-0", "rpg-move--1-0", "rpg-move-0-1", "rpg-move-0--1"] where !followed {
            app.buttons[direction].tap()
            let moved = NSPredicate { _, _ in abs(glass.frame.midX - start.midX) > 10 || abs(glass.frame.midY - start.midY) > 10 }
            followed = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: moved, object: nil)], timeout: 4) == .completed
        }
        XCTAssertTrue(followed, "selection glass follows the camera")
        waitContent("number:42")

        // Delete clears the content but keeps the block, and is undoable.
        app.buttons["rpg-edit-cell"].tap()
        XCTAssertTrue(app.buttons["rpg-cell-delete"].waitForExistence(timeout: 8)); app.buttons["rpg-cell-delete"].tap()
        waitContent("empty")
        XCTAssertEqual(count.value as? String, "1", "deleting content keeps the block")
        app.buttons["rpg-undo"].tap()
        waitContent("number:42")

        // The content survives leaving and reopening the world. Checked over
        // the whole world so the result does not depend on re-selecting.
        app.buttons["rpg-close"].tap()
        XCTAssertTrue(app.buttons["me-rpg-entrance"].waitForExistence(timeout: 8)); app.buttons["me-rpg-entrance"].tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "1"), object: count)], timeout: 15), .completed)
        let cells = app.staticTexts["rpg-world-cells"]
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "number:42"), object: cells)], timeout: 15), .completed,
                       "world cells after reopening: \(cells.value ?? "nil")")
        attach(app, name: "review-rpg-cell-reopened")
        app.buttons["rpg-close"].tap()
    }

    @MainActor
    func testRPGWorldSeedChunksAndMovement() {
        let app = launch(discover: false, flags: ["--rpg-ui-tests", "--rpg-reset-world"])
        app.buttons["navigation-me"].tap(); app.buttons["me-rpg-entrance"].tap()
        let count = app.staticTexts["rpg-loaded-chunks"]
        XCTAssertTrue(count.waitForExistence(timeout: 8))
        let ready = NSPredicate { _, _ in (Int(count.value as? String ?? "0") ?? 0) > 0 }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: ready, object: count)], timeout: 20), .completed)
        let position = app.staticTexts["rpg-position"]
        let before = position.label
        app.buttons["rpg-move-1-0"].tap()
        XCTAssertNotEqual(position.label, before)
        app.buttons["rpg-move--1-0"].tap()
        XCTAssertEqual(position.label, before)
        attach(app, name: "review-rpg-p2-world")
        app.buttons["rpg-close"].tap()
    }

    @MainActor
    func testRPGSkeletonCanValidateExitAndPreserveOtherModules() {
        let app = launch(discover: false, flags: ["--rpg-ui-tests", "--rpg-reset-world"])
        app.buttons["navigation-me"].tap()
        let entrance = app.buttons["me-rpg-entrance"]
        XCTAssertTrue(entrance.waitForExistence(timeout: 5)); entrance.tap()
        XCTAssertTrue(app.buttons["rpg-close"].waitForExistence(timeout: 5))
        app.buttons["rpg-validate"].tap()
        XCTAssertTrue(app.staticTexts["世界数据往返校验通过。"].waitForExistence(timeout: 5))
        app.buttons["rpg-close"].tap()
        XCTAssertTrue(app.buttons["me-library"].waitForExistence(timeout: 5))
        app.buttons["me-treasure-map"].tap()
        XCTAssertTrue(app.buttons["treasure-wall-mode"].waitForExistence(timeout: 5))
        app.buttons["treasure-map-close"].tap()
        app.buttons["navigation-home"].tap()
        XCTAssertTrue(app.buttons["navigation-me"].exists)
    }

    @MainActor
    private func waitLandlord(_ app: XCUIApplication, _ condition: @escaping ([String: String]) -> Bool, timeout: TimeInterval = 20) {
        let probe = app.staticTexts["landlord-probe"]
        XCTAssertTrue(probe.waitForExistence(timeout: 5))
        let predicate = NSPredicate { _, _ in
            let pairs = (probe.value as? String ?? "").split(separator: ";").compactMap { item -> (String, String)? in
                let pair = item.split(separator: "=", maxSplits: 1)
                return pair.count == 2 ? (String(pair[0]), String(pair[1])) : nil
            }
            return condition(Dictionary(pairs, uniquingKeysWith: { first, _ in first }))
        }
        let result = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: probe)], timeout: timeout)
        if result != .completed { print("LANDLORD_TIMEOUT: \(probe.value as? String ?? "missing")"); print(app.debugDescription) }
        XCTAssertEqual(result, .completed)
    }
    @MainActor
    func testLandlordClassicWholeGameAndNewRound() {
        let app = launch(discover: false, flags: ["--treasure-wall-ui-tests", "--landlord-ui-tests"])
        XCTAssertTrue(app.staticTexts["background-test-state"].waitForExistence(timeout: 15))
        openTreasureMap(app); app.buttons["treasure-landlord-mode"].tap()
        XCTAssertTrue(app.buttons["landlord-new-game"].waitForExistence(timeout: 5))
        app.buttons["landlord-new-game"].tap()
        app.buttons["landlord-bid-3"].tap()
        app.buttons["landlord-hint"].tap(); app.buttons["landlord-play"].tap()
        waitLandlord(app) { $0["valid"] == "1" && (Int($0["history"] ?? "0") ?? 0) > 0 && $0["players"] == "0" }
        app.switches["landlord-auto"].tap()
        XCTAssertEqual(app.switches["landlord-auto"].value as? String, "1")
        waitLandlord(app, { $0["phase"] == "finished" && $0["valid"] == "1" }, timeout: 45)
        attach(app, name: "review-v241-classic-result")
        app.buttons["landlord-new-game"].tap()
        waitLandlord(app) { $0["phase"] == "bidding" && $0["history"] == "0" && $0["cards"] == "51" }
        XCTAssertEqual(app.switches["landlord-auto"].value as? String, "0")
    }
    @MainActor
    func testLandlordMediaBudgetFocusBackgroundAndModeCleanup() {
        let app = launch(discover: false, flags: ["--treasure-wall-ui-tests", "--landlord-ui-tests"])
        let ready = app.staticTexts["background-test-state"]
        XCTAssertTrue(ready.waitForExistence(timeout: 15))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "背景测试就绪"), object: ready)], timeout: 15), .completed)
        openTreasureMap(app); app.buttons["treasure-landlord-mode"].tap()
        app.buttons["landlord-settings"].tap()
        app.segmentedControls["landlord-style"].buttons["媒体牌面"].tap()
        for index in [0, 1, 2, 11] {
            let item = app.buttons["landlord-media-scroll-fixture-\(index)"]
            guard revealListControl(item, in: app) else { return }; item.tap()
        }
        app.buttons["landlord-settings-done"].tap()
        waitLandlord(app) { (Int($0["players"] ?? "0") ?? 0) > 0 && (Int($0["players"] ?? "99") ?? 99) <= 2 && (Int($0["advancing"] ?? "0") ?? 0) > 0 && (Int($0["frames"] ?? "0") ?? 0) > 0 && $0["muted"] == "1" && $0["valid"] == "1" }
        waitLandlord(app) { (Int($0["posters"] ?? "0") ?? 0) > 0 }
        let videoCards = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@ AND value CONTAINS %@", "landlord-hand-", "视频牌面"))
        guard let card = videoCards.allElementsBoundByIndex.first(where: { $0.isHittable }) else { XCTFail("No visible video card"); return }
        card.press(forDuration: 0.7)
        XCTAssertTrue(app.buttons["landlord-focus-close"].waitForExistence(timeout: 5))
        waitLandlord(app) { $0["players"] == "1" && $0["history"] == "0" && $0["cards"] == "51" }
        app.buttons["landlord-focus-sound"].tap()
        waitLandlord(app) { $0["muted"] == "0" }
        app.buttons["landlord-focus-close"].tap()
        waitLandlord(app) { $0["muted"] == "1" && $0["history"] == "0" }
        XCUIDevice.shared.press(.home); app.activate()
        waitLandlord(app) { $0["muted"] == "1" && (Int($0["advancing"] ?? "0") ?? 0) > 0 }
        app.buttons["landlord-settings"].tap()
        app.buttons["landlord-test-memory"].tap()
        app.buttons["landlord-settings-done"].tap()
        waitLandlord(app) { $0["pressure"] == "1" && $0["players"] == "0" && $0["owned"] == "0" && (Int($0["cache"] ?? "9999999") ?? 9999999) <= 2097152 && $0["history"] == "0" }
        app.buttons["landlord-settings"].tap(); app.buttons["landlord-retry"].tap()
        app.buttons["landlord-settings-done"].tap()
        waitLandlord(app) { (Int($0["advancing"] ?? "0") ?? 0) > 0 && $0["muted"] == "1" }
        app.buttons["landlord-bid-3"].tap()
        app.buttons["landlord-hint"].tap(); app.buttons["landlord-play"].tap()
        waitLandlord(app) { (Int($0["history"] ?? "0") ?? 0) > 0 && $0["valid"] == "1" && (Int($0["players"] ?? "99") ?? 99) <= 2 && (Int($0["owned"] ?? "99") ?? 99) <= 2 }
        app.switches["landlord-auto"].tap()
        XCTAssertEqual(app.switches["landlord-auto"].value as? String, "1")
        waitLandlord(app, { $0["phase"] == "finished" && $0["valid"] == "1" }, timeout: 45)
        attach(app, name: "review-v241-media-result")
        for _ in 0..<3 {
            app.buttons["treasure-free-mode"].tap()
            app.buttons["treasure-wall-mode"].tap()
            XCTAssertTrue(app.buttons["wall-select"].waitForExistence(timeout: 5))
            app.buttons["treasure-landlord-mode"].tap()
            waitLandlord(app) { (Int($0["players"] ?? "99") ?? 99) <= 2 && $0["valid"] == "1" }
        }
        app.buttons["landlord-settings"].tap()
        app.segmentedControls["landlord-style"].buttons["经典牌面"].tap()
        app.buttons["landlord-settings-done"].tap()
        waitLandlord(app) { $0["players"] == "0" && $0["cache"] == "0" && $0["phase"] == "finished" }
    }

    @MainActor
    func testVideoWallSelectionLimitModesFocusAndCleanup() {
        let app = launch(discover: false, flags: ["--treasure-wall-ui-tests"])
        let ready = app.staticTexts["background-test-state"]
        XCTAssertTrue(ready.waitForExistence(timeout: 15))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "背景测试就绪"), object: ready)], timeout: 15), .completed)
        openTreasureMap(app)
        XCTAssertFalse(app.buttons["treasure-directed-settings"].exists)
        let freeMode = app.buttons["treasure-free-mode"]
        let wallMode = app.buttons["treasure-wall-mode"]
        XCTAssertTrue(freeMode.isSelected)
        wallMode.tap()
        XCTAssertTrue(app.buttons["wall-select"].waitForExistence(timeout: 5))
        app.buttons["wall-select"].tap()
        let clear = app.buttons["wall-clear"]
        XCTAssertTrue(clear.waitForExistence(timeout: 5)); clear.tap()
        XCTAssertTrue(app.steppers["wall-target-count"].label.contains("4"))
        for index in 0..<10 {
            let item = app.buttons["wall-pick-scroll-fixture-\(index)"]
            guard revealListControl(item, in: app) else { return }
            item.tap()
            XCTAssertEqual(item.value as? String, "已选择")
        }
        let eleventh = app.buttons["wall-pick-scroll-fixture-10"]
        for _ in 0..<6 { if eleventh.exists { break }; app.swipeUp() }
        XCTAssertTrue(eleventh.waitForExistence(timeout: 5))
        XCTAssertFalse(eleventh.isEnabled, "The eleventh different video must be disabled")
        attach(app, name: "review-v23-limit-ten")
        app.buttons["wall-selection-done"].tap()
        let modes = app.segmentedControls["wall-mode"]
        XCTAssertTrue(modes.waitForExistence(timeout: 5))
        modes.buttons["同时"].tap()
        if app.switches["wall-loop"].value as? String == "0" { app.switches["wall-loop"].tap() }
        XCTAssertEqual(app.switches["wall-loop"].value as? String, "1")
        if app.switches["wall-muted"].value as? String == "1" { app.switches["wall-muted"].tap() }
        app.buttons["wall-play-pause"].tap()
        func waitWall(_ predicate: @escaping ([String: Int]) -> Bool) {
            let probe = app.staticTexts["wall-probe"]
            XCTAssertTrue(probe.waitForExistence(timeout: 5))
            let condition = NSPredicate { _, _ in
                guard let value = probe.value as? String, let data = value.data(using: .utf8),
                      let state = try? JSONDecoder().decode([String: Int].self, from: data) else { return false }
                return predicate(state)
            }
            let result = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: condition, object: probe)], timeout: 15)
            if result != .completed { print("WALL_TIMEOUT: \(probe.value as? String ?? "missing")"); print(app.debugDescription) }
            XCTAssertEqual(result, .completed)
        }
        waitWall { $0["selected"] == 10 && $0["loop"] == 1 && ($0["advancing"] ?? 0) > 0 && ($0["players"] ?? 11) <= ($0["limit"] ?? 0) && ($0["audible"] ?? 2) <= 1 }
        let last = app.buttons["wall-tile-scroll-fixture-9"]
        guard revealListControl(last, in: app) else { return }
        XCTAssertTrue(last.isHittable, "The tenth cell is scrollable")
        last.tap()
        XCTAssertTrue(app.buttons["wall-unfocus"].waitForExistence(timeout: 5))
        waitWall { $0["players"] == 1 && ($0["advancing"] ?? 0) > 0 && ($0["audible"] ?? 2) <= 1 }
        app.buttons["wall-unfocus"].tap()
        app.switches["wall-muted"].tap()
        waitWall { $0["audible"] == 0 }
        app.buttons["wall-play-pause"].tap()
        waitWall { $0["playing"] == 0 }
        app.buttons["wall-stop"].tap()
        waitWall { $0["players"] == 0 }
        for mode in ["顺序", "随机"] {
            modes.buttons[mode].tap(); app.buttons["wall-play-pause"].tap()
            waitWall { $0["players"] == 1 && ($0["advancing"] ?? 0) > 0 }
            if mode == "随机" {
                XCUIDevice.shared.press(.home); app.activate()
                waitWall { $0["playing"] == 0 && $0["players"] == 0 && $0["ownedTotal"] == 0 }
            }
            app.buttons["wall-stop"].tap()
            waitWall { $0["players"] == 0 }
        }
        app.buttons["wall-play-pause"].tap()
        waitWall { $0["players"] == 1 && ($0["advancing"] ?? 0) > 0 }
        freeMode.tap()
        XCTAssertFalse(app.buttons["wall-select"].exists)
        wallMode.tap()
        XCTAssertTrue(app.buttons["wall-select"].label.contains("10/10"))
        waitWall { $0["playing"] == 0 && $0["players"] == 0 && $0["ownedTotal"] == 0 }
        attach(app, name: "review-v23-stopped-wall")
        app.buttons["wall-select"].tap()
        app.buttons["wall-clear"].tap()
        let single = app.buttons["wall-pick-scroll-fixture-0"]
        guard revealListControl(single, in: app) else { return }
        single.tap(); app.buttons["wall-selection-done"].tap()
        modes.buttons["顺序"].tap()
        if app.switches["wall-loop"].value as? String == "1" { app.switches["wall-loop"].tap() }
        XCTAssertEqual(app.switches["wall-loop"].value as? String, "0")
        app.buttons["wall-play-pause"].tap()
        let message = app.staticTexts["wall-message"]
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "本轮播放完成。"), object: message)], timeout: 20), .completed)
        waitWall { $0["players"] == 0 && $0["playing"] == 0 }
    }

    @MainActor
    private func openTreasureMap(_ app: XCUIApplication) {
        app.buttons["navigation-me"].tap()
        let entrance = app.buttons["me-treasure-map"]
        XCTAssertTrue(entrance.waitForExistence(timeout: 5)); entrance.tap()
        XCTAssertTrue(app.buttons["treasure-wall-mode"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testAssistantSearchRoutesTreasureAndTypedMediaWithoutAI() {
        let app = launch(discover: false, flags: ["--assistant-dock-ui-tests"])
        let input = app.textFields["assistant-input"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap(); input.typeText("月藏图")
        let command = app.buttons["assistant-command-treasureMap"]
        XCTAssertTrue(command.waitForExistence(timeout: 5)); command.tap()
        XCTAssertTrue(app.buttons["treasure-wall-mode"].waitForExistence(timeout: 5))
        app.buttons["treasure-map-close"].tap()
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap(); input.typeText("视频墙")
        let settingsCommand = app.buttons["assistant-command-treasurePlayback"]
        XCTAssertTrue(settingsCommand.waitForExistence(timeout: 5)); settingsCommand.tap()
        XCTAssertTrue(app.buttons["wall-select"].waitForExistence(timeout: 8))
        app.buttons["treasure-map-close"].tap()
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
            openTreasureMap(app)
            XCTAssertTrue(app.buttons["treasure-video-mode"].waitForExistence(timeout: 5))
        }
        func select(_ title: String) {
            let menu = app.buttons["treasure-video-mode"]
            let expected = title == "静止封面" ? "静止封面" : "自动播放"
            if menu.value as? String == expected { return }
            menu.tap()
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
            let result = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: condition, object: probe)], timeout: 12)
            if result != .completed {
                print("PREVIEW_TIMEOUT_SNAPSHOT: \(probe.value as? String ?? "missing")")
                attach(app, name: "review-preview-timeout")
            }
            XCTAssertEqual(result, .completed)
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
        if layout.label == "自由" { layout.tap() }
        waitForPreview { $0["nodes"] == 3 && ($0["advancing"] ?? 0) > 0 }
        let before = app.staticTexts["treasure-video-probe"].value as? String ?? ""
        let beforeState = (try? JSONDecoder().decode([String: Int].self, from: Data(before.utf8))) ?? [:]
        app.buttons["treasure-wall-mode"].tap()
        XCTAssertTrue(app.buttons["wall-select"].waitForExistence(timeout: 5))
        waitForPreview { $0["players"] == 0 && $0["nodes"] == 0 }
        app.buttons["treasure-free-mode"].tap()
        waitForPreview { $0["nodes"] == 3 && ($0["advancing"] ?? 0) > 0 && $0["configuration"] == beforeState["configuration"] }
        select("静止封面")
        waitForPreview { $0["players"] == 0 && $0["nodes"] == 0 && $0["centerIcons"] == 0 }
        attach(app, name: "review-treasure-static-video-no-center-icon")
    }

    @MainActor
    func testTreasureDragKeepsTouchAndPhysicsOwnership() {
        let app = launch(discover: false, flags: ["--treasure-drag-ui-tests"])
        openTreasureMap(app)
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
            let startFraction = ((before["y"] ?? 0) - (before["originY"] ?? 0)) / max(1, height)
            let targetFraction = startFraction < 0.5 ? 0.85 : 0.15
            let end = screen.withOffset(CGVector(dx: (before["originX"] ?? 0) + width * x,
                                                dy: (before["originY"] ?? 0) + height * targetFraction))
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
        openTreasureMap(app)
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
        guard app.buttons["加入播放队列"].waitForExistence(timeout: 5) else {
            print(app.debugDescription); attach(app, name: "review-grid-hold-failure")
            XCTFail("Long press did not open the treasure actions menu"); return
        }
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

    /// Keep list targets above the floating navigation dock. A row may be
    /// accessible while its center still belongs to the dock's hit region.
    @MainActor
    private func revealListControl(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        let bounds = app.frame
        for _ in 0..<30 {
            var moveDown = false
            if element.exists {
                let frame = element.frame
                if element.isHittable && frame.minY >= bounds.minY + 90 && frame.maxY <= bounds.maxY - 110 { return true }
                moveDown = frame.height > 0 && frame.minY < bounds.minY + 90
            }
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: moveDown ? 0.35 : 0.65))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: moveDown ? 0.55 : 0.45))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        print(app.debugDescription)
        attach(app, name: "review-list-control-not-visible")
        XCTFail("List target is not safely visible above navigation: \(element)")
        return false
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
        // 发现 is now the second segment of 首页.
        app.buttons["navigation-home"].tap(); app.buttons["navigation-discover"].tap()
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
        XCTAssertLessThan(top.frame.maxY, app.buttons["navigation-home"].frame.minY)
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
        // Bar order is now 沙盒 / 首页 / 拍摄 / 朋友圈 / 我; 发现 is a 首页 segment.
        XCTAssertEqual(bar.buttons.count, 5)
        bar.buttons["首页"].tap(); app.buttons["navigation-discover"].tap()
        XCTAssertTrue(app.buttons["discover-sources"].waitForExistence(timeout: 5))
        bar.buttons["我"].tap()
        XCTAssertTrue(app.buttons["settings-entry"].waitForExistence(timeout: 5))
        // Slide from 我 back to 首页 (the second item), not past it into the sandbox.
        let start = bar.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5))
        start.press(forDuration: 0.01, thenDragTo: bar.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)))
        app.buttons["home-segment-recommend"].tap()
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
            guard revealListControl(asset, in: app) else { return }
            if asset.value as? String != "已选择" { asset.tap() }
            XCTAssertEqual(asset.value as? String, "已选择", "The background row did not accept selection")
        }
        let picker = app.descendants(matching: .any).matching(identifier: "background-playback-mode").firstMatch
        guard revealListControl(picker,in:app) else{return}
        picker.tap()
        let sequential=app.buttons["顺序循环"]
        XCTAssertTrue(sequential.waitForExistence(timeout:5));sequential.tap()
        XCTAssertTrue(app.staticTexts["background-playback-summary"].label.contains("2 项 · 顺序循环"))
        attach(app, name: "review-button-background-playlist")
        app.terminate(); app.launch(); openBackgroundSettings()
        let persistedSummary = app.staticTexts["background-playback-summary"]
        guard revealListControl(persistedSummary,in:app) else{return}
        XCTAssertTrue(persistedSummary.label.contains("2 项 · 顺序循环"))
    }

    @MainActor
    func testConfiguredMenuPersistsAndShowsExtraActionInMore() {
        let app = launch(discover: false, flags: ["--keep-menu-settings"])
        func openEditor() {
            app.buttons["navigation-me"].tap(); app.buttons["settings-entry"].tap()
            app.buttons["context-menu-settings-entry"].tap()
            XCTAssertTrue(app.navigationBars["长按与底栏"].waitForExistence(timeout: 5))
            guard revealListControl(app.buttons["媒体卡片"], in: app) else { return }
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
        let homeBackground = app.buttons["background-target-page.home"]
        guard revealListControl(homeBackground, in: app) else { return }
        homeBackground.tap()
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



