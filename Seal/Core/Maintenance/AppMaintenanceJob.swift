import Foundation

/// 独立的维护作业：把原本挂在**读取路径**上的三件写操作收敛到一处，并统一加空闲租约。
///
/// 为什么顺序不能变：
/// 1. **记录恢复**（导入事务恢复 + 缺失记录补建）必须最先 —— 后面两步都依赖 DB 与文件已对齐。
/// 2. **Seal 自身注册**会重写 Seal 自己的应用目录，属于覆盖写操作。
/// 3. **孤儿文件清理**是唯一的删除步骤，放最后，这样前面任何一步发现用户开始操作都能干净退出。
///
/// 每一步前后都检查 `MaintenanceGate.shouldAbort`：用户一旦开始签名 / 安装 / 续签，
/// 作业立即停止，并且**不再进入后续步骤**（尤其是删除）。
///
/// 另见 `MaintenanceGate` 的说明：维护作业永远不阻塞用户操作，非空闲就跳过本轮。
@MainActor
final class AppMaintenanceJob {
    enum Outcome: Equatable {
        /// 非空闲，本轮完全没动（没有写入、没有删除）。
        case skipped
        case completed(OrphanSweepReport)
        /// 中途发现前台操作启动，已停止；`stage` 记录停在哪一步。
        case aborted(stage: String, reason: String)
        case failed(ImportFailure)
    }

    private let gate: any MaintenanceLeasing
    private let appStore: any AppStore
    private let fileStore: AppFileStore
    private let recovery: AppRecordRecovery?
    private let selfAppRegistrar: SelfAppRegistrar?
    private let logStore: SealLogStore?

    init(
        gate: any MaintenanceLeasing,
        appStore: any AppStore,
        fileStore: AppFileStore,
        recovery: AppRecordRecovery?,
        selfAppRegistrar: SelfAppRegistrar?,
        logStore: SealLogStore?
    ) {
        self.gate = gate
        self.appStore = appStore
        self.fileStore = fileStore
        self.recovery = recovery
        self.selfAppRegistrar = selfAppRegistrar
        self.logStore = logStore
    }

    func run() async -> Outcome {
        guard let token = gate.tryAcquire() else { return .skipped }
        defer { gate.end(token) }

        // ── 1. 记录恢复 ────────────────────────────────────────────────
        if let recovery {
            do {
                try await recovery.restoreMissingRecords()
            } catch let failure as ImportFailure {
                return .failed(failure)
            } catch {
                return .failed(Self.unexpectedFailure(stage: "记录恢复", error: error))
            }
            if gate.shouldAbort(token) {
                return .aborted(stage: "记录恢复", reason: "用户操作已开始")
            }
        }

        // ── 2. Seal 自身注册 ───────────────────────────────────────────
        if let selfAppRegistrar {
            do {
                try await selfAppRegistrar.ensureRegistered()
            } catch {
                // 自注册失败不阻断后续清理（清理是安全的：它只删 DB 里没有引用的目录），
                // 但必须留痕，不能静默吞掉。
                try? await logStore?.append(
                    category: .system,
                    level: .warning,
                    message: "Seal 自身记录同步失败",
                    code: "SEAL-SELF-REG-001"
                )
            }
            if gate.shouldAbort(token) {
                return .aborted(stage: "Seal 自身注册", reason: "用户操作已开始")
            }
        }

        // ── 3. 孤儿文件清理（唯一的删除步骤）────────────────────────────
        do {
            // 删除前复核 DB 引用：**现在**取一次有效 ID，不复用作业开始时或更早的快照。
            // 快照与删除之间只要有新记录写入，就会把新应用的文件目录当孤儿删掉。
            guard gate.shouldAbort(token) == false else {
                return .aborted(stage: "孤儿文件清理", reason: "用户操作已开始")
            }
            let currentRecords = try await appStore.fetchAll()
            let report = try await fileStore.clearOrphanedAppFiles(
                validAppIDs: Set(currentRecords.map(\.id))
            )
            return .completed(report)
        } catch let failure as ImportFailure {
            return .failed(failure)
        } catch {
            return .failed(Self.unexpectedFailure(stage: "孤儿文件清理", error: error))
        }
    }

    private static func unexpectedFailure(stage: String, error: Error) -> ImportFailure {
        let nsError = error as NSError
        return ImportFailure(
            title: "本地维护未完成",
            reason: "\(stage)遇到未预期错误，已停止本轮维护，未完成的步骤下次启动会继续。\n[\(nsError.domain) \(nsError.code)]",
            recovery: "下次打开 Seal 会自动继续",
            code: "SEAL-STORAGE-007"
        )
    }
}
