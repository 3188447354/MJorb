import Foundation
import Testing
@testable import Seal

/// 设备端扫回判据（`InstalledRecordRecoveryPolicy`）的单测。
///
/// 背景（2026-09-25 用户反馈）：「只卸载了 Seal，其他 Seal 签名的 App 没卸载，
/// 重装 Seal 后它们进不了已安装列表」。记录（`Seal.sqlite`）随 Seal 一起没了，
/// 唯一痕迹是设备端的描述文件。
///
/// 这条链路会**写记录**，而它的错法**不崩、不编译失败，只在真机上多造或少造记录** ——
/// 多造 = 列表里出现点开就报错的僵尸；少造 = 用户的应用永远回不来。
/// 所以每一条边界都必须在这里钉死。
struct InstalledRecordRecoveryPolicyTests {
    // MARK: - 形态判据

    @Test
    func recognisesSealGeneratedShapeOnlyInTheMiddle() {
        // `<原始>.seal.<team>` —— 正常形态。
        #expect(InstalledRecordRecoveryPolicy.isSealGeneratedBundleIdentifier(
            "com.example.demo.seal.ABCDE12345"
        ))
        // 大小写不敏感（Bundle ID 本身大小写不敏感）。
        #expect(InstalledRecordRecoveryPolicy.isSealGeneratedBundleIdentifier(
            "com.example.demo.SEAL.abcde12345"
        ))
        // `.seal.` 必须在**中间**：前后都要有内容。
        #expect(InstalledRecordRecoveryPolicy.isSealGeneratedBundleIdentifier(".seal.ABCDE") == false)
        #expect(InstalledRecordRecoveryPolicy.isSealGeneratedBundleIdentifier("com.demo.seal.") == false)
        // 别的工具的形态（`<原始>.<teamID>`）不得命中。
        #expect(InstalledRecordRecoveryPolicy.isSealGeneratedBundleIdentifier(
            "com.example.demo.ABCDE12345"
        ) == false)
        #expect(InstalledRecordRecoveryPolicy.isSealGeneratedBundleIdentifier("") == false)
    }

    // MARK: - 反推原始 Bundle ID

    @Test
    func stripsSealTeamSuffix() {
        #expect(InstalledRecordRecoveryPolicy.originalBundleIdentifier(
            fromMapped: "com.example.demo.seal.ABCDE12345",
            teamIdentifier: "ABCDE12345"
        ) == "com.example.demo")
        // Team 大小写不同也要能剥掉。
        #expect(InstalledRecordRecoveryPolicy.originalBundleIdentifier(
            fromMapped: "com.example.demo.seal.abcde12345",
            teamIdentifier: "ABCDE12345"
        ) == "com.example.demo")
    }

    /// 🔴 这条是「取第一次还是取最后一次 `.seal.`」的判别点。
    ///
    /// 原始 Bundle ID **本身可能含 `.seal.`**（例如 `com.mjorb.seal.apps`）。
    /// 拿不到 Team 时若取**第一次** `.seal.`，会把原始 ID 截断成 `com.mjorb`
    /// —— 那是一条**不存在**的 Bundle ID，用户点续签会得到 `SEAL-BUNDLE-002`。
    @Test
    func fallsBackToTheLastSealMarkerSoOriginalsContainingSealSurvive() {
        #expect(InstalledRecordRecoveryPolicy.originalBundleIdentifier(
            fromMapped: "com.mjorb.seal.apps.seal.ABCDE12345",
            teamIdentifier: nil
        ) == "com.mjorb.seal.apps")
    }

    @Test
    func returnsNilWhenNothingCanBeStripped() {
        #expect(InstalledRecordRecoveryPolicy.originalBundleIdentifier(
            fromMapped: "com.example.demo",
            teamIdentifier: "ABCDE12345"
        ) == nil)
        // `.seal.` 在开头 ⇒ 剥完是空串 ⇒ 身份不完整，宁可不建。
        #expect(InstalledRecordRecoveryPolicy.originalBundleIdentifier(
            fromMapped: ".seal.ABCDE12345",
            teamIdentifier: "ABCDE12345"
        ) == nil)
        #expect(InstalledRecordRecoveryPolicy.originalBundleIdentifier(
            fromMapped: "   ",
            teamIdentifier: "ABCDE12345"
        ) == nil)
    }

    // MARK: - 候选筛选

    @Test
    func buildsDraftForUnknownSealSignedProfileOfTrustedTeam() {
        let context = makeContext(teams: ["ABCDE12345"])
        let drafts = InstalledRecordRecoveryPolicy.drafts(
            profiles: [makeProfile(bundleID: "com.example.demo.seal.ABCDE12345", team: "ABCDE12345")],
            context: context
        )
        #expect(drafts.count == 1)
        #expect(drafts.first?.bundleIdentifier == "com.example.demo.seal.ABCDE12345")
        #expect(drafts.first?.originalBundleIdentifier == "com.example.demo")
        #expect(drafts.first?.teamIdentifier == "ABCDE12345")
        #expect(drafts.first?.displayName == "com.example.demo")
    }

    @Test
    func skipsBundleIdentifierAlreadyCoveredByARecord() {
        let context = makeContext(
            known: ["com.example.demo.seal.ABCDE12345"],
            teams: ["ABCDE12345"]
        )
        let drafts = InstalledRecordRecoveryPolicy.drafts(
            profiles: [makeProfile(bundleID: "com.example.demo.seal.ABCDE12345", team: "ABCDE12345")],
            context: context
        )
        #expect(drafts.isEmpty)
    }

    /// 用户主动从已安装列表移除过的，扫回**必须尊重那次删除** ——
    /// 否则「删一次、下次启动又回来一次」，永远删不掉。
    @Test
    func respectsDismissedTombstones() {
        let context = makeContext(
            dismissed: ["com.example.demo.seal.ABCDE12345"],
            teams: ["ABCDE12345"]
        )
        let drafts = InstalledRecordRecoveryPolicy.drafts(
            profiles: [makeProfile(bundleID: "com.example.demo.seal.ABCDE12345", team: "ABCDE12345")],
            context: context
        )
        #expect(drafts.isEmpty)
    }

    /// Seal 自己由 `SelfAppRegistrar` 专门管理；扫回再造一条只会得到
    /// 「两条都叫 Seal」的重复记录。
    @Test
    func neverRecoversSealItself() {
        let context = makeContext(teams: ["ABCDE12345"])
        let drafts = InstalledRecordRecoveryPolicy.drafts(
            profiles: [
                makeProfile(bundleID: "com.mjorb.seal", team: "ABCDE12345"),
                makeProfile(bundleID: "com.mjorb.seal.seal.ABCDE12345", team: "ABCDE12345"),
            ],
            context: context
        )
        #expect(drafts.isEmpty)
    }

    /// 设备端 dump 出来的是**全部**描述文件（含别的工具、旧账号留下的）。
    /// Team 是唯一能证明「这份 profile 属于当前这批账号/记录」的证据。
    @Test
    func rejectsProfilesFromUntrustedTeam() {
        let context = makeContext(teams: ["ABCDE12345"])
        let drafts = InstalledRecordRecoveryPolicy.drafts(
            profiles: [makeProfile(bundleID: "com.example.demo.seal.OTHERTEAM", team: "OTHERTEAM")],
            context: context
        )
        #expect(drafts.isEmpty)
        // 没有 Team 的描述文件同样不可信。
        let noTeam = InstalledRecordRecoveryPolicy.drafts(
            profiles: [makeProfile(bundleID: "com.example.demo.seal.ABCDE12345", team: nil)],
            context: context
        )
        #expect(noTeam.isEmpty)
    }

    /// 扩展不是独立安装的 App（`isAppInstalled` 对扩展恒为 false），
    /// 单独建记录只会得到一条点开就报错的僵尸记录。
    @Test
    func doesNotRecoverExtensionsAsStandaloneApps() {
        let context = makeContext(teams: ["ABCDE12345"])
        let drafts = InstalledRecordRecoveryPolicy.drafts(
            profiles: [
                makeProfile(bundleID: "com.example.demo.seal.ABCDE12345", team: "ABCDE12345"),
                makeProfile(bundleID: "com.example.demo.share.seal.ABCDE12345", team: "ABCDE12345"),
            ],
            context: context
        )
        #expect(drafts.map(\.bundleIdentifier) == ["com.example.demo.seal.ABCDE12345"])
    }

    /// LockDown 路径同一份 profile 会落 raw + plist 两份 ⇒ 必须按 Bundle ID 去重。
    @Test
    func deduplicatesDuplicateProfileDumps() {
        let context = makeContext(teams: ["ABCDE12345"])
        let drafts = InstalledRecordRecoveryPolicy.drafts(
            profiles: [
                makeProfile(bundleID: "com.example.demo.seal.ABCDE12345", team: "ABCDE12345"),
                makeProfile(bundleID: "com.example.demo.seal.ABCDE12345", team: "ABCDE12345"),
            ],
            context: context
        )
        #expect(drafts.count == 1)
    }

    @Test
    func sortsDraftsSoTheProbeOrderIsReproducible() {
        let context = makeContext(teams: ["ABCDE12345"])
        let drafts = InstalledRecordRecoveryPolicy.drafts(
            profiles: [
                makeProfile(bundleID: "com.zeta.app.seal.ABCDE12345", team: "ABCDE12345"),
                makeProfile(bundleID: "com.alpha.app.seal.ABCDE12345", team: "ABCDE12345"),
            ],
            context: context
        )
        #expect(drafts.map(\.bundleIdentifier) == [
            "com.alpha.app.seal.ABCDE12345",
            "com.zeta.app.seal.ABCDE12345",
        ])
    }

    // MARK: - 折成记录：身份必须诚实

    @Test
    func skipsRecordWhenTheAppIsNotActuallyInstalled() {
        let draft = makeDraft()
        #expect(InstalledRecordRecoveryPolicy.makeRecord(
            from: draft,
            installedOnDevice: false,
            accountID: nil
        ) == nil)
    }

    /// 🔴 这条是整条链路里最容易「好心办坏事」的地方：扫回的记录**从来没有过本地 IPA**，
    /// 所以不能带任何「已签名产物」的痕迹 —— 否则下游会拿一个不存在的文件去签名/安装。
    @Test
    func recoveredRecordCarriesNoSignedArtifactTraces() {
        let draft = makeDraft()
        let record = InstalledRecordRecoveryPolicy.makeRecord(
            from: draft,
            installedOnDevice: true,
            accountID: nil
        )
        #expect(record != nil)
        guard let record else { return }
        #expect(record.signedIPARelativePath == nil)
        #expect(record.signedIPASHA256 == nil)
        #expect(record.signedArtifactStatus == nil)
        #expect(record.hasSignedArtifact == false)
        #expect(record.signingTargets.isEmpty)
        #expect(record.extensions.isEmpty)
    }

    /// 🔴 证书序列号必须留空。
    ///
    /// 描述文件里的 `DeveloperCertificates` 是**授权列表**，不是**实际签名者**。
    /// 一旦填上，两处破坏性链路会立刻选中这条记录：
    /// ① 证书轮换的「自动重签受影响应用」（它没有本地 IPA ⇒ 必然抛 `SEAL-RECOVER-002`）；
    /// ② 撤销证书的确认弹窗会承诺「这 N 个应用会被自动重新签名安装」，而其中有一个
    ///    永远不会成功 —— 那就是弹窗骗人。
    @Test
    func recoveredRecordNeverClaimsACertificateSerialNumber() {
        let draft = makeDraft()
        let record = InstalledRecordRecoveryPolicy.makeRecord(
            from: draft,
            installedOnDevice: true,
            accountID: nil
        )
        #expect(record?.certificateSerialNumber == nil)
    }

    @Test
    func recoveredRecordLandsInInstalledListWithTheDeviceIdentity() {
        let draft = makeDraft()
        let accountID = UUID()
        let record = InstalledRecordRecoveryPolicy.makeRecord(
            from: draft,
            installedOnDevice: true,
            accountID: accountID
        )
        #expect(record != nil)
        guard let record else { return }
        #expect(record.state == .installed)
        #expect(record.belongsInInstalledList)
        #expect(record.isSeal == false)
        // 设备上**实际**的 Bundle ID 必须填：缺了它点续签会抛 `SEAL-BUNDLE-002`。
        #expect(record.mappedBundleIdentifier == draft.bundleIdentifier)
        #expect(record.originalBundleIdentifier == draft.originalBundleIdentifier)
        #expect(record.preferredBundleIdentifier == draft.bundleIdentifier)
        #expect(record.signingTeamID == draft.teamIdentifier)
        #expect(record.accountID == accountID)
        #expect(record.provisioningProfileUUID == draft.profileUUID)
        #expect(record.expiryDate == draft.profileExpirationDate)
        // 我们只知道它现在装着，不知道什么时候装的。
        #expect(record.lastInstalledAt == nil)
        #expect(record.signedDeviceIdentifier == nil)
        #expect(record.importWarnings == [InstalledRecordRecoveryPolicy.recoveryWarning])
    }

    /// 占位路径必须落在**这次**的 id 目录下，而且**绝不能**指向任何真实文件。
    @Test
    func placeholderIPAPathIsScopedToTheRecordIDAndDoesNotExist() {
        let id = UUID()
        let record = InstalledRecordRecoveryPolicy.makeRecord(
            from: makeDraft(),
            installedOnDevice: true,
            accountID: nil,
            id: id
        )
        #expect(record?.ipaRelativePath == "Apps/\(id.uuidString)/Original.ipa")
        #expect(record?.ipaRelativePath.isEmpty == false)
    }

    // MARK: - 上下文构造

    @Test
    func contextCollectsKnownBundleIdentifiersIncludingExtensions() {
        let record = AppRecord(
            originalBundleIdentifier: "com.example.demo",
            mappedBundleIdentifier: "com.example.demo.seal.ABCDE12345",
            name: "示例",
            version: "1.0",
            buildNumber: "1",
            size: 1,
            state: .installed,
            signingTeamID: "abcde12345",
            ipaRelativePath: "Apps/Test/Original.ipa",
            importedAt: Date(),
            extensions: [
                AppExtensionRecord(
                    name: "Share",
                    originalBundleIdentifier: "com.example.demo.share",
                    mappedBundleIdentifier: "com.example.demo.share.seal.ABCDE12345"
                ),
            ]
        )
        let context = InstalledRecordRecoveryPolicy.context(
            records: [record],
            accountTeamIdentifiers: ["FGHIJ67890"],
            dismissedBundleIdentifiers: [],
            sealCanonicalBundleIdentifier: "com.mjorb.seal"
        )
        // 主 App 与扩展都算「已覆盖」。
        #expect(context.knownBundleIdentifiers.contains("com.example.demo.seal.abcde12345"))
        #expect(context.knownBundleIdentifiers.contains("com.example.demo.share.seal.abcde12345"))
        // Team 统一大写：记录的 Team 与账号的 Team 要能对上。
        #expect(context.knownTeamIdentifiers == ["ABCDE12345", "FGHIJ67890"])
        #expect(context.sealCanonicalBundleIdentifier == "com.mjorb.seal")
    }

    // MARK: - 摘要

    @Test
    func summaryOnlyLogsWhenThereWasSomethingToSay() {
        var summary = InstalledRecordRecoverySummary()
        #expect(summary.shouldLog == false)
        summary.candidates = 2
        #expect(summary.shouldLog)
        var failed = InstalledRecordRecoverySummary()
        failed.stage = "failed-save"
        #expect(failed.shouldLog)
    }

    @Test
    func summaryMessageNamesTheStageAndTheFirstError() {
        var summary = InstalledRecordRecoverySummary()
        summary.candidates = 3
        summary.recovered = 2
        summary.notInstalled = 1
        summary.stage = "done"
        summary.samples = ["com.example.demo.seal.ABCDE12345"]
        let message = summary.logMessage
        #expect(message.contains("候选 3"))
        #expect(message.contains("补回 2"))
        #expect(message.contains("阶段 done"))
        #expect(message.contains("com.example.demo.seal.ABCDE12345"))
    }

    // MARK: - 墓碑

    @Test
    func tombstonesRoundTripAndNormaliseBundleIdentifiers() {
        let url = makeTemporaryFileURL()
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(DismissedInstalledRecordTombstones.all(fileURL: url).isEmpty)
        DismissedInstalledRecordTombstones.insert(
            ["com.example.demo.seal.ABCDE12345", "   "],
            fileURL: url
        )
        let stored = DismissedInstalledRecordTombstones.all(fileURL: url)
        // 归一化（去空白 + 小写）后才入集合 —— 判据查表用的是归一化后的键。
        #expect(stored == ["com.example.demo.seal.abcde12345"])

        // 再插一条：**累加**，不是覆盖。
        DismissedInstalledRecordTombstones.insert(
            ["com.other.app.seal.ABCDE12345"],
            fileURL: url
        )
        #expect(DismissedInstalledRecordTombstones.all(fileURL: url).count == 2)
    }

    /// 读失败必须按**空集**处理：宁可按「没删过」处理（只是多一条记录），
    /// 也不能按「全删过」处理 —— 那会让扫回静默失效。
    @Test
    func tombstonesFailOpenWhenTheFileIsUnreadable() {
        let url = makeTemporaryFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try? Data("not json".utf8).write(to: url)
        #expect(DismissedInstalledRecordTombstones.all(fileURL: url).isEmpty)
    }

    // MARK: - 辅助

    private func makeContext(
        known: Set<String> = [],
        dismissed: Set<String> = [],
        teams: Set<String>
    ) -> InstalledRecordRecoveryPolicy.Context {
        InstalledRecordRecoveryPolicy.Context(
            knownBundleIdentifiers: known,
            knownTeamIdentifiers: teams,
            dismissedBundleIdentifiers: dismissed,
            sealCanonicalBundleIdentifier: "com.mjorb.seal"
        )
    }

    private func makeProfile(
        bundleID: String,
        team: String?
    ) -> DeviceProvisioningProfileSummary {
        DeviceProvisioningProfileSummary(
            bundleIdentifier: bundleID,
            teamIdentifier: team,
            uuid: UUID().uuidString,
            name: "Seal Profile",
            creationDate: Date(timeIntervalSince1970: 1_700_000_000),
            expirationDate: Date(timeIntervalSince1970: 1_700_600_000)
        )
    }

    private func makeDraft() -> InstalledRecordRecoveryPolicy.Draft {
        InstalledRecordRecoveryPolicy.Draft(
            bundleIdentifier: "com.example.demo.seal.ABCDE12345",
            originalBundleIdentifier: "com.example.demo",
            teamIdentifier: "ABCDE12345",
            profileUUID: "11111111-2222-3333-4444-555555555555",
            profileName: "Seal Profile",
            profileCreationDate: Date(timeIntervalSince1970: 1_700_000_000),
            profileExpirationDate: Date(timeIntervalSince1970: 1_700_600_000),
            displayName: "com.example.demo"
        )
    }

    private func makeTemporaryFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("seal-tombstone-test-\(UUID().uuidString).json")
    }
}
