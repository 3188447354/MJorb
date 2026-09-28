import Foundation
import Security

/// 本 App 全部钥匙串条目所在的 service。迁移要按 service 逐个改可访问性。
enum SealKeychainServices {
    /// `KeychainVault`：账号密钥（Apple ID 口令、authToken、各证书的 P12）。
    static let accountVault = "com.mjorb.seal.account"
    /// `KeychainAnisetteProvisioningStore`：anisette 机器标识与 provisioning 状态。
    static let anisetteProvisioning = "com.mjorb.seal.anisette-v3"

    static var all: [String] { [accountVault, anisetteProvisioning] }
}

/// 钥匙串条目的可访问性等级 —— **必须能在锁屏下读到**。
///
/// 🔴 不能退回 `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`（本文件之前就是它）。
///
/// 「不打开 App 的续签」由快捷指令在**锁屏**状态下冷启动进程触发
/// （`RefreshAllAppsIntent` 的 `openAppWhenRun = false`），而那条链路**每次都现读钥匙串**，
/// 进程里没有任何内存缓存：
/// ① `SigningCoordinator.signAndInstall` 一进来就 `keychain.load(accountID:)` 取
///    `AccountSecret`（authToken / 口令 / 各证书 P12）—— **profile-only 续签也走这条**，
///    它只更新描述文件，照样要这份密钥；
/// ② 每次 Apple 请求都要 anisette（`AnisetteClient` 的 `loadIdentifier()` / `load()`）。
///
/// 锁屏时 `WhenUnlocked` 条目不可读 ⇒ 抛 `KeychainError` ⇒
/// `RenewalCoordinator.isRetryable` 不认它（不是通道瞬时错误、不是 `SEAL-NET-`、不是网络错误）
/// ⇒ 不重试 ⇒ `SEAL-RENEW-500` 直接判失败进抽屉。
/// 2026-09-28 真机日志里只剩一句 `Seal.KeychainError 1`（OSStatus 被 NSError 桥接丢掉，
/// 见 `KeychainError.describe`），看起来像「钥匙串里没有」，其实是设备锁定。
///
/// 保留 `ThisDeviceOnly`：口令与私钥**不随 iCloud 钥匙串同步**（AGENTS.md §4「禁止证书导入/导出」）。
/// 上游 SideStore/AltStore 用的是 `.afterFirstUnlock` **＋ `synchronizable(true)`** ——
/// 那是为了让它的 App 与 App Extension 共享账号；Seal 只跟「可访问性」这一半，
/// **不跟**同步那一半（对照台账见 `docs/upstream-alignment.md`）。
enum SealKeychainAccessibility {
    static let value: CFString = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
}

/// 单个 service 的迁移结果。
enum KeychainAccessibilityMigrationOutcome: Equatable {
    /// 已把可访问性改成目标值（`SecItemUpdate` 命中并成功）。
    case updated
    /// 这个 service 下没有匹配的条目（新装、或用户还没加账号）。
    case nothingToDo
    /// 设备锁着，系统拒绝改 `WhenUnlocked` 条目。**不是失败** ——
    /// 等下次解锁后启动 / 回到前台再迁一次即可。
    case deviceLocked
    case failed(OSStatus)
}

/// 一次迁移的汇总判定。抽成纯值类型是为了能单测 ——
/// 「什么时候算迁完了」这条规则很微妙，写错会让修复静默失效（见 `shouldMarkCompleted`）。
struct KeychainAccessibilityMigrationSummary: Equatable {
    let outcomes: [String: KeychainAccessibilityMigrationOutcome]

    init(outcomes: [String: KeychainAccessibilityMigrationOutcome]) {
        self.outcomes = outcomes
    }

    var didChangeAnything: Bool {
        outcomes.values.contains(.updated)
    }

    var isBlocked: Bool {
        outcomes.values.contains(.deviceLocked)
    }

    var hasFailure: Bool {
        outcomes.values.contains { outcome in
            if case .failed = outcome { return true }
            return false
        }
    }

    /// 只有「至少改过一项」且「没有锁定、没有失败」才算迁移完成。
    ///
    /// 🔴 为什么不拿 `.nothingToDo` 当完成：设备锁着时 `SecItemUpdate` 也可能返回
    /// `errSecItemNotFound`（条目在锁屏下不可见）而不是 `errSecInteractionNotAllowed`
    /// ⇒ 会被误判成「本来就没有条目」⇒ 一旦落标记就再也不重试，修复静默失效。
    /// 代价是「本来就没有条目」时每次启动多跑两次 `SecItemUpdate`（无日志、无副作用），可接受。
    var shouldMarkCompleted: Bool {
        didChangeAnything && !isBlocked && !hasFailure
    }
}

/// 把**升级前**写入的 `WhenUnlockedThisDeviceOnly` 条目改成 `SealKeychainAccessibility.value`。
///
/// 🔴 为什么必须迁移、不能只改写入常量：改常量只影响**新写入**的条目，而 profile-only 续签
/// 这条最常见的路径**根本不写钥匙串**（只读）⇒ 老设备上的条目会一直是旧值，
/// 「锁屏续签」就永远修不好。已加过账号的用户，钥匙串里躺的正是旧值。
///
/// 只改可访问性、不删不重建：口令与私钥的明文**不出内存**，也不丢数据。
/// 查询只按 `class + service`（不带 account），因此同一 service 下的**所有**条目一次改完
/// （一个 Apple ID 一条，多账号就是多条）。
enum KeychainAccessibilityMigrator {
    static func run(
        services: [String] = SealKeychainServices.all
    ) -> [String: KeychainAccessibilityMigrationOutcome] {
        var results: [String: KeychainAccessibilityMigrationOutcome] = [:]
        for service in services {
            results[service] = classify(migrate(service: service))
        }
        return results
    }

    /// OSStatus → 分类。纯函数，单测直接钉它（真机上的实际返回码取不到，只能靠这层归类兜住）。
    static func classify(_ status: OSStatus) -> KeychainAccessibilityMigrationOutcome {
        switch status {
        case errSecSuccess: return .updated
        case errSecItemNotFound: return .nothingToDo
        case errSecInteractionNotAllowed: return .deviceLocked
        default: return .failed(status)
        }
    }

    private static func migrate(service: String) -> OSStatus {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any
        ]
        let attributes: [String: Any] = [
            kSecAttrAccessible as String: SealKeychainAccessibility.value
        ]
        return SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    }
}

/// 迁移的一次性标记。
///
/// 🔴 为什么需要标记：`SecItemUpdate` 在属性已经是目标值时照样返回 `errSecSuccess`
/// ⇒ 不加标记的话每次启动 / 每次回前台都会再写一条「已就绪」日志，把 1000 条环形缓冲刷掉。
/// 标记与钥匙串条目同生命周期（卸载 App 两者一起没），所以不会出现「标记说迁完了、条目还是旧值」。
enum KeychainAccessibilityMigrationMarker {
    private static let key = "keychain.accessibility.migrated.v1"

    static var isCompleted: Bool {
        UserDefaults.standard.bool(forKey: key)
    }

    static func markCompleted() {
        UserDefaults.standard.set(true, forKey: key)
    }
}

/// 同步执行迁移并决定是否落「已完成」标记；返回本次摘要（已标记过则返回 `nil`）。
///
/// 🔴 **必须在任何钥匙串读取之前同步执行**：`SealApp.init()` 是进程最早执行点，
/// 快捷指令冷启动的续签在那之后才读钥匙串。做成同步（而非 `Task`）是为了保证
/// 「迁移先于续签跑完」的时序 —— 续签前的那道通道等待给了日志 Task 时间，但
/// **标记与迁移本体不能等**。
@MainActor
extension KeychainAccessibilityMigrator {
    static func runSynchronously() -> KeychainAccessibilityMigrationSummary? {
        guard !KeychainAccessibilityMigrationMarker.isCompleted else { return nil }
        let summary = KeychainAccessibilityMigrationSummary(outcomes: run())
        if summary.shouldMarkCompleted {
            KeychainAccessibilityMigrationMarker.markCompleted()
        }
        return summary
    }

    /// 把一次迁移摘要写进日志（`runSynchronously` 返回非 `nil` 时才调用）。
    static func log(summary: KeychainAccessibilityMigrationSummary, logStore: SealLogStore?) async {
        if summary.shouldMarkCompleted {
            try? await logStore?.append(
                category: .system,
                message: "钥匙串可访问性已迁移为「首次解锁后可读」，锁屏下的后台续签可正常读取账号密钥与 anisette",
                code: "SEAL-KEYCHAIN-001"
            )
        } else if summary.isBlocked {
            // 设备锁着时系统可能拒绝改 WhenUnlocked 条目；不是失败，等下次解锁后启动再迁。
            try? await logStore?.append(
                category: .system,
                level: .warning,
                message: "钥匙串可访问性迁移：设备仍锁定，本次未完成，解锁后打开 Seal 会自动补迁",
                code: "SEAL-KEYCHAIN-002"
            )
        } else if summary.hasFailure {
            try? await logStore?.append(
                category: .system,
                level: .warning,
                message: "钥匙串可访问性迁移失败：\(summary.outcomes.map { "\($0.key)=\($0.value)" }.joined(separator: "，"))，下次启动重试",
                code: "SEAL-KEYCHAIN-003"
            )
        }
    }
}