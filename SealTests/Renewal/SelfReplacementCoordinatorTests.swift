import Foundation
import Testing
@testable import Seal

struct SelfReplacementCoordinatorTests {
    enum InstallOutcome {
        case success
        case timeout
        case connectionLost
    }

    @Test(arguments: [InstallOutcome.success, .timeout, .connectionLost])
    func submitCallsInstallExactlyOnce(outcome: InstallOutcome) async throws {
        let channel = CountingInstallChannel(outcome: outcome)
        let fixture = try await CoordinatorFixture.make(channel: channel)

        _ = try? await fixture.coordinator.submitPrepared(
            transactionID: fixture.transaction.id,
            progress: { _ in }
        )

        #expect(await channel.installCallCount == 1)
        #expect(try await fixture.store.loadPending()?.submission != nil)
    }

    @Test
    func secondSubmitForSameTransactionIsRejectedBeforeChannelCall() async throws {
        let fixture = try await CoordinatorFixture.make(channel: CountingInstallChannel())
        _ = try? await fixture.coordinator.submitPrepared(
            transactionID: fixture.transaction.id,
            progress: { _ in }
        )
        await #expect(throws: SelfReplacementStoreError.alreadySubmitted) {
            try await fixture.coordinator.submitPrepared(
                transactionID: fixture.transaction.id,
                progress: { _ in }
            )
        }
        #expect(await fixture.channel.installCallCount == 1)
    }
}

private actor CountingInstallChannel: InstallChannel {
    private(set) var installCallCount = 0
    private let outcome: SelfReplacementCoordinatorTests.InstallOutcome

    init(outcome: SelfReplacementCoordinatorTests.InstallOutcome = .success) {
        self.outcome = outcome
    }

    func start() async throws -> String { "DEVICE-1" }
    func diagnose() async -> InstallChannelDiagnostics { .empty }
    func isReady() async -> Bool { true }
    func pushIpa(ipaData: Data, bundleID: String) async throws {}
    func installPushedIpa(bundleID: String, isSelfReplacement: Bool) async throws {}
    func install(ipaData: Data, bundleID: String, isSelfReplacement: Bool) async throws {
        installCallCount += 1
        switch outcome {
        case .success: break
        case .timeout: throw CancellationError()
        case .connectionLost: throw ImportFailure(title: "连接丢失", reason: "fixture", recovery: "重试", code: "SEAL-INSTALL-001")
        }
    }
    func verifyInstalled(bundleID: String) async throws {}
}

private struct CoordinatorFixture {
    let coordinator: SelfReplacementCoordinator
    let store: SelfReplacementTransactionStore
    let transaction: SelfReplacementTransaction
    let channel: CountingInstallChannel

    static func make(channel: CountingInstallChannel) async throws -> CoordinatorFixture {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "SealCoordinatorTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let documents = root.appending(path: "Documents", directoryHint: .isDirectory)
        let cache = root.appending(path: "Caches", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)

        let store = SelfReplacementTransactionStore(
            fileURL: root.appending(path: "SelfSigningHandoff.json")
        )
        let fileStore = AppFileStore(documentsDirectory: documents, cacheDirectory: cache)
        let transaction = SelfReplacementTransaction.fixture
        _ = try await store.create(transaction)

        let coordinator = SelfReplacementCoordinator(
            store: store,
            identityReader: AppBundleSigningIdentityReader { _ in
                .init(serialNumber: "ABC123", cmsValid: true, codeDirectoryValid: true)
            },
            ipaIdentityReader: SignedIPAIdentityReader(
                bundleReader: AppBundleSigningIdentityReader { _ in
                    .init(serialNumber: "ABC123", cmsValid: true, codeDirectoryValid: true)
                }
            ),
            installChannel: channel,
            fileStore: fileStore,
            keychain: KeychainVault(),
            processID: SelfReplacementProcess.currentID
        )
        return CoordinatorFixture(
            coordinator: coordinator,
            store: store,
            transaction: transaction,
            channel: channel
        )
    }
}

private extension SelfReplacementTransaction {
    static var fixture: SelfReplacementTransaction {
        SelfReplacementTransaction.make(
            id: UUID(),
            accountID: UUID(),
            preparedProcessID: UUID(),
            installedBefore: .unknown(bundleIdentifier: "com.example.seal"),
            candidate: .legacy(
                transactionID: UUID(),
                bundleIdentifier: "com.example.seal",
                teamIdentifier: "TEAM",
                profileUUID: "PROFILE-UUID",
                certificateSerialNumber: "ABC123"
            ),
            signedIPARelativePath: "Apps/Seal/Signed.ipa"
        )
    }
}
