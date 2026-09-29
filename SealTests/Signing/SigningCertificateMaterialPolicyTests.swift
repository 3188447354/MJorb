import Foundation
import Testing
@testable import Seal

struct SigningCertificateMaterialPolicyTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test
    func externalSealCanEstablishNewIdentityOnlyForItsRunningTeam() {
        #expect(SigningCertificateMaterialPolicy.externalSealSerial(
            isSeal: true, teamID: "TEAM", runningTeamID: "TEAM", runningSerials: ["0AA11"], remoteSerials: ["AA11"], localPrivateKeySerials: [], expectedSerialNumber: "AA11"
        ) == "AA11")
        #expect(SigningCertificateMaterialPolicy.externalSealSerial(
            isSeal: true, teamID: "TEAM", runningTeamID: "TEAM", runningSerials: ["AA11"], remoteSerials: ["AA11", "BB22"], localPrivateKeySerials: [], expectedSerialNumber: "BB22"
        ) == nil)
        #expect(SigningCertificateMaterialPolicy.externalSealSerial(
            isSeal: true, teamID: "TEAM", runningTeamID: "TEAM", runningSerials: ["0AA11"], remoteSerials: ["AA11"], localPrivateKeySerials: []
        ) == "AA11")
        #expect(SigningCertificateMaterialPolicy.externalSealSerial(
            isSeal: false, teamID: "TEAM", runningTeamID: "TEAM", runningSerials: ["AA11"], remoteSerials: ["AA11"], localPrivateKeySerials: []
        ) == nil)
        #expect(SigningCertificateMaterialPolicy.externalSealSerial(
            isSeal: true, teamID: "OTHER", runningTeamID: "TEAM", runningSerials: ["AA11"], remoteSerials: ["AA11"], localPrivateKeySerials: []
        ) == nil)
        #expect(SigningCertificateMaterialPolicy.externalSealSerial(
            isSeal: true, teamID: "TEAM", runningTeamID: "TEAM", runningSerials: ["AA11"], remoteSerials: ["AA11"], localPrivateKeySerials: ["0AA11"]
        ) == nil)
        #expect(SigningCertificateMaterialPolicy.externalSealSerial(
            isSeal: true, teamID: "TEAM", runningTeamID: "TEAM", runningSerials: [], remoteSerials: ["AA11"], localPrivateKeySerials: []
        ) == nil)
    }

    @Test
    func lifetimeMustCoverAnEntireNewProfile() {
        let minimum = SigningCertificateMaterialPolicy.minimumRemainingLifetime
        #expect(SigningCertificateMaterialPolicy.reuseStatus(validity: nil, now: now) == .invalidValidity)
        #expect(SigningCertificateMaterialPolicy.reuseStatus(
            validity: X509CertificateValidity(notBefore: now.addingTimeInterval(-100), notAfter: now.addingTimeInterval(minimum)), now: now
        ) == .insufficientLifetime)
        #expect(SigningCertificateMaterialPolicy.reuseStatus(
            validity: X509CertificateValidity(notBefore: now.addingTimeInterval(-100), notAfter: now.addingTimeInterval(minimum + 1)), now: now
        ) == .reusable)
        #expect(SigningCertificateMaterialPolicy.reuseStatus(
            validity: X509CertificateValidity(notBefore: now.addingTimeInterval(100), notAfter: now.addingTimeInterval(minimum + 1000)), now: now
        ) == .invalidValidity)
    }

    /// 快速路径列表命中支：serial 在生效列表 && 剩余寿命 ≥ 7 天才复用（序列号归一化去前导零）。
    @Test
    func fastPathReusesOnlyWhenSerialIsInActiveListAndLifetimeCoversProfile() {
        #expect(SigningCertificateMaterialPolicy.fastPathReuseDecision(
            remoteSerials: ["0AA11", "BB22"], targetSerialNumber: "AA11", reuseStatus: .reusable
        ) == .reuseFromActiveList)
        // 列表里没有目标 serial ⇒ 落慢速路径（不能拿一张没备案的证书配新描述文件）。
        #expect(SigningCertificateMaterialPolicy.fastPathReuseDecision(
            remoteSerials: ["CC33"], targetSerialNumber: "AA11", reuseStatus: .reusable
        ) == .fallThroughToSlowPath)
    }

    /// 列表命中支的 7 天门槛：serial 在列表但寿命不足/日期无效，仍不得复用。
    @Test
    func fastPathListHitStillRequiresFullLifetime() {
        #expect(SigningCertificateMaterialPolicy.fastPathReuseDecision(
            remoteSerials: ["AA11"], targetSerialNumber: "AA11", reuseStatus: .insufficientLifetime
        ) == .fallThroughToSlowPath)
        #expect(SigningCertificateMaterialPolicy.fastPathReuseDecision(
            remoteSerials: ["AA11"], targetSerialNumber: "AA11", reuseStatus: .invalidValidity
        ) == .fallThroughToSlowPath)
    }

    /// 网络回退支：列表拉取失败（remoteSerials == nil），只要本地过 7 天校验就回退复用，
    /// 否则落慢速路径 —— 免费账号临近到期的证书丢给 iOS 会判「尚未验证」闪退。
    @Test
    func fastPathNetworkFallbackStillPassesThroughLifetimeGate() {
        #expect(SigningCertificateMaterialPolicy.fastPathReuseDecision(
            remoteSerials: nil, targetSerialNumber: "AA11", reuseStatus: .reusable
        ) == .reuseLocalWithoutList)
        #expect(SigningCertificateMaterialPolicy.fastPathReuseDecision(
            remoteSerials: nil, targetSerialNumber: "AA11", reuseStatus: .insufficientLifetime
        ) == .fallThroughToSlowPath)
    }

    /// 空列表也视作「不在生效列表」⇒ 落慢速路径，不能拿空列表当网络回退。
    @Test
    func fastPathEmptyListIsNotAFallback() {
        #expect(SigningCertificateMaterialPolicy.fastPathReuseDecision(
            remoteSerials: [], targetSerialNumber: "AA11", reuseStatus: .reusable
        ) == .fallThroughToSlowPath)
    }

    @Test
    func capacityRecoveryRotatesOnlyCertificatesThatCannotCoverANewProfile() {
        let candidates = SigningCertificateMaterialPolicy.rotationCandidates(
            remoteSerialNumbers: ["0AA11", "BB22", "CC33", "DD44"],
            reuseStatusBySerial: [
                "AA11": .reusable,
                "BB22": .insufficientLifetime,
                "CC33": .invalidValidity
            ],
            runningSealSerialNumbers: ["0DD44"]
        )

        #expect(candidates.map(\.serialNumber) == ["CC33", "BB22", "DD44"])
        #expect(candidates.map(\.reason) == [.invalidValidity, .insufficientLifetime, .missingPrivateKey])
    }

    @Test
    func capacityRecoveryKeepsRunningSealCertificateUntilLast() {
        let candidates = SigningCertificateMaterialPolicy.rotationCandidates(
            remoteSerialNumbers: ["SEAL", "ORPHAN"],
            reuseStatusBySerial: [:],
            runningSealSerialNumbers: ["0SEAL"]
        )

        #expect(candidates.map(\.serialNumber) == ["ORPHAN", "SEAL"])
        #expect(candidates.last?.isRunningSealCertificate == true)
    }

    @Test
    func capacityRecoveryStillOffersTheRunningSealCertificateWhenItIsTheOnlyOne() {
        // 🔴 免费团队只有一个活动槽位，而 Seal 自己的证书在覆盖安装后必然丢失本机私钥
        // ⇒ 若把它从候选里剔除，账号就**永久**建不出新证书：构建 47 真机实测，
        // 签任何 App / 续签任何 App 都报 `SEAL-CERT-204b`（3022 名额满），用户「啥也干不了」。
        // ⇒ 它必须**仍在候选里**，只是排在最后（撤销后的恢复由证书轮换子流程负责）。
        let candidates = SigningCertificateMaterialPolicy.rotationCandidates(
            remoteSerialNumbers: ["SEAL"],
            reuseStatusBySerial: [:],
            runningSealSerialNumbers: ["0SEAL"]
        )

        #expect(candidates.isEmpty == false)
        #expect(candidates.map(\.serialNumber) == ["SEAL"])
        #expect(candidates.last?.isRunningSealCertificate == true)
    }

    @Test
    func missingOrCorruptP12DoesNotCountAsLocalPrivateKey() {
        var secret = AccountSecret(email: "test@example.invalid", accountIdentifier: "test", dsid: "test", authToken: "test", password: nil)
        #expect(SigningCertificateMaterialPolicy.availableCertificate(secret: secret, serialNumber: "AA11") == nil)
        secret.storeCertificateMaterial(p12: Data([0, 1, 2]), serialNumber: "AA11", machineIdentifier: nil)
        #expect(SigningCertificateMaterialPolicy.availableCertificate(secret: secret, serialNumber: "0AA11") == nil)
    }

    @Test
    func reauthenticationPreservesHistoricalSigningMaterial() {
        var old = AccountSecret(email: "test@example.invalid", accountIdentifier: "test", dsid: "old", authToken: "old", password: nil)
        old.storeCertificateMaterial(p12: Data([1]), serialNumber: "AA11", machineIdentifier: "a")
        old.storeCertificateMaterial(p12: Data([2]), serialNumber: "BB22", machineIdentifier: "b")
        let authenticated = AccountSecret(email: "test@example.invalid", accountIdentifier: "test", dsid: "new", authToken: "new", password: nil)
        let merged = authenticated.preservingSigningMaterial(from: old)
        #expect(merged.authToken == "new")
        #expect(merged.p12(for: "0AA11") == Data([1]))
        #expect(merged.p12(for: "BB22") == Data([2]))
        #expect(merged.machineIdentifier(for: "AA11") == "a")
        let other = AccountSecret(email: "other@example.invalid", accountIdentifier: "other", dsid: "new", authToken: "new", password: nil)
        #expect(other.preservingSigningMaterial(from: old).certificateP12BySerial.isEmpty)
    }
}
