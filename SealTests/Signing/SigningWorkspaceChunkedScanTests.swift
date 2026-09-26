import Foundation
import Testing
@testable import Seal

/// `SigningWorkspace.containsBytes` —— **分块扫描**的正确性。
///
/// ⚠️ 这个函数必须有单测（2026-09-19 真机教训 ✗）：
/// 它的**跨块边界**逻辑写错过一次 —— 用 `replaceSubrange` 缩短了缓冲区，
/// 导致下一轮 `read` **越界写堆** ⇒ 构建 163 直接崩在 `preparingBundle` ✗✗。
/// **那种错法读代码看不出来** ✗，只能靠边界用例钉住 ✓。
///
/// 还有一条更隐蔽的：**重叠少留一个字节** ⇒ 跨块边界的匹配被漏掉
/// ⇒ 该改写的没改 ⇒ **装完启动闪退** ✗✗（比崩溃更难查 ✓）。
///
/// ⚠️ 守卫 R53 会核对本文件里「跨块」那条用例确实存在。
struct SigningWorkspaceChunkedScanTests {

    /// 造一个临时文件，返回 URL；用完由调用方删除。
    private func makeFile(_ bytes: [UInt8]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("chunked-scan-\(UUID().uuidString).bin")
        try Data(bytes).write(to: url)
        return url
    }

    @Test
    func findsNeedleAtTheVeryStart() throws {
        let url = try makeFile(Array("NEEDLE-then-padding".utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        let workspace = SigningWorkspace()
        #expect(workspace.containsBytes(Data("NEEDLE".utf8), in: url, chunkSize: 8))
    }

    @Test
    func findsNeedleAtTheVeryEnd() throws {
        let url = try makeFile(Array("padding-then-NEEDLE".utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        let workspace = SigningWorkspace()
        #expect(workspace.containsBytes(Data("NEEDLE".utf8), in: url, chunkSize: 8))
    }

    /// 🔴 **最关键的一条**：needle **横跨两块边界** ✓
    ///
    /// `chunkSize: 4` + 前缀 3 字节 ⇒ `NEEDLE` 的前 1 字节在第一块、后 5 字节在第二块 ✓。
    /// **重叠少留一个字节，这条就会失败** ✗（那正是「装完闪退」的成因 ✓）。
    @Test
    func findsNeedleStraddlingAChunkBoundary() throws {
        let url = try makeFile(Array("abcNEEDLExyz".utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        let workspace = SigningWorkspace()
        #expect(workspace.containsBytes(Data("NEEDLE".utf8), in: url, chunkSize: 4))
    }

    @Test
    func reportsMissingNeedle() throws {
        // 长文件（跨多块）+ 不存在的 needle ⇒ 必须走完整个文件再返回 false ✓
        let url = try makeFile(Array(repeating: UInt8(ascii: "x"), count: 1000))
        defer { try? FileManager.default.removeItem(at: url) }
        let workspace = SigningWorkspace()
        #expect(workspace.containsBytes(Data("NEEDLE".utf8), in: url, chunkSize: 64) == false)
    }

    @Test
    func handlesEmptyFileAndLongerNeedle() throws {
        let empty = try makeFile([])
        defer { try? FileManager.default.removeItem(at: empty) }
        let workspace = SigningWorkspace()
        #expect(workspace.containsBytes(Data("N".utf8), in: empty, chunkSize: 8) == false)

        let short = try makeFile(Array("ab".utf8))
        defer { try? FileManager.default.removeItem(at: short) }
        #expect(workspace.containsBytes(Data("abcdef".utf8), in: short, chunkSize: 8) == false)
    }

    @Test
    func findsNeedleEqualToWholeFile() throws {
        let url = try makeFile(Array("NEEDLE".utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        let workspace = SigningWorkspace()
        #expect(workspace.containsBytes(Data("NEEDLE".utf8), in: url, chunkSize: 8))
    }

    @Test
    func reportsMissingFileAsFalse() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString).bin")
        let workspace = SigningWorkspace()
        #expect(workspace.containsBytes(Data("N".utf8), in: missing, chunkSize: 8) == false)
    }

    // MARK: - 2026-09-26：`containsBytes` 改成零拷贝搜索后的边界判据

    /// 🔴 `bufferContains` 的**边界**判据。
    ///
    /// 2026-09-26 把 `containsBytes` 里的 `Data(buffer[0..<total]).range(of: needle)`
    /// 换成裸缓冲区上的手写搜索（省掉每轮一次 256 KB 的 malloc + memcpy）✓
    /// ⇒ 搜索的**边界语义**从「系统实现保证」变成「我们自己保证」，必须自己钉住：
    ///  ① needle **恰好落在缓冲区最末尾**（`lastStart = count - needleCount` 这个边界）；
    ///  ② needle **比缓冲区还长** ⇒ 必须 false，**不能越界读**；
    ///  ③ **空 needle** ⇒ 必须 false，与 `containsBytes` 开头的 `needleBytes.isEmpty` 早退一致 ✓；
    ///  ④ 首字节命中但后续不匹配 ⇒ 必须 false（保证「预筛 + 逐字节比对」不会假阳性）；
    ///  ⑤ `count` 只算前 N 字节 ⇒ needle 落在 N 之后时必须 false。
    @Test
    func bufferContainsHandlesBoundaries() {
        let haystack = Array("abcNEEDLE".utf8)
        haystack.withUnsafeBufferPointer { raw in
            guard let base = raw.baseAddress else { return }
            #expect(SigningWorkspace.bufferContains(base, count: raw.count, needle: Array("NEEDLE".utf8)))
            #expect(SigningWorkspace.bufferContains(base, count: raw.count, needle: Array("abcNEEDLE".utf8)))
            #expect(SigningWorkspace.bufferContains(base, count: raw.count, needle: Array("abcNEEDLEX".utf8)) == false)
            #expect(SigningWorkspace.bufferContains(base, count: raw.count, needle: []) == false)
            #expect(SigningWorkspace.bufferContains(base, count: raw.count, needle: Array("NEEDLX".utf8)) == false)
            #expect(SigningWorkspace.bufferContains(base, count: 3, needle: Array("NEEDLE".utf8)) == false)
        }
    }
}
