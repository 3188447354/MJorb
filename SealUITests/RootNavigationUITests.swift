import XCTest

final class RootNavigationUITests: XCTestCase {
    @MainActor
    func testSwitchesBetweenTheTwoRootTabs() {
        let app = XCUIApplication()
        // 显式越过开屏协议门控：它把 `RootTabView` 整个挡在协议页后面，
        // 不越过的话下面第 10 行「Seal」标题就会超时（2026-10-08 CI 的真实报红）。
        app.launchArguments = ["--ui-testing-empty", "--ui-testing-agreement-accepted"]
        app.launch()

        XCTAssertTrue(app.staticTexts["Seal"].waitForExistence(timeout: 10))
        let appsTab = tabButton(identifier: "root-tab-apps", title: "应用", in: app)
        let settingsTab = tabButton(identifier: "root-tab-settings", title: "我的", in: app)
        XCTAssertTrue(appsTab.waitForExistence(timeout: 10))
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 10))

        settingsTab.tap()
        XCTAssertTrue(app.navigationBars["我的"].waitForExistence(timeout: 5))

        appsTab.tap()
        XCTAssertTrue(app.staticTexts["Seal"].waitForExistence(timeout: 5))

        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "Seal Root Navigation"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func tabButton(identifier: String, title: String, in app: XCUIApplication) -> XCUIElement {
        let identified = app.buttons[identifier]
        if identified.waitForExistence(timeout: 2) {
            return identified
        }
        return app.tabBars.buttons[title]
    }
}
