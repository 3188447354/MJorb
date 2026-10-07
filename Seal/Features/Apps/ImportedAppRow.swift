import SwiftUI
import UIKit

struct ImportedAppRow: View {
    let app: AppRecord
    let iconData: Data?

    /// 行图标解码缓存（性能优化 2026-10-04）：导入列表滚动时避免重复解码。
    private static let iconCache = NSCache<NSString, UIImage>()

    var body: some View {
        HStack(spacing: 14) {
            icon

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(app.displayName)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)

                    Text("v\(Self.displayVersion(for: app))")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color.sealTextSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }

                bundleIdentifierText
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .truncationMode(.middle)
                    .textSelection(.enabled)

                // 待安装源标签：按 PendingUpdateKind 企业级分类显示
                // - newVersion：红色"有新版本待安装"
                // - sameVersion：橙色"有更新待安装"（同版本不同包）
                // - downgrade：灰色"旧版本"（降级，需手动确认）
                // - none：不显示
                if app.belongsInInstalledList, let kind = Self.pendingUpdateKind(app) {
                    switch kind {
                    case .newVersion:
                        Text("有新版本待安装")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.red, in: RoundedRectangle(cornerRadius: 7))
                    case .sameVersion:
                        Text("有更新待安装")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.orange, in: RoundedRectangle(cornerRadius: 7))
                    case .downgrade:
                        Text("旧版本")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.gray, in: RoundedRectangle(cornerRadius: 7))
                    case .none:
                        EmptyView()
                    }
                }
            }

            Spacer(minLength: 8)
            trailing
        }
        .frame(minHeight: 72)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            [app.displayName, "版本 \(app.version)", displayBundleIdentifier, trailingLabel]
                .joined(separator: "，")
        )
        .accessibilityIdentifier("imported-app-row")
    }

    private var displayBundleIdentifier: String {
        if app.belongsInInstalledList || app.belongsInSignedList {
            return app.mappedBundleIdentifier ?? app.originalBundleIdentifier
        }
        // 未签名的 app 列表中始终显示原始 Bundle ID（与官方一致）
        // 用户手动修改的 preferredBundleIdentifier 只在签名抽屉内生效
        return app.originalBundleIdentifier
    }

    @ViewBuilder
    private var bundleIdentifierText: some View {
        let identifier = displayBundleIdentifier
        if identifier.lowercased().hasSuffix(".seal"), identifier.count > 5 {
            let prefix = String(identifier.dropLast(5))
            Text(prefix).foregroundColor(Color.sealTextSecondary)
                + Text(".seal").foregroundColor(Color.sealAccent)
        } else {
            Text(identifier).foregroundStyle(Color.sealTextSecondary)
        }
    }

    @ViewBuilder private var icon: some View {
        Group {
            if let iconData {
                let key = app.id.uuidString as NSString
                let image: UIImage? = {
                    if let cached = Self.iconCache.object(forKey: key) {
                        return cached
                    }
                    guard let decoded = UIImage(data: iconData) else { return nil }
                    Self.iconCache.setObject(decoded, forKey: key)
                    return decoded
                }()
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .accessibilityHidden(true)
                }
            } else {
                Image(systemName: "app.fill")
                    .resizable()
                    .scaledToFit()
                    .padding(11)
                    .foregroundStyle(Color.sealAccent)
                    .background(Color.sealSurface)
                    .accessibilityHidden(true)
            }
        }
        .frame(width: 52, height: 52)
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var trailing: some View {
        if app.needsIPAImport {
            // 空壳记录：显示待导入徽标
            Text("待导入 IPA")
                .font(.caption.weight(.semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.orange, in: RoundedRectangle(cornerRadius: 8))
        } else if app.belongsInInstalledList {
            let validity = AppOperationPresentation(app: app).validity
            Text(validity?.text ?? "已安装")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(color(for: validity?.tone))
                .frame(minWidth: 70, alignment: .trailing)
        } else {
            VStack(alignment: .trailing, spacing: 5) {
                Text(app.size.formatted(.byteCount(style: .file)))
                    .font(.subheadline)
                Text(AppImportTimeFormatter.string(from: app.importedAt))
                    .font(.caption)
            }
            .foregroundStyle(Color.sealTextSecondary)
            .frame(minWidth: 82, alignment: .trailing)
        }
    }

    private var signedValidity: AppValidityPresentation? {
        guard let expiry = app.provisioningProfileExpirationDate ?? app.expiryDate else { return nil }
        var copy = app
        copy.state = .installed
        copy.expiryDate = expiry
        return AppOperationPresentation(app: copy).validity
    }

    private var signedValidityText: String {
        if app.signedArtifactStatus == .missing { return "文件缺失" }
        if app.signedArtifactStatus == .damaged { return "文件损坏" }
        if app.signedArtifactStatus == .deviceUnavailable { return "设备不可用" }
        return signedValidity?.text ?? app.signedArtifactStatus?.title ?? "未安装"
    }

    private var signedValidityColor: Color {
        if let status = app.signedArtifactStatus,
           [SignedArtifactStatus.missing, .damaged, .deviceUnavailable, .expired].contains(status) {
            return .sealDanger
        }
        return color(for: signedValidity?.tone)
    }

    private var trailingLabel: String {
        if app.needsIPAImport {
            return "待导入 IPA"
        }
        if app.belongsInInstalledList {
            return AppOperationPresentation(app: app).validity?.text ?? "已安装"
        }
        return "\(app.size.formatted(.byteCount(style: .file)))，\(AppImportTimeFormatter.string(from: app.importedAt))"
    }

    private func color(for tone: AppValidityTone?) -> Color {
        switch tone {
        case .success: .sealSuccess
        case .warning: .sealWarning
        case .danger: .sealDanger
        case .neutral, nil: .sealTextSecondary
        }
    }

    /// 待安装源的企业级分类：Seal 用运行版本比，其他 App 只看指纹（无已装版本可比）。
    /// 返回 nil 表示无待安装（不显示标签）。
    private static func pendingUpdateKind(_ app: AppRecord) -> ProfileOnlyRenewalPolicy.PendingUpdateKind? {
        if app.isSeal {
            let runningVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            let kind = ProfileOnlyRenewalPolicy.pendingUpdateKind(
                recordedVersion: app.version,
                runningVersion: runningVersion,
                pendingUpdateSourceFingerprint: app.pendingUpdateSourceFingerprint,
                installedFingerprint: app.installedFingerprint
            )
            return kind == .none ? nil : kind
        } else {
            // 非 Seal：没有已装版本号可比，只看指纹。指纹不同 ⇒ 有包待安装，
            // 统一按 sameVersion 显示"有更新待安装"，不声称是新版本。
            guard let pending = app.pendingUpdateSourceFingerprint,
                  !pending.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            if let installed = app.installedFingerprint,
               !installed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               pending == installed {
                return nil
            }
            return .sameVersion
        }
    }

    /// 是否有待安装的自更新源：用 ProfileOnlyRenewalPolicy.hasPendingUpdateSource
    /// 的同源判据（版本比较 + 指纹），不能直接用 hasPendingSelfUpdateSource
    ///（那个标志自替换后不清，会常驻）。
    private static func hasPendingSelfUpdate(_ app: AppRecord) -> Bool {
        guard app.isSeal else { return false }
        let runningVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return ProfileOnlyRenewalPolicy.hasPendingUpdateSource(
            recordedVersion: app.version,
            runningVersion: runningVersion,
            pendingUpdateSourceFingerprint: app.pendingUpdateSourceFingerprint,
            installedFingerprint: app.installedFingerprint
        )
    }

    /// 显示版本：Seal 显示带 beta 构建号（1.0.0-beta28），方便区分新旧。
    private static func displayVersion(for app: AppRecord) -> String {
        guard app.isSeal else { return app.version }
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? app.version
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        if !build.isEmpty {
            return "\(short)-beta\(build)"
        }
        return short
    }
}
