import Foundation
import Testing
@testable import Seal

/// 应用内更新是一条远程代码投递通道：装进设备的 IPA 完全由 Release 响应决定。
/// `browser_download_url` 是不可信输入 —— 不校验来源就等于允许从任意域名拉 IPA。
struct UpdateCheckerAssetTests {

    @Test
    func acceptsGitHubDownloadHostsOverHTTPS() throws {
        for raw in [
            "https://github.com/sun/Seal-Releases/releases/download/1.0/Seal.ipa",
            "https://objects.githubusercontent.com/github-production-release-asset/x/y"
        ] {
            let url = try #require(URL(string: raw))
            // 第二参数要的是 Comment?，变量不能隐式转换 —— 用插值字面量
            #expect(UpdateChecker.isTrustedDownloadURL(url), "\(raw)")
        }
    }

    @Test
    func rejectsPlainHTTP() throws {
        let url = try #require(URL(string: "http://github.com/sun/Seal-Releases/a.ipa"))
        #expect(UpdateChecker.isTrustedDownloadURL(url) == false)
    }

    /// 核心：即使仓库名硬编码，响应里的直链也必须独立校验 host。
    @Test
    func rejectsForeignHosts() throws {
        let url = try #require(URL(string: "https://evil.example.com/Seal.ipa"))
        #expect(UpdateChecker.isTrustedDownloadURL(url) == false)
    }

    /// 多个 IPA 时不能靠 API 返回顺序决定装哪个 —— 那让「多加一个附件」成为投毒手法。
    @Test
    func multipleIPAAssetsYieldNoDirectLink() {
        let assets = [
            asset(name: "Seal.ipa", url: "https://github.com/a/one.ipa"),
            asset(name: "Seal-Other.ipa", url: "https://github.com/a/two.ipa")
        ]
        #expect(UpdateChecker.ipaDownloadURL(from: assets) == nil)
    }

    /// 不可信的附件要先被过滤掉，再判断「是否恰好一个」——
    /// 否则一个恶意附件 + 一个正常附件会被算成「多个」而静默降级，
    /// 或者反过来：恶意附件是唯一一个时直接被采用。
    @Test
    func untrustedAssetIsFilteredBeforeCounting() {
        let assets = [asset(name: "Seal.ipa", url: "https://evil.example.com/Seal.ipa")]
        #expect(UpdateChecker.ipaDownloadURL(from: assets) == nil)
    }

    @Test
    func theLoneTrustedIPABecomesTheDirectLink() {
        let assets = [
            asset(name: "notes.md", url: "https://github.com/a/notes.md"),
            asset(name: "Seal.ipa", url: "https://github.com/a/Seal.ipa")
        ]
        #expect(
            UpdateChecker.ipaDownloadURL(from: assets)?.absoluteString
                == "https://github.com/a/Seal.ipa"
        )
    }

    /// 交叉校验：声称的版本要与包内真实版本对得上（tag 允许带 v 前缀）。
    @Test
    func advertisedVersionMatchesTheIPAVersionIgnoringTheVPrefix() {
        #expect(UpdateChecker.advertisedVersion("v1.0.13", matchesIPAVersion: "1.0.13"))
        #expect(UpdateChecker.advertisedVersion("1.0.13", matchesIPAVersion: "1.0.13"))
    }

    /// 核心：声称是新版本、包里却是旧的 —— 典型的「资产被替换」。
    /// 只校验下载域名看不出这种情况（域名完全合法）。
    @Test
    func aMismatchedIPAVersionIsRejected() {
        #expect(UpdateChecker.advertisedVersion("1.0.13", matchesIPAVersion: "1.0.12") == false)
        #expect(UpdateChecker.advertisedVersion("2.0.0", matchesIPAVersion: "1.0.0") == false)
    }

    private func asset(name: String, url: String) -> [String: Any] {
        ["name": name, "browser_download_url": url]
    }
}
