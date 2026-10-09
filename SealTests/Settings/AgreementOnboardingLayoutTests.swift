import XCTest
@testable import Seal

final class AgreementOnboardingLayoutTests: XCTestCase {
    func testMatchesTheSealDrawerGeometry() {
        XCTAssertEqual(AgreementOnboardingLayout.iconSize, 112)
        XCTAssertEqual(AgreementOnboardingLayout.drawerCornerRadius, 29)
        XCTAssertEqual(AgreementOnboardingLayout.horizontalInset, 22)
    }
}
