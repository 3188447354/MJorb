import Foundation

/// 证书轮换的「不得自动撤销」闸门。
///
/// 🔴 **自动撤销「运行中 Seal 正在用」的证书 = 把 Seal 变砖**（2026-09-26，构建 46 真机）。
///
/// 撤销之后 Seal 只能靠本事务末尾的**自替换安装**恢复，而那一步失败 Seal 当场打不开
/// （构建 38 就是这样变砖的：撤销 `…3DC8D5F3` 后自替换没落盘）。
/// 构建 46 的日志把同一条链路完整重演了一遍 —— 用户报的「签名续签链路你弄坏了」正是它：
///
/// ```
/// 01:24:32  证书检查：远端 1 张，本机有私钥 0 张，可复用 0 张；Seal 在用但无私钥 1 张
/// 01:24:37  证书轮换：撤销 …442EB5AF，原因=无本机私钥，运行中Seal=是
/// 01:24:44  重签 Seal → 开始自替换安装
/// 01:24:50  3 秒内进程仍存活（转场未生效），强制 exit(0)
/// 01:25:30  SEAL-SELF-109  Seal 自更新中止
/// 01:25:52  准备签名：Guoguo          ← 证书轮换的自动恢复
/// ```
///
/// 上游 SideStore 的 `CertificateProvisioningFlow` 里**撤销必须经用户确认**
/// （`replaceCertificate` 分支；`CertificateProvisioningFlow.swift:142-187`）——
/// 它没有任何一条「静默撤掉自己在用的证书」的路径。
///
/// 本仓**没有**「撤销 Seal 自己的证书」这个确认入口（`SEAL-CERT-204e` 的一键流程
/// `revokeKeylessCertificatesAfterConfirmation` 会**跳过** Seal 的证书，见
/// `sealProtectedSerials`），所以这里的选择是**不做**：把运行中 Seal 的证书从候选里剔除。
///
/// - 还有别的候选 ⇒ 照常轮换（Seal 的证书本来也排在最后，`rotationRank` 最高）；
/// - 剔除后为空 ⇒ 调用方 `throw` 回原始 `SEAL-CERT-204b`（名额满），
///   交回既有的自动清理 / `SEAL-CERT-204e` 用户确认路径 —— 那条路径同样跳过 Seal 的证书，
///   所以**绝不会静默把 Seal 弄坏**。
///
/// ⚠️ 抽成纯函数是为了可单测：真机复现「撤销运行中 Seal 的证书」需要免费账号
/// ＋ 丢失本机私钥 ＋ 撞 3022 三个条件同时成立，构造不出来。
enum SigningCertificateRotationGate {
    /// 剔除「运行中 Seal 正在使用」的证书候选。
    ///
    /// - Parameter isSigningSeal: 本轮是否在签 / 续签 **Seal 自身**。
    ///   自身续签时撤自己的证书是本事务**设计内**的一步（末尾会以新证书重新安装），
    ///   保持原行为 —— 它由 `sealSignerConfirmed`（读不出运行身份就整体拒绝轮换）单独守。
    static func candidatesExcludingRunningSealCertificate(
        candidates: [SigningCertificateRotationCandidate],
        isSigningSeal: Bool
    ) -> [SigningCertificateRotationCandidate] {
        guard isSigningSeal == false else { return candidates }
        return candidates.filter { $0.isRunningSealCertificate == false }
    }
}
