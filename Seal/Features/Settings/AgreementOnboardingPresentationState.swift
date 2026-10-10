import Foundation

enum AgreementPolicyDocument: String, Identifiable, Equatable {
    case privacy
    case terms

    var id: Self { self }
}

/// Keeps the required-consent drawer recoverable after a user temporarily declines it.
struct AgreementOnboardingPresentationState {
    var isConsentSheetPresented = true
    private(set) var isAwaitingDeclineAcknowledgement = false
    private(set) var presentedPolicy: AgreementPolicyDocument?

    mutating func decline() {
        isConsentSheetPresented = false
        isAwaitingDeclineAcknowledgement = true
    }

    mutating func acknowledgeDecline() {
        guard isAwaitingDeclineAcknowledgement else { return }
        isConsentSheetPresented = true
        isAwaitingDeclineAcknowledgement = false
    }

    mutating func openPolicy(_ policy: AgreementPolicyDocument) {
        presentedPolicy = policy
    }

    mutating func closePolicy() {
        presentedPolicy = nil
    }
}
