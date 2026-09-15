import CryptoKit
import Foundation

enum SelfReplacementFailure: Error, Equatable, Sendable {
    case runningIdentityUnknown
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
}

/// 同一进程即使重新构造容器也不能冒充重启；进程身份在启动时固定。
enum SelfReplacementProcess {
    static let currentID = UUID()
}

actor SelfReplacementCoordinator: SelfReplacing {
    private let store: SelfReplacementTransactionStore
    private let identityReader: AppBundleSigningIdentityReader
    private let ipaIdentityReader: SignedIPAIdentityReader
    private let installChannel: any InstallChannel
    private let fileStore: AppFileStore
    private let keychain: KeychainVault
    private let processID: UUID

    init(
        store: SelfReplacementTransactionStore,
        identityReader: AppBundleSigningIdentityReader,
        ipaIdentityReader: SignedIPAIdentityReader,
        installChannel: any InstallChannel,
        fileStore: AppFileStore,
        keychain: KeychainVault,
        processID: UUID
    ) {
        self.store = store
        self.identityReader = identityReader
        self.ipaIdentityReader = ipaIdentityReader
        self.installChannel = installChannel
        self.fileStore = fileStore
        self.keychain = keychain
        self.processID = processID
    }

    func prepare(
        app: AppRecord,
        accountID: UUID,
        signedIPARelativePath: String
    ) async throws -> SelfReplacementTransaction {
        let running = try identityReader.read(bundleURL: Bundle.main.bundleURL)
        guard running.isComplete else { throw SelfReplacementFailure.runningIdentityUnknown }
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
        let running = try identityReader.read(bundleURL: Bundle.main.bundleURL)
        return SelfReplacementPolicy.reconcile(
            transaction: transaction,
            running: running,
            currentProcessID: processID,
            preparedProcessID: transaction.preparedProcessID
        )
    }
}

private extension SHA256 {
    static func hexDigest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02X", $0) }.joined()
    }
}
