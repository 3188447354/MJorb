import CryptoKit
import Foundation

enum SelfReplacementFailure: Error, Equatable, Sendable {
    case runningIdentityUnknown([String])
    case bundleShapeChanged
    case localSigningIdentityUnavailable
    case candidateChanged
}

/// Seal 自替换委托边界：签名协调器只负责「准备一笔事务 + 提交一次安装」，
/// 安装结果由下一次启动的新进程对账确认。
protocol SelfReplacing: Actor {
    func prepare(
        app: AppRecord,
        accountID: UUID,
        signedIPARelativePath: String
    ) async throws -> SelfReplacementTransaction
    func submitPrepared(
        transactionID: UUID,
        progress: @escaping @Sendable (Double) async -> Void
    ) async throws
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

    init(
        store: SelfReplacementTransactionStore,
        readRunningIdentity: @escaping @Sendable () throws -> InstalledIdentity,
        ipaIdentityReader: SignedIPAIdentityReader,
        installChannel: any InstallChannel,
        fileStore: AppFileStore,
        keychain: KeychainVault,
        processID: UUID
    ) {
        self.store = store
        self.readRunningIdentity = readRunningIdentity
        self.ipaIdentityReader = ipaIdentityReader
        self.installChannel = installChannel
        self.fileStore = fileStore
        self.keychain = keychain
        self.processID = processID
    }

    init(
        store: SelfReplacementTransactionStore,
        identityReader: AppBundleSigningIdentityReader,
        ipaIdentityReader: SignedIPAIdentityReader,
        installChannel: any InstallChannel,
        fileStore: AppFileStore,
        keychain: KeychainVault,
        processID: UUID
    ) {
        self.init(
            store: store,
            readRunningIdentity: { try identityReader.read(bundleURL: Bundle.main.bundleURL) },
            ipaIdentityReader: ipaIdentityReader,
            installChannel: installChannel,
            fileStore: fileStore,
            keychain: keychain,
            processID: processID
        )
    }

    func prepare(
        app: AppRecord,
        accountID: UUID,
        signedIPARelativePath: String
    ) async throws -> SelfReplacementTransaction {
        let running = try readRunningIdentity()
        guard running.isComplete else {
            throw SelfReplacementFailure.runningIdentityUnknown(running.readErrors)
        }
        let ipaData = try await fileStore.read(relativePath: signedIPARelativePath)
        let id = UUID()
        let candidate = try ipaIdentityReader.read(ipaData: ipaData, transactionID: id)
        guard candidate.targets.map(\.bundleIdentifier).sorted()
                == running.targets.map(\.bundleIdentifier).sorted() else {
            throw SelfReplacementFailure.bundleShapeChanged
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
        return try await store.create(transaction)
    }

    func submitPrepared(
        transactionID: UUID,
        progress: @escaping @Sendable (Double) async -> Void
    ) async throws {
        let transaction = try await store.requirePending(id: transactionID)
        let data = try await fileStore.read(relativePath: transaction.signedIPARelativePath)
        guard SHA256.hexDigest(data) == transaction.candidate.ipaSHA256 else {
            throw SelfReplacementFailure.candidateChanged
        }
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

    func reconcileAtLaunch() async throws -> SelfReplacementReconcileAction {
        guard let transaction = try await store.loadPending() else { return .none }
        let running = try readRunningIdentity()
        return SelfReplacementPolicy.reconcile(
            transaction: transaction,
            running: running,
            currentProcessID: processID,
            preparedProcessID: transaction.preparedProcessID
        )
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
