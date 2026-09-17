import Foundation
import UIKit
@preconcurrency import AltSign

struct CreatedCertificateMaterial: Sendable {
    let updatedSecret: AccountSecret
    let serialNumber: String
    let machineIdentifier: String?
    let machineName: String
}

actor ApplePortalCertificateService {
    private let anisetteProvider: any AnisetteProvider

    init(anisetteProvider: any AnisetteProvider = AnisetteV3Client()) {
        self.anisetteProvider = anisetteProvider
    }

    func createLocalCertificate(
        account: AppleAccountRecord,
        secret: AccountSecret
    ) async throws -> CreatedCertificateMaterial {
        do {
            return try await createOnce(account: account, secret: secret)
        } catch ALTAppleAPIError.invalidAnisetteData {
            await anisetteProvider.resetProvisioning()
            return try await createOnce(account: account, secret: secret)
        }
    }

    func revokeCertificate(
        serialNumber: String,
        account: AppleAccountRecord,
        secret: AccountSecret
    ) async throws {
        do {
            try await revokeOnce(
                serialNumber: serialNumber,
                account: account,
                secret: secret
            )
        } catch ALTAppleAPIError.invalidAnisetteData {
            await anisetteProvider.resetProvisioning()
            try await revokeOnce(
                serialNumber: serialNumber,
                account: account,
                secret: secret
            )
        }
    }

    private func createOnce(
        account: AppleAccountRecord,
        secret: AccountSecret
    ) async throws -> CreatedCertificateMaterial {
        let context = try await context(account: account, secret: secret)
        let deviceName = await MainActor.run { UIDevice.current.name }

        let requested: ALTCertificate
        do {
            // ⚠️ **证书轮换路径的「创建证书」也必须过退避重试**（2026-09-17 补）。
            //
            // 它与 `ApplePortalSigningService` 的证书创建是**两条链路**，而「遇 1100 就退避」
            // 这条规则原先只落在签名那条上（本仓第 6 次「规则只覆盖一条链路」）。
            //
            // 为什么这条后果最严重：轮换的顺序是**先 revoke、再创建** ——
            // 撤销成功而创建失败（1100 被当成真过期、直接抛）会让这个账号变成 **0 张证书**，
            // 于是**用它签过的所有 App 立刻打不开**（不崩、不编译失败，只在真机上废掉一堆 App）。
            // 退避重试把「限流」和「真失败」分开：限流等几秒就好了。
            //
            // 判据与间隔**共用** `ApplePortalSigningService` 那一份（不在这里抄一遍）——
            // 两边漂移的话，同一个 1100 会在一条链路上重试、在另一条上直接失败。
            requested = try await withSessionRecovery("创建证书（证书轮换）") {
                try await addCertificate(
                    team: context.team,
                    session: context.session,
                    deviceName: deviceName
                )
            }
        } catch {
            if let failure = CertificateRequestFailurePolicy.requestFailure(error: error, limitCode: "SEAL-CERT-204") { throw failure }
            throw error
        }
        do {
            let refreshed = try await fetchCertificates(
                team: context.team,
                session: context.session
            )
            guard let certificate = refreshed.first(where: {
                $0.serialNumber.caseInsensitiveCompare(requested.serialNumber) == .orderedSame
            }) else {
                throw Self.failure(
                    title: "证书创建结果不一致",
                    reason: "Apple 已返回新证书，但重新同步后无法确认该证书。",
                    recovery: "重新同步证书",
                    code: "SEAL-CERT-209"
                )
            }

            let fullCert = ALTCertificate(x509: certificate, privateKey: requested.privateKey)
            guard let p12 = try? fullCert.unencryptedP12Data() else {
                throw Self.failure(
                    title: "无法保存本机证书",
                    reason: "Apple 已创建证书，但 Seal 无法将证书与本机私钥组成 P12。",
                    recovery: "重新同步后重试",
                    code: "SEAL-CERT-202"
                )
            }

            var updatedSecret = secret
            updatedSecret.storeCertificateMaterial(
                p12: p12,
                serialNumber: certificate.serialNumber,
                machineIdentifier: certificate.machineIdentifier
            )

            return CreatedCertificateMaterial(
                updatedSecret: updatedSecret,
                serialNumber: certificate.serialNumber,
                machineIdentifier: certificate.machineIdentifier,
                machineName: certificate.machineName ?? "Apple Development"
            )
        } catch {
            let cleanedUp = await cleanUpNewCertificate(
                serialNumber: requested.serialNumber,
                certificate: requested,
                team: context.team,
                session: context.session,
                account: account,
                secret: secret
            )
            guard cleanedUp else {
                throw Self.failure(
                    title: "证书清理未完成",
                    reason: "签名证书已创建，但后续处理失败；自动撤销该证书也失败，可能残留一个占用名额的证书。",
                    recovery: "请稍后重试",
                    code: "SEAL-CERT-215b"
                )
            }
            if let failure = error as? ImportFailure { throw failure }
            throw error
        }
    }

    private func cleanUpNewCertificate(
        serialNumber: String,
        certificate: ALTCertificate,
        team: ALTTeam,
        session: ALTAppleAPISession,
        account: AppleAccountRecord,
        secret: AccountSecret
    ) async -> Bool {
        if (try? await revoke(certificate.x509, team: team, session: session)) != nil {
            return true
        }
        await anisetteProvider.resetProvisioning()
        guard let refreshedContext = try? await context(account: account, secret: secret),
              let certificates = try? await fetchCertificates(
                  team: refreshedContext.team,
                  session: refreshedContext.session
              ) else {
            return false
        }
        guard let exactCertificate = certificates.first(where: {
            $0.serialNumber.caseInsensitiveCompare(serialNumber) == .orderedSame
        }) else {
            return true
        }
        return (try? await revoke(
            exactCertificate,
            team: refreshedContext.team,
            session: refreshedContext.session
        )) != nil
    }

    private func revokeOnce(
        serialNumber: String,
        account: AppleAccountRecord,
        secret: AccountSecret
    ) async throws {
        let context = try await context(account: account, secret: secret)
        let certificates = try await fetchCertificates(team: context.team, session: context.session)
        guard let certificate = certificates.first(where: {
            $0.serialNumber.caseInsensitiveCompare(serialNumber) == .orderedSame
        }) else {
            throw Self.failure(
                title: "证书撤销失败",
                reason: "在 Apple 服务器上未找到要撤销的证书（序列号 \(serialNumber)）。",
                recovery: "请在「我的」中重新同步证书状态后重试",
                code: "SEAL-CERT-210a"
            )
        }
        try await revoke(certificate, team: context.team, session: context.session)
    }

    private func context(
        account: AppleAccountRecord,
        secret: AccountSecret
    ) async throws -> (team: ALTTeam, session: ALTAppleAPISession) {
        let anisette = try await anisetteProvider.fetch()
        let session = ALTAppleAPISession(
            dsid: secret.dsid,
            authToken: secret.authToken,
            anisetteData: anisette,
            xcodeVersion: AppleAccountClient.xcodeVersion
        )
        let altAccount = ALTAccount()
        altAccount.appleID = secret.email
        altAccount.identifier = secret.accountIdentifier
        let teams = try await fetchTeams(account: altAccount, session: session)
        guard let team = teams.first(where: { $0.identifier == account.teamID }) else {
            throw Self.failure(
                title: "账号 Team 不一致",
                reason: "Apple 返回的团队列表中已找不到已保存的 Team ID。",
                recovery: "选择 Team",
                code: "SEAL-AUTH-112b"
            )
        }
        return (team, session)
    }

    private func fetchTeams(
        account: ALTAccount,
        session: ALTAppleAPISession
    ) async throws -> [ALTTeam] {
        let box: LegacyBox<[ALTTeam]> = try await withAppleTimeout {
            try await withCheckedThrowingContinuation {
                continuation in
                let callback = ContinuationBox(continuation)
                ALTAppleAPI.shared.fetchTeams(for: account, session: session) { teams, error in
                    Self.resume(callback, value: teams, error: error)
                }
            }
        }
        return box.value
    }

    private func fetchCertificates(
        team: ALTTeam,
        session: ALTAppleAPISession
    ) async throws -> [ALTX509Certificate] {
        let box: LegacyBox<[ALTX509Certificate]> = try await withAppleTimeout {
            try await withCheckedThrowingContinuation {
                continuation in
                let callback = ContinuationBox(continuation)
                ALTAppleAPI.shared.fetchCertificates(for: team, session: session) { certificates, error in
                    Self.resume(callback, value: certificates, error: error)
                }
            }
        }
        return box.value
    }

    private func addCertificate(
        team: ALTTeam,
        session: ALTAppleAPISession,
        deviceName: String
    ) async throws -> ALTCertificate {
        let box: LegacyBox<ALTCertificate> = try await withAppleTimeout {
            try await withCheckedThrowingContinuation {
                continuation in
                let callback = ContinuationBox(continuation)
                ALTAppleAPI.shared.addCertificate(
                    machineName: Self.certificateMachineName(deviceName: deviceName),
                    to: team,
                    session: session
                ) { certificate, error in
                    Self.resume(callback, value: certificate, error: error)
                }
            }
        }
        return box.value
    }

    private func revoke(
        _ certificate: ALTX509Certificate,
        team: ALTTeam,
        session: ALTAppleAPISession
    ) async throws {
        try await withAppleTimeout {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                let callback = ContinuationBox(continuation)
                ALTAppleAPI.shared.revoke(certificate, for: team, session: session) { success, error in
                    if success {
                        callback.resume()
                    } else {
                        callback.resume(throwing: error ?? URLError(.badServerResponse))
                    }
                }
            }
        }
    }

    /// 遇 Apple 1100（会话被掐断）时退避重试 —— 与 `ApplePortalSigningService` **共用判据与间隔**。
    ///
    /// 刻意只复用 `ApplePortalSigningService` 的两个成员，而**不是**把整段逻辑复制一份：
    /// 复制的部分迟早漂移（「同一条规则两份实现」在本仓已踩过 6 次，见技能）。
    /// 于是两边保证一致的是「**哪些错误值得重试**」（`isSessionExpiredError`）与
    /// 「**退避多久**」（`sessionRecoveryBackoffNanoseconds`）—— 这两项才是会漂移的东西。
    ///
    /// ⚠️ **已知的可观测性缺口**：本服务没有 `logStore`，所以重试**不会写日志**。
    /// 之所以还能接受：重试**成功**时结果本身可见（证书建出来了）；
    /// 重试**耗尽**时错误照旧向上抛，会变成 `SEAL-CERT-227` 那条「证书轮换失败」提示
    /// （已写明后果是「用这些证书签名的 App 现在无法启动」）⇒ 失败仍然看得出来。
    /// 要补日志得给它注入 `SealLogStore`（三个构造点都拿得到），属另一轮改动。
    private func withSessionRecovery<T>(
        _ label: String,
        operation: () async throws -> T
    ) async throws -> T {
        var lastError: Error?
        let delays: [UInt64] = [0] + ApplePortalSigningService.sessionRecoveryBackoffNanoseconds
        for delay in delays {
            if delay > 0 {
                try Task.checkCancellation()
                try await Task.sleep(nanoseconds: delay)
            }
            do {
                return try await operation()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                guard ApplePortalSigningService.isSessionExpiredError(error) else { throw error }
                lastError = error
            }
        }
        if let lastError { throw lastError }
        throw ALTAppleAPIError.unknown()
    }

    private static func certificateMachineName(deviceName: String) -> String {
        let sanitizedDevice = deviceName
            .filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
        let devicePart = sanitizedDevice.isEmpty ? "Device" : String(sanitizedDevice.prefix(18))
        return "Seal-\(devicePart)"
    }
    /// 与签名服务共用 ContinuationBox，防止 AltSign 重复或迟到回调导致二次 resume。
    private static func resume<T>(
        _ callback: ContinuationBox<LegacyBox<T>>,
        value: T?,
        error: Error?
    ) {
        if let value {
            callback.resume(returning: LegacyBox(value))
        } else {
            callback.resume(throwing: error ?? URLError(.badServerResponse))
        }
    }

    private static func failure(
        title: String,
        reason: String,
        recovery: String,
        code: String
    ) -> ImportFailure {
        ImportFailure(title: title, reason: reason, recovery: recovery, code: code)
    }
}
