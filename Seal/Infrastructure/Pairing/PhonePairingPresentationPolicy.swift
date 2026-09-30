import Foundation

/// iOS 27+ exposes Remote Pairing in Developer Mode, so pairing can begin on
/// the phone that will use the resulting credentials. Earlier systems retain
/// the existing desktop-file acquisition path.
struct PhonePairingPresentationPolicy: Equatable, Sendable {
    let majorOSVersion: Int

    init(majorOSVersion: Int) {
        self.majorOSVersion = majorOSVersion
    }

    var usesPhonePairing: Bool {
        majorOSVersion >= 27
    }

    var showsDesktopAssistant: Bool {
        usesPhonePairing == false
    }

    var showsPairingFileImport: Bool {
        usesPhonePairing == false
    }
}
