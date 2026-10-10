import Foundation

/// 源码已经确认的失败事实。未知状态不允许伪装成具体问题。
enum FailureCondition: String, Codable, Equatable, Sendable {
    case appleServiceUnavailable
    case appleRateLimited
    case credentialsRejected
    case verificationCodeRejected
    case twoFactorAuthenticationRequired
    case signingAccountUnavailable
    case accountVerificationRequired
    case recordedSigningIdentityUnavailable
    case fullResignRequired
    case pairingRequired
    case deviceTrustRequired
    case tunnelUnavailable
    case deviceStorageFull
    case deviceAppLimitReached
    case installationStillRunning
    case signedArtifactInvalid
    case localStorageWriteFailed
    case logServiceUnavailable
    case logExportFileInvalid
    case unexpected
}

/// 一条失败最多提供一个主要用户动作，防止界面层组合出猜测式指引。
enum FailureAction: String, Codable, Equatable, Sendable {
    case retry
    case waitThenRetry
    case addAccount
    case reauthenticateAccount
    case enterNewVerificationCode
    case fullResign
    case repairPairing
    case trustDevice
    case openLocalDevVPN
    case freeDeviceStorage
    case removeInstalledApp
    case checkInstallationResult
    case reinstallFromSignedArtifact
    case reimportIPA
    case restartSeal
    case copyDiagnostics
}

/// 失败所属操作，仅用于审计、测试和诊断关联，不能用于改写用户动作。
enum FailureOperation: String, Codable, Equatable, Sendable {
    case sign
    case renew
    case batchRenew
    case authenticateAccount
    case validateAccount
    case install
    case importIPA
    case exportLog
    case unknown
}

/// 原始错误首次被分类的边界。
enum FailureOrigin: String, Codable, Equatable, Sendable {
    case authentication
    case applePortal
    case provisioning
    case signing
    case deviceChannel
    case installer
    case fileStore
    case logStore
    case unknown
}

/// 核心领域的导航意图。SwiftUI 将其单向映射为具体页面，核心层不得引用 Features。
enum FailureRoute: String, Codable, Equatable, Sendable {
    case account
    case certificates
    case pairing
    case localDevVPN
}

/// 重试所有权，防止不同入口各自根据错误码前缀猜测是否可重试。
enum FailureRetryDisposition: String, Codable, Equatable, Sendable {
    case none
    case automatic
    case manual
    case waitForInFlightWork
}
