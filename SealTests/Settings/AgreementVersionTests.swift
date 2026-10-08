import XCTest
@testable import Seal

/// 协议版本与同意状态的最小测试。
final class AgreementVersionTests: XCTestCase {

    private let testKey = "seal.test.agreedAgreementVersion"

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: testKey)
        super.tearDown()
    }

    /// 未同意过 → 需要展示协议页
    func testNeedsOnboardingWhenNeverAgreed() {
        UserDefaults.standard.removeObject(forKey: AgreementVersion.storageKey)
        XCTAssertTrue(needsAgreementOnboarding())
    }

    /// 已同意当前版本 → 不需要展示
    func testNoOnboardingWhenAgreedCurrentVersion() {
        UserDefaults.standard.set(AgreementVersion.current, forKey: AgreementVersion.storageKey)
        XCTAssertFalse(needsAgreementOnboarding())
    }

    /// 同意的是旧版本 → 需要重新同意
    func testNeedsOnboardingWhenVersionUpgraded() {
        UserDefaults.standard.set(AgreementVersion.current - 1, forKey: AgreementVersion.storageKey)
        XCTAssertTrue(needsAgreementOnboarding())
    }

    /// 元数据不为空
    func testAgreementMetadataNotEmpty() {
        XCTAssertFalse(AgreementMetadata.Privacy.effectiveDate.isEmpty)
        XCTAssertFalse(AgreementMetadata.Terms.effectiveDate.isEmpty)
        XCTAssertGreaterThan(AgreementMetadata.Privacy.version, 0)
        XCTAssertGreaterThan(AgreementMetadata.Terms.version, 0)
    }
}
