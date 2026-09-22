import Foundation
import Testing
@testable import Seal

/// 日志导出的表头必须**自带构建标识**。
///
/// 为什么值得单测：`CURRENT_PROJECT_VERSION` 由 `Scripts/build-unsigned-ipa.sh` 取
/// `GITHUB_RUN_NUMBER`，所以它唯一对应一次 CI 构建、进而唯一对应一个提交。
///
/// 2026-09-17 实际踩到的坑：一份真机日志的文案是 `安装后旧描述文件清理（<bundleID>）：…`，
/// 与当前源码的 `（主 <bundleID>，共 N 个 Bundle ID）` 不一致 —— 顺着这个不一致去比对历史提交，
/// 才发现那份日志来自一个**比修复更早的构建**，整轮分析的前提都不成立。
/// 表头有构建号的话，`grep 构建` 一眼就能定版。
struct SealLogTextFormatterTests {

    private func entry(_ message: String, code: String? = nil) -> SealLogEntry {
        SealLogEntry(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            category: .installation,
            message: message,
            code: code
        )
    }

    @Test
    func diagnosticTimestampUsesBeijingISO8601() {
        let timestamp = Date(timeIntervalSince1970: 1_789_622_938)

        #expect(
            SealLogTextFormatter.diagnosticTimestamp(timestamp) == "2026-09-17T13:28:58+08:00"
        )
    }

    // MARK: - 表头

    @Test
    func headerCarriesBuildLabel() {
        let text = SealLogTextFormatter.exportText(
            [entry("测试")],
            capacity: 1000,
            buildLabel: "1.1.16 (91)"
        )

        #expect(text.contains("构建 1.1.16 (91)"), "表头必须带上构建标识，否则日志无法定版")
    }

    /// 构建号必须在**正文之前** —— 排在后面等于让人翻到文件尾才知道自己看的是哪个版本。
    @Test
    func buildLabelComesBeforeEntries() {
        let text = SealLogTextFormatter.exportText(
            [entry("正文第一条")],
            buildLabel: "1.1.16 (91)"
        )

        // 判定取到局部变量再断言：`#expect` 是宏，会把表达式重写成闭包、子表达式绑成 `$0`。
        let labelAt = text.range(of: "构建 1.1.16 (91)")
        let entryAt = text.range(of: "正文第一条")
        var ordered = false
        if let labelAt, let entryAt {
            ordered = labelAt.lowerBound < entryAt.lowerBound
        }
        #expect(ordered, "构建号必须排在正文之前，否则无法一眼定版")
    }

    /// 表头第二行必须解释「构建号从哪来」—— 否则拿到日志的人不知道
    /// `1.1.16 (91)` 里的 `91` 该去哪里查。
    @Test
    func headerExplainsWhereTheBuildNumberComesFrom() {
        let text = SealLogTextFormatter.exportText([], buildLabel: "1.1.16 (91)")

        #expect(text.contains("CI run number"))
    }

    // MARK: - 真实导出路径

    /// 走**真实的** `SealLogStore.exportText()`：源码断言只能证明参数被传了，
    /// 证明不了它真的出现在导出文本里（比如 `SealLogStore` 忘了透传）。
    @Test
    func storeExportIncludesBuildLabel() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "SealLogFormatter-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SealLogStore(
            fileURL: directory.appending(path: "Logs.json"),
            fileProtector: MarkerFileProtector()
        )
        try await store.append(category: .system, message: "一条日志")

        let text = try await store.exportText()

        #expect(text.contains("构建 "), "导出文本里必须有构建标识这一行")
        #expect(text.contains(SealLogTextFormatter.currentBuildLabel),
                "必须是当前构建的标识，而不是写死的字符串")
    }

    // MARK: - 回归：加了表头行不能挤掉原有内容

    @Test
    func entriesAndNoticeSurviveTheExtraHeaderLine() {
        let text = SealLogTextFormatter.exportText(
            [entry("第一条", code: "SEAL-TEST-001"), entry("第二条")],
            capacity: 500,
            notice: "（滚动丢弃提示）",
            buildLabel: "1.1.16 (91)"
        )

        #expect(text.contains("保留最近 500 条"))
        #expect(text.contains("（滚动丢弃提示）"))
        #expect(text.contains("第一条"))
        #expect(text.contains("第二条"))
        #expect(text.contains("[SEAL-TEST-001]"))
        // 空行仍在：表头与正文之间要有视觉分隔，否则第一行日志会被当成表头的一部分。
        #expect(text.contains("\n\n"))
    }
}
