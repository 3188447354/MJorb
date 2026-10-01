import SwiftUI

struct OpenSourceLicensesView: View {
    private static func makeURL(_ string: String) -> URL {
        guard let url = URL(string: string) else {
            fatalError("编译期固定 URL 无效: \(string)")
        }
        return url
    }

    private let dependencies: [OpenSourceDependency] = [
        OpenSourceDependency(
            name: "AltSign",
            license: "许可证待确认",
            url: Self.makeURL("https://github.com/sunuannian1/AltSign")
        ),
        OpenSourceDependency(
            name: "SideSign",
            license: "GPL-3.0",
            url: Self.makeURL("https://github.com/SideStore/SideSign")
        ),
        OpenSourceDependency(
            name: "AnisetteKit",
            license: "AGPL-3.0",
            url: Self.makeURL("https://github.com/mahee96/AnisetteKit")
        ),
        OpenSourceDependency(
            name: "Minimuxer",
            license: "AGPL-3.0",
            url: Self.makeURL("https://github.com/SideStore/minimuxer")
        ),
        OpenSourceDependency(
            name: "ZIPFoundation",
            license: "MIT",
            url: Self.makeURL("https://github.com/weichsel/ZIPFoundation")
        ),
        OpenSourceDependency(
            name: "DeviceSupport",
            license: "GPL-2.0 / LGPL-2.1",
            url: Self.makeURL("https://github.com/SideStore/DeviceSupport")
        ),
        OpenSourceDependency(
            name: "swift-crypto",
            license: "Apache-2.0",
            url: Self.makeURL("https://github.com/apple/swift-crypto")
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
