import SwiftUI

struct SigningCertificateSettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel
    let relatedApps: [AppRecord]
    let certificateExportHandler: CertificateExportHandler
    @State private var selectedAccountID: UUID?
    @State private var certificatePendingRevocation: ApplePortalCertificateSnapshot?

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                accountCard

                selfManagementCard
                    // 自更新覆盖安装由「重新打开的新进程」对账确认：旧进程结算发生在
                    // 重新启动 Seal 之后。这里在等待确认态下自动轮询本地状态，一旦对账
                    // 完成（事务被结算/关闭）本页自动切到已完成，无需人手点「检查安装结果」。
                    .task(id: viewModel.selfManagement.state) {
                        guard viewModel.selfManagement.state == .awaitingReplacementConfirmation else {
                            return
                        }
                        while !Task.isCancelled {
                            await viewModel.refreshSelfManagementState()
                            if viewModel.selfManagement.state != .awaitingReplacementConfirmation {
                                break
                            }
                            try? await Task.sleep(nanoseconds: 2_000_000_000)
                        }
                    }

                Text("签名证书")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.sealTextSecondary)
                    .padding(.leading, 8)

                certificateContent
            }
            .padding(20)
        }
        .navigationTitle("签名证书")
        .navigationBarTitleDisplayMode(.inline)
        .alert(item: $viewModel.alertFailure) { failure in
            Alert(
                title: Text(failure.title),
                message: Text(failure.userMessage),
                dismissButton: .default(Text(failure.recovery))
            )
        }
        .alert(item: $certificatePendingRevocation) { certificate in
            Alert(
                title: Text("撤销这张证书？"),
                message: Text(revocationWarning(for: certificate)),
                primaryButton: .destructive(Text("撤销")) {
                    if let account = activeAccount {
                        Task { await viewModel.revokeCertificate(serialNumber: certificate.serialNumber, for: account) }
                    }
                },
                secondaryButton: .cancel(Text("取消"))
            )
        }
        .task {
            if selectedAccountID == nil {
                selectedAccountID = viewModel.activeAccount?.id
            }
            await viewModel.load(force: true)
            await viewModel.refreshSelfManagementState()
            guard let account = activeAccount else { return }
            await viewModel.refreshCertificateHealthLocally(for: account)
            await viewModel.refreshCertificateInventory(for: account, force: true)
        }
        .refreshable {
            await viewModel.load(force: true)
            await viewModel.refreshSelfManagementState()
            guard let account = activeAccount else { return }
            await viewModel.refreshCertificateHealthLocally(for: account)
            await viewModel.refreshCertificateInventory(for: account, force: true)
        }
        .sealScreenBackground()
    }

    private var activeAccount: AppleAccountRecord? {
        if let id = selectedAccountID, let account = viewModel.accounts.first(where: { $0.id == id }) {
            return account
        }
        return viewModel.activeAccount
    }

    private var selectableAccounts: [AppleAccountRecord] {
        viewModel.accounts.filter { AccountAvailabilityPolicy.isSelectable($0) }
    }

    @ViewBuilder
    private var accountCard: some View {
        VStack(spacing: 0) {
            if selectableAccounts.isEmpty {
                Text("请先添加并验证 Apple ID")
                    .foregroundStyle(Color.sealTextSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 16)
            } else {
                Menu {
                    ForEach(selectableAccounts) { account in
                        Button {
                            selectedAccountID = account.id
                            Task {
                                await viewModel.selectActiveAccount(account)
                                await viewModel.refreshCertificateInventory(for: account, force: true)
                            }
                        } label: {
                            Text(viewModel.fullEmail(for: account))
                            if account.id == activeAccount?.id {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                } label: {
                    HStack {
                        Text("Apple ID")
                            .foregroundStyle(.primary)
                        Spacer()
                        if let account = activeAccount {
                            Text(viewModel.fullEmail(for: account))
                                .foregroundStyle(Color.sealTextSecondary)
                                .lineLimit(1)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption)
                                .foregroundStyle(Color.sealTextSecondary)
                        } else {
                            Text("请选择")
                                .foregroundStyle(Color.sealTextSecondary)
                        }
                    }
                    .padding(.vertical, 14)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if let account = activeAccount {
                    Divider()
                    detailRow("Team ID", account.teamID.isEmpty ? "—" : account.teamID)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .glassSurface(cornerRadius: 24)
    }

    @ViewBuilder
    private var certificateContent: some View {
        if let account = activeAccount {
            unifiedCertificateCard(account: account)
        } else {
            noAccountCard
        }
    }

    /// 自管理状态卡：当前真实签名者、本机可用身份、事务状态和下一步。
    /// View 只读 ViewModel 汇总好的展示模型，不自己猜状态。
    private var selfManagementCard: some View {
        let presentation = viewModel.selfManagement
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                Text(presentation.title)
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 8)
                if presentation.state == .awaitingReplacementConfirmation {
                    Button {
                        Task { await viewModel.refreshSelfManagementState() }
                    } label: {
                        Text("检查安装结果")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.sealAccent)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.sealAccent.opacity(0.12), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            Text(presentation.detail)
                .font(.caption)
                .foregroundStyle(Color.sealTextSecondary)
            HStack(spacing: 8) {
                Text("当前真实签名者")
                    .font(.caption)
                    .foregroundStyle(Color.sealTextSecondary)
                Spacer(minLength: 8)
                Text(viewModel.sealActualSignerSerialNumber.map(fullSerialText) ?? "读取失败")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Color.sealTextSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            if presentation.showsComputerRecovery {
                Text("不要卸载 Seal。请用电脑按相同 Bundle ID、扩展标识和 Team 覆盖安装。")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.sealDanger)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .glassSurface(cornerRadius: 24)
    }

    /// 单个证书卡片：本机在用证书（如有）在上，账号下其余证书（可撤销）合并展示。
    private func unifiedCertificateCard(account: AppleAccountRecord) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if account.certificateSerialNumber?.isEmpty == false {
                localCertificateSection(account: account)
            } else {
                missingCertificateHeader
            }
            otherCertificatesSection(account: account)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .glassSurface(cornerRadius: 24)
    }

    private func localCertificateSection(account: AppleAccountRecord) -> some View {
        let health = viewModel.certificateHealthStatus(for: account.id)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                Text(localCertificateDisplayName(account))
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.88)
                Text("本机在用")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.sealSuccess)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.sealSuccess.opacity(0.14), in: Capsule())
                Spacer(minLength: 12)
                Text(certificateSummary(health))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(certificateSummaryColor(health))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        certificateSummaryColor(health).opacity(0.12),
                        in: Capsule()
                    )
            }
            .padding(.bottom, 8)

            Text(fullSerialText(account.certificateSerialNumber ?? ""))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Color.sealTextSecondary)
                .padding(.bottom, 14)

            Divider()

            VStack(spacing: 0) {
                certificateHealthRow(
                    expirationTitle(health),
                    value: expirationText(health),
                    state: nil
                )
                Divider()
                certificateHealthRow(
                    "本机签名私钥",
                    value: localPrivateKeyText(health),
                    state: health?.localPrivateKey
                )
                Divider()
                installedAppsSection(account: account)
                Divider()
                Button {
                    certificateExportHandler.exportToLiveContainer()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.subheadline.weight(.semibold))
                        Text("导出证书给 LiveContainer")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(Color.sealTextSecondary)
                    }
                    .foregroundStyle(Color.sealAccent)
                    .padding(.vertical, 12)
                }
            }
        }
    }

    private var missingCertificateHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("当前没有本机可用证书")
                .font(.headline)
            Text("首次签名时将自动创建。")
                .font(.subheadline)
                .foregroundStyle(Color.sealTextSecondary)
        }
        .padding(.bottom, 6)
    }

    @ViewBuilder
    private func otherCertificatesSection(account: AppleAccountRecord) -> some View {
        let certificates = nonLocalCertificates(account: account)
        if certificates.isEmpty {
            EmptyView()
        } else {
            Divider()
                .padding(.vertical, 14)
            Text("账号下的其他证书")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.sealTextSecondary)
                .padding(.bottom, 6)
            ForEach(Array(certificates.enumerated()), id: \.element.id) { index, certificate in
                if index > 0 { Divider() }
                remoteCertificateRow(certificate)
            }
        }
    }

    private func nonLocalCertificates(account: AppleAccountRecord) -> [ApplePortalCertificateSnapshot] {
        let inventory = viewModel.certificateInventory(for: account.id)
        let allCertificates = inventory?.certificates ?? []
        return deduplicatedCertificates(allCertificates).filter {
            !CertificateRevocationImpact.isLocalCertificate(
                serialNumber: $0.serialNumber,
                account: account
            )
        }
    }

    /// 证书角色的固定标签含义：真实签名者 > 本机持有私钥 > 仅 Apple 端存在；
    /// 身份读不出来时无法证明任何一张不是 Seal 的命，一律标「关联状态无法确认」。
    private func roleLabels(for certificate: ApplePortalCertificateSnapshot) -> [CertificateRoleLabel] {
        guard let signer = viewModel.sealActualSignerSerialNumber else {
            return [.associationUnknown]
        }
        var labels: [CertificateRoleLabel] = []
        if CertificateRevocationImpact.isActualSealSigner(
            serialNumber: certificate.serialNumber,
            actualSealSignerSerialNumber: signer
        ) {
            labels.append(.currentSealSigner)
        } else if certificate.hasLocalPrivateKey {
            labels.append(.locallyUsable)
        } else {
            labels.append(.external)
        }
        if CertificateRevocationImpact.associatedApps(
            serialNumber: certificate.serialNumber,
            apps: relatedApps
        ).isEmpty == false {
            labels.append(.associatedOnThisDevice)
        }
        return labels
    }

    private func remoteCertificateRow(
        _ certificate: ApplePortalCertificateSnapshot
    ) -> some View {
        let labels = roleLabels(for: certificate)
        // 真实签名者或「无法确认关联」都不提供撤销入口（ViewModel 层还有硬拒绝兜底）。
        let revocationAllowed = labels.contains(.currentSealSigner) == false
            && labels.contains(.associationUnknown) == false
        return HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(certificate.displayName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    ForEach(labels, id: \.title) { label in
                        Text(label.title)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(label == .currentSealSigner ? Color.sealDanger : Color.sealTextSecondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(
                                (label == .currentSealSigner ? Color.sealDanger : Color.sealTextSecondary).opacity(0.12),
                                in: Capsule()
                            )
                    }
                }
                Text(fullSerialText(certificate.serialNumber))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Color.sealTextSecondary)
                Text(expirationLine(certificate))
                    .font(.caption)
                    .foregroundStyle(Color.sealTextSecondary)
            }
            Spacer(minLength: 8)
            if revocationAllowed {
                Button {
                    certificatePendingRevocation = certificate
                } label: {
                    Text("撤销")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.sealDanger)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Color.sealDanger.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 10)
    }

    private func revocationWarning(for certificate: ApplePortalCertificateSnapshot) -> String {
        CertificateRevocationImpact.warningMessage(
            serialNumber: certificate.serialNumber,
            apps: relatedApps,
            isLocalCertificate: false
        )
    }

    private func certificateHealthRow(
        _ title: String,
        value: String,
        state: CertificateHealthStatus.CheckState?
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .foregroundStyle(Color.sealTextSecondary)
            Spacer(minLength: 12)
            HStack(spacing: 7) {
                if let state {
                    Image(systemName: stateIcon(state))
                        .foregroundStyle(stateColor(state))
                        .accessibilityHidden(true)
                }
                Text(value)
                    .foregroundStyle(state.map { stateColor($0) } ?? Color.primary)
                    .multilineTextAlignment(.trailing)
            }
        }
        .padding(.vertical, 12)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title)，\(value)")
    }

    private func certificateSummary(_ health: CertificateHealthStatus?) -> String {
        guard let health else { return "检查中" }
        if health.expirationState == .invalid { return "无效" }
        return health.isUsable ? "可用" : "无效"
    }

    private func certificateSummaryColor(_ health: CertificateHealthStatus?) -> Color {
        guard let health else { return Color.sealTextSecondary }
        if health.expirationState == .invalid { return Color.sealDanger }
        return health.isUsable ? Color.sealSuccess : Color.sealWarning
    }

    private func stateIcon(_ state: CertificateHealthStatus.CheckState) -> String {
        switch state {
        case .valid: "checkmark.circle.fill"
        case .invalid: "exclamationmark.triangle.fill"
        case .unknown: "questionmark.circle"
        }
    }

    private func stateColor(_ state: CertificateHealthStatus.CheckState) -> Color {
        switch state {
        case .valid: Color.sealSuccess
        case .invalid: Color.sealDanger
        case .unknown: Color.sealTextSecondary
        }
    }

    private func expirationTitle(_ health: CertificateHealthStatus?) -> String {
        guard let health else { return "证书有效期" }
        if health.portalPresence == .invalid { return "Apple 侧证书状态" }
        return health.expirationState == .invalid ? "证书已过期" : "证书有效期至"
    }

    private func expirationText(_ health: CertificateHealthStatus?) -> String {
        guard let health else { return "检查中" }
        if health.portalPresence == .invalid { return "已撤销或不存在" }
        guard let expirationDate = health.expirationDate else { return "无法确认" }
        return SealSettingsDateFormatter.string(from: expirationDate)
    }

    private func localPrivateKeyText(_ health: CertificateHealthStatus?) -> String {
        guard let health else { return "检查中" }
        switch health.localPrivateKey {
        case .valid: return "可用"
        case .invalid: return "缺失或损坏（不能用于新签名）"
        case .unknown: return "无法确认"
        }
    }

    private func fullSerialText(_ serialNumber: String) -> String {
        "序列号 \(serialNumber)"
    }

    private func expirationLine(_ certificate: ApplePortalCertificateSnapshot) -> String {
        guard let expirationDate = certificate.expirationDate else {
            return "有效期：无法确认"
        }
        return "有效期至 \(SealSettingsDateFormatter.string(from: expirationDate))"
    }

    private func deduplicatedCertificates(
        _ certificates: [ApplePortalCertificateSnapshot]
    ) -> [ApplePortalCertificateSnapshot] {
        var seen = Set<String>()
        return certificates.filter { certificate in
            let key = SigningCertificateSelectionPolicy.normalizedSerialNumber(certificate.serialNumber)
            return seen.insert(key).inserted
        }
    }

    private func localCertificateDisplayName(_ account: AppleAccountRecord) -> String {
        guard let localSerial = account.certificateSerialNumber?.trimmingCharacters(in: .whitespacesAndNewlines),
              localSerial.isEmpty == false,
              let inventory = viewModel.certificateInventory(for: account.id) else {
            return "本机证书"
        }
        let normalized = SigningCertificateSelectionPolicy.normalizedSerialNumber(localSerial)
        return inventory.certificates.first {
            SigningCertificateSelectionPolicy.normalizedSerialNumber($0.serialNumber) == normalized
        }?.displayName ?? "本机证书"
    }

    @ViewBuilder
    private func installedAppsSection(account: AppleAccountRecord) -> some View {
        // 与上方「本机已安装 App 在用」行标签同源判定（顶层序列号 + 每个签名 target 的序列号），
        // 否则会出现「标签说在用、清单说暂无」的矛盾，Seal 自身也会被漏掉。
        let installedApps = CertificateRevocationImpact.installedAppsAssociated(
            serialNumber: account.certificateSerialNumber ?? "",
            apps: relatedApps
        )
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("本机已安装 App")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.sealTextSecondary)
                Spacer(minLength: 8)
                Text("由该证书签名")
                    .font(.caption2)
                    .foregroundStyle(Color.sealTextSecondary)
            }
            if installedApps.isEmpty {
                Text("暂无")
                    .font(.caption)
                    .foregroundStyle(Color.sealTextSecondary)
            } else {
                ForEach(installedApps) { app in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(app.name)
                                .font(.subheadline.weight(.medium))
                                .lineLimit(1)
                            Text(app.mappedBundleIdentifier ?? app.originalBundleIdentifier)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(Color.sealTextSecondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 12)
    }

    private var noAccountCard: some View {
        VStack(spacing: 10) {
            Image(systemName: "person.crop.circle.badge.exclamationmark")
                .font(.system(size: 34))
                .foregroundStyle(Color.sealWarning)
            Text("未选择 Apple ID")
                .font(.headline)
            Text("返回 Apple ID 页面，选择一个已验证账号。")
                .font(.subheadline)
                .foregroundStyle(Color.sealTextSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .glassSurface(cornerRadius: 24)
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(title)
                .foregroundStyle(.primary)
            Spacer(minLength: 12)
            Text(value)
                .foregroundStyle(Color.sealTextSecondary)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 15)
    }
}