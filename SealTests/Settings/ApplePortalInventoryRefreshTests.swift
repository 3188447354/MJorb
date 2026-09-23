import Testing
@testable import Seal

@Suite("Apple ID 总览同步范围")
struct ApplePortalInventoryRefreshTests {
    @Test
    func summaryRefreshUsesOneCompleteInventoryScope() {
        let scope = ApplePortalInventoryService.FetchScope.all

        #expect(scope.includesAppIDs)
        #expect(scope.includesCertificates)
    }
}
