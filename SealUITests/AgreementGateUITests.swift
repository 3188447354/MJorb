import XCTest

/// 开屏协议门控的用例。
///
/// 🔴 为什么必须单独有这一条（2026-10-08）：
/// 门控（`AgreementOnboardingView`）把**整个** `RootTabView` 挡在协议页后面。
/// 它 2026-10-07 引入时没同步 `SealUITests`，于是 7 个既有 UI 用例全部停在协议页、
/// `swift-regression` 一路红；而中间几十次 run 都被新推送顶成 `cancelled`，
/// 这个红点一直没暴露 —— 直到 2026-10-08 第一次真跑完才报出来，
/// 当时差点被误判成「本轮改动引入的回归」。
///
/// ⇒ 既有用例现在用 `--ui-testing-agreement-accepted` **显式**越过门控（快、确定性）；
/// 而「门控本身还在、还能拦人、同意后真能进主界面」这件事由本用例负责。
/// 两者缺一：只有旁路 ⇒ 门控被删掉也没人知道；只有本用例 ⇒ 每个用例都要多点一次、更慢更抖。
final class AgreementGateUITests: XCTestCase {
    /// 「未同意」这个前提**不用**依赖模拟器里攒下来的 `UserDefaults` ——
    /// 那样本用例会随执行顺序 / 模拟器是否复用而时红时绿。
    /// 用启动参数把它钉进 `NSArgumentDomain`（优先级高于持久域、且不落盘）：
    /// `AgreementOnboardingView` 读的就是 `UserDefaults.standard`，所以这里一定能读到 0。
    private static let storageKey = "seal.agreedAgreementVersion"

    @MainActor
    func testFirstLaunchBlocksTheAppUntilTheAgreementsAreAccepted() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing-empty",
            "-\(Self.storageKey)", "0"
        ]
        app.launch()

        // ① 门控生效：停在协议页，看不到根界面。
        XCTAssertTrue(app.staticTexts["欢迎使用"].waitForExistence(timeout: 10))
        let agree = app.buttons["同意并继续"]
        XCTAssertTrue(agree.exists)
        XCTAssertTrue(app.buttons["暂不使用"].exists)
        XCTAssertFalse(app.buttons["import-toolbar-button"].exists)

        // ② 同意之后必须真的进得去主界面 —— 只断言「按钮消失」会把
        //    「门关了但主界面也没起来」这种死锁放过去。
        agree.tap()
        XCTAssertTrue(app.buttons["import-toolbar-button"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["待签名，0 个"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testAgreementLinksOpenTheirInAppDocuments() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing-empty",
            "-\(Self.storageKey)", "0"
        ]
        app.launch()

        XCTAssertTrue(app.buttons["agreement-privacy-link"].waitForExistence(timeout: 10))
        app.buttons["agreement-privacy-link"].tap()
        XCTAssertTrue(app.navigationBars["隐私政策"].waitForExistence(timeout: 10))

        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["agreement-terms-link"].waitForExistence(timeout: 10))
        app.buttons["agreement-terms-link"].tap()
        XCTAssertTrue(app.navigationBars["用户协议"].waitForExistence(timeout: 10))
    }
}
