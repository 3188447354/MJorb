import Foundation
import Testing
import ZIPFoundation
@testable import Seal

struct SigningWorkspaceTests {
    @Test
    func safelyRemapsMainAndExtensionThenPackagesIPA() throws {
        let source = try IPAArchiveFixture.make(includeShareExtension: true)
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let root = FileManager.default.temporaryDirectory.appending(
            path: "SealSigningTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = SigningWorkspace()
        let prepared = try workspace.prepare(
            ipaURL: source,
            workspaceRoot: root.appending(path: "Work"),
            originalBundleID: "com.example.demo",
            teamID: "TEAMID"
        )
        let output = root.appending(path: "Signed.ipa")

        try workspace.package(prepared, outputURL: output)
        let parsed = try IPAParserService().parse(url: output)

        // 打包策略（2026-09-26 起**逐条目**选择压缩方法）：
        //  · **未压缩**类型（Info.plist / 可执行文件 / embedded.mobileprovision）⇒ 必须 deflate。
        //    原因：`FileManager.zipItem` 的**默认**是 .none（store 不压缩），
        //    而 iOS installd / CoreDevice 对 store-mode ZIP 兼容性差 ——
        //    大文件/非标准结构 IPA 会在定位/解压阶段失败并误报 MissingPackagePath。
        //    真机可用的 jas 与爱思/AltStore/SideStore 标准 IPA 都以 deflate 为主。
        //  · **已经压过**的类型（png / jpg / mp4 / `Assets.car`…）⇒ store，
        //    不再白压一遍（几乎压不动体积，却要付一整遍压缩的 CPU）。
        //    夹具里的 `AppIcon60x60@3x.png` 正好覆盖这一支 ✓。
        // ⚠️ ZIPFoundation 0.9.20 的 `Entry` 只公开 `isCompressed`（= 压缩方法非 .none），
        //    所以判据只能落在「哪些条目没有被压缩」上 ✓。
        let packaged = try Archive(url: output, accessMode: .read)
        let packagedFiles = packaged.filter { $0.type == .file }
        #expect(packagedFiles.isEmpty == false)

        let storedFiles = packagedFiles.filter { $0.isCompressed == false }
        #expect(storedFiles.contains { $0.path.hasSuffix(".png") },
                "已压缩类型（png）必须 store；实际被 store 的：\(storedFiles.map(\.path))")
        #expect(storedFiles.allSatisfy { $0.path.hasSuffix(".png") },
                "只有已压缩类型才允许 store；实际被 store 的：\(storedFiles.map(\.path))")
        #expect(packagedFiles.contains { $0.isCompressed && $0.path.hasSuffix("Info.plist") },
                "未压缩类型（Info.plist）必须 deflate")

        #expect(parsed.bundleIdentifier == prepared.mappedMainBundleID)
        #expect(parsed.extensions.first?.originalBundleIdentifier ==
            prepared.bundleIDMappings["com.example.demo.share"])
    }

    @Test
    func noExtensionIPAProvisionsOnlyMainAppID() throws {
        let source = try IPAArchiveFixture.make()
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let root = FileManager.default.temporaryDirectory.appending(
            path: "SealNoExtensionTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let prepared = try SigningWorkspace().prepare(
            ipaURL: source,
            workspaceRoot: root.appending(path: "Work"),
            originalBundleID: "com.example.demo",
            teamID: "TEAMID"
        )

        #expect(prepared.bundleIDMappings == ["com.example.demo": prepared.mappedMainBundleID])
    }

    @Test
    func appliesCustomDisplayNameAndPrimaryIconToPackagedApp() throws {
        let source = try IPAArchiveFixture.make()
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let root = FileManager.default.temporaryDirectory.appending(
            path: "SealCustomSigningTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let iconData = try #require(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR4nGP4DwQACfsD/fteaysAAAAASUVORK5CYII="
        ))
        let workspace = SigningWorkspace()
        let prepared = try workspace.prepare(
            ipaURL: source,
            workspaceRoot: root.appending(path: "Work"),
            originalBundleID: "com.example.demo",
            teamID: "TEAMID",
            preferredDisplayName: "Demo Custom",
            preferredIconData: iconData
        )

        let infoData = try Data(contentsOf: prepared.appURL.appending(path: "Info.plist"))
        let info = try #require(try PropertyListSerialization.propertyList(
            from: infoData,
            options: [],
            format: nil
        ) as? [String: Any])
        #expect(info["CFBundleDisplayName"] as? String == "Demo Custom")
        #expect(info["CFBundleName"] as? String == "Demo Custom")
        #expect(FileManager.default.fileExists(atPath: prepared.appURL.appending(path: "SealCustomIcon60@3x.png").path))

        let output = root.appending(path: "Signed.ipa")
        try workspace.package(prepared, outputURL: output)
        let parsed = try IPAParserService().parse(url: output)
        #expect(parsed.name == "Demo Custom")
    }

    @Test
    func removesThirdPartySigningResidueButKeepsOrdinaryFiles() throws {
        let source = try IPAArchiveFixture.make(extraEntries: [
            (path: "Payload/Demo.app/lzlukvca_inject.js", data: Data("inject".utf8)),
            (path: "Payload/Demo.app/SignedByEsign", data: Data("mark".utf8)),
            (path: "Payload/Demo.app/normal.json", data: Data("{}".utf8))
        ])
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let root = FileManager.default.temporaryDirectory.appending(
            path: "SealResidueTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let prepared = try SigningWorkspace().prepare(
            ipaURL: source,
            workspaceRoot: root.appending(path: "Work"),
            originalBundleID: "com.example.demo",
            teamID: "TEAMID"
        )

        // ESign 注入脚本与签名标记必须在重签前清除
        #expect(FileManager.default.fileExists(
            atPath: prepared.appURL.appending(path: "lzlukvca_inject.js").path) == false)
        #expect(FileManager.default.fileExists(
            atPath: prepared.appURL.appending(path: "SignedByEsign").path) == false)
        // 普通资源不得被误伤
        #expect(FileManager.default.fileExists(
            atPath: prepared.appURL.appending(path: "normal.json").path))
    }

    /// 🔴 打包压缩策略：**载荷已压过 ⇒ store，其余 ⇒ deflate**（2026-09-26）。
    ///
    /// 两条判据同样重要：
    ///  · 漏了 store ⇒ 白花一整遍压缩的 CPU（本项要修的病）；
    ///  · 漏了 deflate ⇒ IPA 体积被撑大，而体积直接决定上传与安装耗时，
    ///    并且 store-mode ZIP 在 iOS installd / CoreDevice 上兼容性差 ✗。
    @Test
    func compressionPolicyStoresOnlyAlreadyCompressedPayloads() {
        for path in [
            "Payload/Demo.app/AppIcon60x60@3x.png",
            "Payload/Demo.app/Assets.car",
            "Payload/Demo.app/intro.mp4",
            "Payload/Demo.app/song.m4a",
            "Payload/Demo.app/photo.HEIC",
            "Payload/Demo.app/backup.zip"
        ] {
            #expect(SigningWorkspace.compressionMethod(forRelativePath: path) == .none,
                    "\(path) 已压缩，应当 store")
        }

        for path in [
            "Payload/Demo.app/Info.plist",
            "Payload/Demo.app/Demo",
            "Payload/Demo.app/PlugIns/Share.appex/Share",
            "Payload/Demo.app/embedded.mobileprovision",
            "Payload/Demo.app/font.ttf",
            "Payload/Demo.app/data.json",
            "Payload/Demo.app/",
            ""
        ] {
            #expect(SigningWorkspace.compressionMethod(forRelativePath: path) == .deflate,
                    "\(path) 未压缩，必须 deflate")
        }
    }

    /// 🔴 钉住 `PreparePurpose.layoutOnly` 的**唯一**承诺：
    /// 跳过「瘦身 arm64e」与「ESign 布局归一化」**不得改变**
    /// `provisioningProfiles` 看到的东西 —— 即主 Bundle ID 映射、扩展映射、扩展集合
    /// 与完整 `.signing` **完全一致** ✓。
    ///
    /// 为什么必须有这条：profile-only 续签用 `.layoutOnly` 推导目标集合，
    /// 而记录里的目标集合来自当初的**完整签名** —— 两者只要差一个目标，
    /// 就会抛 `SEAL-PROFILE-331a`（应用目标已变化）⇒ 每次都退化成完整重签 ✗✗，
    /// 而这**正是本项优化要避免的**（「省了 30 秒」却把快路径关掉，是净亏）。
    ///
    /// 同时钉住**判别力**：夹具里放一个根目录 `.framework`，
    /// `.signing` 必须把它挪进 `Frameworks/`，`.layoutOnly` 必须**原样不动** ——
    /// 少了后半条，`purpose` 开关就算恒等于 `.signing` 也测不出来 ✗。
    @Test
    func layoutOnlyKeepsMappingsAndExtensionSetIdenticalToSigning() throws {
        let source = try IPAArchiveFixture.make(
            includeShareExtension: true,
            extraEntries: [
                // 根目录的 .framework ⇒ 触发归一化那条「全树遍历」路径
                (path: "Payload/Demo.app/Root.framework/Root", data: Data("root-framework".utf8))
            ]
        )
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let root = FileManager.default.temporaryDirectory.appending(
            path: "SealPreparePurposeTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let workspace = SigningWorkspace()
        let signingPrepared = try workspace.prepare(
            ipaURL: source,
            workspaceRoot: root.appending(path: "Signing"),
            originalBundleID: "com.example.demo",
            teamID: "TEAMID"
        )
        let layoutPrepared = try workspace.prepare(
            ipaURL: source,
            workspaceRoot: root.appending(path: "Layout"),
            originalBundleID: "com.example.demo",
            teamID: "TEAMID",
            purpose: .layoutOnly
        )

        // ① 两种用途下，provisioningProfiles 的输入必须逐项一致
        #expect(layoutPrepared.mappedMainBundleID == signingPrepared.mappedMainBundleID)
        #expect(layoutPrepared.bundleIDMappings == signingPrepared.bundleIDMappings)
        // ⚠️ 不用 `workspace.appExtensionURLs`（那是 `private`，`@testable` 也看不到）——
        // 直接读 `PlugIns/` 目录，判据与 `ALTApplication.loadExtensions()` 同源（只认 .appex）✓
        func extensionNames(in appURL: URL) -> [String] {
            let plugins = appURL.appending(path: "PlugIns", directoryHint: .isDirectory)
            let entries = (try? FileManager.default.contentsOfDirectory(atPath: plugins.path)) ?? []
            return entries.filter { $0.lowercased().hasSuffix(".appex") }.sorted()
        }
        let signingExtensions = extensionNames(in: signingPrepared.appURL)
        #expect(extensionNames(in: layoutPrepared.appURL) == signingExtensions)
        #expect(signingExtensions.isEmpty == false)

        // ② 判别力：归一化在 `.signing` 里必须发生，在 `.layoutOnly` 里必须**不**发生
        #expect(FileManager.default.fileExists(
            atPath: signingPrepared.appURL.appending(path: "Frameworks/Root.framework").path))
        #expect(FileManager.default.fileExists(
            atPath: signingPrepared.appURL.appending(path: "Root.framework").path) == false)
        #expect(FileManager.default.fileExists(
            atPath: layoutPrepared.appURL.appending(path: "Root.framework").path))
        #expect(FileManager.default.fileExists(
            atPath: layoutPrepared.appURL.appending(path: "Frameworks/Root.framework").path) == false)
    }
}
