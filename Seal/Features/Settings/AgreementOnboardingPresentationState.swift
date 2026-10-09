import Foundation

/// Keeps the required-consent drawer recoverable after a user temporarily declines it.
struct AgreementOnboardingPresentationState {
    var isConsentSheetPresented = true

    mutating func decline() {
        isConsentSheetPresented = false
    }

    mutating func acknowledgeDecline() {
        isConsentSheetPresented = true
    }
}
