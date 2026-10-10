import XCTest
@testable import Seal

final class AgreementOnboardingLayoutTests: XCTestCase {
    func testMatchesTheSealDrawerGeometry() {
        XCTAssertEqual(AgreementOnboardingLayout.iconSize, 92)
        XCTAssertEqual(AgreementOnboardingLayout.iconCornerRadius, 22)
        XCTAssertEqual(AgreementOnboardingLayout.drawerCornerRadius, 29)
        XCTAssertEqual(AgreementOnboardingLayout.horizontalInset, 22)
        XCTAssertEqual(AgreementOnboardingLayout.initialDrawerFraction, 0.38)
        XCTAssertEqual(AgreementOnboardingLayout.compactContentSpacing, 18)
        XCTAssertEqual(AgreementOnboardingLayout.brandNamePointSize, 46)
        XCTAssertEqual(AgreementOnboardingLayout.brandTaglinePointSize, 20)
        XCTAssertEqual(AgreementOnboardingLayout.brandTagline, "让应用始终可用")
        XCTAssertEqual(AgreementOnboardingLayout.consentTitle, "欢迎使用")
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

    func testReadingPolicyKeepsTheWelcomeDrawerPresented() {
        var state = AgreementOnboardingPresentationState()

        state.openPolicy(.privacy)

        XCTAssertTrue(state.isConsentSheetPresented)
        XCTAssertEqual(state.presentedPolicy, .privacy)

        state.closePolicy()

        XCTAssertTrue(state.isConsentSheetPresented)
        XCTAssertNil(state.presentedPolicy)
    }
}
