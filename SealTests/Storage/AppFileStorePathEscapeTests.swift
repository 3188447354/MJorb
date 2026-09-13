import Foundation
import Testing
@testable import Seal

/// 路径逃逸防护：`Apps/<uuid>` 若被换成指向别处的符号链接，
/// 纯字符串前缀比较（standardizedFileURL）依然会通过，写入就落到 Apps 之外。
struct AppFileStorePathEscapeTests {

    /// 核心：通过符号链接逃出 Documents 的路径必须被拒绝。
    @Test
    func fileURLRejectsAPathThatEscapesThroughASymlink() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let appID = UUID()
        // Apps/<appID> ——> 指向 Documents 之外的真实目录
        try FileManager.default.createSymbolicLink(
            at: fixture.appsRoot.appending(path: appID.uuidString),
            withDestinationURL: fixture.outside
        )

        do {
            _ = try await fixture.store.fileURL(relativePath: "Apps/\(appID.uuidString)/Original.ipa")
            Issue.record("符号链接逃逸必须被拒绝（否则写入会落到 Apps 之外）")
        } catch {
            #expect(error is ImportFailure)
        }
    }

    /// 正常路径不能被误伤 —— 加固后仍要放行。
    @Test
    func fileURLStillAcceptsAPathInsideDocuments() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let appID = UUID()

        let url = try await fixture.store.fileURL(relativePath: "Apps/\(appID.uuidString)/Original.ipa")

        #expect(url.lastPathComponent == "Original.ipa")
        #expect(url.path.contains(appID.uuidString))
    }

    @Test
    func removingAnAppDirectoryRejectsASymlinkedEscape() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let appID = UUID()
        try FileManager.default.createSymbolicLink(
            at: fixture.appsRoot.appending(path: appID.uuidString),
            withDestinationURL: fixture.outside
        )

        do {
            try await fixture.store.removeApp(appID: appID)
            Issue.record("符号链接逃逸必须被拒绝")
        } catch {
            #expect(error is ImportFailure)
        }
        // 关键：链接指向的目录必须还在（不能被顺带删掉）
        #expect(FileManager.default.fileExists(atPath: fixture.outside.path))
    }

    // MARK: - 夹具

    private struct Fixture {
        let root: URL
        let appsRoot: URL
        let outside: URL
        let store: AppFileStore
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "SealPathEscape-\(UUID().uuidString)", directoryHint: .isDirectory)
        let documents = root.appending(path: "Documents", directoryHint: .isDirectory)
        let cache = root.appending(path: "Caches", directoryHint: .isDirectory)
        let outside = root.appending(path: "Outside", directoryHint: .isDirectory)
        let appsRoot = documents.appending(path: "Apps", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: appsRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        // 放个哨兵文件，便于断言「外面的目录没被删」
        try Data("outside".utf8).write(to: outside.appending(path: "sentinel.txt"))
        return Fixture(
            root: root,
            appsRoot: appsRoot,
            outside: outside,
            store: AppFileStore(
                documentsDirectory: documents,
                cacheDirectory: cache,
                fileProtector: MarkerFileProtector()
            )
        )
    }
}
