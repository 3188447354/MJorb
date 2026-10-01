import Foundation
import Testing
@testable import Seal

@Suite("Apple 门户证书回包代次")
struct ApplePortalInventoryRefreshGateTests {
    @Test
    func newerRefreshRejectsOlderResponse() {
        var gate = ApplePortalInventoryRefreshGate()
        let accountID = UUID()
        let older = gate.issueTicket(for: accountID)
        let newer = gate.issueTicket(for: accountID)

        #expect(gate.accepts(older) == false)
        #expect(gate.accepts(newer))
    }

    @Test
    func revokeInvalidatesOutstandingResponse() {
        var gate = ApplePortalInventoryRefreshGate()
        let ticket = gate.begin(for: UUID())

        gate.invalidate(for: ticket.accountID)

        #expect(gate.accepts(ticket) == false)
    }
}
