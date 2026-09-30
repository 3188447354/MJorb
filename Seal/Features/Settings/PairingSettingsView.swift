import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct PairingSettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @State private var isFileImporterPresented = false
    @State private var isPairingExportWarningPresented = false
    @State private var isPairingFileExporterPresented = false
    @State private var pairingExportDocument: PairingExportDocument?

    var body: some View {
        ScrollView(showsIndicators: false) {
            if presentationPolicy.usesPhonePairing {
                phonePairingContent
            } else {
                VStack(spacing: 20) {
                    hero
                    if let pairing = viewModel.pairingRecord {
                        details(pairing)
                        if pairing.validationStatus == .fileUnreadable || pairing.validationStatus == .deviceMismatch {
                            acquisitionGuide
                        }
                    } else {
                        acquisitionGuide
                    }
                    actions
                }
                .padding(20)
            }
        }
        .navigationTitle("设备")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: [
                UTType(filenameExtension: "mobiledevicepairing") ?? .data,
                .propertyList,
                .json,
                .data,
                .item
            ],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                Task { await viewModel.importPairingFile(at: url) }
            case .failure:
                break
            }
        }
        .fileExporter(
            isPresented: $isPairingFileExporterPresented,
            document: pairingExportDocument,
            contentType: PairingExportDocument.contentType,
            defaultFilename: "Seal-Pairing.mobiledevicepairing"
        ) { _ in
            pairingExportDocument = nil
        }
        .confirmationDialog(
            "导出设备配对凭据？",
            isPresented: $isPairingExportWarningPresented,
            titleVisibility: .visible
        ) {
            Button("导出配对文件") {
                preparePairingFileExport()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("文件包含设备配对私钥。仅保存到你信任的位置，勿发送给陌生人或上传到公共网盘。")
        }
        .alert(item: $viewModel.alertFailure) { failure in
            Alert(
                title: Text(failure.title),
                message: Text(failure.userMessage),
                dismissButton: .default(Text(failure.recovery))
            )
        }
        .sealScreenBackground()
        .task {
            if presentationPolicy.usesPhonePairing {
                await viewModel.refreshPhonePairingStatus()
            } else if presentationPolicy.showsDesktopAssistant {
                _ = await viewModel.importPairingAssistantInboxIfPresent()
            }
        }
    }

    private var presentationPolicy: PhonePairingPresentationPolicy {
        PhonePairingPresentationPolicy(
            majorOSVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        )
    }

    private var phonePairingContent: some View {
        VStack(spacing: 20) {
            phonePairingHero
            phonePairingProgress
            phonePairingDetails
            if case let .showingCode(code) = viewModel.phonePairingState {
                pairingCode(code)
            }
            phonePairingAction
        }
        .padding(20)
    }

    private var phonePairingHero: some View {
        let presentation = phonePresentation
        return VStack(spacing: 10) {
            Image(systemName: presentation.icon)
                .font(.system(size: 42, weight: .medium))
                .foregroundStyle(presentation.color)
            Text(presentation.title)
                .font(.title2.weight(.semibold))
            Text(presentation.detail)
                .font(.subheadline)
                .foregroundStyle(Color.sealTextSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .glassSurface(cornerRadius: 24)
    }

    private var phonePairingProgress: some View {
        HStack(spacing: 8) {
            phoneStep("开发者模式", index: 0)
            phoneStep("设备配对", index: 1)
            phoneStep("LocalDevVPN", index: 2)
            phoneStep("完成", index: 3)
        }
    }

    private func phoneStep(_ title: String, index: Int) -> some View {
        let current = phoneProgressIndex
        return VStack(spacing: 8) {
            Capsule()
                .fill(index < current ? Color.sealSuccess : index == current ? Color.sealAccent : Color.sealHairline)
                .frame(height: 6)
            Text(title)
                .font(.caption.weight(index == current ? .semibold : .regular))
                .foregroundStyle(index <= current ? Color.primary : Color.sealTextSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
        }
        .frame(maxWidth: .infinity)
    }

    private var phonePairingDetails: some View {
        VStack(spacing: 0) {
            phoneDetailRow("设备配对", phonePairingStatusText)
            Divider()
            phoneDetailRow("LocalDevVPN", localDevVPNStatusText)
            if let pairing = viewModel.pairingRecord {
                Divider()
                phoneDetailRow("设备 UDID", deviceIdentifierText(pairing))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .glassSurface(cornerRadius: 18)
    }

    private func phoneDetailRow(_ title: String, _ value: String) -> some View {
        HStack(spacing: 12) {
            Text(title)
            Spacer(minLength: 12)
            Text(value)
                .foregroundStyle(Color.sealTextSecondary)
                .multilineTextAlignment(.trailing)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.subheadline)
        .frame(minHeight: 50)
    }

    private func pairingCode(_ code: String) -> some View {
        VStack(spacing: 8) {
            Text("配对码")
                .font(.caption.weight(.medium))
                .foregroundStyle(Color.sealTextSecondary)
            Text(code)
                .font(.system(size: 34, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .tracking(5)
            Text("在系统设置中确认此配对码")
                .font(.caption)
                .foregroundStyle(Color.sealTextSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .glassSurface(cornerRadius: 18)
    }

    @ViewBuilder
    private var phonePairingAction: some View {
        switch viewModel.phonePairingState {
        case .idle:
            if viewModel.pairingRecord?.isPaired == true {
                Button("验证 LocalDevVPN") {
                    Task { await viewModel.validatePhonePairing() }
                }
                .sealPrimaryAction(cornerRadius: 12)
                Button("重新配对") {
                    Task { await viewModel.startPhonePairing() }
                }
                .sealOutlineAction(cornerRadius: 12)
            } else {
                Button("开始设备配对") {
                    Task { await viewModel.startPhonePairing() }
                }
                .sealPrimaryAction(cornerRadius: 12)
            }
        case .waitingForLocalDevVPN:
            Button("验证 LocalDevVPN") {
                Task { await viewModel.validatePhonePairing() }
            }
            .sealPrimaryAction(cornerRadius: 12)
        case .completed:
            Button("重新配对") {
                Task { await viewModel.startPhonePairing() }
            }
            .sealOutlineAction(cornerRadius: 12)
        case .failed:
            Button("重新配对") {
                Task { await viewModel.startPhonePairing() }
            }
            .sealPrimaryAction(cornerRadius: 12)
        case .requestingLocalNetwork, .waitingForSystemConfirmation, .showingCode, .validating:
            Button(phonePresentation.actionTitle) {}
                .sealPrimaryAction(cornerRadius: 12)
                .disabled(true)
        }
    }

    private var phonePresentation: (title: String, detail: String, icon: String, color: Color, actionTitle: String) {
        switch viewModel.phonePairingState {
        case .idle:
            return ("准备配对", "在开发者模式中与 Seal 配对，完成后即可签名、安装和续签。", "iphone.and.arrow.forward", .sealAccent, "开始设备配对")
        case .requestingLocalNetwork:
            return ("准备配对", "正在请求本地网络权限。", "network", .sealAccent, "正在准备")
        case .waitingForSystemConfirmation:
            return ("在系统中配对", "前往 设置 > 隐私与安全性 > 开发者模式，在“与 Seal 配对”中选择 Seal。", "gearshape.2", .sealAccent, "等待系统确认")
        case .showingCode:
            return ("确认配对码", "将下方配对码与系统设置中的提示核对后确认。", "number.square", .sealAccent, "等待系统确认")
        case .validating:
            return ("验证连接", "正在检查 LocalDevVPN 是否可用。", "arrow.triangle.2.circlepath", .sealAccent, "正在验证")
        case .waitingForLocalDevVPN:
            return ("等待 LocalDevVPN", "设备配对已保存。打开 LocalDevVPN 后继续验证。", "vpn", .sealWarning, "验证 LocalDevVPN")
        case .completed:
            return ("配对完成", "设备已准备好，可签名、安装和续签。", "checkmark.circle.fill", .sealSuccess, "重新配对")
        case .failed:
            return ("需要重新配对", "未完成系统确认或本地网络不可用。", "exclamationmark.triangle.fill", .sealDanger, "重新配对")
        }
    }

    private var phoneProgressIndex: Int {
        switch viewModel.phonePairingState {
        case .idle, .requestingLocalNetwork: 0
        case .waitingForSystemConfirmation, .showingCode: 1
        case .validating, .waitingForLocalDevVPN: 2
        case .completed: 3
        case .failed: 1
        }
    }

    private var phonePairingStatusText: String {
        switch viewModel.phonePairingState {
        case .completed: "已完成"
        case .waitingForLocalDevVPN, .validating: "已保存，待验证"
        case .failed: "未完成"
        case .idle where viewModel.pairingRecord?.isPaired == true: "已完成"
        default: "待配对"
        }
    }

    private var localDevVPNStatusText: String {
        switch viewModel.phonePairingState {
        case .completed: "已验证"
        case .validating: "验证中"
        case .waitingForLocalDevVPN: "待连接"
        default: "待验证"
        }
    }

    private var hero: some View {
        VStack(spacing: 12) {
            Image(systemName: heroIcon)
                .font(.system(size: 50, weight: .medium))
                .foregroundStyle(heroColor)
            Text(heroTitle)
                .font(.title2.weight(.semibold))
            Text(heroSubtitle)
                .font(.subheadline)
                .foregroundStyle(Color.sealTextSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(28)
        .glassSurface(cornerRadius: 24)
    }

    private func details(_ pairing: PairingRecord) -> some View {
        VStack(spacing: 0) {
            detailRow("配对类型", pairing.isRemotePairing ? "远程配对" : "本机配对")
            Divider()
            detailRow("设备 UDID", deviceIdentifierText(pairing))
            Divider()
            detailRow("配对状态", pairing.validationStatus.title)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .glassSurface(cornerRadius: 18)
    }

    private var acquisitionGuide: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("连接设备")
                .font(.headline)
            Text("使用电脑端 Seal 配对助手生成配对文件后，可通过「导入配对文件」手动选择，或由配对助手自动写入 Seal。")
                .font(.subheadline)
                .foregroundStyle(Color.sealTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("远程配对需要 iOS 17.4 及以上；Seal 最低支持 iOS 17.4，iOS 17.3.1 及以下无法安装。")
                .font(.caption)
                .foregroundStyle(Color.sealTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .glassSurface(cornerRadius: 18)
    }

    private var actions: some View {
        VStack(spacing: 12) {
            Button {
                isFileImporterPresented = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "square.and.arrow.down")
                    Text("导入配对文件")
                }
            }
            .sealPrimaryAction(cornerRadius: 12)

            if viewModel.pairingRecord != nil {
                Button {
                    isPairingExportWarningPresented = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "square.and.arrow.up")
                        Text("导出配对文件")
                    }
                }
                .sealOutlineAction(cornerRadius: 12)
            }

            Button(viewModel.pairingRecord == nil ? "检查配对状态" : "重新检查") {
                Task {
                    await viewModel.testPairingConnection()
                }
            }
            .sealOutlineAction(cornerRadius: 12)
        }
    }

    private func preparePairingFileExport() {
        Task {
            guard let data = await viewModel.pairingFileDataForExport() else { return }
            pairingExportDocument = PairingExportDocument(data: data)
            isPairingFileExporterPresented = true
        }
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        HStack(spacing: 12) {
            Text(title)
            Spacer(minLength: 12)
            Text(value)
                .foregroundStyle(Color.sealTextSecondary)
                .multilineTextAlignment(.trailing)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(minHeight: 54)
    }

    private var heroIcon: String {
        guard let status = viewModel.pairingRecord?.validationStatus else {
            return "iphone.badge.exclamationmark"
        }
        switch status {
        case .verified: return "checkmark.circle.fill"
        case .validating: return "arrow.triangle.2.circlepath"
        case .unverified: return "clock.badge.checkmark"
        case .deviceMismatch, .fileUnreadable: return "exclamationmark.triangle.fill"
        }
    }

    private var heroColor: Color {
        guard let status = viewModel.pairingRecord?.validationStatus else { return .sealWarning }
        switch status {
        case .verified: return .sealSuccess
        case .validating: return .sealAccent
        case .unverified: return .sealWarning
        case .deviceMismatch, .fileUnreadable: return .sealDanger
        }
    }

    private var heroTitle: String {
        guard let pairing = viewModel.pairingRecord else { return "未导入" }
        return pairing.validationStatus.title
    }

    private var heroSubtitle: String {
        guard let status = viewModel.pairingRecord?.validationStatus else {
            return "请先在电脑上完成设备配对。"
        }
        switch status {
        case .unverified:
            return "设备信息已保存。首次连接成功后会完成配对。"
        case .validating:
            return "正在确认当前 iPhone 是否匹配。"
        case .verified:
            return "已完成配对。连接暂时不可用也不会取消配对。"
        case .deviceMismatch:
            return "当前设备不匹配，请重新配对。"
        case .fileUnreadable:
            return "设备信息无法读取，请重新配对。"
        }
    }

    private func deviceIdentifierText(_ pairing: PairingRecord) -> String {
        if let id = pairing.validatedDeviceIdentifier, id.isEmpty == false { return id }
        if let id = pairing.deviceIdentifier, id.isEmpty == false { return id }
        return "待验证"
    }
}

private struct PairingExportDocument: FileDocument {
    static let contentType = UTType(filenameExtension: "mobiledevicepairing") ?? .propertyList
    static var readableContentTypes: [UTType] { [contentType, .propertyList] }

    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
