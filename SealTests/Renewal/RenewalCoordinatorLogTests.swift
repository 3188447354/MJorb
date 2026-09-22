import Foundation
import Testing
@testable import Seal

/// 批量续签的逐项成功日志（`SEAL-RENEW-020`）。
///
/// **为什么这条日志值得单测**：它要回答的不是「成功了吗」，而是
/// 「这次续签到底给我换了一份**新的**描述文件吗，还是只是重签了旧的那份」。
/// 2026-09-17 真机反馈的困惑正是这个 —— 用户续签 LiveContainer 时界面停在
/// 「安装中」，取消后看到 App 像是重装了，却无法确认描述文件有没有换成新申请的；
/// 而当时的日志里**一个字都没有**（「续签并安装成功」只在单签路径里写，
/// 批量走的是 `RenewalCoordinator` → `SigningCoordinator.signAndInstall`）。
///
/// **为什么必须抽成纯函数再测**：源码断言只能证明「日志里有描述文件字段」，
/// 证明不了它真的把 UUID 与时间**写出来了**（可能被脱敏吃掉、字段可能是 nil、
/// 格式化可能失败）。而这条日志的失败方向是「用户把日志发给我，我还是看不出结论」，
/// 不崩、不编译失败、单测也不会红 —— 只能靠这里钉住。
@Suite("批量续签的逐项成功日志：描述文件身份的自证串")
struct RenewalCoordinatorLogTests {
    private func makeRecord(
        profileUUID: String?,
        created: Date? = nil,
        expires: Date? = nil
    ) -> AppRecord {
        AppRecord(
            originalBundleIdentifier: "com.example.original",
            name: "批量日志测试",
            version: "1.0",
            buildNumber: "1",
            size: 1,
            state: .installed,
            provisioningProfileUUID: profileUUID,
            provisioningProfileCreationDate: created,
            provisioningProfileExpirationDate: expires,
            ipaRelativePath: "Apps/Test/Original.ipa",
            importedAt: Date()
        )
    }

    /// 正例：UUID 与两个时间都要出现在同一行里。
    ///
    /// 断言「三个字段都在」而不是逐字比对整串 —— 后者会让任何文案微调都变成测试失败，
    /// 反而促使别人把测试改宽（甚至改空），失去守护作用。
    @Test
    func profileIdentityIncludesUUIDAndBothDates() {
        // 取自 2026-09-17 真机日志那一刻：北京时间 13:28:58 ⇒ UTC 05:28:58。
        // 用真实时刻而不是随手编的数字，是为了让「创建时间 ≈ 续签时刻」这条自证逻辑
        // 在测试里也一眼可见。
        let created = Date(timeIntervalSince1970: 1_789_622_938)
        let expires = Date(timeIntervalSince1970: 1_790_227_738)
        let text = RenewalCoordinator.describeProfile(
            makeRecord(
                profileUUID: "11111111-2222-3333-4444-555555555555",
                created: created,
                expires: expires
            )
        )
        #expect(text.contains("11111111-2222-3333-4444-555555555555"))
        #expect(text.contains("2026-09-17"))   // 创建时间
        #expect(text.contains("2026-09-24"))   // 到期时间
    }

    /// UUID 缺失时不能写成空串 —— 空串会让日志看起来「这一项没有描述文件」，
    /// 而实际情况是记录里没存下来。两者后续动作不同。
    @Test
    func missingUUIDIsSpelledOut() {
        let text = RenewalCoordinator.describeProfile(makeRecord(profileUUID: nil))
        #expect(text.contains("未知"))
    }

    /// 时间缺失时同样要显式写「未知」，不能整段消失 ——
    /// 否则「日志里有 UUID 但没有时间」会被读成「描述文件没有创建时间」这种不存在的状态。
    @Test
    func missingDatesAreSpelledOutRatherThanOmitted() {
        let text = RenewalCoordinator.describeProfile(
            makeRecord(profileUUID: "11111111-2222-3333-4444-555555555555")
        )
        #expect(text.contains("11111111-2222-3333-4444-555555555555"))
        #expect(text.contains("未知"))
        #expect(text.contains("创建"))
        #expect(text.contains("到期"))
    }

    /// 时间必须是 ISO8601 北京时间（能和 Apple 门户返回的时间直接对照），
    /// 不是本地化格式 —— 导出日志的人可能不在中文环境里读它。
    @Test
    func datesAreBeijingISO8601NotLocalized() {
        let created = Date(timeIntervalSince1970: 1_789_622_938)
        let text = RenewalCoordinator.describeProfile(
            makeRecord(profileUUID: "UUID", created: created)
        )
        // 断言**完整**形态而不是 `contains("T")`：
        // 单字符字面量会同时匹配 `String.contains(_: Character)` 与
        // `StringProtocol.contains(_: String)`，让 `#expect` 的宏展开变得难以预料
        // （见 2026-09-16 那次 `contains(where:)` 的教训）。完整串既无歧义又更强。
        #expect(text.contains("2026-09-17T13:28:58+08:00"))
    }
}
