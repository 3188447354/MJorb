import Foundation
import Testing
@testable import Seal

/// `embeddedProfiles` 是「安装后清理旧 profile 时保留哪几份」的唯一依据。
/// 它的错法只有两种，两种都会让清理失效或误删：
/// - 漏掉扩展 ⇒ 扩展的旧 profile 永远清不掉（2026-09-16 用户反馈的堆积）。
/// - 多算了不会被安装的 profile（Frameworks）⇒ 真正的旧 profile 被当成「在用」而保留。
struct SignedArtifactProfileReaderTests {

    private func makeSealApp() -> IPAArchiveFixture.AppSpec {
        IPAArchiveFixture.AppSpec(
            directoryName: "Seal.app",
            bundleIdentifier: "com.example.seal",
            name: "Seal",
            version: "1.0.0",
            buildNumber: "1"
        )
    }

    @Test
    func collectsMainAndExtensionProfiles() throws {
        let url = try IPAArchiveFixture.make(
            apps: [makeSealApp()],
            includeShareExtension: true,
            includeMobileProvision: true,
            extensionMobileProvision: IPAArchiveFixture.makeMinimalMobileProvisionData(
                uuid: "EXTENSION-PROFILE-UUID",
                bundleIdentifier: "com.example.seal.share"
            )
        )
        let profiles = SignedArtifactProfileReader.embeddedProfiles(in: try Data(contentsOf: url))

        #expect(profiles.count == 2)
        let byBundleID = Dictionary(
            uniqueKeysWithValues: profiles.map { ($0.bundleIdentifier, $0.uuid) }
        )
        // Bundle ID 取自 profile 自己的 application-identifier，TeamIdentifier 前缀已剥掉
        #expect(byBundleID["com.example.seal"] == "FIXTURE-PROFILE-UUID")
        #expect(byBundleID["com.example.seal.share"] == "EXTENSION-PROFILE-UUID")
    }

    @Test
    func ignoresFrameworkProvisions() throws {
        // Frameworks 下的 embedded.mobileprovision 不会被 installd 装成设备 profile。
        // 把它算进保留集合，等于给这个 Bundle ID 发了一张「永远不许清理」的免死金牌。
        // 两种位置都要排除：主 App 下的，以及扩展（.appex）下的。
        let url = try IPAArchiveFixture.make(
            apps: [makeSealApp()],
            includeShareExtension: true,
            includeMobileProvision: true,
            extraEntries: [
                (
                    path: "Payload/Seal.app/Frameworks/Foo.framework/embedded.mobileprovision",
                    data: IPAArchiveFixture.makeMinimalMobileProvisionData(
                        uuid: "MAIN-FRAMEWORK-PROFILE-UUID",
                        bundleIdentifier: "com.example.seal.framework"
                    )
                ),
                (
                    path: "Payload/Seal.app/PlugIns/Share.appex/Frameworks/Bar.framework/embedded.mobileprovision",
                    data: IPAArchiveFixture.makeMinimalMobileProvisionData(
                        uuid: "EXTENSION-FRAMEWORK-PROFILE-UUID",
                        bundleIdentifier: "com.example.seal.share.framework"
                    )
                ),
            ]
        )
        let profiles = SignedArtifactProfileReader.embeddedProfiles(in: try Data(contentsOf: url))

        // 只剩主 App 与扩展两份（两者共用同一个 UUID ⇒ 去重后 1 份）
        #expect(profiles.count == 1)
        #expect(profiles.map(\.uuid) == ["FIXTURE-PROFILE-UUID"])
    }

    @Test
    func deduplicatesProfileSharedByMainAndExtension() throws {
        // 免费账号下主 App 与扩展共用同一份 profile 是常态，保留集合里只应出现一次。
        let url = try IPAArchiveFixture.make(
            apps: [makeSealApp()],
            includeShareExtension: true,
            includeMobileProvision: true
        )
        let profiles = SignedArtifactProfileReader.embeddedProfiles(in: try Data(contentsOf: url))

        #expect(profiles.count == 1)
        #expect(profiles.first?.uuid == "FIXTURE-PROFILE-UUID")
    }

    @Test
    func returnsEmptyWhenNoProfileIsEmbedded() throws {
        let url = try IPAArchiveFixture.make(apps: [makeSealApp()], includeMobileProvision: false)
        let profiles = SignedArtifactProfileReader.embeddedProfiles(in: try Data(contentsOf: url))

        // 空集合 ⇒ 调用方一份都不删。绝不能退化成「全部都要删」。
        #expect(profiles.isEmpty)
    }
}
