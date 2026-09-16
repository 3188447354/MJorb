import Foundation

/// 安装阶段的计时簿记。
///
/// 规则只有一条，却被两条链路各抄了一遍：
///   - 单签 / 单次续签：`AppsViewModel.updateSigningStage`；
///   - 批量续签：`BatchRefreshSession.advanceStage`。
///
/// 规则是「进入 `.installing` 记一次起点，同一阶段被重复推送时不重置，离开安装阶段则清空」。
/// 两处各写一遍的风险是漂移，而这类漂移**不会崩、不会编译失败、也不会跑挂单测**，
/// 只会在真机上表现为：计时永远停在 0:00（比不显示更像卡死），
/// 或者把上一项的等待时间带到下一项（凭空造出「已等待 12 分钟」）。
/// 抽成纯函数既消掉重复，也让规则本身可以被单测钉住。
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
}
