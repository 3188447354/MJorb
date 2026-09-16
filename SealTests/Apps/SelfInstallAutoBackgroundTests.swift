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
        // `.standDown` 的语义是「不触发转场、也不强杀进程」，只有用户真的自己切走了才成立。
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
        // 穷举全部已知状态：一旦有人把别的状态也接上 `.standDown`（= 不再触发转场，
        // 也不再走 exit(0) 兜底），这里立刻红。
        let known: [UIApplication.State] = [.active, .inactive, .background]
        var standingDown: [UIApplication.State] = []
        for state in known where SelfInstallAutoBackground.step(for: state) == .standDown {
            standingDown.append(state)
        }
        #expect(standingDown == [.background])
    }
}
