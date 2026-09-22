import Testing
import UIKit
@testable import Seal

/// Seal 自续签「回主屏幕」的前台状态判断。
///
/// 这段判断决定「Seal 覆盖安装自己」时旧进程什么时候让出前台 —— iOS 只有在旧进程
/// 退出前台之后才会用新版完成替换。判断错了**不会崩、不会编译失败、也不会跑挂单测**，
/// 只会在真机上永久停在 93%（2026-09-16 真机反馈），所以必须由这里钉住。
///
/// `@MainActor`：`UIApplication` 在 Swift 6 严格并发下是主 actor 隔离的，
/// 被测函数跟着隔离，测试也跟着走（与 `ApplicationOperationCoordinatorTests` 同一写法）。
@MainActor
struct SelfInstallAutoBackgroundTests {

    @Test
    func activeStateTriggersTheHomeTransition() {
        #expect(SelfInstallAutoBackground.step(for: .active) == .triggerTransition)
    }

    @Test
    func inactiveStateWaitsInsteadOfGivingUp() {
        // 根因回归：旧实现把 `.inactive` 当成「用户已离开」直接 return，
        // 连 exit(0) 兜底一起跳过。而 `.inactive` 只是**瞬时**失焦
        //（控制中心、通知横幅、来电、App 切换器预览、系统弹窗），进程仍占着前台，
        // iOS 永远等不到替换时机 —— 界面永久停在 93%。
        #expect(SelfInstallAutoBackground.step(for: .inactive) == .waitForForeground)
        #expect(SelfInstallAutoBackground.step(for: .inactive) != .standDown)
    }

    @Test
    func onlyBackgroundCountsAsUserLeaving() {
        // `.standDown` 的语义是「用户把 App 切走了，进程不再占着前台」，
        // 只有 `.background` 才成立。注意它**不等于**「什么都不做」——
        // 那正是 2026-09-16 真机停在 93% 的原因，见下面的 `poll` 测试。
        #expect(SelfInstallAutoBackground.step(for: .background) == .standDown)
        #expect(SelfInstallAutoBackground.step(for: .active) != .standDown)
        #expect(SelfInstallAutoBackground.step(for: .inactive) != .standDown)
    }

    @Test
    func unknownStateIsTreatedAsStillInForeground() throws {
        // 未知状态宁可多等一轮，也不能静默放弃安装：放弃 = 永久停在 93%。
        // 用一个已知三态之外的原始值构造，模拟未来系统新增的前台状态。
        let unknown = try #require(UIApplication.State(rawValue: 99))
        #expect(SelfInstallAutoBackground.step(for: unknown) == .waitForForeground)
    }

    @Test
    func exactlyOneStateStandsDown() {
        // 穷举全部已知状态：一旦有人把别的状态也接上 `.standDown`，这里立刻红。
        // `.standDown` 现在的含义是「用户在别处，先等他回来、等不到再强杀」，
        // 而不是旧实现的「直接放弃」。
        let known: [UIApplication.State] = [.active, .inactive, .background]
        var standingDown: [UIApplication.State] = []
        for state in known where SelfInstallAutoBackground.step(for: state) == .standDown {
            standingDown.append(state)
        }
        #expect(standingDown == [.background])
    }

    // MARK: - 轮询预算（`poll`）
    //
    // 这段判断是「再等等」与「该动手了」的分界，错了**不会崩、不会编译失败**，
    // 只会在真机上永久停在 93% —— 必须由这里钉住。

    @Test
    func activeStateActsImmediately() {
        #expect(
            SelfInstallAutoBackground.poll(for: .triggerTransition, waited: 0, rounds: 0) == .act
        )
    }

    @Test
    func backgroundStateWaitsInsteadOfGivingUp() {
        // 根因回归（2026-09-16 真机，两份日志各两次自续签）：
        // 旧实现把 `.background` 当成「用户已离开、iOS 会自己完成替换」**立即放弃**，
        // 结果进程既不转场也不退出、永久占着前台，iOS 永远等不到替换时机 —— 停在 93%。
        // 新语义：先等用户回到前台，等不到再强杀。
        #expect(SelfInstallAutoBackground.poll(for: .standDown, waited: 0, rounds: 0) == .wait)
        #expect(SelfInstallAutoBackground.poll(for: .standDown, waited: 4, rounds: 0) == .wait)
    }

    @Test
    func backgroundWaitIsBounded() {
        // 「等」必须**有界**：无限等是另一种形式的永久卡住。
        // 7.9 / 8 与 `SelfInstallAutoBackground.backgroundWaitSeconds` 同步；
        // 改动那个常量时这条会红，是有意为之（守卫另有断言钉住常量值）。
        #expect(SelfInstallAutoBackground.poll(for: .standDown, waited: 7.9, rounds: 0) == .wait)
        #expect(SelfInstallAutoBackground.poll(for: .standDown, waited: 8, rounds: 0) == .act)
    }

    @Test
    func inactiveWaitIsBoundedByRounds() {
        // `.inactive` 用**轮数**而不是总时长：语义是「等系统浮层消失」。
        // 5 / 6 与 `inactiveRetryLimit` 同步（6 轮 × 0.5 秒 = 3 秒）。
        #expect(
            SelfInstallAutoBackground.poll(for: .waitForForeground, waited: 0, rounds: 5) == .wait
        )
        #expect(
            SelfInstallAutoBackground.poll(for: .waitForForeground, waited: 0, rounds: 6) == .act
        )
    }

    @Test
    func everyStateEventuallyActs() {
        // 穷举：预算耗尽后**每个**状态都必须给出 `.act`，不允许存在「永远等下去」的组合。
        // 这条直接钉住「不会再出现永久停在 93%」。
        let steps: [SelfInstallAutoBackground.ReturnHomeStep] = [
            .triggerTransition,
            .standDown,
            .waitForForeground,
        ]
        for step in steps {
            #expect(SelfInstallAutoBackground.poll(for: step, waited: 600, rounds: 99) == .act)
        }
    }
}
