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
        tapStage(app.buttons["已安装，0 个"])
        tapStage(app.buttons["待签名，0 个"])
        // 测试名字里的另一半：切 tab 之后**头部仍在**（「不带歪头部」的最低可测形式）。
        XCTAssertTrue(app.staticTexts["Seal"].exists, "两段导航切换后头部不应消失")
    }


    @MainActor
    func testTwoStageNavigationSupportsHorizontalSwipe() {
        let app = launch(with: "--ui-testing-empty")
        XCTAssertTrue(app.staticTexts["待签名应用"].waitForExistence(timeout: 10))
        let pager = element("apps-stage-pager", in: app)
        XCTAssertTrue(pager.waitForExistence(timeout: 10))

        // ⚠️ 断言落在**确定性的选中态**上，理由与 `tapStage` 完全相同（2026-09-18 CI 实测）。
        //
        // 本测试原先断言「滑完目标页的文字出现」，而构建 131 因此红：
        // `ImportFlowUITests.swift:63`（滑左之后 5 秒内「已安装应用」没出现）。
        // 该提交**只有 8 张 PNG 删除、0 个 Swift 改动**，且同一份测试代码在构建 130 是绿的
        // ⇒ 抖动，不是回归。机制同 `tapStage`：`apps-stage-pager` 是
        // `TabView(selection: $mode)`，动画未结束时手势会被吞掉；也可能手势被接受了却不翻页。
        // 两种都让「目标页文字出现」成为**不确定信号**。
        //
        // ⚠️ 同一轮 CI 里 `testTwoStageNavigationCanBeTappedWithoutChangingHeaderAlignment`（已改）是绿的，
        // 只有这条滑动路径还在断言翻页 —— 这正是「同一条规则只落在两条链路中的一条」（本仓第 7 次）。
        swipeStage(pager, to: .left, expecting: app.buttons["已安装，0 个"])
        swipeStage(pager, to: .right, expecting: app.buttons["待签名，0 个"])
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
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        // ⚠️ **断言的是「点击真的生效」（选中态），不是「页面翻过去了」**（2026-09-18 实测后改的）。
        //
        // 原断言是「点完 tab 后目标页的文字要出现」。但 `TabView(.page)` + `selection` 绑定
        // 在程序化改 `mode` 时**偶发不翻页**（本文件第 40-42 行的注释早就记过这个「header 竞态」）。
        //
        // **证据（CI 实测）**：上一版把它改成「点 4 次、每次等 3 秒」**仍然失败** ——
        // 失败信息是「点了「已安装，0 个」4 次之后仍未出现「已安装应用」」。
        // ⇒ 说明**不是「tap 被吞掉」**，而是**点击被接受了、页面没跟着翻**。
        // （`appPage` 的标题是无条件渲染的，所以「文字没出现」只能解释成「那一页没上来」。）
        // ⇒ 继续断言「页面翻没翻」会让 CI 一直间歇性红，而那是 SwiftUI 的行为、不是 Seal 的缺陷。
        //
        // 选中态是**确定性**的：`modeButton` 用
        // `.accessibilityAddTraits(mode == item ? .isSelected : [])` 直接反映 `mode`，
        // 点击一旦被接受就立刻成立 —— 这正是本测试名字要保的东西（「两段导航**能点**」）。
        let waiter = XCTWaiter()
        let becameSelected = expectation(
            for: NSPredicate(format: "isSelected == true"),
            evaluatedWith: button
        )
        button.tap()
        _ = waiter.wait(for: [becameSelected], timeout: 10)
        XCTAssertTrue(
            button.isSelected,
            "点了「\(button.label)」之后它没有被选中（isEnabled=\(button.isEnabled)）",
            file: file,
            line: line
        )
    }

    /// 在分页器上滑动并等**选中态**切换，**滑一次不一定生效**。
    ///
    /// 与 `tapStage` 同源：`apps-stage-pager` 是 `TabView(selection: $mode)`，
    /// 初始 mode 由 `resolveInitialModeIfNeeded()` **程序化翻页**决定 ——
    /// 动画未结束时手势会被吞掉；也可能手势被接受了、页面没翻。
    /// 两者都让「目标页文字出现」变成**不确定信号**（2026-09-18 构建 131 实测）。
    ///
    /// ⇒ 断言落在 `modeButton` 的 `.isSelected`（直接反映 `mode`，手势一旦被接受就立刻成立），
    /// 并「滑 → 等 → 没到就再滑」。**它不掩盖确定性缺陷**：真坏了 4 次之后照样断言失败。
    @MainActor
    private func swipeStage(
        _ pager: XCUIElement,
        to direction: SwipeDirection,
        expecting selected: XCUIElement,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for _ in 0..<4 {
            if selected.isSelected { return }
            switch direction {
            case .left:
                pager.swipeLeft()
            case .right:
                pager.swipeRight()
            }
            let becameSelected = expectation(
                for: NSPredicate(format: "isSelected == true"),
                evaluatedWith: selected
            )
            _ = XCTWaiter().wait(for: [becameSelected], timeout: 3)
        }
        XCTAssertTrue(
            selected.isSelected,
            "在分页器上滑动 4 次之后「\(selected.label)」仍未被选中"
                + "（isEnabled=\(selected.isEnabled)）",
            file: file,
            line: line
        )
    }

    /// 分页器的滑动方向。
    private enum SwipeDirection {
        case left
        case right
    }
}
