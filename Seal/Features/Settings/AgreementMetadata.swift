import Foundation

/// 协议元数据：生效日期、标题统一在这里，不要在多个 View 里手写。
/// 注意：版本号只有一个源 —— AgreementVersion.current（AgreementOnboardingView.swift），
/// 它是"是否重新弹同意页"的门禁。这里不放 version，避免改错地方导致用户收不到重新同意。
enum AgreementMetadata {
    /// 隐私政策
    enum Privacy {
        static let effectiveDate = "2026.10.07"
        static let title = "隐私政策"
    }

    /// 用户协议
    enum Terms {
        static let effectiveDate = "2026.10.07"
        static let title = "用户协议"
    }
}
