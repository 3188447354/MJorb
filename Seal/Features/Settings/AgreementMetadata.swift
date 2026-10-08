import Foundation

/// 协议元数据：生效日期、版本号统一在这里，不要在多个 View 里手写。
enum AgreementMetadata {
    /// 隐私政策
    enum Privacy {
        static let version = 1
        static let effectiveDate = "2026.10.07"
        static let title = "隐私政策"
    }

    /// 用户协议
    enum Terms {
        static let version = 1
        static let effectiveDate = "2026.10.07"
        static let title = "用户协议"
    }
}
