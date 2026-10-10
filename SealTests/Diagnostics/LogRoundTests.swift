import Testing
@testable import Seal

struct LogRoundTests {
    @Test
    func failedItemRetainsItsSourceErrorCode() throws {
        let rounds = LogRound.parse(from: """
        2026-10-10 10:00:00 信息 Seal ━━━━━━━
        ▶ 第1轮 · 10:00:00 · 手动 · 1个App
        2026-10-10 10:00:03 错误 Seal [SEAL-INSTALL-702s] ✗ Example 安装失败
        原因：设备空间不足
        ■ 共用3秒 · 0/1 成功
        ━━━━━━━
        """)

        let item = try #require(rounds.first?.items.first)
        #expect(item.succeeded == false)
        #expect(item.code == "SEAL-INSTALL-702s")
    }
}
