import Foundation
import Testing
@testable import Seal

struct PhonePairingPresentationPolicyTests {
    @Test
    func iOS27UsesPhoneOnlyAcquisitionWithoutDesktopFallback() {
        let policy = PhonePairingPresentationPolicy(majorOSVersion: 27)

        #expect(policy.usesPhonePairing)
        #expect(policy.showsDesktopAssistant == false)
        #expect(policy.showsPairingFileImport == false)
    }

    @Test
    func preIOS27KeepsExistingDesktopAcquisition() {
        let policy = PhonePairingPresentationPolicy(majorOSVersion: 26)

        #expect(policy.usesPhonePairing == false)
        #expect(policy.showsDesktopAssistant)
        #expect(policy.showsPairingFileImport)
    }

    @Test
    func laterSystemsKeepThePhoneOnlyPath() {
        let policy = PhonePairingPresentationPolicy(majorOSVersion: 28)

        #expect(policy.usesPhonePairing)
        #expect(policy.showsDesktopAssistant == false)
        #expect(policy.showsPairingFileImport == false)
    }
}
