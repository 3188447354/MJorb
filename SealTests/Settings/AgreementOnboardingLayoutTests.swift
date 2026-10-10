import XCTest
@testable import Seal

final class AgreementOnboardingLayoutTests: XCTestCase {
    func testMatchesTheSealDrawerGeometry() {
        XCTAssertEqual(AgreementOnboardingLayout.iconSize, 112)
        XCTAssertEqual(AgreementOnboardingLayout.drawerCornerRadius, 29)
        XCTAssertEqual(AgreementOnboardingLayout.horizontalInset, 22)
        XCTAssertEqual(AgreementOnboardingLayout.initialDrawerFraction, 0.38)
        XCTAssertEqual(AgreementOnboardingLayout.compactContentSpacing, 18)
    }

    func testAcknowledgingDeclineRestoresTheConsentDrawerAfterTheAlertDismisses() {
        var state = AgreementOnboardingPresentationState()

        state.decline()
        XCTAssertFalse(state.isConsentSheetPresented)
        XCTAssertTrue(state.isAwaitingDeclineAcknowledgement)

        state.acknowledgeDecline()
        XCTAssertTrue(state.isConsentSheetPresented)
        XCTAssertFalse(state.isAwaitingDeclineAcknowledgement)
    }

    func testPolicyNavigationExpandsAndReturnRestoresCompactDrawer() {
        var state = AgreementOnboardingPresentationState()

        state.openPolicy()
        XCTAssertTrue(state.isReadingPolicy)

        state.closePolicy()
        XCTAssertFalse(state.isReadingPolicy)
    }
}
