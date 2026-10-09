import Foundation
import Testing
@testable import Seal

@Suite("证书库存可见性")
struct ApplePortalInventoryVisibilityTests {
    @Test
    func filtersDismissedCertificateBeforePublishingInventory() {
        let dismissedSerial = "DISMISSED-\(UUID().uuidString)"
        let visibleSerial = "VISIBLE-\(UUID().uuidString)"
        CertificateDismissalStore.dismiss(serialNumber: dismissedSerial)

        let inventory = ApplePortalInventory(
            accountID: UUID(),
            teamID: "TEAM",
            teamName: "Team",
            appIDs: [],
            certificates: [
                certificate(serial: dismissedSerial),
                certificate(serial: visibleSerial)
            ],
            fetchedAt: Date()
        )

        let visible = inventory.filteringDismissedCertificates()

        #expect(visible.certificates.map(\.serialNumber) == [visibleSerial])
    }

    private func certificate(serial: String) -> ApplePortalCertificateSnapshot {
        ApplePortalCertificateSnapshot(
            serialNumber: serial,
            machineName: "Apple Development",
            machineIdentifier: nil,
            hasLocalPrivateKey: false,
            expirationDate: nil
        )
    }
}
