import Testing
@testable import Seal

@Suite("存储清理结果文案")
struct StorageMaintenanceSummaryTests {
    @Test
    func reportsReleasedSpace() {
        #expect(StorageMaintenanceSummary.temporaryCacheCleared(freedBytes: 1_024).contains("已释放"))
    }

    @Test
    func distinguishesNoReclaimableFiles() {
        #expect(StorageMaintenanceSummary.unusedFilesCleared(freedBytes: -1).contains("没有发现"))
    }
}
