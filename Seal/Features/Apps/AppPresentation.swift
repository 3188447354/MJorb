import Foundation

enum AppValidityTone: Equatable, Sendable {
    case success
    case neutral
    case warning
    case danger
}

struct AppValidityPresentation: Equatable, Sendable {
    let text: String
    let detailText: String
    let tone: AppValidityTone
}

enum AppOperationKind: Equatable, Sendable {
    case signing
    case renewal
    case urgentRenewal
    case expiredRenewal
}

struct AppOperationPresentation: Equatable, Sendable {
    let kind: AppOperationKind
    let validity: AppValidityPresentation?

    init(app: AppRecord, now: Date = Date()) {
        guard app.belongsInInstalledList, let expiryDate = app.expiryDate else {
            kind = .signing
            validity = nil
            return
        }

        let interval = expiryDate.timeIntervalSince(now)
        guard interval > 0 else {
            kind = .expiredRenewal
            validity = AppValidityPresentation(text: "已过期", detailText: "已过期", tone: .danger)
            return
        }

        if interval < 86_400 {
            kind = .urgentRenewal
            let hours = max(1, Int(interval / 3_600))
            validity = AppValidityPresentation(text: "\(hours)小时", detailText: "\(hours)小时", tone: .danger)
            return
        }

        let days = max(1, Int(interval / 86_400))
        kind = days <= 3 ? .urgentRenewal : .renewal
        validity = AppValidityPresentation(
            text: "\(days)天",
            detailText: "\(days)天",
            // 充裕期（>3天）用中性陈述，不使用 success 绿色：剩余可续签天数不是一种“成功”，
            // success 语义保留给证书校验可用（CertificateValidationStatus.available）。
            tone: days <= 3 ? .warning : .neutral
        )
    }

    var sheetTitle: String { primaryAction }

    var primaryAction: String {
        switch kind {
        case .signing: "签名并安装"
        // 入口尚未完成身份核验，不能预告一定会安装新 IPA。
        case .renewal, .urgentRenewal, .expiredRenewal: "续签"
        }
    }
}

enum AppImportTimeFormatter {
    static func string(
        from date: Date,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        let time = shared.dateFormat("HH:mm", calendar: calendar).string(from: date)
        if calendar.isDate(date, inSameDayAs: now) {
            return "今天 \(time)"
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return "昨天 \(time)"
        }
        return shared.dateFormat("M月d日 HH:mm", calendar: calendar).string(from: date)
    }

    /// `DateFormatter` 的构造代价是毫秒级，而这个函数在**每一行的 body 里**被调用
    /// （`ImportedAppRow` 的时间行与无障碍标签），批量续签期间每个进度 tick 都会重算全部行。
    /// 缓存按「格式 + 时区」为键：时区变了必须换实例，否则结果整体偏移。
    private static let shared = DateFormatCache()
}

/// 线程安全的 `DateFormatter` 缓存（键：格式 + 时区标识 + locale）。
private final class DateFormatCache: @unchecked Sendable {
    private let lock = NSLock()
    private var cache: [String: DateFormatter] = [:]

    func dateFormat(_ format: String, calendar: Calendar) -> DateFormatter {
        let key = "\(format)|\(calendar.timeZone.identifier)|\(calendar.identifier)"
        lock.lock()
        if let cached = cache[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = format

        lock.lock()
        // 两个调用方同时构造同一格式时，保留先写入的那个，避免同一 key 存两个实例。
        defer { lock.unlock() }
        if let existing = cache[key] { return existing }
        cache[key] = formatter
        return formatter
    }
}


enum ProfileDisplayStatus: Equatable, Sendable {
    case available
    case expiringSoon
    case expired
    case mismatch
    case pendingValidation
    case missing

    var title: String {
        switch self {
        case .available: "可用"
        case .expiringSoon: "临期"
        case .expired: "已过期"
        case .mismatch: "不匹配"
        case .pendingValidation: "待校验"
        case .missing: "未记录"
        }
    }

    var tone: AppValidityTone {
        switch self {
        case .available: .success
        case .expiringSoon: .warning
        case .expired, .mismatch: .danger
        case .pendingValidation, .missing: .neutral
        }
    }
}

enum AppSigningPresentationHelpers {
    static let renewNowAction = "立即续签"
    /// 签名 / 续签进行中的统一提示：**Seal 自续签与普通 App 同文案**。
    /// 整条链路由 Seal 自己申请后台保活，用户只要不锁屏、不切走即可；
    /// Seal 自续签的「退回主屏幕」由 Seal 自己完成，不再要求用户手按 Home。
    static let keepSealOpenTip = "请保持 Seal 打开，不要锁屏或切换 App。"
    /// Seal 自续签进入安装阶段（上传完成）后的提示。此时 Seal 会自动触发系统级
    /// 回主屏转场，让 iOS 用新版替换旧进程。文案提前说清楚，避免界面瞬间消失被误读成闪退。
    static let sealReturningHomeTip = "正在退回主屏幕，iOS 会用新版替换 Seal；替换完成后重新打开即可。"

    /// 证书序列号展示值：完整序列号（只留十六进制、转大写、不截断）。
    /// 行标题固定为「证书序列号」，因此这里不再重复「序列号 · 」前缀。
    static func certificateSerialText(serial: String?) -> String {
        guard let serial, serial.isEmpty == false else { return "签名时创建" }
        return fullSerial(serial)
    }

    static func fullSerial(_ value: String) -> String {
        let normalized = value.filter(\.isHexDigit).uppercased()
        return normalized.isEmpty ? value : normalized
    }

    /// 该应用**实际使用**的描述文件 UUID（独立于状态文案，供「描述文件」行独占一行展示）。
    /// 优先取顶层记录（安装确认后回写的真实 profile），顶层缺失时回退到签名 target，
    /// 主 target 优先于扩展 target —— 与「描述文件」行语义一致：这是主应用的 profile。
    static func profileUUIDText(for app: AppRecord) -> String {
        if let uuid = app.provisioningProfileUUID, uuid.isEmpty == false {
            return uuid
        }
        let targets = app.signingTargets
        let main = targets.first { target in
            guard let mapped = app.mappedBundleIdentifier else { return false }
            return target.bundleIdentifier.caseInsensitiveCompare(mapped) == .orderedSame
        }
        if let uuid = (main ?? targets.first)?.profileUUID, uuid.isEmpty == false {
            return uuid
        }
        return "未记录"
    }

    /// 描述文件创建时间：证明「这次续签真的换了一份本轮新生成的 profile」，
    /// 而不是沿用了旧文件（同版本续签只靠有效期看不出来，见 R07）。
    static func profileCreationDate(for app: AppRecord) -> Date? {
        if let date = app.provisioningProfileCreationDate { return date }
        let targets = app.signingTargets
        let main = targets.first { target in
            guard let mapped = app.mappedBundleIdentifier else { return false }
            return target.bundleIdentifier.caseInsensitiveCompare(mapped) == .orderedSame
        }
        return (main ?? targets.first)?.profileCreationDate
    }

    static func profileStatus(for app: AppRecord, now: Date = Date()) -> ProfileDisplayStatus {
        guard let expiration = app.provisioningProfileExpirationDate ?? app.expiryDate else {
            return app.belongsInInstalledList ? .missing : .pendingValidation
        }
        guard expiration > now else { return .expired }

        if let teamID = app.signingTeamID,
           app.signingTargets.isEmpty == false {
            let hasMatchingTeam = app.signingTargets.contains { target in
                target.teamIdentifier.caseInsensitiveCompare(teamID) == .orderedSame
            }
            if hasMatchingTeam == false { return .mismatch }
        }

        if let signedBundleID = app.mappedBundleIdentifier ?? app.preferredBundleIdentifier,
           app.signingTargets.isEmpty == false {
            let hasMatchingBundleID = app.signingTargets.contains { target in
                target.bundleIdentifier.caseInsensitiveCompare(signedBundleID) == .orderedSame
            }
            if hasMatchingBundleID == false { return .mismatch }
        }

        if let serial = app.certificateSerialNumber, serial.isEmpty == false,
           app.signingTargets.isEmpty == false {
            let expected = SigningCertificateSelectionPolicy.normalizedSerialNumber(serial)
            let hasMatchingCertificate = app.signingTargets.contains { target in
                target.certificateSerialNumbers.contains { value in
                    SigningCertificateSelectionPolicy.normalizedSerialNumber(value) == expected
                }
            }
            if hasMatchingCertificate == false { return .mismatch }
        }

        if let deviceID = app.signedDeviceIdentifier, deviceID.isEmpty == false,
           app.signingTargets.isEmpty == false {
            let hasMatchingDevice = app.signingTargets.contains { target in
                target.deviceIdentifiers.contains { $0.caseInsensitiveCompare(deviceID) == .orderedSame }
            }
            if hasMatchingDevice == false { return .mismatch }
        }

        if expiration.timeIntervalSince(now) <= 4 * 86_400 { return .expiringSoon }
        return .available
    }

    static func profileExpirationDate(for app: AppRecord) -> Date? {
        app.provisioningProfileExpirationDate ?? app.expiryDate
    }
}
