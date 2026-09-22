import Foundation

/// 维护作业看到的闸门接口。
///
/// 抽成协议只为测试能注入「检查点返回失效」的替身：「用户操作恰好在作业中途开始」
/// 这条时序无法靠计时或并发调度稳定复现，而它正是 R06 要防的回归。
@MainActor
protocol MaintenanceLeasing: AnyObject {
    /// 空闲时发放租约；非空闲返回 nil（调用方应跳过本轮，不等待）。
    func tryAcquire() -> UUID?
    func end(_ token: UUID)
    /// 关键检查点：租约失效（或已被取代）时返回 true，作业必须立即退出。
    func shouldAbort(_ token: UUID) -> Bool
}

/// 维护作业的「空闲租约」。
///
/// 背景：Seal 的**读取路径**（应用列表加载）过去顺手做了三件写操作 —— 记录恢复、
/// Seal 自身注册、孤儿文件清理。它们既没有租约、也不受加载代次约束，于是可以和
/// 用户正在进行的签名 / 安装 / 续签交错执行：清理可能删掉刚导入应用的文件目录，
/// 自注册可能替换掉正在安装的包。
///
/// 但反过来也不能让这些后台卫生任务去抢 `OperationCoordinator` 的全局单槽 ——
/// 那会让**用户等后台清理**（点「签名」要等清理跑完），这是不可接受的体验降级。
///
/// 因此这里采用「低优先级、可抢占」的模型：
///
/// - 前台操作走 `OperationCoordinator`，用户动作优先，**永远不等待维护**。
/// - 维护作业只在**空闲**（无前台操作、无其他维护作业）时取到租约；
///   取不到就跳过本轮，不排队、不阻塞 —— 下一次刷新或下次启动再试。
/// - 维护作业持租约期间一旦有前台操作启动，租约**立即失效**。
///   作业必须在每个关键写入 / 删除之前调用 `shouldAbort(_:)`，观察到失效就立刻退出。
///
/// 这也是维护作业把「删除」放在最后一步的原因：前面任何一步都可能发现用户开始了新操作，
/// 越早退出越不会留下半成品。
@MainActor
final class MaintenanceGate: MaintenanceLeasing {
    private let coordinator: OperationCoordinator
    private var runningToken: UUID?

    /// 因非空闲而跳过轮次的数量，仅用于诊断与测试断言。
    private(set) var skippedRounds = 0

    init(coordinator: OperationCoordinator) {
        self.coordinator = coordinator
    }

    /// 当前是否空闲（无前台操作、无维护作业在跑）。
    var isIdle: Bool {
        coordinator.activeLease == nil && runningToken == nil
    }

    /// 空闲时发放租约；已有前台操作或维护作业在跑时返回 nil。
    ///
    /// 注意这是**非阻塞**的：拿到 nil 的调用方应当直接跳过本轮，
    /// 而不是等待或重试 —— 维护作业没有「必须现在跑」的语义。
    func tryAcquire() -> UUID? {
        guard coordinator.activeLease == nil, runningToken == nil else {
            skippedRounds += 1
            return nil
        }
        let token = UUID()
        runningToken = token
        return token
    }

    func end(_ token: UUID) {
        guard runningToken == token else { return }
        runningToken = nil
    }

    /// 关键检查点：租约已被取代，或前台操作已经启动 → 作业必须立即退出。
    func shouldAbort(_ token: UUID) -> Bool {
        guard runningToken == token else { return true }
        return coordinator.activeLease != nil
    }
}
