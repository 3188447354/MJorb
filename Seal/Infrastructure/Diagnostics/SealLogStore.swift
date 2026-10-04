import Foundation

actor SealLogStore {
    private let fileURL: URL
    private let maximumEntries: Int
    private let fileProtector: any FileProtecting
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    // 内存缓冲：append 只更新内存，由 flush_task 节流批量落盘，
    // 避免「每条日志都全量读 + JSON 重写 + atomic 双写 + protect」放大成 MB 级磁盘写。
    private var buffer: [SealLogEntry] = []
    private var bufferLoaded = false
    private var pendingFlush = false
    private var hasProtectedOnce = false
    // 2026-10-04: mirror 节流。flush 每次都全量写 Documents/Seal-log.txt（1000 条 encode + atomic 写），
    // 签名/续签期间高频调用。节流到最多 30 秒一次，保留用户排障通道（注释要求不能关）。
    private var lastMirrorDate: Date?
    /// 自上次清空以来被环形丢弃的更早日志条数（导出时提示，避免误以为历史完整）
    private var droppedSinceClear = 0

    init(
        fileURL: URL,
        maximumEntries: Int = 1000,
        fileProtector: any FileProtecting = CompleteFileProtector()
    ) {
        self.fileURL = fileURL
        self.maximumEntries = maximumEntries
        self.fileProtector = fileProtector
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    func append(
        category: SealLogEntry.Category,
        level: SealLogEntry.Level = .info,
        message: String,
        code: String? = nil
    ) throws {
        loadBufferIfNeeded()
        buffer.append(
            SealLogEntry(
                category: category,
                level: level,
                message: LogPrivacyRedactor.redact(message),
                code: code.map(LogPrivacyRedactor.redact)
            )
        )
        if buffer.count > maximumEntries {
            droppedSinceClear += buffer.count - maximumEntries
            buffer = Array(buffer.suffix(maximumEntries))
        }
        scheduleFlush()
    }

    func entries() throws -> [SealLogEntry] {
        loadBufferIfNeeded()
        return Array(buffer.map(Self.redacted).reversed())
    }

    func clear() throws {
        buffer = []
        bufferLoaded = true
        droppedSinceClear = 0
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
        mirrorToDocuments()
    }

    func exportText() throws -> String {
        loadBufferIfNeeded()
        let notice = droppedSinceClear > 0
            ? "（自上次清空以来已有 \(droppedSinceClear) 条更早日志被滚动丢弃）"
            : nil
        // 构建标识显式传下去（而不是靠默认参数）：这条依赖是「日志能不能定版」的关键，
        // 要能被守卫的源码断言看见 —— 删掉它守卫就该红。
        // 🔴 导出（= 镜像到 Documents 的 `Seal-log.txt`）**也必须过脱敏**（AGENTS.md §4）：
        // `append` 只保证**新写入**的那份已脱敏；升级前遗留的未脱敏 JSON 会被原样读进
        // `buffer`，这里若直接交给格式化器就会把它们原样导出（公开仓库即泄露开发者账号）。
        // `entries()` 早就做了这层重脱敏，导出与它同源。
        return SealLogTextFormatter.exportText(
            buffer.map(Self.redacted).reversed(),
            capacity: maximumEntries,
            notice: notice,
            buildLabel: SealLogTextFormatter.currentBuildLabel
        )
    }

    private static func redacted(_ entry: SealLogEntry) -> SealLogEntry {
        SealLogEntry(
            id: entry.id,
            timestamp: entry.timestamp,
            category: entry.category,
            level: entry.level,
            message: LogPrivacyRedactor.redact(entry.message),
            code: entry.code.map(LogPrivacyRedactor.redact)
        )
    }

    private func loadBufferIfNeeded() {
        guard !bufferLoaded else { return }
        buffer = (try? read()) ?? []
        bufferLoaded = true
    }

    private func scheduleFlush() {
        guard !pendingFlush else { return }
        pendingFlush = true
        Task.detached { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            await self?.performFlush()
        }
    }

    private func performFlush() {
        pendingFlush = false
        flush()
    }

    /// 立即把内存缓冲落盘（供测试及需要即时持久的场景；日常 append 仍走节流批量落盘）
    func flush() {
        loadBufferIfNeeded()
        persist(buffer)
        // 每次落盘都同步镜像到 Documents：只镜像 error 会导致顺利签名/续签后
        // 文件 App 的 Seal 文件夹里根本没有 Seal-log.txt 可查。
        mirrorToDocuments()
    }

    /// 把最近日志镜像到 Documents（文件 App → 我的 iPhone → Seal → Seal-log.txt）
    /// 2026-10-04: 节流到 30 秒一次。高频 flush 时全量 encode+写文件是 MB 级磁盘写。
    private func mirrorToDocuments() {
        let now = Date()
        if let last = lastMirrorDate, now.timeIntervalSince(last) < 30 {
            return
        }
        lastMirrorDate = now
        guard let documents = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first else { return }
        let text = (try? exportText()) ?? ""
        try? text.write(
            to: documents.appendingPathComponent("Seal-log.txt"),
            atomically: true,
            encoding: .utf8
        )
    }

    private func persist(_ entries: [SealLogEntry]) {
        let directory = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        // 非 atomic：避免每条日志临时文件 + rename 的双写放大
        try? encoder.encode(entries).write(to: fileURL)
        if !hasProtectedOnce {
            hasProtectedOnce = true
            try? fileProtector.protect(fileURL)
        }
    }

    private func read() throws -> [SealLogEntry] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        return try decoder.decode(
            [SealLogEntry].self,
            from: Data(contentsOf: fileURL)
        )
    }
}
