import Foundation
import Testing
@testable import Seal

struct SelfManagementPresentationTests {
    struct PresentationCase {
        let state: SelfManagementState
        let title: String
        init(_ state: SelfManagementState, _ title: String) {
            self.state = state
            self.title = title
        }
    }

    /// 每个状态都必须有确定的口语化标题。
    @Test(arguments: [
        PresentationCase(.externalBootstrap, "电脑签名，等待本机接管"),
        PresentationCase(.preparingLocalIdentity, "正在准备本机签名身份"),
        PresentationCase(.localIdentityReady, "本机身份已就绪"),
        PresentationCase(.awaitingReplacementConfirmation, "已提交安装，等待重新打开 Seal 确认"),
        PresentationCase(.selfManaged, "Seal 已由本机管理"),
        PresentationCase(.recoveryRequired, "需要电脑覆盖恢复")
    ])
    func stateHasPlainLanguageSummary(testCase: PresentationCase) {
        #expect(SelfManagementPresentation(testCase.state).title == testCase.title)
    }

    /// 等待确认状态下绝不允许再次安装（只提交一次是硬约束）。
    @Test
    func awaitingConfirmationNeverAllowsInstall() {
        let presentation = SelfManagementPresentation(.awaitingReplacementConfirmation)
        #expect(presentation.allowsInstall == false)
        #expect(presentation.showsComputerRecovery == false)
    }

    /// 恢复状态必须引导电脑覆盖，且禁止安装按钮。
    @Test
    func recoveryRequiredShowsComputerRecovery() {
        let presentation = SelfManagementPresentation(.recoveryRequired)
        #expect(presentation.showsComputerRecovery)
        #expect(presentation.allowsInstall == false)
    }

    /// 外部引导与本机身份就绪都允许发起接管；自管态允许常规续签。
    @Test
    func installableStatesAllowInstall() {
        #expect(SelfManagementPresentation(.externalBootstrap).allowsInstall)
        #expect(SelfManagementPresentation(.localIdentityReady).allowsInstall)
        #expect(SelfManagementPresentation(.selfManaged).allowsInstall)
        #expect(SelfManagementPresentation(.preparingLocalIdentity).allowsInstall == false)
    }
}

struct SelfManagementStateResolverTests {
    private func transaction(
        phase: SelfReplacementTransaction.Phase
    ) -> SelfReplacementTransaction {
        var transaction = SelfReplacementTransaction.make(
            id: UUID(),
            accountID: UUID(),
            preparedProcessID: UUID(),
            installedBefore: .unknown(bundleIdentifier: "com.example.seal"),
            candidate: CandidateIdentity(
                transactionID: UUID(),
                ipaSHA256: "IPA-SHA",
                version: "1.0",
                buildNumber: "1",
                targets: []
            ),
            signedIPARelativePath: "Apps/Seal/Signed.ipa"
        )
        transaction.phase = phase
        return transaction
    }

    /// 无事务、真实签名者没有本机私钥：电脑签的 Seal，等待接管。
    @Test
    func noTransactionWithExternalSignerIsExternalBootstrap() {
        let state = SelfManagementStateResolver.resolve(
            identity: .fixtureMain(signerSerialNumber: "EXTERNAL"),
            pendingTransaction: nil,
            signerHasLocalPrivateKey: false
        )
        #expect(state == .externalBootstrap)
    }

    /// 无事务、真实签名者持有本机私钥：Seal 已由本机管理。
    @Test
    func noTransactionWithLocalSignerIsSelfManaged() {
        let state = SelfManagementStateResolver.resolve(
            identity: .fixtureMain(),
            pendingTransaction: nil,
            signerHasLocalPrivateKey: true
        )
        #expect(state == .selfManaged)
    }

    /// 已准备未提交：本机身份就绪，可以提交一次覆盖安装。
    @Test
    func preparedTransactionIsLocalIdentityReady() {
        let state = SelfManagementStateResolver.resolve(
            identity: .fixtureMain(),
            pendingTransaction: transaction(phase: .prepared),
            signerHasLocalPrivateKey: true
        )
        #expect(state == .localIdentityReady)
    }

    /// 已提交（含运输返回 / 旧身份仍在跑）：一律等待下次启动确认。
    @Test(arguments: [
        SelfReplacementTransaction.Phase.submitting,
        .awaitingReplacementConfirmation,
        .installedOldIdentity,
        .settling
    ])
    func submittedTransactionAwaitsConfirmation(phase: SelfReplacementTransaction.Phase) {
        let state = SelfManagementStateResolver.resolve(
            identity: .fixtureMain(),
            pendingTransaction: transaction(phase: phase),
            signerHasLocalPrivateKey: true
        )
        #expect(state == .awaitingReplacementConfirmation)
    }

    /// 事务标记需要恢复：优先于一切其他信号。
    @Test
    func recoveryRequiredTransactionWins() {
        let state = SelfManagementStateResolver.resolve(
            identity: .fixtureMain(),
            pendingTransaction: transaction(phase: .recoveryRequired),
            signerHasLocalPrivateKey: true
        )
        #expect(state == .recoveryRequired)
    }

    /// 身份读不出来：无法确认是外部覆盖还是本机管理，按恢复处理。
    @Test
    func unreadableIdentityRequiresRecovery() {
        let unreadable = InstalledIdentity(
            bundleURL: URL(fileURLWithPath: "/Running/Seal.app"),
            version: "1.0",
            buildNumber: "1",
            targets: [],
            readErrors: ["CMS 读取失败"]
        )
        #expect(SelfManagementStateResolver.resolve(
            identity: unreadable,
            pendingTransaction: nil,
            signerHasLocalPrivateKey: false
        ) == .recoveryRequired)
        #expect(SelfManagementStateResolver.resolve(
            identity: nil,
            pendingTransaction: nil,
            signerHasLocalPrivateKey: false
        ) == .recoveryRequired)
    }

    /// 事务状态优先于「签名者已有本机私钥」：续签进行中不能显示自管态。
    @Test
    func pendingTransactionTakesPrecedenceOverLocalSigner() {
        let state = SelfManagementStateResolver.resolve(
            identity: .fixtureMain(),
            pendingTransaction: transaction(phase: .prepared),
            signerHasLocalPrivateKey: true
        )
        #expect(state == .localIdentityReady)
    }
}
