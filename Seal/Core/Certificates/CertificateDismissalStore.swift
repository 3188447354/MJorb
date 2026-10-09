import Foundation

/// 已撤销/隐藏证书序列号的共享持久化存储。
/// Infrastructure（签名轮换）与 Features（设置页）共用，确保撤销的证书不因 Apple 列表延迟而重现。
enum CertificateDismissalStore {
    private static let key = "seal.dismissedCertificateSerials"

    /// 持久化 dismissal 一个证书序列号（归一化后存入）。
    static func dismiss(serialNumber: String) {
        let normalized = SigningCertificateSelectionPolicy.normalizedSerialNumber(serialNumber)
        var dismissed = UserDefaults.standard.stringArray(forKey: key) ?? []
        if dismissed.contains(normalized) == false {
            dismissed.append(normalized)
            UserDefaults.standard.set(dismissed, forKey: key)
        }
    }

    /// 批量 dismissal。
    static func dismiss(serialNumbers: [String]) {
        for serial in serialNumbers {
            dismiss(serialNumber: serial)
        }
    }

    /// 是否已被 dismissal。
    static func isDismissed(serialNumber: String) -> Bool {
        let normalized = SigningCertificateSelectionPolicy.normalizedSerialNumber(serialNumber)
        let dismissed = UserDefaults.standard.stringArray(forKey: key) ?? []
        return dismissed.contains(normalized)
    }
}
