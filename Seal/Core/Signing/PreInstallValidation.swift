import Foundation

/// 安装前三入口共用的校验。
///
/// 三条安装路径此前各查各的、覆盖面完全不同：
/// - 手动安装（`SigningCoordinator.installSignedArtifact`）**只查主 target**；
/// - 自动缓存复用（`installCachedSignedIPAIfPossible`）**完全不查 target 明细**，
///   只比对主 Bundle ID 与设备标识，且序列号是直接字符串比对（未归一化）；
/// - 新签名直装只做包结构校验（`SignedArtifactValidator`）。
///
/// 于是「主 profile 有效、扩展 profile 已过期或不含本设备」的包能一路走到设备端才失败，
/// 而设备端只回一个 `ApplicationVerificationFailed` 之类的模糊错误 —— 用户拿不到可执行的原因。
///
/// 本校验是**纯函数**：只读签名记录，不碰网络、不碰文件系统，便于逐条构造用例。
enum PreInstallValidation {
    enum Outcome: Equatable {
        case ok
        case rejected(ImportFailure)
    }

    /// 校验签名记录是否足以支撑一次安装。
    ///
    /// - Parameters:
    ///   - bundleIdentifier: 本次要安装的主 Bundle ID（已按包内回读值校正）。
    ///   - deviceIdentifier: 当前设备标识（来自安装通道）。
    ///   - accountTeamID: 所选账号的 Team；传 nil 表示本次不核对 Team。
    ///   - certificateSerialNumber: 本次使用的证书序列号；传 nil 表示本次不核对证书。
    static func validate(
        app: AppRecord,
        bundleIdentifier: String,
        deviceIdentifier: String,
        accountTeamID: String?,
        certificateSerialNumber: String?,
        now: Date = Date()
    ) -> Outcome {
        // ① Bundle ID 记录必须完整且格式合法
        guard BundleIDPolicy.validationError(for: bundleIdentifier) == nil else {
            return .rejected(failure(
                reason: "本机签名包的 Bundle ID 记录不完整或格式无效。",
                code: "SEAL-INSTALL-716"
            ))
        }

        let targets = app.signingTargets

        // ② 老记录可能没有 target 明细，此时按设备标识兜底核对 ——
        //    不能直接判死，否则升级前签好的包会全部装不上。
        guard targets.isEmpty == false else {
            guard let signedDeviceIdentifier = app.signedDeviceIdentifier else {
                return .rejected(failure(
                    reason: "本机签名包缺少描述文件与设备记录，无法确认它能在当前设备安装。",
                    code: "SEAL-INSTALL-721"
                ))
            }
            guard signedDeviceIdentifier.caseInsensitiveCompare(deviceIdentifier) == .orderedSame else {
                return .rejected(failure(
                    reason: "当前设备不在此签名包使用的设备记录中。",
                    code: "SEAL-INSTALL-714a"
                ))
            }
            return .ok
        }

        // ③ 主 target 必须存在，否则「查了扩展却漏了主程序」这种错配会被放过
        guard targets.contains(where: {
            $0.bundleIdentifier.caseInsensitiveCompare(bundleIdentifier) == .orderedSame
        }) else {
            return .rejected(failure(
                reason: "本机签名包的主 target 记录与安装目标不一致。",
                code: "SEAL-INSTALL-722"
            ))
        }

        let expectedSerial = certificateSerialNumber.map(
            SigningCertificateSelectionPolicy.normalizedSerialNumber
        )

        // ④ **逐个 target** 核对：主程序与每个扩展都必须自己有效。
        //    §4 明确要求「主 profile 有效但扩展过期，必须安装前发现」。
        for target in targets {
            let name = target.bundleIdentifier.caseInsensitiveCompare(bundleIdentifier) == .orderedSame
                ? "主程序"
                : "扩展（\(target.bundleIdentifier)）"

            guard target.profileExpirationDate > now else {
                return .rejected(failure(
                    reason: "\(name)的描述文件已经过期，装上去会被 iOS 判为「尚未验证」而闪退。",
                    code: "SEAL-INSTALL-713"
                ))
            }
            guard target.deviceIdentifiers.contains(where: {
                $0.caseInsensitiveCompare(deviceIdentifier) == .orderedSame
            }) else {
                return .rejected(failure(
                    reason: "\(name)的描述文件不包含当前设备。",
                    code: "SEAL-INSTALL-714"
                ))
            }
            if let accountTeamID, accountTeamID.isEmpty == false,
               target.teamIdentifier.caseInsensitiveCompare(accountTeamID) != .orderedSame {
                return .rejected(failure(
                    reason: "\(name)的描述文件 Team 与所选账号不一致。",
                    code: "SEAL-INSTALL-717"
                ))
            }
            if let expectedSerial {
                // 跨来源比对必须归一化（去前导零），否则「同一张证书」会被判成不同
                let serials = Set(target.certificateSerialNumbers.map(
                    SigningCertificateSelectionPolicy.normalizedSerialNumber
                ))
                guard serials.contains(expectedSerial) else {
                    return .rejected(failure(
                        reason: "\(name)的描述文件不包含本次使用的签名证书。",
                        code: "SEAL-INSTALL-718"
                    ))
                }
            }
        }

        return .ok
    }

    /// 拒绝原因对应的签名产物状态，供列表页显示。
    /// 装不上的原因不同，用户该做的事也不同：设备不可用要换设备/重签，文件损坏要重签。
    static func artifactStatus(forCode code: String) -> SignedArtifactStatus {
        switch code {
        case "SEAL-INSTALL-713":
            return .expired
        case "SEAL-INSTALL-714", "SEAL-INSTALL-714a":
            return .deviceUnavailable
        default:
            return .damaged
        }
    }

    private static func failure(reason: String, code: String) -> ImportFailure {
        ImportFailure(
            title: "安装前验证失败",
            reason: reason,
            recovery: "重新签名后再安装",
            code: code
        )
    }
}
