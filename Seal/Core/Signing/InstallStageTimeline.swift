import Foundation

/// 阶段「起点」的簿记。两条规则都在这里，都只有一份实现。
///
/// ## 规则一：安装阶段计时（`tick` / `applied`）
///
/// 「进入 `.installing` 记一次起点，同一阶段被重复推送时不重置，离开安装阶段则清空」。
/// 这条规则曾被两条链路各抄一遍：
///   - 单签 / 单次续签：`AppsViewModel.updateSigningStage`；
///   - 批量续签：`BatchRefreshSession.advanceStage`。
///
/// 两处各写一遍的风险是漂移，而这类漂移**不会崩、不会编译失败、也不会跑挂单测**，
/// 只会在真机上表现为：计时永远停在 0:00（比不显示更像卡死），
/// 或者把上一项的等待时间带到下一项（凭空造出「已等待 12 分钟」）。
/// 抽成纯函数既消掉重复，也让规则本身可以被单测钉住。
///
/// ## 规则二：当前阶段起点（`stageStart`）
///
/// 进度不再只随阶段跳变 —— 阶段内部要按「已过时间」做有上界的估算
/// （见 `SigningProgressBudget`），所以每个阶段都需要一个起点。
/// 规则同样是「阶段变化时重置、重复推送时保持」，但**判据与规则一不同**
/// （规则一只在 `.installing` 上生效，规则二对所有阶段生效），所以是两个函数而不是一个。
/// 放在同一个类型里，是为了让「起点该不该重置」只有一处答案。
enum InstallStageTimeline {
    /// 收到一次阶段推进时，起点该怎么变。
    enum Tick: Equatable {
        /// 同一个安装阶段被重复推送：保持原起点。
        ///
        /// 进入 `.installing` 会被推送不止一次 —— 安装通道的 >1.0 哨兵一次、
        /// 签名侧的阶段补发一次。每次都重置起点会让「已等待 m:ss」永远停在 0:0x。
        case keep
        /// 离开安装阶段：清空。否则上一项 / 上一阶段的等待时间会被带过来。
        case clear
        /// 首次进入安装阶段：记下新起点。
        case restart
    }

    /// - Parameters:
    ///   - stage: 本次推进到的阶段。
    ///   - currentStage: 推进前的阶段；`nil` 表示还没有阶段。
    static func tick(entering stage: SigningStage, currentStage: SigningStage?) -> Tick {
        guard stage == .installing else { return .clear }
        return currentStage == .installing ? .keep : .restart
    }

    /// 把 `Tick` 落到起点上。`now` 只在 `.restart` 时被读取。
    static func applied(_ tick: Tick, startedAt: Date?, now: Date = Date()) -> Date? {
        switch tick {
        case .keep:
            return startedAt
        case .clear:
            return nil
        case .restart:
            return now
        }
    }

    /// 「**当前阶段**起点」的推进规则：阶段变化时重置，同一阶段被重复推送时保持。
    ///
    /// 与上面那条（安装阶段计时）是**两条不同的规则**，但同属「起点簿记」，所以放在
    /// 同一个类型里 —— 否则「起点该不该重置」这件事就会有第二个地方各说各话，
    /// 而这类漂移不崩、不编译失败，只让进度看起来永远停在原地。
    ///
    /// 为什么必须防重复推送：`.pushing` / `.installing` 都会被推送不止一次
    /// （安装通道的 >1.0 哨兵一次、签名侧补发一次）。每次都重置会让阶段内的
    /// 估算永远停在起点，比不做估算更像卡死。
    ///
    /// - Parameters:
    ///   - stage: 本次推进到的阶段。
    ///   - currentStage: 推进前的阶段；`nil` 表示还没有阶段（会话刚创建或刚从失败态重试）。
    ///   - previous: 推进前的起点。
    /// - Returns: 新的起点。**只要阶段变了就一定返回 `now`**（`previous` 为 nil 时也返回
    ///   `now`，而不是 nil —— 返回 nil 等于这个阶段永远没有起点）。
    static func stageStart(
        entering stage: SigningStage,
        currentStage: SigningStage?,
        previous: Date?,
        now: Date = Date()
    ) -> Date? {
        if currentStage == stage, let previous {
            return previous
        }
        return now
    }
}
