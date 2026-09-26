import Foundation
import Testing
@testable import Seal

/// 阶段文案必须与**真实发生的操作**对应（R87，2026-09-26 构建 48 真机，用户要求
/// 「将签名链路和续签和安装实际的真实操作对应的文案写精准，没有做的事不写」）。
///
/// 这条判据不是「文案好不好看」，而是「有没有宣称一件没发生的事」——
/// 历史上已经因此把用户推进过一次死循环：`.preparingBundle` 曾被算进
/// 「正在验证 Apple ID」，用户盯着那行等了 2 分钟，跑去重新验证 Apple ID，然后被限流。
struct SigningStageCopyTests {

    @Test
    func certificateStageNeverClaimsItIsApplyingForACertificate() {
        // 这一阶段做的是「读远端列表 → 查本机私钥 → 决定复用 / 撤销重建」，
        // 而真机日志里绝大多数时候是**复用**（「证书决策：复用 Apple 生效列表中的本机证书」）。
        for isRenewal in [true, false] {
            let title = SigningStage.preparingCertificate.stageTitle(isRenewal: isRenewal)
            #expect(title.contains("申请") == false)
            #expect(title.contains("证书"))
        }
        // profile-only 那条路只核验（不新建），文案保持「正在核验当前证书」。
        #expect(
            RenewalExecutionPath.profileOnly.stageTitle(for: .preparingCertificate)
                == "正在核验当前证书"
        )
    }

    @Test
    func appIDStageNeverClaimsItIsRegisteringWhenItOnlyChecks() {
        // 这一阶段先读账号已有的 App ID，只对缺失的发注册请求
        //（真机日志：「App ID 名额：本次需 1 个…需新注册 0 个」）。
        for isRenewal in [true, false] {
            let title = SigningStage.preparingAppID.stageTitle(isRenewal: isRenewal)
            #expect(title.contains("注册") == false)
            #expect(title.contains("App ID"))
        }
        // 与 profile-only 那条路同一口径。
        #expect(
            RenewalExecutionPath.profileOnly.stageTitle(for: .preparingAppID) == "正在核对 App ID"
        )
    }

    @Test
    func appIDWorkUnitsCountWhatIsReadyNotWhatWasRegistered() {
        // `ApplePortalSigningService` 是在 App ID **解析完成**（复用的 + 新建的都算）之后
        // 才上报计数，所以「已注册」是错的 —— 复用的那一轮一个都没注册。
        let units = SigningWorkUnits(stage: .preparingAppID, done: 1, total: 1)
        let text = SigningStage.preparingAppID.unitsText(units)
        #expect(text != nil)
        #expect(text?.contains("已注册") == false)
        #expect(text?.contains("1 / 1") == true)
    }

    @Test
    func everyStageStillHasANonEmptyTitle() {
        // 改文案不能把某条分支漏成空串（空标题比错标题更难发现）。
        for stage in SigningStage.allCases {
            for isRenewal in [true, false] {
                #expect(stage.stageTitle(isRenewal: isRenewal).isEmpty == false)
            }
            #expect(RenewalExecutionPath.profileOnly.stageTitle(for: stage).isEmpty == false)
        }
    }
}
