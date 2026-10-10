import Foundation

/// Keeps the required-consent drawer recoverable after a user temporarily declines it.
struct AgreementOnboardingPresentationState {
    var isConsentSheetPresented = true
    private(set) var isAwaitingDeclineAcknowledgement = false
    private(set) var isReadingPolicy = false

    mutating func decline() {
        isConsentSheetPresented = false
        isAwaitingDeclineAcknowledgement = true
    }

    mutating func acknowledgeDecline() {
        guard isAwaitingDeclineAcknowledgement else { return }
        isConsentSheetPresented = true
        isAwaitingDeclineAcknowledgement = false
    }

    mutating func openPolicy() {
        isReadingPolicy = true
    }

    mutating func closePolicy() {
        isReadingPolicy = false
    }
}
