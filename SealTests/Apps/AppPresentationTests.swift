import Foundation
import Testing
@testable import Seal

struct AppPresentationTests {
    private let now = Date(timeIntervalSince1970: 1_752_000_000)

    @Test
    func pendingAppsUseSigningPresentation() {
        let app = makeApp(state: .preflightPassed, expiryDate: nil)

        #expect(AppOperationPresentation(app: app, now: now).kind == .signing)
        #expect(AppOperationPresentation(app: app, now: now).sheetTitle == "签名并安装")
        #expect(AppOperationPresentation(app: app, now: now).primaryAction == "签名并安装")
    }

    @Test
    func installedAppsUseNeutralRemainingDayPresentation() {
        let app = makeApp(
            state: .installed,
            expiryDate: now.addingTimeInterval(6 * 86_400 + 3_600)
        )
        let presentation = AppOperationPresentation(app: app, now: now)

        #expect(presentation.kind == .renewal)
        #expect(presentation.validity?.text == "6天")
        #expect(presentation.validity?.tone == .neutral)
    }

    @Test
    func oneDayRemainingIsUrgentAndOrange() {
        let app = makeApp(
            state: .installed,
            expiryDate: now.addingTimeInterval(30 * 3_600)
        )
        let presentation = AppOperationPresentation(app: app, now: now)

        #expect(presentation.kind == .urgentRenewal)
        #expect(presentation.validity?.text == "1天")
        #expect(presentation.validity?.tone == .warning)
        #expect(presentation.primaryAction == "续签")
    }

    @Test
    func lessThanOneDayUsesHoursWithoutPrefix() {
        let app = makeApp(
            state: .installed,
            expiryDate: now.addingTimeInterval(23 * 3_600 + 900)
        )
        let presentation = AppOperationPresentation(app: app, now: now)

        #expect(presentation.validity?.text == "23小时")
        #expect(presentation.validity?.detailText == "23小时")
        #expect(presentation.validity?.tone == .danger)
    }

    @Test
    func expiredAppsRequireReinstallation() {
        let app = makeApp(
            state: .installed,
            expiryDate: now.addingTimeInterval(-60)
        )
        let presentation = AppOperationPresentation(app: app, now: now)

        #expect(presentation.kind == .expiredRenewal)
        #expect(presentation.validity?.text == "已过期")
        #expect(presentation.validity?.tone == .danger)
        #expect(presentation.primaryAction == "续签")
    }

    @Test
    func previouslyInstalledAppsDuringRenewalUseRenewalPresentation() {
        var app = makeApp(
            state: .signing,
            expiryDate: now.addingTimeInterval(5 * 86_400)
        )
        app.lastInstalledAt = now.addingTimeInterval(-86_400)

        let presentation = AppOperationPresentation(app: app, now: now)

        #expect(presentation.kind == .renewal)
    }

    @Test
    func profileOnlyRenewalUsesDeviceProfileCopyForStagesAndSuccess() {
        #expect(
            RenewalExecutionPath.profileOnly.stageTitle(for: .preparingBundle)
                == "正在核对应用身份"
        )
        #expect(
            RenewalExecutionPath.profileOnly.stageTitle(for: .preparingCertificate)
                == "正在核验当前证书"
        )
        #expect(
            RenewalExecutionPath.profileOnly.stageTitle(for: .preparingAppID)
                == "正在核对 App ID"
        )
        #expect(RenewalExecutionPath.profileOnly.successTitle == "描述文件续签完成")
    }

    @Test
    func fullResignRenewalRetainsInstallSuccessCopy() {
        #expect(RenewalExecutionPath.fullResign.successTitle == "续签并安装成功")
    }

    @Test
    func importTimeUsesTodayAndYesterdayLabels() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let reference = calendar.date(
            from: DateComponents(year: 2026, month: 7, day: 18, hour: 12)
        )!
        let today = calendar.date(
            from: DateComponents(year: 2026, month: 7, day: 18, hour: 10, minute: 28)
        )!
        let yesterday = calendar.date(
            from: DateComponents(year: 2026, month: 7, day: 17, hour: 18, minute: 42)
        )!

        #expect(AppImportTimeFormatter.string(from: today, now: reference, calendar: calendar) == "今天 10:28")
        #expect(AppImportTimeFormatter.string(from: yesterday, now: reference, calendar: calendar) == "昨天 18:42")
    }

    // MARK: - 「证书序列号」行下面那句说明（2026-09-26 构建 48 真机）

    /// 用户 2026-09-26 要求：本机没有该证书私钥时，在「证书序列号」那里写一句
    /// 「需要重新签名一次获取本机证书」。
    ///
    /// 这里钉住**「什么时候说话」**这条规则（纯函数，能测）；「文案出现在哪个界面」
    /// 由守卫按源码文本钉 —— 三个界面（进度卡片 / 详情页 / 操作抽屉）共用同一份真源。
    @Test
    func localCertificateNoteOnlySpeaksWhenTheDeviceIsReallyMissingTheKey() {
        // 缺私钥 ⇒ 说完整版（说清「这一次会重签」＋「之后不会」）。
        #expect(
            AppSigningPresentationHelpers.localCertificateNote(for: .needsFullResign)
                == AppSigningPresentationHelpers.localCertificateRebuildDetail
        )
        #expect(
            AppSigningPresentationHelpers.localCertificateCompactNote(for: .needsFullResign)
                == AppSigningPresentationHelpers.localCertificateRebuildNote
        )
        // 正常状态（本机有可复用私钥）与**读不到账号密钥**都不说话 ——
        // 后者尤其重要：把「读不到」说成「你没有证书」，会把用户送去重签一次
        // 本来不需要重签的续签。
        #expect(AppSigningPresentationHelpers.localCertificateNote(for: .ready) == nil)
        #expect(AppSigningPresentationHelpers.localCertificateNote(for: .undetermined) == nil)
        #expect(AppSigningPresentationHelpers.localCertificateCompactNote(for: .ready) == nil)
        #expect(AppSigningPresentationHelpers.localCertificateCompactNote(for: .undetermined) == nil)
        // 文案必须同时说清「这一次要重签」与「之后不再重装」——
        // 缺后半句，用户会以为「每次续签都要重装」，而那正是这套快路径要消除的误解。
        #expect(
            AppSigningPresentationHelpers.localCertificateRebuildDetail.contains("只更新描述文件")
        )
    }

    // MARK: - 「已导入的新版本还没装上」说明（R89，2026-09-26 用户实测）

    /// 用户 2026-09-26 实测：把 1.3.20 的 IPA 导入 1.3.19 的 Seal 里 ⇒ 列表与详情页显示
    /// **1.3.20**，而「关于」里仍是 **1.3.19**（「是不是续签的还是 1.3.19、显示的是 1.3.20」）。
    /// 这句话要说的正是这个错位：列表上的版本号是**待安装的源包**，要续签一次才会真正生效。
    ///
    /// 这里钉住**「什么时候说话」**；「出现在哪个界面」由守卫按源码文本钉
    /// （详情页与操作抽屉共用同一份真源）。
    @Test
    func pendingUpdateNoteOnlySpeaksWhenTheRecordDescribesSomethingNotInstalledYet() {
        // 记录里写的是**新导入的源包**版本，而正在运行的仍是旧版。
        let importedNewer = makeApp(
            state: .installed,
            expiryDate: now.addingTimeInterval(6 * 86_400),
            version: "1.3.20",
            isSeal: true
        )

        #expect(
            AppSigningPresentationHelpers.pendingUpdateNote(
                for: importedNewer,
                runningVersion: "1.3.19"
            ) == AppSigningPresentationHelpers.pendingUpdateDetail
        )
        // 文案必须同时说清「这一次会重装」与「之后不再重装」——
        // 缺后半句，用户会以为「每次续签都要重装」，而那正是这套快路径要消除的误解。
        #expect(
            AppSigningPresentationHelpers.pendingUpdateDetail.contains("完整重签并安装")
                && AppSigningPresentationHelpers.pendingUpdateDetail.contains("只更新描述文件")
        )

        // 版本一致（更新已经装上）⇒ 不说话，否则每次续签都会看到一句假警报。
        let alreadyInstalled = makeApp(
            state: .installed,
            expiryDate: now.addingTimeInterval(6 * 86_400),
            version: "1.3.19",
            isSeal: true
        )
        #expect(
            AppSigningPresentationHelpers.pendingUpdateNote(
                for: alreadyInstalled,
                runningVersion: "1.3.19"
            ) == nil
        )

        // 第三方应用不说话：只有 Seal 自己的运行包能被 `Bundle.main` 读到，
        // 拿 Seal 的版本去比第三方应用的记录版本必然误报。
        let thirdParty = makeApp(
            state: .installed,
            expiryDate: now.addingTimeInterval(6 * 86_400),
            version: "1.3.20"
        )
        #expect(
            AppSigningPresentationHelpers.pendingUpdateNote(
                for: thirdParty,
                runningVersion: "1.3.19"
            ) == nil
        )

        // 运行版本读不到 ⇒ 不说话（不能凭空告诉用户「有更新待安装」）。
        #expect(
            AppSigningPresentationHelpers.pendingUpdateNote(
                for: importedNewer,
                runningVersion: nil
            ) == nil
        )
    }

    private func makeApp(
        state: AppState,
        expiryDate: Date?,
        version: String = "1.0.0",
        isSeal: Bool = false
    ) -> AppRecord {
        AppRecord(
            originalBundleIdentifier: "com.seal.example",
            name: "示例应用",
            version: version,
            buildNumber: "1",
            size: 82_400_000,
            state: state,
            expiryDate: expiryDate,
            ipaRelativePath: "Apps/Example.ipa",
            isSeal: isSeal,
            importedAt: now
        )
    }
}
