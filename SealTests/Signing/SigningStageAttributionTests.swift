import Foundation
import Testing
@testable import Seal

/// 阶段推进「归位到谁」的规则（R86，2026-09-26 构建 48 真机）。
///
/// 这条规则错了**不会崩、不会编译失败**，只会让抽屉显示**别人的阶段**：
/// 父会话已经装完、正在验证时，证书轮换子流程推进的 Seal 阶段把它覆盖回去
/// ⇒ 用户看到「签名到安装步骤后又重签一次」。
///
/// 真机日志（构建 48）逐行印证：
/// ```text
/// 10:07:44  阶段进入：verifying（Guoguo）        ← 父会话：安装已返回，正在验证
/// 10:07:44  阶段进入：waitingForChannel（Seal）  ← 子流程开始覆盖父抽屉
/// 10:07:46  阶段进入：preparingBundle（Seal）
/// 10:07:47  阶段进入：preparingCertificate（Seal）
/// 10:07:47  签名并安装成功
/// ```
struct SigningStageAttributionTests {

    private let sessionAppID = UUID()
    private let otherAppID = UUID()

    @Test
    func stageFromAnotherAppNeverBelongsToTheSession() {
        // 子流程推进的**另一个** App（Seal 自己）—— 只留痕，不写父会话。
        let seal = SigningStageSubject(appID: otherAppID, appName: "Seal", isSeal: true)
        #expect(
            SigningStageAttribution.target(for: seal, sessionAppID: sessionAppID)
                == .otherApp(seal)
        )
        // 非 Seal 的受影响应用同样是「别人的阶段」。
        let other = SigningStageSubject(appID: otherAppID, appName: "Guoguo", isSeal: false)
        #expect(
            SigningStageAttribution.target(for: other, sessionAppID: sessionAppID)
                == .otherApp(other)
        )
    }

    @Test
    func sameAppSubjectBelongsToTheSession() {
        let own = SigningStageSubject(appID: sessionAppID, appName: "Guoguo", isSeal: false)
        #expect(SigningStageAttribution.target(for: own, sessionAppID: sessionAppID) == .session)
    }

    @Test
    func missingSubjectMeansTheSessionItself() {
        // `updateSigningStage(_:subject:)` 的 `subject` 是可选参数：旧调用点
        //（安装通道的 `.installing` 哨兵、`restartSigning` 的 `waitingForChannel`）
        // 一律不传 ⇒ 缺省**必须**等价于会话主体，否则那些阶段会被整段丢掉、抽屉卡住。
        #expect(SigningStageAttribution.target(for: nil, sessionAppID: sessionAppID) == .session)
    }

    @Test
    func unknownSessionIdentityFallsBackToTheLegacyBehaviour() {
        // 会话不存在时无从归属。调用方在此之前已经 `guard let` 过会话存在，
        // 这里只是把「判不出来」收敛到历史行为 —— 绝不能把阶段静默丢掉。
        let seal = SigningStageSubject(appID: otherAppID, appName: "Seal", isSeal: true)
        #expect(SigningStageAttribution.target(for: seal, sessionAppID: nil) == .session)
    }

    @Test
    func installEntryGateFiresOnlyOncePerSubflow() {
        // 子流程的阶段不写进父会话 ⇒ 父会话的 `InstallStageTimeline` 不能给它当闸门，
        // 闸门只能落在子流程自己的「上一次阶段」上。
        #expect(
            SigningStageAttribution.isFirstInstallEntry(entering: .installing, previous: nil)
        )
        #expect(
            SigningStageAttribution.isFirstInstallEntry(entering: .installing, previous: .pushing)
        )
        // 同一阶段会被重复推送（安装通道的 >1.0 哨兵 + 签名侧补发）⇒ 只许触发一次。
        #expect(
            SigningStageAttribution.isFirstInstallEntry(entering: .installing, previous: .installing)
                == false
        )
        // 非安装阶段永远不是「首次进入安装阶段」。
        for stage in SigningStage.allCases where stage != .installing {
            #expect(
                SigningStageAttribution.isFirstInstallEntry(entering: stage, previous: nil) == false
            )
        }
    }

    @Test
    func sealSelfReplacementIsStillRecognisedFromTheSubflow() {
        // 🔴 本次修复**不能**顺手把 Seal 自替换的「回主屏」也一起关掉（R66）：
        // 那条判据是「**Seal** 被覆盖安装」，与父会话是谁无关 ——
        // 构建 31 真机就是因为拿会话主体去判，子流程里恒假 ⇒ installd 一直等旧进程让位。
        let seal = SigningStageSubject(appID: otherAppID, appName: "Seal", isSeal: true)
        guard case .otherApp(let recognised) = SigningStageAttribution.target(
            for: seal,
            sessionAppID: sessionAppID
        ) else {
            Issue.record("子流程里 Seal 的阶段必须被认成「另一个 App」")
            return
        }
        #expect(recognised.isSeal)
        #expect(
            SigningStageAttribution.isFirstInstallEntry(entering: .installing, previous: .pushing)
        )
    }
}
