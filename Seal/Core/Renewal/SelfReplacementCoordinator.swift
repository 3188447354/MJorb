import CryptoKit
import Foundation

enum SelfReplacementFailure: Error, Equatable, Sendable {
    case runningIdentityUnknown([String])
    case bundleShapeChanged
    case extensionRemovalRequiresComputerInstall
    case localSigningIdentityUnavailable
    case candidateChanged
}

/// Seal 自替换委托边界：签名协调器只负责「准备一笔事务 + 提交一次安装」，
/// 安装结果由下一次启动的新进程对账确认。
protocol SelfReplacing: Actor {
    func prepare(
        app: AppRecord,
        accountID: UUID,
        signedIPARelativePath: String,
        preloadedData: Data?
    ) async throws -> SelfReplacementTransaction
    func submitPrepared(
        transactionID: UUID,
        progress: @escaping @Sendable (Double) async -> Void
    ) async throws
    /// 丢弃 prepare 缓存的 IPA Data（调用方在 prepare 成功后用 defer 兜底，
    /// 防止 submitPrepared 没走到时 30MB 常驻）。
    func dropPreparedData(transactionID: UUID) async
    func reconcileAtLaunch() async throws -> SelfReplacementReconcileAction
    func settle() async throws -> SettledSelfReplacement
    func closeAsNotInstalled() async throws
    func requireRecovery(reason: String) async throws
    func finishCleanup(_ summary: ProfileCleanupSummary) async throws
}

/// 结算确认结果：事务 ID、刚读到的真实运行身份，以及精准清理所需的锚点。
struct SettledSelfReplacement: Equatable, Sendable {
    let transactionID: UUID
    let installedIdentity: InstalledIdentity
    let mainBundleIdentifier: String
    let mainProfileUUID: String
    let installedIdentityReadAt: Date
}

/// 同一进程即使重新构造容器也不能冒充重启；进程身份在启动时固定。
enum SelfReplacementProcess {
    static let currentID = UUID()
}

actor SelfReplacementCoordinator: SelfReplacing {
    private let store: SelfReplacementTransactionStore
    private let readRunningIdentity: @Sendable () throws -> InstalledIdentity
    private let ipaIdentityReader: SignedIPAIdentityReader
    private let installChannel: any InstallChannel
    private let fileStore: AppFileStore
    private let keychain: KeychainVault
    private let processID: UUID
    private let logStore: SealLogStore?
    // 性能：prepare 读到的 Data 缓存（2026-10-04）。submitPrepared 紧随其后调用，
    // 复用内存中的 Data，省一次全文件磁盘读 + 一次 SHA256。key 为 transaction ID，
    // 用后即删，不长期占用内存。
    private var preparedDataByTransactionID: [UUID: Data] = [:]

    /// 传输返回到「能读到新包」之间的宽限期。
    ///
    /// `InstallChannel.install()` 返回只代表**传输完成 + installd 接受命令**，真正的替换是
    /// 异步的、对外不可观测。这段窗口内重启读到旧包属正常，绝不能按「未安装」关闭事务
    /// —— 那是终态，关闭后记录会永久停在签名阶段的乐观值（真机构建 38 的变砖链路）。
    ///
    /// 取 90 秒：真机上 22.9 MB 的 Seal 包在 8 秒内成功结算过，11 秒那次却失败了
    /// （同一台设备），说明单看耗时没有判别力；宽限期只需覆盖「installd 仍在忙」的常见情形，
    /// 拖得太长会让「真的失败了」迟迟不落定。
    static let replacementGraceSeconds: TimeInterval = 90

    init(
        store: SelfReplacementTransactionStore,
        readRunningIdentity: @escaping @Sendable () throws -> InstalledIdentity,
        ipaIdentityReader: SignedIPAIdentityReader,
        installChannel: any InstallChannel,
        fileStore: AppFileStore,
        keychain: KeychainVault,
        processID: UUID,
        logStore: SealLogStore? = nil
    ) {
        self.store = store
        self.readRunningIdentity = readRunningIdentity
        self.ipaIdentityReader = ipaIdentityReader
        self.installChannel = installChannel
        self.fileStore = fileStore
        self.keychain = keychain
        self.processID = processID
        self.logStore = logStore
    }

    init(
        store: SelfReplacementTransactionStore,
        identityReader: AppBundleSigningIdentityReader,
        ipaIdentityReader: SignedIPAIdentityReader,
        installChannel: any InstallChannel,
        fileStore: AppFileStore,
        keychain: KeychainVault,
        processID: UUID,
        logStore: SealLogStore? = nil
    ) {
        self.init(
            store: store,
            readRunningIdentity: { try identityReader.read(bundleURL: Bundle.main.bundleURL) },
            ipaIdentityReader: ipaIdentityReader,
            installChannel: installChannel,
            fileStore: fileStore,
            keychain: keychain,
            processID: processID,
            logStore: logStore
        )
    }

    func prepare(
        app: AppRecord,
        accountID: UUID,
        signedIPARelativePath: String,
        preloadedData: Data? = nil
    ) async throws -> SelfReplacementTransaction {
        let running = try readRunningIdentity()
        guard running.isComplete else {
            throw SelfReplacementFailure.runningIdentityUnknown(running.readErrors)
        }
        // 调用方（installSignedIPA）已把 IPA 读进内存做验证，直接复用，
        // 省一次 30MB 全文件磁盘读。没传才自己读。
        let ipaData: Data
        if let preloadedData {
            ipaData = preloadedData
        } else {
            ipaData = try await fileStore.read(relativePath: signedIPARelativePath)
        }
        let id = UUID()
        let candidate = try ipaIdentityReader.read(ipaData: ipaData, transactionID: id)
        if let mismatch = SelfReplacementPolicy.shapeMismatch(
            running: running,
            candidate: candidate
        ) {
            throw mismatch
        }
        guard let secret = try await keychain.load(accountID: accountID),
              let signerSerial = candidate.targets.first?.signerSerialNumber,
              candidate.targets.allSatisfy({
                  SigningCertificateSelectionPolicy.normalizedSerialNumber($0.signerSerialNumber)
                      == SigningCertificateSelectionPolicy.normalizedSerialNumber(signerSerial)
              }),
              let localCertificate = SigningCertificateMaterialPolicy.availableCertificate(
                  secret: secret,
                  serialNumber: signerSerial
              ),
              SigningCertificateMaterialPolicy.reuseStatus(localCertificate) == .reusable else {
            throw SelfReplacementFailure.localSigningIdentityUnavailable
        }
        let transaction = SelfReplacementTransaction.make(
            id: id,
            accountID: accountID,
            preparedProcessID: processID,
            installedBefore: running,
            candidate: candidate,
            signedIPARelativePath: signedIPARelativePath
        )
        let created: SelfReplacementTransaction
        do {
            created = try await store.create(transaction)
        } catch SelfReplacementStoreError.alreadySubmitted {
            // 上次自替换残留的事务文件，直接清掉重建（MJ 要求：不管条件都清）
            try await store.clearPending()
            created = try await store.create(transaction)
        }
        // 缓存 Data 供 submitPrepared 复用（省一次磁盘读 + SHA256）。
        preparedDataByTransactionID[id] = ipaData
        return created
    }

    func submitPrepared(
        transactionID: UUID,
        progress: @escaping @Sendable (Double) async -> Void
    ) async throws {
        let transaction = try await store.requirePending(id: transactionID)
        // 性能：复用 prepare 缓存的 Data（2026-10-04）。命中时跳过磁盘读；
        // 未命中（进程重启后恢复）时回退原逻辑：读文件 + 验哈希。
        let data: Data
        if let cached = preparedDataByTransactionID[transactionID] {
            data = cached
        } else {
            let fromDisk = try await fileStore.read(relativePath: transaction.signedIPARelativePath)
            guard SHA256.hexDigest(fromDisk) == transaction.candidate.ipaSHA256 else {
                throw SelfReplacementFailure.candidateChanged
            }
            data = fromDisk
        }
        preparedDataByTransactionID.removeValue(forKey: transactionID)
        _ = try await store.claimSubmission(transactionID: transactionID)
        do {
            try await installChannel.install(
                ipaData: data,
                bundleID: transaction.candidate.mainBundleIdentifier,
                isSelfReplacement: true,
                onProgress: progress
            )
            try await store.recordTransportReturn(transactionID: transactionID, result: "returned")
        } catch {
            try? await store.recordTransportReturn(transactionID: transactionID, result: "threw")
            throw error
        }
    }

    /// 丢弃 prepare 缓存的 IPA Data。调用方在 prepare 成功后用 defer 兜底调用，
    /// 防止 prepare 与 submitPrepared 之间抛错时 30MB 常驻（submitPrepared 走到
    /// 时自己会删，这里再删一次是无害的幂等操作）。
    func dropPreparedData(transactionID: UUID) async {
        preparedDataByTransactionID.removeValue(forKey: transactionID)
    }

    func reconcileAtLaunch() async throws -> SelfReplacementReconcileAction {
        guard let transaction = try await store.loadPending() else { return .none }
        let running = try readRunningIdentity()
        let withinGrace = Self.isWithinReplacementGrace(transaction, now: Date())
        let action = SelfReplacementPolicy.reconcile(
            transaction: transaction,
            running: running,
            currentProcessID: processID,
            preparedProcessID: transaction.preparedProcessID,
            withinReplacementGrace: withinGrace
        )
        // 宽限期内「保留事务、不结算」原本是**静默**的（`SelfAppRegistrar` 对
        // `.awaitNextLaunch` 不写日志），但这条判据在真机排查时最关键
        //（「为什么这次启动没结算」），所以单独留痕。
        // 只有「不是同一进程 + 判成 awaitNextLaunch」才可能是宽限期路径
        // —— 同一进程的 awaitNextLaunch 另有含义（还没重启），不能混为一谈。
        if action == .awaitNextLaunch,
           withinGrace,
           processID != transaction.preparedProcessID {
            try? await logStore?.append(
                category: .installation,
                level: .warning,
                message: "自替换结算：传输已返回但仍在替换窗口内（\(Int(Self.replacementGraceSeconds)) 秒），本轮不结算、保留事务，下次启动再判。",
                code: "SEAL-SELF-114"
            )
        }
        return action
    }

    /// 是否仍处于「传输已返回、installd 还在替换」的宽限期内。
    ///
    /// 没有 `returnedAt`（例如传输根本没返回就重启）⇒ **不在**宽限期内：
    /// 那种情况本来就该走失败路径，不该被宽限期掩盖。
    static func isWithinReplacementGrace(
        _ transaction: SelfReplacementTransaction,
        now: Date
    ) -> Bool {
        guard let returnedAt = transaction.submission?.returnedAt else { return false }
        return now.timeIntervalSince(returnedAt) < replacementGraceSeconds
    }

    /// 结算：重读当前运行身份，只有它仍与候选身份完全一致才把事务推进到
    /// `.settling` 并返回结算结果；AppRecord 推进与旧 profile 清理由调用方完成。
    func settle() async throws -> SettledSelfReplacement {
        guard let transaction = try await store.loadPending() else {
            throw SelfReplacementStoreError.pendingNotFound
        }
        let readAt = Date()
        let running = try readRunningIdentity()
        guard transaction.candidate.matches(running),
              let main = running.mainTarget else {
            throw SelfReplacementFailure.candidateChanged
        }
        try await store.updatePhase(
            transactionID: transaction.id,
            phase: .settling,
            failureCode: nil
        )
        return SettledSelfReplacement(
            transactionID: transaction.id,
            installedIdentity: running,
            mainBundleIdentifier: main.bundleIdentifier,
            mainProfileUUID: main.profileUUID,
            installedIdentityReadAt: readAt
        )
    }

    /// 当前运行的仍是安装前身份：候选没有落盘，事务按「未安装」关闭，不再对账。
    func closeAsNotInstalled() async throws {
        guard let transaction = try await store.loadPending() else { return }
        try await store.close(transactionID: transaction.id, phase: .installedOldIdentity)
    }

    /// 身份不可判定：事务保持挂起并标记需要电脑覆盖恢复，留给下一次启动再评估。
    func requireRecovery(reason: String) async throws {
        guard let transaction = try await store.loadPending() else { return }
        try await store.updatePhase(
            transactionID: transaction.id,
            phase: .recoveryRequired,
            failureCode: reason
        )
    }

    /// 记录推进与旧 profile 清理都已完成：把清理摘要写入事务审计并终态确认。
    func finishCleanup(_ summary: ProfileCleanupSummary) async throws {
        guard let transaction = try await store.loadPending() else { return }
        try await store.close(
            transactionID: transaction.id,
            phase: .confirmed,
            cleanupSummary: summary.logMessage
        )
    }
}

private extension SHA256 {
    static func hexDigest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02X", $0) }.joined()
    }
}
