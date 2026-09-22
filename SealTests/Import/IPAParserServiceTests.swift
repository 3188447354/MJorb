import Foundation
import Testing
@testable import Seal

struct IPAParserServiceTests {
    @Test
    func parsesAppIconExtensionAndEntitlements() throws {
        let url = try IPAArchiveFixture.make(
            includeShareExtension: true,
            includeEntitlements: true
        )
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let result = try IPAParserService().parse(url: url)

        #expect(result.name == "Demo")
        #expect(result.bundleIdentifier == "com.example.demo")
        #expect(result.version == "1.2.3")
        #expect(result.buildNumber == "45")
        #expect(result.fileSize > 0)
        #expect(result.iconData == Data("fixture-icon".utf8))
        #expect(result.extensions.count == 1)
        #expect(result.extensions.first?.kind == .share)
        #expect(result.entitlementKeys == [
            "aps-environment",
            "com.apple.security.application-groups"
        ])
    }

    @Test
    func preservesUTF8AppNamesAndArchivePaths() throws {
        let url = try IPAArchiveFixture.make(
            apps: [
                .init(
                    directoryName: "示例应用.app",
                    bundleIdentifier: "com.example.utf8",
                    name: "示例应用"
                )
            ]
        )
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let result = try IPAParserService().parse(url: url)

        #expect(result.name == "示例应用")
        #expect(result.bundleIdentifier == "com.example.utf8")
    }

    @Test
    func rejectsArchiveWithoutAppInfo() throws {
        let url = try IPAArchiveFixture.make(includeInfo: false)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        assertFailure(code: "SEAL-IPA-101") {
            _ = try IPAParserService().parse(url: url)
        }
    }

    @Test
    func rejectsMalformedAppInfo() throws {
        let url = try IPAArchiveFixture.make(apps: [.init(malformedInfo: true)])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        assertFailure(code: "SEAL-IPA-102") {
            _ = try IPAParserService().parse(url: url)
        }
    }

    @Test
    func rejectsMultipleAppRoots() throws {
        let url = try IPAArchiveFixture.make(apps: [
            .init(),
            .init(directoryName: "Other.app", bundleIdentifier: "com.example.other")
        ])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        assertFailure(code: "SEAL-IPA-103") {
            _ = try IPAParserService().parse(url: url)
        }
    }

    @Test
    func rejectsUnsafeArchivePath() throws {
        let url = try IPAArchiveFixture.make(
            extraEntries: [("../outside", Data("unsafe".utf8))]
        )
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        assertFailure(code: "SEAL-IPA-104") {
            _ = try IPAParserService().parse(url: url)
        }
    }

    @Test
    func rejectsExpandedSizeOverLimit() throws {
        let url = try IPAArchiveFixture.make()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let limits = ArchiveLimits(
            maximumEntryCount: 100,
            maximumExpandedSize: 1,
            maximumMetadataSize: 1_000_000
        )

        assertFailure(code: "SEAL-IPA-105") {
            _ = try IPAParserService(limits: limits).parse(url: url)
        }
    }

    @Test
    func rejectsNestedIPAWrapperBeforeReadingInnerArchive() throws {
        let url = try IPAArchiveFixture.make(
            apps: [], includeIcon: false,
            extraEntries: [("nested.ipa", Data("not-an-archive".utf8))]
        )
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        assertFailure(code: "SEAL-IPA-101b") {
            _ = try IPAParserService().parse(url: url)
        }
    }

    private func assertFailure(
        code: String,
        operation: () throws -> Void,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        do {
            try operation()
            Issue.record("Expected import to fail.", sourceLocation: sourceLocation)
        } catch let failure as ImportFailure {
            #expect(failure.code == code, sourceLocation: sourceLocation)
        } catch {
            Issue.record("Unexpected error: \(error)", sourceLocation: sourceLocation)
        }
    }
}

/// `isEncryptedMachOHeader` 的两条防呆判据：`cmdsize` 不前进会空转，
/// 非对齐的 `load(as:)` 会直接崩。两者都不报错、只在真机上表现为"导入卡死/闪退"，
/// 所以必须用纯函数字节级喂料钉住。
struct MachOEncryptionHeaderTests {
    /// 造一段 64 位 Mach-O 头部：`commands` 里每个元素是 (cmd, cmdsize, cryptid)。
    private func header(
        magic: UInt32 = 0xFEEDFACF,
        ncmds: UInt32,
        sizeofcmds: UInt32,
        commands: [(UInt32, UInt32, UInt32)] = []
    ) -> Data {
        var data = Data(capacity: 32 + commands.count * 24)
        func append(_ value: UInt32) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        append(magic)          // magic
        append(0x0100000C)     // cputype (arm64)
        append(0)              // cpusubtype
        append(2)              // filetype = MH_EXECUTE
        append(ncmds)
        append(sizeofcmds)
        append(0)              // flags
        append(0)              // reserved
        for command in commands {
            append(command.0)      // cmd
            append(command.1)      // cmdsize
            append(0)              // cryptoff
            append(0)              // cryptsize
            append(command.2)      // cryptid
            append(0)              // pad
        }
        return data
    }

    @Test
    func shortHeaderIsNotEncrypted() {
        #expect(IPAParserService.isEncryptedMachOHeader(Data(repeating: 0, count: 8)) == false)
        #expect(IPAParserService.isEncryptedMachOHeader(Data()) == false)
    }

    @Test
    func detectsCryptidAndIgnoresZeroCryptid() {
        let encrypted = header(
            ncmds: 1,
            sizeofcmds: 24,
            commands: [(0x2C, 24, 1)]
        )
        #expect(IPAParserService.isEncryptedMachOHeader(encrypted), "cryptid=1 必须判为加密")

        let plain = header(
            ncmds: 1,
            sizeofcmds: 24,
            commands: [(0x2C, 24, 0)]
        )
        #expect(IPAParserService.isEncryptedMachOHeader(plain) == false)
    }

    /// `cmdsize == 0` ⇒ `offset` 永远不前进，而 `ncmds` 同样是包内自填值（这里给满 42 亿）。
    /// 修复前这里会空转到天荒地老；现在必须在第一条命令处直接放弃。
    @Test
    func zeroCmdsizeTerminatesInsteadOfSpinning() {
        let data = header(ncmds: .max, sizeofcmds: 4096, commands: [(0x2C, 0, 0)])
        let started = Date()
        let result = IPAParserService.isEncryptedMachOHeader(data)
        let elapsed = Date().timeIntervalSince(started)
        #expect(result == false)
        #expect(elapsed < 1, "cmdsize=0 时未立即退出，实际耗时 \(elapsed) 秒")
    }

    /// 非 4 对齐的 `cmdsize`（9）会让后续偏移变奇数 ⇒ `load(as:)` 当场崩。
    /// 这里同时验证它会**前进**并最终越界退出（不是空转）。
    @Test
    func misalignedCmdsizeNeitherCrashesNorSpins() {
        var commands: [(UInt32, UInt32, UInt32)] = []
        for _ in 0..<600 { commands.append((0x0B, 9, 0)) }
        let data = header(ncmds: .max, sizeofcmds: 4096, commands: commands)
        let started = Date()
        let result = IPAParserService.isEncryptedMachOHeader(data)
        #expect(result == false)
        #expect(Date().timeIntervalSince(started) < 1, "非对齐 cmdsize 未正常退出")
    }

    /// fat 包只读前 4KB 判不了各架构的 cryptid —— 目前明确**不下结论**（返回 false），
    /// 这条测试钉住现状，避免有人误以为 fat 也被检过。
    @Test
    func fatHeaderIsNotConcludedAsUnencryptedByContract() {
        let fat = header(magic: 0xCAFEBABE, ncmds: .max, sizeofcmds: 4096)
        #expect(IPAParserService.isEncryptedMachOHeader(fat) == false)
    }
}
