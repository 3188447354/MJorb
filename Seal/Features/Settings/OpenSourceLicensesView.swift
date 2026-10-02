import SwiftUI

struct OpenSourceLicensesView: View {
    private static func makeURL(_ string: String) -> URL {
        guard let url = URL(string: string) else {
            fatalError("编译期固定 URL 无效: \(string)")
        }
        return url
    }

    /// 2026-10-02 据实审计：只列**实际编进 Seal 安装包**的第三方组件。
    ///
    /// 审计方法：`project.yml` 的 Seal target 直接依赖 + `Vendor/*/Package.swift`
    /// 的传递依赖，逐个核对仓库里的 LICENSE 文件 / README 许可证声明，
    /// 并验证每个 URL 可访问。审计结论：
    /// - 新增 CodeSignKit、GSACryptoKit、libdeflate：随 SideSign 静态链接进包，
    ///   旧列表漏了。
    /// - 新增 Unicorn Engine：AnisetteKit 链接的二进制 xcframework（GPL-2.0）。
    /// - 新增 OpenSSL：AltSign / CodeSignKit / GSACryptoKit 链接的二进制
    ///   xcframework（Apache-2.0）。
    /// - 新增 swift-asn1：CodeSignKit 主 target 的依赖（Apache-2.0）。
    /// - DeviceSupport 改名 libimobiledevice 并修正 URL：旧 URL
    ///   `SideStore/DeviceSupport` 已 404；实际编进包的是 Vendor 里
    ///   libimobiledevice 全家桶源码（COPYING/COPYING.LESSER 为 GPL-2.0/LGPL-2.1）。
    /// - AltSign 未列入：sunuannian1 fork 在锁定 revision 下没有 LICENSE 文件，
    ///   许可证状态不明，不在此处展示（不影响其随包分发的事实）。
    /// - 不单列的：CryptoExtras（属 swift-crypto 同一条目）、RustBridge
    ///   （属 Minimuxer 包内）、AltSign 树内 C 源码（minizip-ng/ldid/corecrypto，
    ///   属 AltSign 包内）；EMProxy 在 vendored Minimuxer 里不存在，未链接。
    private let dependencies: [OpenSourceDependency] = [
        OpenSourceDependency(
            name: "OpenSSL",
            license: "Apache-2.0",
            url: Self.makeURL("https://github.com/krzyzanowskim/OpenSSL")
        ),
        OpenSourceDependency(
            name: "SideSign",
            license: "GPL-3.0",
            url: Self.makeURL("https://github.com/SideStore/SideSign")
        ),
        OpenSourceDependency(
            name: "CodeSignKit",
            license: "AGPL-3.0",
            url: Self.makeURL("https://github.com/mahee96/CodeSignKit")
        ),
        OpenSourceDependency(
            name: "GSACryptoKit",
            license: "AGPL-3.0",
            url: Self.makeURL("https://github.com/mahee96/GSACryptoKit")
        ),
        OpenSourceDependency(
            name: "libdeflate",
            license: "MIT",
            url: Self.makeURL("https://github.com/SideStore/libdeflate")
        ),
        OpenSourceDependency(
            name: "AnisetteKit",
            license: "AGPL-3.0",
            url: Self.makeURL("https://github.com/mahee96/AnisetteKit")
        ),
        OpenSourceDependency(
            name: "Unicorn Engine",
            license: "GPL-2.0",
            url: Self.makeURL("https://github.com/mahee96/unicorn")
        ),
        OpenSourceDependency(
            name: "Minimuxer",
            license: "AGPL-3.0",
            url: Self.makeURL("https://github.com/SideStore/minimuxer")
        ),
        OpenSourceDependency(
            name: "libimobiledevice",
            license: "GPL-2.0 / LGPL-2.1",
            url: Self.makeURL("https://github.com/libimobiledevice/libimobiledevice")
        ),
        OpenSourceDependency(
            name: "ZIPFoundation",
            license: "MIT",
            url: Self.makeURL("https://github.com/weichsel/ZIPFoundation")
        ),
        OpenSourceDependency(
            name: "swift-crypto",
            license: "Apache-2.0",
            url: Self.makeURL("https://github.com/apple/swift-crypto")
        ),
        OpenSourceDependency(
            name: "swift-asn1",
            license: "Apache-2.0",
            url: Self.makeURL("https://github.com/apple/swift-asn1")
        )
    ]

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                VStack(spacing: 0) {
                    ForEach(Array(dependencies.enumerated()), id: \.element.id) { index, dependency in
                        Link(destination: dependency.url) {
                            HStack(alignment: .center, spacing: 14) {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(dependency.name)
                                        .font(.system(size: 17, weight: .semibold))
                                        .foregroundStyle(.primary)
                                    Text(dependency.license)
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(Color.sealAccent)
                                }
                                Spacer(minLength: 12)
                                Image(systemName: "arrow.up.right")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(Color.sealTextSecondary)
                            }
                            .padding(.vertical, 15)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        if index < dependencies.count - 1 {
                            Divider()
                        }
                    }
                }
                .padding(.horizontal, 16)
                .background(Color.sealSurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.sealHairline.opacity(0.58), lineWidth: 0.8)
                }
            }
            .padding(20)
        }
        .navigationTitle("组件与许可")
        .navigationBarTitleDisplayMode(.inline)
        .sealScreenBackground()
    }
}

private struct OpenSourceDependency: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let license: String
    let url: URL
}
