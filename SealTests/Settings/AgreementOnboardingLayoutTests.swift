import XCTest
@testable import Seal

final class AgreementOnboardingLayoutTests: XCTestCase {
    func testMatchesTheSealDrawerGeometry() {
        XCTAssertEqual(AgreementOnboardingLayout.iconSize, 112)
        XCTAssertEqual(AgreementOnboardingLayout.drawerCornerRadius, 29)
        XCTAssertEqual(AgreementOnboardingLayout.horizontalInset, 22)
        XCTAssertEqual(AgreementOnboardingLayout.initialDrawerFraction, 0.44)
        XCTAssertEqual(AgreementOnboardingLayout.compactContentSpacing, 18)
    }

    func testAcknowledgingDeclineRepresentsTheConsentDrawer() {
        var state = AgreementOnboardingPresentationState()

        state.decline()
        XCTAssertFalse(state.isConsentSheetPresented)

        state.acknowledgeDecline()
        XCTAssertTrue(state.isConsentSheetPresented)
    }
}
