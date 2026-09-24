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

    @Test
    func replacementGraceKeepsTheTransactionPendingInsteadOfClosingIt() {
        // 「仍在安装前身份」有两种成因，必须分开处理：
        //   ① 安装**真的失败了** ⇒ 按未安装关闭事务（终态）；
        //   ② 传输刚返回、installd 还在替换**进行中** ⇒ 此刻读到旧包完全正常。
        // 把 ② 当 ① 处理是不可恢复的：`closeAsNotInstalled` 会写 `settledAt`，
        // 之后每次启动都不再对账，而记录已在签名阶段被乐观推进成新 profile
        // ⇒ 记录与设备现实永久错位（维护作业随后会删掉设备上正在用的那份 profile）。
        // 真机构建 38 的变砖链路正是这样：01:46:19 上传完成、01:46:30 判失败。
        //
        // 造一个「候选还没落盘」的事务：安装前身份与候选版本号不同
        // ⇒ `candidate.matches(running)` 为 false，而 `running == installedBefore` 成立。
        let oldIdentity = InstalledIdentity(
            bundleURL: URL(fileURLWithPath: "/Applications/Seal.app"),
            version: "0.9.0",
            buildNumber: "1",
            targets: [.mainFixture, .extensionFixture],
            readErrors: []
        )
        let transaction = SelfReplacementTransaction.make(
            id: UUID(),
            accountID: UUID(),
            preparedProcessID: UUID(),
            installedBefore: oldIdentity,
            candidate: .fixture,
            signedIPARelativePath: "Apps/Seal/Signed.ipa"
        )

        // 替换窗口已过 ⇒ 认定候选确实没落盘，按未安装关闭。
        let afterGrace = SelfReplacementPolicy.reconcile(
            transaction: transaction,
            running: oldIdentity,
            currentProcessID: UUID(),
            preparedProcessID: transaction.preparedProcessID
        )
        #expect(afterGrace == .closeAsNotInstalled)

        // 仍在替换窗口内 ⇒ 保留事务、下次启动再判，绝不写终态。
        let withinGrace = SelfReplacementPolicy.reconcile(
            transaction: transaction,
            running: oldIdentity,
            currentProcessID: UUID(),
            preparedProcessID: transaction.preparedProcessID,
            withinReplacementGrace: true
        )
        #expect(withinGrace == .awaitNextLaunch)
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
