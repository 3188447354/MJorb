import SwiftUI
import UniformTypeIdentifiers

struct SigningCertificateSettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel
    let relatedApps: [AppRecord]
    let certificateExportHandler: CertificateExportHandler
    @State private var selectedAccountID: UUID?
    @State private var certificatePendingRevocation: ApplePortalCertificateSnapshot?
    @State private var isCertificateImporterPresented = false
    @State private var cleanupPlan: CertificateCleanupPlan?
    @State private var isCleanupEmptyNoticePresented = false

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                accountCard

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
        .confirmationDialog(
            "撤销这个证书？",
            isPresented: Binding(
                get: { certificatePendingRevocation != nil },
                set: { if !$0 { certificatePendingRevocation = nil } }
            ),
            titleVisibility: .visible,
            presenting: certificatePendingRevocation
        ) { certificate in
            Button("撤销证书", role: .destructive) {
                guard let account = activeAccount else { return }
                let serialNumber = certificate.serialNumber
                certificatePendingRevocation = nil
                Task { await viewModel.revokeCertificate(serialNumber: serialNumber, for: account) }
            }
            Button("取消", role: .cancel) { certificatePendingRevocation = nil }
        } message: { certificate in
            Text(revocationWarning(for: certificate))
        }
        .confirmationDialog(
            "清理不可用证书？",
            isPresented: Binding(
                get: { cleanupPlan != nil },
                set: { if !$0 { cleanupPlan = nil } }
            ),
            titleVisibility: .visible,
            presenting: cleanupPlan
        ) { plan in
            Button("撤销 \(plan.revocable.count) 张并新建证书", role: .destructive) {
                guard let account = activeAccount else { return }
                cleanupPlan = nil
                Task { await viewModel.executeCertificateCleanup(plan, for: account, apps: relatedApps) }
            }
            Button("取消", role: .cancel) { cleanupPlan = nil }
        } message: { plan in
            Text(cleanupConfirmationMessage(for: plan))
        }
        .alert("无需清理", isPresented: $isCleanupEmptyNoticePresented) {
            Button("好", role: .cancel) {}
        } message: {
            Text("账号下的证书都仍可用：本机持有私钥，或仍有已安装应用在用。")
        }
        .task {
            if selectedAccountID == nil {
                selectedAccountID = viewModel.activeAccount?.id
            }
            await viewModel.load(force: true)
            if let account = activeAccount {
                await viewModel.refreshCertificateInventory(for: account, force: true)
            }
        }
        .refreshable {
            await viewModel.load(force: true)
            if let account = activeAccount {
                await viewModel.refreshCertificateInventory(for: account, force: true)
            }
        }
        .fileImporter(
            isPresented: $isCertificateImporterPresented,
            allowedContentTypes: [UTType(filenameExtension: "p12") ?? .data]
        ) { result in
            guard let account = activeAccount else { return }
            switch result {
            case let .success(url):
                Task {
                    await viewModel.importSigningCertificate(from: url, for: account)
                }
            case let .failure(error):
                guard (error as NSError).code != NSUserCancelledError else { return }
                viewModel.alertFailure = ImportFailure(
                    title: "无法读取证书备份",
                    reason: "P12 文件无法读取。\n[\((error as NSError).domain) \((error as NSError).code)]",
                    recovery: "重新选择 P12",
                    code: "SEAL-CERT-206a"
                )
            }
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
                    detailRow("Team", TeamNameDisplayFormatter.string(from: account.teamName))
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
            if account.certificateSerialNumber?.isEmpty == false {
                localCertificateCard(account: account)
            } else {
                missingCertificateCard
            }
            teamCertificatesCard(account: account)
        } else {
            noAccountCard
        }
    }

    private func localCertificateCard(account: AppleAccountRecord) -> some View {
        let health = viewModel.certificateHealthStatus(for: account.id)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                Text("Apple 开发证书")
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.88)
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
                certificateHealthRow(
                    "Apple 侧可用于本机",
                    value: usableAppIDCountText(health),
                    state: nil
                )
                Divider()
                Button {
                    isCertificateImporterPresented = true
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.down.doc")
                            .font(.subheadline.weight(.semibold))
                        Text("从 P12 备份恢复本机私钥")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(Color.sealTextSecondary)
                    }
                    .foregroundStyle(Color.sealAccent)
                    .padding(.vertical, 12)
                }
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .glassSurface(cornerRadius: 24)
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

    private func relatedAppCountText(_ health: CertificateHealthStatus?) -> String {
        guard let count = health?.relatedAppCount else { return "无法确认" }
        return count == 0 ? "尚未使用" : "\(count) 个 App"
    }

    private func localPrivateKeyText(_ health: CertificateHealthStatus?) -> String {
        guard let health else { return "检查中" }
        switch health.localPrivateKey {
        case .valid: return "可用"
        case .invalid: return "缺失或损坏（不能用于新签名）"
        case .unknown: return "无法确认"
        }
    }

    private func usableAppIDCountText(_ health: CertificateHealthStatus?) -> String {
        guard let count = health?.usableOnCurrentDeviceAppIDCount else { return "无法确认" }
        return "\(count) 个 App ID"
    }

    @ViewBuilder
    private func teamCertificatesCard(account: AppleAccountRecord) -> some View {
        let certificates = viewModel.certificateInventory(for: account.id)?.certificates ?? []
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("账号下的全部证书")
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.88)
                Spacer(minLength: 12)
                Text(certificates.isEmpty ? "—" : "\(certificates.count) 个")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.sealTextSecondary)
            }
            .padding(.bottom, 14)

            if certificates.isEmpty {
                Text("下拉刷新以从 Apple 服务器获取证书清单。")
                    .font(.subheadline)
                    .foregroundStyle(Color.sealTextSecondary)
                    .padding(.vertical, 12)
            } else {
                ForEach(Array(certificates.enumerated()), id: \.element.id) { index, certificate in
                    if index > 0 { Divider() }
                    certificateRow(certificate, account: account)
                }

                Divider()

                Button {
                    Task {
                        guard let plan = await viewModel.prepareCertificateCleanup(
                            for: account,
                            apps: relatedApps
                        ) else { return }
                        if plan.revocable.isEmpty {
                            isCleanupEmptyNoticePresented = true
                        } else {
                            cleanupPlan = plan
                        }
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "wand.and.broom")
                            .font(.subheadline.weight(.semibold))
                        Text("清理不可用证书并新建")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        if viewModel.isCertificateOperationRunning {
                            ProgressView()
                        } else {
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(Color.sealTextSecondary)
                        }
                    }
                    .foregroundStyle(Color.sealAccent)
                    .padding(.vertical, 12)
                }
                .disabled(viewModel.isCertificateOperationRunning)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .glassSurface(cornerRadius: 24)
    }

    private func cleanupConfirmationMessage(for plan: CertificateCleanupPlan) -> String {
        var lines: [String] = []
        let names = plan.revocable.prefix(5).map { certificate in
            let serial = SigningCertificateSelectionPolicy.normalizedSerialNumber(certificate.serialNumber)
            return "\(certificate.displayName)（…\(serial.suffix(6))）"
        }
        lines.append("将撤销 \(plan.revocable.count) 张不可用证书：\(names.joined(separator: "、"))。")
        if plan.revocable.count > 5 {
            lines.append("以及另外 \(plan.revocable.count - 5) 张。")
        }
        if plan.deviceVerified {
            lines.append("已核验：这些证书本机没有私钥、没有已安装应用在用、设备端描述文件也未引用。")
        } else {
            lines.append("未连接设备，未能核验设备端描述文件：如果其他签名工具用这个 Apple ID 安装过应用，撤销其证书会让那些应用失效。")
        }
        lines.append("撤销后将自动创建一张新证书并绑定本机。证书一旦撤销无法恢复。")
        return lines.joined(separator: "\n")
    }

    private func certificateRow(
        _ certificate: ApplePortalCertificateSnapshot,
        account: AppleAccountRecord
    ) -> some View {
        let isLocal = CertificateRevocationImpact.isLocalCertificate(
            serialNumber: certificate.serialNumber,
            account: account
        )
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                    Text(certificate.displayName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("证书标识：\(certificate.machineName)")
                        .font(.caption2)
                        .foregroundStyle(Color.sealTextSecondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                if isLocal {
                    Text("本机在用")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.sealAccent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.sealAccent.opacity(0.12), in: Capsule())
                }
                Spacer(minLength: 8)
                Button("撤销", role: .destructive) {
                    certificatePendingRevocation = certificate
                }
                .font(.subheadline.weight(.semibold))
                .disabled(viewModel.isCertificateOperationRunning)
            }
            Text(serialText(certificate.serialNumber))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(Color.sealTextSecondary)
            Text(expirationLine(certificate))
                .font(.caption)
                .foregroundStyle(Color.sealTextSecondary)
            associatedAppsView(for: certificate)
        }
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private func associatedAppsView(
        for certificate: ApplePortalCertificateSnapshot
    ) -> some View {
        let apps = CertificateRevocationImpact.associatedApps(
            serialNumber: certificate.serialNumber,
            apps: relatedApps
        )
        VStack(alignment: .leading, spacing: 5) {
            if apps.isEmpty {
                Label("本机记录中未找到关联 App", systemImage: "link.badge.plus")
                    .font(.caption)
                    .foregroundStyle(Color.sealTextSecondary)
            } else {
                Text("关联 App（\(apps.count) 个）")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.sealTextSecondary)
                ForEach(apps.prefix(5)) { app in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: app.state == .installed ? "checkmark.circle.fill" : "circle")
                            .font(.caption2)
                            .foregroundStyle(app.state == .installed ? Color.sealSuccess : Color.sealTextSecondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(app.name)
                                .font(.caption.weight(.medium))
                                .lineLimit(1)
                            Text("\(app.mappedBundleIdentifier ?? app.originalBundleIdentifier) · \(app.state.title)")
                                .font(.caption2)
                                .foregroundStyle(Color.sealTextSecondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
                if apps.count > 5 {
                    Text("还有 \(apps.count - 5) 个关联 App")
                        .font(.caption2)
                        .foregroundStyle(Color.sealTextSecondary)
                }
            }
        }
        .padding(.top, 3)
    }

    private func serialText(_ serialNumber: String) -> String {
        let normalized = SigningCertificateSelectionPolicy.normalizedSerialNumber(serialNumber)
        return "序列号 …\(normalized.suffix(12))"
    }

    private func expirationLine(_ certificate: ApplePortalCertificateSnapshot) -> String {
        guard let expirationDate = certificate.expirationDate else {
            return "有效期：无法确认"
        }
        return "有效期至 \(SealSettingsDateFormatter.string(from: expirationDate))"
    }

    private func revocationWarning(for certificate: ApplePortalCertificateSnapshot) -> String {
        guard let account = activeAccount else { return "" }
        return CertificateRevocationImpact.warningMessage(
            serialNumber: certificate.serialNumber,
            apps: relatedApps,
            isLocalCertificate: CertificateRevocationImpact.isLocalCertificate(
                serialNumber: certificate.serialNumber,
                account: account
            )
        )
    }

    private var missingCertificateCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("当前没有本机可用证书")
                .font(.headline)
            Text("首次签名时将自动创建。")
                .font(.subheadline)
                .foregroundStyle(Color.sealTextSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .glassSurface(cornerRadius: 20)
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
