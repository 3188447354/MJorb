import SwiftUI
import UniformTypeIdentifiers

struct SigningCertificateSettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel
    let relatedApps: [AppRecord]
    let certificateExportHandler: CertificateExportHandler
    @State private var selectedAccountID: UUID?
    @State private var isCertificateImporterPresented = false

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

    private func localPrivateKeyText(_ health: CertificateHealthStatus?) -> String {
        guard let health else { return "检查中" }
        switch health.localPrivateKey {
        case .valid: return "可用"
        case .invalid: return "缺失或损坏（不能用于新签名）"
        case .unknown: return "无法确认"
        }
    }

    @ViewBuilder
    private func teamCertificatesCard(account: AppleAccountRecord) -> some View {
        let inventory = viewModel.certificateInventory(for: account.id)
        let allCertificates = inventory?.certificates ?? []
        let certificates = deduplicatedCertificates(allCertificates).filter {
            !CertificateRevocationImpact.isLocalCertificate(
                serialNumber: $0.serialNumber,
                account: account
            )
        }
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

            if allCertificates.isEmpty {
                Text("下拉刷新以从 Apple 服务器获取证书清单。")
                    .font(.subheadline)
                    .foregroundStyle(Color.sealTextSecondary)
                    .padding(.vertical, 12)
            } else if certificates.isEmpty {
                Text("除本机在用的证书外，账号下没有其他证书。")
                    .font(.subheadline)
                    .foregroundStyle(Color.sealTextSecondary)
                    .padding(.vertical, 12)
            } else {
                ForEach(Array(certificates.enumerated()), id: \.element.id) { index, certificate in
                    if index > 0 { Divider() }
                    certificateRow(certificate)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .glassSurface(cornerRadius: 24)
    }

    private func certificateRow(
        _ certificate: ApplePortalCertificateSnapshot
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(certificate.displayName)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Text(fullSerialText(certificate.serialNumber))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Color.sealTextSecondary)
            Text(expirationLine(certificate))
                .font(.caption)
                .foregroundStyle(Color.sealTextSecondary)
        }
        .padding(.vertical, 12)
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
        let installedApps = CertificateRevocationImpact.affectedApps(
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
