import Foundation
import Testing
@testable import Seal

/// 安装阶段补发规则的回归防线（2026-09-16 真机反馈）。
///
/// 真机现象：单签停在 93%、批量续签抽屉停在「传输中」，两者都「怎么都没反应」。
/// 批量那一半的根因是：`BatchRefreshEvent` 只承载 `SigningStage`，接不到安装通道
/// 上传完成的 1.01 哨兵，于是从上传结束到 installd 装完整段时间里没有任何阶段推进。
///
/// 这条规则一旦被改回「只在 Seal 自替换时补发」，**编译与静态守卫都不会报错**，
/// 只有真机上才会重新出现「卡在传输」。所以必须在这里钉住。
struct InstallStageBridgeTests {

    @Test
    func emitsInstallingOnlyAfterUploadCompletes() {
        #expect(InstallStageBridge.shouldEmitInstalling(uploadProgress: 0, enabled: true) == false)
        #expect(InstallStageBridge.shouldEmitInstalling(uploadProgress: 0.5, enabled: true) == false)
        // 1.0 是「上传到 100%」的正常值：设备此时还没开始安装，
        // 用 >= 提前切阶段会让 UI 谎报「正在安装」，掩盖真正的上传。
        #expect(InstallStageBridge.shouldEmitInstalling(uploadProgress: 1.0, enabled: true) == false)
        #expect(InstallStageBridge.shouldEmitInstalling(uploadProgress: 1.01, enabled: true))
        #expect(InstallStageBridge.shouldEmitInstalling(uploadProgress: 2, enabled: true))
    }

    @Test
    func staysSilentWhenTheCallerAlreadyOwnsTheSentinel() {
        // 单签路径的 UI 自己订阅 Double 哨兵（SigningProgressView.onChange）。
        // 签名侧再补发一次会让「谁负责切阶段」出现两个来源 —— 阶段推进变成偶发。
        #expect(InstallStageBridge.shouldEmitInstalling(uploadProgress: 1.01, enabled: false) == false)
        #expect(InstallStageBridge.shouldEmitInstalling(uploadProgress: 0.99, enabled: false) == false)
    }
}
