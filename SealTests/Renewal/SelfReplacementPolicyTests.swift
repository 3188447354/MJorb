import Foundation
import Testing
@testable import Seal

struct ReconcileCase {
    let candidateMatches: Bool
    let oldMatches: Bool
    let readable: Bool
    let expected: SelfReplacementReconcileAction
    var input: SelfReplacementPolicy.Input {
        .init(candidateMatches: candidateMatches, oldMatches: oldMatches, readable: readable)
    }
}

struct SelfReplacementPolicyTests {
    @Test(arguments: [
        ReconcileCase(candidateMatches: true, oldMatches: false, readable: true, expected: .settle),
        ReconcileCase(candidateMatches: false, oldMatches: true, readable: true, expected: .closeAsNotInstalled),
        ReconcileCase(candidateMatches: false, oldMatches: false, readable: true, expected: .requireRecovery(reason: "当前 Seal 与安装前身份、候选身份都不一致")),
        ReconcileCase(candidateMatches: false, oldMatches: false, readable: false, expected: .requireRecovery(reason: "无法完整读取当前 Seal 主程序和扩展身份"))
    ])
    func reconciliationNeverRequestsAutomaticInstall(testCase: ReconcileCase) {
        #expect(SelfReplacementPolicy.reconcile(testCase.input) == testCase.expected)
    }

    @Test
    func sameProcessReturnsAwaitNextLaunch() {
        let transaction = SelfReplacementTransaction.fixture
        let action = SelfReplacementPolicy.reconcile(
            transaction: transaction,
            running: .fixture,
            currentProcessID: transaction.preparedProcessID,
            preparedProcessID: transaction.preparedProcessID
        )
        #expect(action == .awaitNextLaunch)
    }

    @Test
    func mainMatchesButExtensionMismatchRequiresRecovery() {
        let transaction = SelfReplacementTransaction.fixture
        let installed = InstalledIdentity.fixture
        let running = InstalledIdentity(
            bundleURL: installed.bundleURL,
            version: installed.version,
            buildNumber: installed.buildNumber,
            targets: [
                .mainFixture,
                SignedTargetIdentity(
                    kind: .appExtension,
                    bundleIdentifier: "com.example.seal.share",
                    teamIdentifier: "T3432ZHJUF9",
                    applicationIdentifier: "T3432ZHJUF9.com.example.seal.share",
                    profileUUID: "profile-uuid",
                    profileExpirationDate: .distantFuture,
                    signerSerialNumber: "DIFFERENT",
                    signerCertificateSHA256: String(repeating: "A", count: 64),
                    status: .complete
                )
            ],
            readErrors: []
        )
        let action = SelfReplacementPolicy.reconcile(
            transaction: transaction,
            running: running,
            currentProcessID: UUID(),
            preparedProcessID: transaction.preparedProcessID
        )
        #expect(action == .requireRecovery(reason: "当前 Seal 与安装前身份、候选身份都不一致"))
    }

    @Test
    func noExtensionShapeAllowsSelfReplacement() {
        let running = InstalledIdentity(
            bundleURL: URL(fileURLWithPath: "/Applications/Seal.app"),
            version: "1.1.16",
            buildNumber: "3",
            targets: [.mainFixture],
            readErrors: []
        )
        let candidate = CandidateIdentity(
            transactionID: UUID(),
            ipaSHA256: String(repeating: "B", count: 64),
            version: "1.1.16",
            buildNumber: "3",
            targets: [.mainFixture]
        )
        #expect(SelfReplacementPolicy.shapeMismatch(running: running, candidate: candidate) == nil)
    }

    @Test
    func extensionRemovalRequiresComputerInstallInsteadOfSelfReplacement() {
        let running = InstalledIdentity.fixture // 旧版：主程序 + 内置扩展
        let candidate = CandidateIdentity(
            transactionID: UUID(),
            ipaSHA256: String(repeating: "B", count: 64),
            version: "1.1.16",
            buildNumber: "3",
            targets: [.mainFixture] // 新版：无扩展
        )
        #expect(
            SelfReplacementPolicy.shapeMismatch(running: running, candidate: candidate)
                == .extensionRemovalRequiresComputerInstall
        )
    }
}

private extension SelfReplacementTransaction {
    static var fixture: SelfReplacementTransaction {
        SelfReplacementTransaction.make(
            id: UUID(),
            accountID: UUID(),
            preparedProcessID: UUID(),
            installedBefore: .fixture,
            candidate: .fixture,
            signedIPARelativePath: "Apps/Seal/Signed.ipa"
        )
    }
}

private extension CandidateIdentity {
    static var fixture: CandidateIdentity {
        CandidateIdentity(
            transactionID: UUID(),
            ipaSHA256: String(repeating: "B", count: 64),
            version: "1.0.0",
            buildNumber: "1",
            targets: [.mainFixture, .extensionFixture]
        )
    }
}

private extension InstalledIdentity {
    static var fixture: InstalledIdentity {
        InstalledIdentity(
            bundleURL: URL(fileURLWithPath: "/Applications/Seal.app"),
            version: "1.0.0",
            buildNumber: "1",
            targets: [.mainFixture, .extensionFixture],
            readErrors: []
        )
    }
}

private extension SignedTargetIdentity {
    static let mainFixture = SignedTargetIdentity(
        kind: .mainApp,
        bundleIdentifier: "com.example.seal",
        teamIdentifier: "T3432ZHJUF9",
        applicationIdentifier: "T3432ZHJUF9.com.example.seal",
        profileUUID: "profile-uuid",
        profileExpirationDate: .distantFuture,
        signerSerialNumber: "ABC123",
        signerCertificateSHA256: String(repeating: "A", count: 64),
        status: .complete
    )

    static let extensionFixture = SignedTargetIdentity(
        kind: .appExtension,
        bundleIdentifier: "com.example.seal.share",
        teamIdentifier: "T3432ZHJUF9",
        applicationIdentifier: "T3432ZHJUF9.com.example.seal.share",
        profileUUID: "profile-uuid",
        profileExpirationDate: .distantFuture,
        signerSerialNumber: "ABC123",
        signerCertificateSHA256: String(repeating: "A", count: 64),
        status: .complete
    )
}
