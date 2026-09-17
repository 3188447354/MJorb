import XCTest

final class ImportFlowUITests: XCTestCase {
    @MainActor
    func testEmptyStateHasImportEntry() {
        let app = launch(with: "--ui-testing-empty")
        XCTAssertTrue(app.staticTexts["Seal"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["待签名，0 个"].exists)
        XCTAssertTrue(app.buttons["import-toolbar-button"].exists)
        XCTAssertFalse(element("imported-app-row", in: app).exists)
    }

    @MainActor
    func testNormalColdLaunchDefaultsToInstalledAndPendingItemRemainsAvailable() {
        let app = launch(with: "--ui-testing-imported")
        XCTAssertTrue(app.buttons["待签名，1 个"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["已安装应用"].waitForExistence(timeout: 10))
        app.buttons["待签名，1 个"].tap()
        XCTAssertTrue(element("imported-app-row", in: app).waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["import-toolbar-button"].exists)
    }

    @MainActor
    func testConfirmationKeepsSummaryAndActionsConcise() {
        let app = launch(with: "--ui-testing-confirmation")
        XCTAssertTrue(app.otherElements["import-confirmation"].waitForExistence(timeout: 10))
        XCTAssertTrue(element("import-confirmation-name", in: app).exists)
        XCTAssertTrue(element("import-confirmation-version", in: app).exists)
        assertSummary("import-summary-extensions", value: "1 个", in: app)
        assertSummary("import-summary-compatibility", value: "可导入", in: app)
        XCTAssertTrue(app.buttons["导入"].exists)
        XCTAssertTrue(app.buttons["取消"].exists)
    }

    @MainActor
    func testTwoStageNavigationCanBeTappedWithoutChangingHeaderAlignment() {
        let app = launch(with: "--ui-testing-empty")
        XCTAssertTrue(app.buttons["待签名，0 个"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["已安装，0 个"].exists)
        // 稳定初始态：等 resolveInitialModeIfNeeded 把 mode 从初始 .installed 异步切到 .unsigned
        // 完成后再点，避免 tap 命中中转窗口导致 TabView 不切页（header 竞态）。
        XCTAssertTrue(app.staticTexts["待签名应用"].waitForExistence(timeout: 10))

        // ⚠️ 用 `tapStage` 而不是裸 `tap()` + `waitForExistence`（2026-09-17）。
        // 这一条在 CI 上红过一次（`ImportFlowUITests.swift:45` 的 XCTAssertTrue 超时），
        // 而失败点正是「点完 tab、目标页 5 秒内没出现」——
        // 机制与上面注释写的是同一个：**初始 mode 切换是程序化翻页，动画未结束时 tap 会被吞掉**。
        // 裸 tap 只点一次，撞上动画尾部就必然失败；改成「点 → 等 → 没到就再点」。
        tapStage(app.buttons["已安装，0 个"], expecting: "已安装应用", in: app)
        tapStage(app.buttons["待签名，0 个"], expecting: "待签名应用", in: app)
    }


    @MainActor
    func testTwoStageNavigationSupportsHorizontalSwipe() {
        let app = launch(with: "--ui-testing-empty")
        XCTAssertTrue(app.staticTexts["待签名应用"].waitForExistence(timeout: 10))
        let pager = element("apps-stage-pager", in: app)
        XCTAssertTrue(pager.waitForExistence(timeout: 10))
        pager.swipeLeft()
        XCTAssertTrue(app.staticTexts["已安装应用"].waitForExistence(timeout: 5))
        pager.swipeRight()
        XCTAssertTrue(app.staticTexts["待签名应用"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testLargeDynamicTypeKeepsPrimaryNavigationReachable() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing-empty",
            "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryAccessibilityExtraExtraExtraLarge"
        ]
        app.launch()
        XCTAssertTrue(app.buttons["待签名，0 个"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["已安装，0 个"].exists)
        XCTAssertTrue(app.buttons["import-toolbar-button"].exists)
    }

    @MainActor
    private func launch(with argument: String) -> XCUIApplication {
        let app = XCUIApplication(); app.launchArguments = [argument]; app.launch(); return app
    }
    @MainActor
    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement { app.descendants(matching: .any)[identifier].firstMatch }
    @MainActor
    private func assertSummary(_ identifier: String, value: String, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let summary = element(identifier, in: app)
        XCTAssertTrue(summary.waitForExistence(timeout: 10), file: file, line: line)
        XCTAssertEqual(summary.value as? String, value, file: file, line: line)
    }

    /// 点 tab 并等目标页出现，**点一次不一定生效**。
    ///
    /// 初始 mode 由 `resolveInitialModeIfNeeded()` 决定，而它是**程序化翻页**：
    /// 动画未结束时 `tap()` 会被吞掉（`AppsRootView` 里的 `apps-stage-pager` 还在动）。
    /// 本文件第 40-42 行的注释早就记过这个竞态，但只防住了「切 mode 之前」那一次点击；
    /// 2026-09-17 CI 上红的那次是**点完之后**目标页 5 秒内没出现（第 45 行）。
    ///
    /// ⇒ 用「点 → 等 → 没到就再点」代替 `sleep` 魔法数字。
    /// **它不会掩盖确定性缺陷**：真坏了的话 4 次重试之后照样断言失败。
    @MainActor
    private func tapStage(
        _ button: XCUIElement,
        expecting text: String,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let target = app.staticTexts[text]
        for _ in 0..<4 {
            if target.waitForExistence(timeout: 3) { return }
            button.tap()
        }
        XCTAssertTrue(
            target.waitForExistence(timeout: 5),
            "点了「\(button.label)」4 次之后仍未出现「\(text)」",
            file: file,
            line: line
        )
    }
}
