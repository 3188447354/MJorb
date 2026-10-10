import Foundation
import Testing
@testable import Seal

struct RenewalRoundSummaryTests {
    @Test
    func singleSigningUsesTheSameCardGrammarAndRealSharedDurationAsBatchRenewal() {
        let summary = RenewalRoundSummary(
            roundNumber: 0,
            triggerSource: .manual,
            operation: .singleSigning,
            startedAt: Date(timeIntervalSince1970: 0),
            endedAt: Date(timeIntervalSince1970: 2.4),
            items: [
                RenewalRoundItem(
                    appName: "Demo",
                    outcome: .succeeded,
                    duration: 2.4,
                    profileExpirationDate: nil,
                    failureCode: nil,
                    failureReason: nil,
                    failureRecovery: nil
                )
            ]
        )

        let message = summary.humanReadableMessage()
        #expect(message.contains("单独签名"))
        #expect(message.contains("✓ Demo 成功，用了2.4秒"))
        #expect(message.contains("■ 完成 · 共用2.4秒 · 1/1 成功"))
    }

    @Test
    func singleRenewalUsesTheSameCardGrammarAndRealSharedDurationAsBatchRenewal() {
        let summary = RenewalRoundSummary(
            roundNumber: 0,
            triggerSource: .manual,
            operation: .singleRenewal,
            startedAt: Date(timeIntervalSince1970: 0),
            endedAt: Date(timeIntervalSince1970: 3),
            items: [
                RenewalRoundItem(
                    appName: "Demo",
                    outcome: .failed,
                    duration: 3,
                    profileExpirationDate: nil,
                    failureCode: "SEAL-TEST-001",
                    failureReason: "设备未连接",
                    failureRecovery: "检查连接后重试"
                )
            ]
        )

        let message = summary.humanReadableMessage()
        #expect(message.contains("单独续签"))
        #expect(message.contains("✗ Demo 失败，用了3秒"))
        #expect(message.contains("■ 完成 · 共用3秒 · 1失败"))
    }
}
