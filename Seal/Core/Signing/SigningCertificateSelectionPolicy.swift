import Foundation

enum SigningCertificateSelectionPolicy {
    static let teamMismatchTitle = "开发者团队不匹配"

    /// 「应用记录的绑定账号」与「本次所选账号」的关系 —— 让调用方能对**悬空回退**留痕。
    ///
    /// ⚠️ 刻意做成枚举而不是 `Bool`：「绑定的账号被删过（已按同 Team 放行）」与
    /// 「绑定账号还在（精确一致）」是两件**下一步动作完全不同**的事 —— 前者要留痕说明
    /// 「改用了同 Team 的哪个账号」，后者什么都不用说。
    enum AccountBinding: Equatable {
        /// 绑定账号与所选账号一致（或该应用不受这条校验约束）
        case consistent
        /// 绑定账号已**悬空**（账号被删过、又重新添加 ⇒ UUID 变了），已按同 Team 放行
        case recoveredFromDanglingBinding(previousAccountID: UUID)
        /// 记录里**从来没有**账号绑定 —— 设备端扫回的记录就是这样，已按同 Team 放行。
        ///
        /// 与 `.recoveredFromDanglingBinding` 是**同一族、不同成因**：那条是「UUID 指向一个
        /// 已经不在账号库里的账号」，这条是「压根没记过」。两者的**放行判据相同**
        /// （都交给同 `signingTeamID` 判据），但日志必须能分开 ——
        /// 前者说明用户删过 Apple ID，后者说明这条记录是设备端扫回来的（本地从未签过）。
        case recoveredFromMissingBinding
    }

    /// 校验「所选账号」有没有资格给这个应用续签。
    ///
    /// - Parameter knownAccountIDs: 账号库里**现存**账号的 ID 集合，用来判断
    ///   `app.accountID` 是不是**悬空引用**。
    ///   🔴 **必须传**（`SigningCoordinator` 传的就是它刚读到的账号库）。
    ///   传 `nil` 时按「绑定账号仍然存在」处理 ⇒ **保持旧行为（宁可拒绝）**，
    ///   这样漏改的调用点不会因此变危险。
    ///
    /// ## 为什么不能只比 UUID（2026-09-25 真机，构建 37 实证）
    ///
    /// 删 Apple ID → 重新添加会**生成新的账号 UUID**；而应用记录里存的还是旧 UUID
    /// （`SettingsViewModel.deleteAccount` 刻意保留绑定，防误用其他账号续签）。
    /// 裸的「UUID 直接相等」比较必然不等 ⇒ 抛 `SEAL-AUTH-111`「Apple ID 不匹配」，
    /// **连下面那句同 Team 比较都走不到**。
    ///
    /// 真机现象：删账号→重新添加之后，「**只有 Seal 自己能续签，其他应用一律报
    /// Apple ID 不匹配**」—— Seal 走上面 `isSeal` 那条分支（只比 Team、不比 UUID），
    /// 第三方应用才走到这里。
    ///
    /// ⇒ 这与 `RenewalAccountResolver`（守卫 R68）是**同一个「悬空引用」陷阱家族的第三处**：
    /// 解析器负责「**选哪个账号**」（它已用同 Team 回退选对了），这里负责
    /// 「**校验选得对不对**」，两处判据必须一致 —— 否则上游放行、下游又拦，等于没修。
    ///
    /// ## 判据
    ///
    /// - 绑定账号**仍在**账号库 ⇒ 这是真的「用了别的账号」⇒ **拒绝**（保护不丢）；
    /// - 绑定账号**已悬空** ⇒ 交给同 `signingTeamID` 判据：同 Team 放行（签名身份、
    ///   Keychain 访问组、App Group 都不变），换 Team 拒绝（`SEAL-AUTH-112`）；
    /// - 绑定账号**压根没有**（`nil`）⇒ 同上（交给同 Team 判据）。见下节。
    ///
    /// ## 第四种表现：`accountID` 压根没有（2026-09-25 真机，构建 43 实证）
    ///
    /// 上一节讲的是「UUID 指向一个已经不存在的账号」。这一节是「**从来没记过账号**」——
    /// 旧实现把它当成「无法自动续签」直接抛 `SEAL-AUTH-110`，而它其实是**合法状态**：
    ///
    /// `AppRecordRecovery.recoverRecordsFromDeviceProfiles` 扫回记录时按 Team 匹配账号
    /// （`accounts.first { $0.teamID == draft.teamIdentifier }?.id`），而**扫回恰好发生在
    /// 「配对成功之后、用户添加 Apple ID 之前」** ⇒ 那一刻账号库是空的 ⇒ `accountID` 写 `nil`。
    /// 之后导入覆盖更新会**如实继承**这个 `nil`
    /// （`ImportWorkflow.makeInstalledUpdateRecord` 传的就是 `existing.accountID`），
    /// 于是这条记录**永远**续签不了。
    ///
    /// 真机现象（构建 43）：重装 Seal → 扫回 2 个应用 → 导入 IPA 覆盖更新 → 点「立即续签」
    /// ⇒ **全部**报 `SEAL-AUTH-110`「缺少签名账号记录」；而**紧邻的上一条**日志正是
    /// `开始续签：Guoguo，Apple ID：sun***@gmail.com，Team：…` ——
    /// 说明 `RenewalAccountResolver` 已经按同 Team **成功解析出账号**（上游放行），
    /// 是**这里**又把它拦下了 ⇒ 又一次「上游放行、下游又拦，等于没修」。
    ///
    /// ⇒ 这与 `RenewalAccountResolver`（守卫 R68）／上一节的悬空 UUID（R70）是
    /// **同一个「悬空引用」陷阱家族的第四处**。判据不变：**决定签名身份的是
    /// `signingTeamID`，不是 `accountID`**。缺 `accountID` 不影响安全性 ——
    /// 同 Team 的账号签出来的是同一个签名身份，installd 覆盖的仍是设备上同一个 App。
    ///
    /// ⚠️ 放行的**前提**是 Team 判据仍然生效：既没有账号绑定、**又**没有 Team 时，
    /// 会落到下面的 `SEAL-AUTH-113`（缺少团队记录）⇒ 仍然拒绝 ✓。
    /// 续签成功后 `SigningCoordinator.applySigningResult` 会把 `accountID` 写回记录
    /// （`app.accountID = accountID`）⇒ 这条记录**自愈**，下次就走正常路径了。
    @discardableResult
    static func validateAccountAndTeam(
        for app: AppRecord,
        account: AppleAccountRecord,
        knownAccountIDs: Set<UUID>? = nil
    ) throws -> AccountBinding {
        if app.isSeal {
            // Seal 续签的硬性前提：新 Seal 的签名身份（Team + Bundle ID）必须与当前运行包一致，
            // 否则装上的是「另一个身份的应用」——iOS 判为新 App，容器/钥匙串访问组全部失效，
            // 且爱思/其他工具签的 Seal 用自己 Apple ID 续签必然变砖（2026-09-15 真机确认）。
            //
            // 读不到 Team（爱思企业签/通配描述文件常常取不到 teamIdentifier）绝不能放行：
            // 读不到 = 无法确认身份一致 = 续签注定变砖，必须拦下并引导用户用原方式重装。
            guard let teamID = normalized(app.signingTeamID) else {
                throw ImportFailure(
                    title: "无法用当前账号续签 Seal",
                    reason: "这份 Seal 不是用当前 Apple ID 签的（读不到它的开发者团队信息，可能是爱思助手或其他工具签的）。用别的账号续签会改变签名身份，装上后打不开。",
                    recovery: "想用当前 Apple ID 长期使用 Seal：请先在 Seal 里用当前账号完整签名并安装一次 Seal（而不是续签），之后就能正常续签了",
                    code: "SEAL-SELF-104"
                )
            }
            guard teamID.caseInsensitiveCompare(account.teamID) == .orderedSame else {
                throw ImportFailure(
                    title: teamMismatchTitle,
                    reason: "当前 Seal 属于其他开发者团队，所选 Apple ID 无权续签。强行续签会改变签名身份，装上后打不开。",
                    recovery: "使用签名 Seal 时的原 Apple ID 续签；或先用当前账号完整签名并安装一次 Seal",
                    code: "SEAL-SELF-103"
                )
            }
            return .consistent
        }
        guard app.state == .installed || app.isSeal else { return .consistent }
        // 🔴 刻意**不做**「`accountID` 必须有值」的 guard（理由见本函数文档注释的
        //    「第四种表现」）：记录里没有账号绑定是**合法状态** —— 设备端扫回的记录就是
        //    这样（扫回发生在「配对之后、添加 Apple ID 之前」，那一刻账号库还是空的）。
        //    决定签名身份的是 `signingTeamID`，缺 `accountID` 只说明「本地没记过」，
        //    不影响同 Team 续签的安全性。
        var binding: AccountBinding = .consistent
        if let boundAccountID = app.accountID {
            // 🔴 同样刻意**不做**「UUID 直接相等」的 guard（理由见本函数文档注释）：
            //    绑定账号可能已**悬空**（删过 Apple ID 再重新添加 ⇒ 账号拿到新 UUID），
            //    那时「UUID 不等」并不代表「用了别的账号」，只代表「记录过期了」。
            if boundAccountID != account.id {
                // 绑定账号**仍在**账号库 ⇒ 这才是真的「用了别的账号」⇒ 拒绝（保护不丢）。
                // 传 `nil`（未提供账号库）时视为「仍存在」⇒ 保持旧行为，宁可拒绝。
                let boundAccountStillExists = knownAccountIDs?.contains(boundAccountID) ?? true
                if boundAccountStillExists {
                    throw ImportFailure(
                        title: "Apple ID 不匹配",
                        reason: "这个应用是用其他 Apple ID 签名的，续签必须使用原账号。",
                        recovery: "在「我的」中切换到原 Apple ID，或用当前账号重新签名安装",
                        code: "SEAL-AUTH-111"
                    )
                }
                // 已悬空 ⇒ 不在这里拦，落到下面的同 Team 判据（同 Team 才放行）。
                binding = .recoveredFromDanglingBinding(previousAccountID: boundAccountID)
            }
        } else {
            // 记录里从来没有账号绑定（设备端扫回的记录）⇒ 同样交给同 Team 判据。
            binding = .recoveredFromMissingBinding
        }
        guard let teamID = normalized(app.signingTeamID) else {
            throw ImportFailure(
                title: "缺少团队记录",
                reason: "这个应用没有记录上次签名使用的开发者团队，无法自动续签。",
                recovery: "重新导入 IPA 并签名安装；Seal 自身请在「我的」中添加对应 Apple ID",
                code: "SEAL-AUTH-113"
            )
        }
        guard teamID.caseInsensitiveCompare(account.teamID) == .orderedSame else {
            throw ImportFailure(
                title: teamMismatchTitle,
                reason: "这个应用属于其他开发者团队，当前 Apple ID 无权续签。",
                recovery: "使用原开发者团队的 Apple ID 续签，或用当前账号重新签名安装",
                code: "SEAL-AUTH-112"
            )
        }
        return binding
    }

    static func resolvedSerialNumber(
        for app: AppRecord,
        account: AppleAccountRecord,
        requestedSerialNumber: String? = nil,
        knownAccountIDs: Set<UUID>? = nil
    ) throws -> String? {
        try validateAccountAndTeam(for: app, account: account, knownAccountIDs: knownAccountIDs)
        let local = normalized(account.certificateSerialNumber)
        if let requested = normalized(requestedSerialNumber),
           let local,
           requested.caseInsensitiveCompare(local) == .orderedSame {
            return local
        }
        if let selected = normalized(account.selectedCertificateSerialNumber),
           let local,
           selected.caseInsensitiveCompare(local) == .orderedSame {
            return local
        }
        return local
    }

    static func localAvailabilityMessage(
        for app: AppRecord,
        account: AppleAccountRecord,
        knownAccountIDs: Set<UUID>? = nil
    ) -> String? {
        do {
            try validateAccountAndTeam(for: app, account: account, knownAccountIDs: knownAccountIDs)
        } catch let failure as ImportFailure {
            return failure.reason
        } catch {
            return "续签账号不可用"
        }
        guard let selected = normalized(account.selectedCertificateSerialNumber) else { return nil }
        guard let local = normalized(account.certificateSerialNumber),
              selected.caseInsensitiveCompare(local) == .orderedSame else {
            return "本机没有所选证书对应的私钥，将在签名时自动处理证书。"
        }
        return nil
    }

    private static func normalized(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    /// 证书序列号跨来源比对前的统一归一化：只留十六进制、转大写、剥离前导 0。
    ///
    /// 根因：AltSign（`ALTCertificate.serialNumber`）走 big-number 十六进制，会剥掉最高半字节的
    /// 前导 0；而 `ProvisioningProfileReader` 走 `SecCertificateCopySerialNumberData`，按原始 DER
    /// 字节 `%02X` 拼串，会保留最高半字节的 0（如 `0E76A893…` vs `E76A893…`）。两者实为同一证书、
    /// 同一序列号，直接 `caseInsensitiveCompare` 会误判成“证书已被轮换/不在授权列表”。
    static func normalizedSerialNumber(_ serial: String) -> String {
        let hex = serial.filter(\.isHexDigit).uppercased()
        let trimmed = hex.drop(while: { $0 == "0" })
        return trimmed.isEmpty ? "0" : String(trimmed)
    }
}
