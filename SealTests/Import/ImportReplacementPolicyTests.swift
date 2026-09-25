import Foundation
import Testing
@testable import Seal

/// 覆盖更新判据（`ImportReplacementPolicy`）的单测。
///
/// 背景（2026-09-25 用户反馈）：导入一个**已安装应用的新版本 IPA**（同 Bundle ID）原先会
/// 新建一条待签名记录落到「待签名」页 —— 根因是 `ImportWorkflow.commit` 里 `existing`
/// 被硬编码成 `nil`。判据抽成纯函数就是为了把三条边界钉死：
/// ① 只认**已安装**记录（待签名记录绝不能当覆盖目标，否则会毁掉「多副本」路径）；
/// ② 只认 `originalBundleIdentifier`（mapped/preferred 是**签名后**的身份，
///    拿它们匹配会把「同原始包、不同签名身份」的副本一并吞掉）；
/// ③ 提交前必须按 id 复核（记录可能在确认页停留期间被删、或不再是已安装状态）。
struct ImportReplacementPolicyTests {
    @Test
    func findsInstalledRecordForSameOriginalBundleIdentifier() {
        let installed = makeRecord(original: "com.example.demo", isInstalled: true)
        let candidate = ImportReplacementPolicy.installedReplacementCandidate(
            for: makeParsed(bundleIdentifier: "com.example.demo"),
            in: [installed]
        )
        #expect(candidate?.id == installed.id)
    }

    @Test
    func ignoresPendingRecordsSoMultiCopyImportStillWorks() {
        let pending = makeRecord(original: "com.example.demo", isInstalled: false)
        let candidate = ImportReplacementPolicy.installedReplacementCandidate(
            for: makeParsed(bundleIdentifier: "com.example.demo"),
            in: [pending]
        )
        #expect(candidate == nil)
    }

    @Test
    func ignoresSealRecordSoSelfUpdatePathIsNotHijacked() {
        let seal = makeRecord(original: "com.example.demo", isInstalled: true, isSeal: true)
        let candidate = ImportReplacementPolicy.installedReplacementCandidate(
            for: makeParsed(bundleIdentifier: "com.example.demo"),
            in: [seal]
        )
        #expect(candidate == nil)
    }

    @Test
    func matchesOriginalIdentifierNotSignedIdentity() {
        // 记录签名后被映射成别的 Bundle ID：即使导入包的原始 ID 与它的 mapped 相同也不该命中 ——
        // 覆盖更新比的是「导入包的原始身份」，不是「签名后的身份」。
        let other = makeRecord(
            original: "com.example.other",
            mapped: "com.example.demo",
            isInstalled: true
        )
        let candidate = ImportReplacementPolicy.installedReplacementCandidate(
            for: makeParsed(bundleIdentifier: "com.example.demo"),
            in: [other]
        )
        #expect(candidate == nil)
    }

    @Test
    func picksMostRecentlyInstalledAmongDuplicates() {
        let older = makeRecord(
            original: "com.example.demo",
            isInstalled: true,
            installedAt: Date(timeIntervalSince1970: 100)
        )
        let newer = makeRecord(
            original: "com.example.demo",
            isInstalled: true,
            installedAt: Date(timeIntervalSince1970: 900)
        )
        let candidate = ImportReplacementPolicy.installedReplacementCandidate(
            for: makeParsed(bundleIdentifier: "com.example.demo"),
            in: [older, newer]
        )
        #expect(candidate?.id == newer.id)
    }

    @Test
    func bundleIdentifierComparisonIgnoresCaseAndWhitespace() {
        let installed = makeRecord(original: "Com.Example.Demo", isInstalled: true)
        let candidate = ImportReplacementPolicy.installedReplacementCandidate(
            for: makeParsed(bundleIdentifier: "  com.example.demo "),
            in: [installed]
        )
        #expect(candidate?.id == installed.id)
    }

    @Test
    func blankImportedBundleIdentifierNeverMatches() {
        let installed = makeRecord(original: "   ", isInstalled: true)
        let candidate = ImportReplacementPolicy.installedReplacementCandidate(
            for: makeParsed(bundleIdentifier: "  "),
            in: [installed]
        )
        #expect(candidate == nil)
    }

    @Test
    func confirmedReplacementRequiresTheSameRecordIdentifier() {
        let installed = makeRecord(original: "com.example.demo", isInstalled: true)
        let parsed = makeParsed(bundleIdentifier: "com.example.demo")

        #expect(ImportReplacementPolicy.confirmedReplacement(
            appID: installed.id,
            for: parsed,
            in: [installed]
        )?.id == installed.id)
        // 记录在确认页停留期间被删 / 换了 id ⇒ 复核不过，绝不替换别的记录
        #expect(ImportReplacementPolicy.confirmedReplacement(
            appID: UUID(),
            for: parsed,
            in: [installed]
        ) == nil)
        #expect(ImportReplacementPolicy.confirmedReplacement(
            appID: installed.id,
            for: parsed,
            in: []
        ) == nil)
    }

    @Test
    func confirmedReplacementRejectsTargetThatIsNoLongerInstalled() {
        let record = makeRecord(original: "com.example.demo", isInstalled: false)
        let candidate = ImportReplacementPolicy.confirmedReplacement(
            appID: record.id,
            for: makeParsed(bundleIdentifier: "com.example.demo"),
            in: [record]
        )
        #expect(candidate == nil)
    }

    // MARK: - Helpers

    private func makeParsed(bundleIdentifier: String) -> ParsedIPA {
        ParsedIPA(
            name: "Demo",
            bundleIdentifier: bundleIdentifier,
            version: "2.0",
            buildNumber: "9",
            fileSize: 10,
            iconData: nil,
            extensions: [],
            entitlementKeys: [],
            importWarnings: []
        )
    }

    private func makeRecord(
        original: String,
        mapped: String? = nil,
        isInstalled: Bool,
        isSeal: Bool = false,
        installedAt: Date = Date(timeIntervalSince1970: 500)
    ) -> AppRecord {
        AppRecord(
            originalBundleIdentifier: original,
            mappedBundleIdentifier: mapped,
            name: "Demo",
            version: "1.0",
            buildNumber: "1",
            size: 10,
            state: isInstalled ? .installed : .preflightPassed,
            accountID: isInstalled ? UUID() : nil,
            lastInstalledAt: isInstalled ? installedAt : nil,
            ipaRelativePath: "Apps/\(UUID().uuidString)/Original.ipa",
            isSeal: isSeal,
            importedAt: Date(timeIntervalSince1970: 100)
        )
    }
}
