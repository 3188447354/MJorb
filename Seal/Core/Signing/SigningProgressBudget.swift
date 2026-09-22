import Foundation

/// 一个阶段内部的**真实**完成量：已完成 / 总数。
///
/// 存在理由：界面不该在「假预估」与「全程静止」之间二选一（2026-09-19 设计讨论）。
/// 本仓多数阶段其实**有可数的对象** —— 解压条目、待注册 bundle ID、待重签的可执行文件、
/// 待核对的安装项。把这些计数报上来，环与数字就每一格都可解释。
///
/// ⚠️ 必须带 `stage`：消费侧只采信与当前阶段一致的计数。残留上一阶段的旧值会把进度从
/// 新阶段的地板拽回去 —— 与 `installProgress` 当年「切阶段后残留旧值」是同一类缺陷。
struct SigningWorkUnits: Equatable, Sendable {
    let stage: SigningStage
    let done: Int
    let total: Int

    /// 阶段内部完成比例（0–1）。`total <= 0` 或 `done < 0` 时返回 nil ⇒
    /// 表示「这次没有可信信号」，界面退回不确定态，而不是画 0% 或除零。
    var fraction: Double? {
        guard total > 0, done >= 0 else { return nil }
        return Swift.min(1, Double(done) / Double(total))
    }
}

extension SigningWorkUnits {
    /// 一条上报该不该采信 —— 单签与批量**共用这一份**判据（同一条规则抄两遍
    /// 是本仓第 7 次踩坑的来源）。
    ///
    /// 丢弃「同一阶段的倒退计数」：Phase 1 有「扩展降级 / 跳过」分支，跳过后回报的
    /// `done` 会变小 ⇒ 屏幕上的数字往回跳一格，正是「跳着走」的观感来源。
    static func shouldAccept(_ next: SigningWorkUnits, over current: SigningWorkUnits?) -> Bool {
        guard let current, current.stage == next.stage else { return true }
        return next.done >= current.done
    }
}

/// 签名 / 续签进度环与底部阶段轨道的**唯一**数值来源。
///
/// ## 为什么需要它（2026-09-18 用户反馈「进度条跳着走、看着像卡住」）
///
/// 旧实现里「进度」是 `SigningStage` 的纯函数：10 个阶段 → 10 个写死的常数
/// （6/16/23/30/42/54/68/78→90/93/99），**没有任何时间项**。两次阶段推送之间
/// 界面只能冻结，阶段一变就跳一格 —— 「跳着走」就是这么来的。
/// 更糟的是两个长阶段：`preparingBundle`（解压 + 重写 + 重签 + 打包，抖音 780 MB
/// 实测 **112 秒**）全程钉在 23%，`.installing`（installd 不回进度）全程钉在 93%。
///
/// ## 现在的模型
///
/// 每个阶段有一对「地板 / 天花板」：
///   - `floor`：**进入本阶段时已经确认到达**的进度（= 上一阶段的 `ceiling`）；
///   - `ceiling`：本阶段**估算的上界**（= 下一阶段的 `floor`）。
///
/// 阶段内部用指数收敛逼近天花板：
///
///     value(t) = floor + (ceiling − floor) · (1 − e^(−t / τ))
///
/// 三个性质都是刻意的：
///   1. **永不越过天花板**（`1 − e^(−x) < 1`）⇒ 不会「提前到站」，阶段真正完成时
///      数字也不会往回退；
///   2. **单调不减** ⇒ 阶段切换处 `ceiling_i == floor_{i+1}`，所以进度是连续的，
///      既不跳也不回退；
///   3. **先快后慢** ⇒ 越接近天花板爬得越慢，正好匹配「不知道还要多久」的直觉。
///
/// 有真实信号的阶段（`.pushing` 的 AFC 上传回调）**不做估算**，直接用真实值；
/// 此时 `confirmedProgress` 也等于该值，界面上整段弧都是深色（见 `isEstimated`）。
///
/// ## 两条硬约束（改表之前先读）
///
/// ⚠️ **`ceiling_i == floor_{i+1}` 是这套模型全部的连续性所在**。改表时若破坏它，
/// 表现是「阶段切换时进度跳一下 / 往回退」—— 不崩、不报错、只在真机上看得见。
/// 它由 `SigningProgressBudgetTests` 与守卫 R36（解析本表逐行比对）两侧钉住。
///
/// ⚠️ 这套数值**不承诺**「完成百分比」：天花板以内的部分是**估算**。所以界面必须把
/// 「已确认」（`confirmedProgress`）与「估算」（`overallProgress`）画成**两种笔触**，
/// 并给估算部分加扫光 —— 否则等于用一根确定进度的条去编数字。
/// 这也是 `InstallWaitNote` 当初「刻意不编造假百分比」那条判断的延续：
/// 那里不编，是因为 `installing` 的耗时与包大小、设备 IO 都相关；
/// 这里可以给估算，是因为**有上界**，永远不会走到「100% 了却还没装完」。
enum SigningProgressBudget {
    /// 底部阶段轨道的格数。
    ///
    /// **与阶段数不是一对一**：语义相近的阶段（「准备文件 / 申请证书」）共用一格。
    /// 旧实现把 10 个阶段压进 5 格，但格内比例用的是写死的常数，与真实完成度无关；
    /// 现在格内比例由 `bucketFill` 从「格内已完成阶段数 + 本阶段完成比例」算出。
    static let bucketCount = 5

    /// 「本阶段已用时」的显示门槛（秒）。
    ///
    /// 短暂阶段显示计时只会让人以为在拖时间；只有明显偏长的阶段才需要它来安抚
    /// （`preparingBundle` 在抖音上 112 秒，是这条门槛存在的理由）。
    static let elapsedDisplayThreshold: TimeInterval = 4

    /// 一个阶段的进度预算。
    struct Plan: Equatable, Sendable {
        /// 进入本阶段时已确认到达的进度（0–100）。
        let floor: Double
        /// 本阶段估算的上界（0–100）。**必须等于下一阶段的 `floor`**。
        let ceiling: Double
        /// 指数收敛的时间常数（秒）。越大爬得越慢，适合长阶段。
        let timeConstant: TimeInterval
        /// 本阶段是否有真实进度信号（有则不做估算）。
        let usesRealProgress: Bool
        /// 本阶段落在底部轨道的第几格（0 起）。
        let bucket: Int
        /// 本阶段在该格内的序号（0 起）。
        let indexInBucket: Int
    }

    /// 阶段 → 预算。
    ///
    /// **这是唯一一张表**：进度环、阶段轨道、估算函数都从这里取值，不再各写一份
    /// switch。旧实现有三处 switch 各抄一遍同一套语义（`segmentFraction` /
    /// `overallProgress` / `timelinePosition`），而本仓已因「同一条规则两份实现」
    /// 踩过 6 次以上 —— 每一次都是「改了一处、另一处静默失效」。
    ///
    /// ## 时间常数 `timeConstant`（τ）—— 2026-09-18 **按真机实测重标**
    ///
    /// 规则：**τ ≈ 该阶段实测耗时的 1/2.5**。`1−e^(−t/τ)` 在 `t ≈ 2.5τ` 时才走到 92%，
    /// 所以取这个比例能让爬升**贯穿整个阶段**，而不是「先冲后停」。
    ///
    /// 实测来源：构建 133 真机日志的各阶段时间戳（`318***5***@qq.com` 签抖音 +
    /// LiveContainer 成功那次）：
    ///
    /// | 阶段 | 实测 | 旧 τ | 新 τ |
    /// |---|---|---|---|
    /// | `preparingAccount` | ~18 秒 | 1.6 | **7** |
    /// | `preparingBundle` | **118 秒**（抖音）/ 0–3 秒（小包） | 24 | **45** |
    /// | `preparingCertificate` | ~10 秒（含证书轮换） | 1.6 | **4** |
    /// | `preparingAppID` | ~14 秒（含描述文件） | 3 | **5** |
    /// | `preparingProfiles` | 同上（日志未单独分段） | 3 | **4** |
    /// | `signing` | 0–1 秒 | 3 | **1.5** |
    /// | `pushing` | ~3 秒 | 8 | **3** |
    /// | `installing` | 4–6 秒（**但长安装可达数分钟**） | 20 | **20（不动）** |
    ///
    /// ⚠️ `installing` **刻意不动**：installd 不回报进度，而它可能长到几分钟
    /// （真机见过静默 9 分钟 ✗）⇒ τ 必须按**长尾**取，不能按典型的 4–6 秒取 ✓。
    /// `waitingForChannel` / `verifying` 也保持原值（本来就秒级）✓。
    ///
    /// ⚠️ 样本量**只有一两次真机**（小包 + 抖音）⇒ 等阶段时间戳日志攒够数据后**再校准一次** ✓。
    static func plan(
        for stage: SigningStage,
        renewalExecutionPath: RenewalExecutionPath? = nil
    ) -> Plan {
        if renewalExecutionPath == .profileOnly {
            return profileOnlyPlan(for: stage)
        }
        switch stage {
        case .waitingForChannel:
            return Plan(
                floor: 6, ceiling: 8, timeConstant: 1.0,
                usesRealProgress: false, bucket: 0, indexInBucket: 0
            )
        case .preparingAccount:
            return Plan(
                floor: 8, ceiling: 14, timeConstant: 7,
                usesRealProgress: false, bucket: 1, indexInBucket: 0
            )
        case .preparingBundle:
            return Plan(
                floor: 14, ceiling: 38, timeConstant: 45,
                usesRealProgress: false, bucket: 1, indexInBucket: 1
            )
        case .preparingCertificate:
            return Plan(
                floor: 38, ceiling: 46, timeConstant: 4,
                usesRealProgress: false, bucket: 1, indexInBucket: 2
            )
        case .preparingAppID:
            return Plan(
                floor: 46, ceiling: 58, timeConstant: 5,
                usesRealProgress: false, bucket: 2, indexInBucket: 0
            )
        case .preparingProfiles:
            return Plan(
                floor: 58, ceiling: 66, timeConstant: 4,
                usesRealProgress: false, bucket: 2, indexInBucket: 1
            )
        case .signing:
            return Plan(
                floor: 66, ceiling: 74, timeConstant: 1.5,
                usesRealProgress: false, bucket: 3, indexInBucket: 0
            )
        case .pushing:
            return Plan(
                floor: 74, ceiling: 88, timeConstant: 3,
                usesRealProgress: true, bucket: 4, indexInBucket: 0
            )
        case .installing:
            return Plan(
                floor: 88, ceiling: 95, timeConstant: 20,
                usesRealProgress: false, bucket: 4, indexInBucket: 1
            )
        case .verifying:
            return Plan(
                floor: 95, ceiling: 99.5, timeConstant: 1.5,
                usesRealProgress: false, bucket: 4, indexInBucket: 2
            )
        }
    }

    /// profile-only 不会重签、传输或安装 IPA，因此不能沿用完整重签的十阶段分配。
    /// 这张表只枚举会真实发生的六个阶段；不可能到达的阶段退回完整路径，避免异常
    /// 事件把轨道映射成无定义状态。
    private static func profileOnlyPlan(for stage: SigningStage) -> Plan {
        switch stage {
        case .waitingForChannel:
            return Plan(
                floor: 0, ceiling: 8, timeConstant: 1.0,
                usesRealProgress: false, bucket: 0, indexInBucket: 0
            )
        case .preparingAccount:
            return Plan(
                floor: 8, ceiling: 22, timeConstant: 7,
                usesRealProgress: false, bucket: 1, indexInBucket: 0
            )
        case .preparingBundle:
            return Plan(
                floor: 22, ceiling: 40, timeConstant: 45,
                usesRealProgress: false, bucket: 2, indexInBucket: 0
            )
        case .preparingCertificate:
            return Plan(
                floor: 40, ceiling: 55, timeConstant: 4,
                usesRealProgress: false, bucket: 2, indexInBucket: 1
            )
        case .preparingAppID:
            return Plan(
                floor: 55, ceiling: 75, timeConstant: 5,
                usesRealProgress: false, bucket: 3, indexInBucket: 0
            )
        case .preparingProfiles:
            return Plan(
                floor: 75, ceiling: 99.5, timeConstant: 4,
                usesRealProgress: false, bucket: 4, indexInBucket: 0
            )
        case .signing, .pushing, .installing, .verifying:
            return plan(for: stage)
        }
    }

    /// 第 `bucket` 格承载几个阶段。
    ///
    /// **由表推导，不另写一份数字** —— 否则以后往某个格子里加阶段时，
    /// 格子数会静默错位（表现是「该格填到 2/3 就变绿」或「永远填不满」）。
    static func bucketTotal(
        _ bucket: Int,
        renewalExecutionPath: RenewalExecutionPath? = nil
    ) -> Int {
        var total = 0
        for stage in activeStages(for: renewalExecutionPath)
            where plan(for: stage, renewalExecutionPath: renewalExecutionPath).bucket == bucket {
            total += 1
        }
        return total
    }

    private static func activeStages(
        for renewalExecutionPath: RenewalExecutionPath?
    ) -> [SigningStage] {
        guard renewalExecutionPath == .profileOnly else { return SigningStage.allCases }
        return [
            .waitingForChannel,
            .preparingAccount,
            .preparingBundle,
            .preparingCertificate,
            .preparingAppID,
            .preparingProfiles
        ]
    }

    /// 本阶段已经过的秒数 → 估算进度（0–100）。
    ///
    /// - Parameter elapsed: 进入本阶段的时刻到现在的秒数。负数按 0 处理
    ///   （时钟回拨、或起点晚于当前时刻时，不该出现负进度）。
    static func estimatedProgress(
        stage: SigningStage,
        elapsed: TimeInterval,
        renewalExecutionPath: RenewalExecutionPath? = nil
    ) -> Double {
        let budget = plan(for: stage, renewalExecutionPath: renewalExecutionPath)
        let safeElapsed = max(0, elapsed)
        let convergence = 1 - exp(-safeElapsed / budget.timeConstant)
        return budget.floor + (budget.ceiling - budget.floor) * convergence
    }

    /// 界面最终显示的进度（0–100）。
    ///
    /// ⚠️ 2026-09-19：**生产路径不再用它显示数字** —— 数字一律走
    /// `confirmedProgress(stage:realProgress:workUnits:)`（只有真实信号才给百分比）。
    /// 保留它是因为「按时间收敛」这件事仍要有唯一出口（轨道格内填充经 `stageFraction`
    /// 的兜底分支使用同一套公式），删掉就会逼出第二份收敛实现 —— 本仓已为
    /// 「同一条规则两份实现」踩过 7 次。
    ///
    /// - Parameter realProgress: 安装通道回传的真实上传进度（0–1）。**只有**
    ///   `Plan.usesRealProgress` 为真的阶段采信它，其余阶段一律忽略 —— 否则切到
    ///   别的阶段后残留的旧值会把进度拽回去。
    static func overallProgress(
        stage: SigningStage,
        elapsed: TimeInterval,
        realProgress: Double?,
        renewalExecutionPath: RenewalExecutionPath? = nil
    ) -> Double {
        let budget = plan(for: stage, renewalExecutionPath: renewalExecutionPath)
        guard budget.usesRealProgress else {
            return estimatedProgress(
                stage: stage,
                elapsed: elapsed,
                renewalExecutionPath: renewalExecutionPath
            )
        }
        let fraction = clampUnit(realProgress)
        return budget.floor + (budget.ceiling - budget.floor) * fraction
    }

    /// **已确认**到达的进度（0–100）：上一阶段真正完成时到达的位置。
    ///
    /// 界面用它画深色那一段弧。它**不随时间变化** —— 本阶段无论估算爬到哪里，
    /// 深色弧都停在进入本阶段时的位置，直到阶段真正完成。这是「不编数字」在视觉上的
    /// 落点：用户看到浅色弧在长、深色弧不动，就知道浅色那段是估计。
    static func confirmedProgress(
        stage: SigningStage,
        realProgress: Double?,
        renewalExecutionPath: RenewalExecutionPath? = nil
    ) -> Double {
        let budget = plan(for: stage, renewalExecutionPath: renewalExecutionPath)
        guard budget.usesRealProgress else { return budget.floor }
        let fraction = clampUnit(realProgress)
        return budget.floor + (budget.ceiling - budget.floor) * fraction
    }

    /// 本阶段**真实**的完成比例（0–1）；没有可信信号时返回 nil。
    ///
    /// 优先级只有一条：`workUnits`（可数的对象）＞ 字节进度（仅 `usesRealProgress`
    /// 的阶段采信）＞ nil。返回 nil 时界面**不给数字**、改画不确定的转弧 ——
    /// 这是「假预估」与「全程静止」之外的第三条路（2026-09-19 设计讨论）。
    static func realFraction(
        stage: SigningStage,
        realProgress: Double?,
        workUnits: SigningWorkUnits?,
        renewalExecutionPath: RenewalExecutionPath? = nil
    ) -> Double? {
        if let workUnits, workUnits.stage == stage, let fraction = workUnits.fraction {
            return fraction
        }
        guard plan(for: stage, renewalExecutionPath: renewalExecutionPath).usesRealProgress,
              let realProgress else { return nil }
        return clampUnit(realProgress)
    }

    /// 环能不能给这个数字：能 ⇒ 有真实信号；不能 ⇒ 转弧、环心不放数字。
    static func hasRealSignal(
        stage: SigningStage,
        realProgress: Double?,
        workUnits: SigningWorkUnits?,
        renewalExecutionPath: RenewalExecutionPath? = nil
    ) -> Bool {
        realFraction(
            stage: stage,
            realProgress: realProgress,
            workUnits: workUnits,
            renewalExecutionPath: renewalExecutionPath
        ) != nil
    }

    /// 带真实信号版的「已确认进度」（0–100）。
    ///
    /// 无真实信号时返回**地板值**，而不是按时间爬的估算 —— 屏幕上出现的每一个百分比
    /// 都必须有出处。时间驱动的那一套只留给底部轨道格内的缓慢填充
    /// （有界、且永远不会称「已完成」）。
    static func confirmedProgress(
        stage: SigningStage,
        realProgress: Double?,
        workUnits: SigningWorkUnits?,
        renewalExecutionPath: RenewalExecutionPath? = nil
    ) -> Double {
        let budget = plan(for: stage, renewalExecutionPath: renewalExecutionPath)
        guard let fraction = realFraction(
            stage: stage,
            realProgress: realProgress,
            workUnits: workUnits,
            renewalExecutionPath: renewalExecutionPath
        ) else {
            return budget.floor
        }
        return budget.floor + (budget.ceiling - budget.floor) * fraction
    }

    /// 本阶段是否处于「估算」状态。
    ///
    /// 界面据此决定要不要给当前格加扫光、给弧的前端加呼吸点：有真实上传进度的格子
    /// 本身就在动，再叠一层扫光会像两个进度在打架。
    static func isEstimated(
        stage: SigningStage,
        renewalExecutionPath: RenewalExecutionPath? = nil
    ) -> Bool {
        plan(for: stage, renewalExecutionPath: renewalExecutionPath).usesRealProgress == false
    }

    /// 本阶段内部的完成比例（0–1）：地板为 0、天花板为 1。
    ///
    /// 因为 `ceiling_i == floor_{i+1}`，阶段真正完成时它会到达 1，而下一阶段从 0 起
    /// ⇒ 阶段轨道在衔接处不跳。
    static func stageFraction(
        stage: SigningStage,
        elapsed: TimeInterval,
        realProgress: Double?,
        workUnits: SigningWorkUnits? = nil,
        renewalExecutionPath: RenewalExecutionPath? = nil
    ) -> Double {
        let budget = plan(for: stage, renewalExecutionPath: renewalExecutionPath)
        let span = budget.ceiling - budget.floor
        guard span > 0 else { return 0 }
        // 有真实信号就用真实的；没有才退回「按已过时间收敛」的格内填充。
        // 这条兜底刻意**只**服务于轨道：它不产生百分比数字（数字走 `confirmedProgress`）。
        if let fraction = realFraction(
            stage: stage,
            realProgress: realProgress,
            workUnits: workUnits,
            renewalExecutionPath: renewalExecutionPath
        ) {
            return fraction
        }
        let value = estimatedProgress(
            stage: stage,
            elapsed: elapsed,
            renewalExecutionPath: renewalExecutionPath
        )
        return clampUnit((value - budget.floor) / span)
    }

    /// 底部第 `bucket` 格该填多少（0–1）。
    ///
    /// 三种状态全部由这里给出，界面里不再有任何分支：
    ///   - 已经过去的格 ⇒ 1；
    ///   - 当前格 ⇒ `(格内已完成阶段数 + 本阶段完成比例) / 格内阶段总数`；
    ///   - 还没到的格 ⇒ 0。
    ///
    /// 于是每次阶段推进，轨道都**一定**动一小格（旧实现是把写死的 0.33/0.5/0.67
    /// 塞进桶里，与真实完成度无关），而格与格之间的衔接是连续的。
    static func bucketFill(
        _ bucket: Int,
        stage: SigningStage,
        elapsed: TimeInterval,
        realProgress: Double?,
        workUnits: SigningWorkUnits? = nil,
        renewalExecutionPath: RenewalExecutionPath? = nil
    ) -> Double {
        let budget = plan(for: stage, renewalExecutionPath: renewalExecutionPath)
        if bucket < budget.bucket { return 1 }
        if bucket > budget.bucket { return 0 }
        let total = bucketTotal(
            budget.bucket,
            renewalExecutionPath: renewalExecutionPath
        )
        guard total > 0 else { return 0 }
        let fraction = stageFraction(
            stage: stage,
            elapsed: elapsed,
            realProgress: realProgress,
            workUnits: workUnits,
            renewalExecutionPath: renewalExecutionPath
        )
        return clampUnit((Double(budget.indexInBucket) + fraction) / Double(total))
    }

    /// 是否该由进度卡片自己显示「本阶段已用时」。
    ///
    /// `.installing` / `.verifying` 排除在外：那两段由 `InstallWaitNote` 统一报
    /// 「已等待 m:ss」，两处各报一遍会让同一个数字在同一张卡片上出现两次。
    static func showsOwnElapsed(stage: SigningStage, elapsed: TimeInterval) -> Bool {
        if stage == .installing || stage == .verifying { return false }
        return elapsed >= elapsedDisplayThreshold
    }

    private static func clampUnit(_ value: Double?) -> Double {
        guard let value else { return 0 }
        return min(1, max(0, value))
    }
}
