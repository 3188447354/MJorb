import Foundation

/// 安装通道「上传进度」→ 签名阶段「安装中」的桥接规则。
///
/// 背景（2026-09-16 真机反馈）：续签/签名在安装环节看起来「卡死了」——
/// 单签停在 93%，批量续签抽屉停在「传输中」，怎么都没反应。两个现象是同一个缺口：
///
/// 安装通道用**上传百分比**回报 AFC 阶段（0→1.0 逐值），上传结束、installd 即将
/// 开始安装时再发一个 >1.0 的哨兵（Rust 侧 101 → 1.01）。单签路径的 UI 直接订阅
/// 这个 Double，能在 1.01 到达时把阶段切到 `.installing`；
/// 而**批量续签的 progress 回调只透传 `SigningStage`**，根本接不到这个 Double ——
/// 于是从上传完成到 installd 装完（可达数分钟）的整段时间里，抽屉一直显示
/// 「传输中」，用户无法区分「在装」和「死了」。
///
/// 所以规则是：**只要调用方的进度回调看不到 Double 哨兵，就必须在上传完成时
/// 由签名侧显式补发一次 `.installing`**。抽成纯函数是为了能单测这条规则，
/// 并让「自替换」与「普通安装」两个分支共用同一份判定，不再各写一遍。
enum InstallStageBridge {
    /// 上传完成哨兵：>1.0（1.01）表示「上传结束，installd 即将安装」。
    /// 用 `>` 而不是 `>=`：1.0 是上传到 100% 的正常值，此时设备尚未开始安装，
    /// 提前切阶段会让 UI 谎报「正在安装」。
    static let uploadCompletionSentinel: Double = 1.0

    /// 是否需要补发 `.installing`。
    /// - Parameters:
    ///   - uploadProgress: 安装通道回传的上传进度（0…1.0 为上传中，>1.0 为完成哨兵）。
    ///   - enabled: 调用方的进度回调是否只承载 `SigningStage`（批量续签为 true）。
    ///     单签路径为 false —— 它的 UI 自己订阅了 Double 哨兵，这里再发一次虽然同值幂等，
    ///     但会让「谁负责切阶段」这件事出现两个来源，故保持单一来源。
    static func shouldEmitInstalling(uploadProgress: Double, enabled: Bool) -> Bool {
        enabled && uploadProgress > uploadCompletionSentinel
    }
}
