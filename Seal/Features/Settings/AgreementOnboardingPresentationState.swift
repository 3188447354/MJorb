import Foundation

/// Keeps the required-consent drawer recoverable after a user temporarily declines it.
struct AgreementOnboardingPresentationState {
    var isConsentSheetPresented = true
    private(set) var isAwaitingDeclineAcknowledgement = false

    mutating func decline() {
        isConsentSheetPresented = false
        isAwaitingDeclineAcknowledgement = true
    }

    mutating func acknowledgeDecline() {
        guard isAwaitingDeclineAcknowledgement else { return }
        isConsentSheetPresented = true
        isAwaitingDeclineAcknowledgement = false
    }
}
