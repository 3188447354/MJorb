import Foundation
import Security
import Testing
@testable import Seal

/// 钉住「锁屏下后台续签」的必要条件：钥匙串条目必须**锁屏可读**，且升级前写入的旧条目
/// 会被迁移过去。
///
/// 真机上的实际 OSStatus 取不到（日志里一度只剩 `Seal.KeychainError 1`），所以归类与
/// 「什么时候算迁完」这两条判据必须落成纯函数在这里钉死。
struct KeychainAccessibilityTests {
    @Test
    func accessibilityIsReadableWhileLocked() {
        // 只有「首次解锁后可读」在锁屏时仍可读；`WhenUnlocked` 会让后台续签直接失败。
        #expect(
            SealKeychainAccessibility.value as String
                == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
        )
        #expect(
            SealKeychainAccessibility.value as String
                != kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String
        )
        #expect(
            SealKeychainAccessibility.value as String
                != kSecAttrAccessibleWhenUnlocked as String
        )
        // 保留 `ThisDeviceOnly`：口令与私钥不随 iCloud 钥匙串同步（AGENTS.md §4）。
        // ⚠️ 不能拿 `as String` 去 `contains("ThisDeviceOnly")` —— 这些常量的字符串值
        // 是 `cku` / `ck` 这类短码，不含长名。用「与不带 ThisDeviceOnly 的变体不相等」来钉。
        #expect(
            SealKeychainAccessibility.value as String
                != kSecAttrAccessibleAfterFirstUnlock as String
        )
    }

    @Test
    func servicesCoverBothKeychainStores() {
        #expect(SealKeychainServices.all == ["com.mjorb.seal.account", "com.mjorb.seal.anisette-v3"])
        // 迁移是按 service 逐个改的 —— 漏一个 service 就等于漏一个 store。
        #expect(SealKeychainServices.all.contains(SealKeychainServices.accountVault))
        #expect(SealKeychainServices.all.contains(SealKeychainServices.anisetteProvisioning))
    }

    @Test
    func classifiesStatusIntoOutcomes() {
        #expect(KeychainAccessibilityMigrator.classify(errSecSuccess) == .updated)
        #expect(KeychainAccessibilityMigrator.classify(errSecItemNotFound) == .nothingToDo)
        #expect(KeychainAccessibilityMigrator.classify(errSecInteractionNotAllowed) == .deviceLocked)
        #expect(KeychainAccessibilityMigrator.classify(errSecAuthFailed) == .failed(errSecAuthFailed))
    }

    @Test
    func marksCompletedOnlyWhenSomethingChangedWithoutBlockOrFailure() {
        // 全新安装 / 用户还没加账号：什么都没改 ⇒ 不落标记（下次启动再看一眼，无副作用）。
        #expect(
            KeychainAccessibilityMigrationSummary(outcomes: [:]).shouldMarkCompleted == false
        )
        // 🔴 关键一条：设备锁着时 `SecItemUpdate` 有可能返回 `errSecItemNotFound`
        // （条目在锁屏下不可见）⇒ 全 `.nothingToDo`。若把它当「迁完了」，
        // 修复就会静默失效（永远不再重试）。
        #expect(
            KeychainAccessibilityMigrationSummary(
                outcomes: [
                    SealKeychainServices.accountVault: .nothingToDo,
                    SealKeychainServices.anisetteProvisioning: .nothingToDo
                ]
            ).shouldMarkCompleted == false
        )
        // 至少改过一项、且没有锁定/失败 ⇒ 完成。
        #expect(
            KeychainAccessibilityMigrationSummary(
                outcomes: [
                    SealKeychainServices.accountVault: .updated,
                    SealKeychainServices.anisetteProvisioning: .nothingToDo
                ]
            ).shouldMarkCompleted
        )
        // 有一项被锁定 ⇒ 不完成，等下次解锁后补做。
        #expect(
            KeychainAccessibilityMigrationSummary(
                outcomes: [
                    SealKeychainServices.accountVault: .updated,
                    SealKeychainServices.anisetteProvisioning: .deviceLocked
                ]
            ).shouldMarkCompleted == false
        )
        // 有一项失败 ⇒ 不完成。
        #expect(
            KeychainAccessibilityMigrationSummary(
                outcomes: [
                    SealKeychainServices.accountVault: .updated,
                    SealKeychainServices.anisetteProvisioning: .failed(errSecAuthFailed)
                ]
            ).shouldMarkCompleted == false
        )
    }

    @Test
    func summaryReportsBlockedAndFailureSeparately() {
        let locked = KeychainAccessibilityMigrationSummary(
            outcomes: [SealKeychainServices.accountVault: .deviceLocked]
        )
        #expect(locked.isBlocked)
        #expect(locked.hasFailure == false)

        let failed = KeychainAccessibilityMigrationSummary(
            outcomes: [SealKeychainServices.accountVault: .failed(errSecAuthFailed)]
        )
        #expect(failed.isBlocked == false)
        #expect(failed.hasFailure)
    }

    @Test
    func keychainErrorExposesRealStatusInsteadOfAlwaysOne() {
        let error = KeychainError(status: errSecInteractionNotAllowed)
        let nsError = error as NSError
        // 🔴 之前这里是 domain=`Seal.KeychainError`、code 恒为 1、文案是系统默认 ——
        // 真机日志只剩一句 `Seal.KeychainError 1`，分不清「设备锁定」和「条目不存在」。
        #expect(nsError.domain == "Seal.KeychainError")
        #expect(nsError.code == Int(errSecInteractionNotAllowed))
        #expect(nsError.localizedDescription.contains("锁定"))

        let missing = KeychainError(status: errSecItemNotFound) as NSError
        #expect(missing.code == Int(errSecItemNotFound))
        #expect(missing.localizedDescription.contains("没有这一项"))
    }
}