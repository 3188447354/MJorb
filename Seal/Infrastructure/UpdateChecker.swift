import Foundation

/// 启动更新通知检查器
/// 从 GitHub Releases 拉取最新版本，有更新时弹窗提示
/// 弹窗标题和内容来自 Release 的 name 和 body，可在 GitHub 发版时自定义
struct UpdateChecker {
    static let shared = UpdateChecker()

    private let repo = "sunuannian1/Seal-Releases"
    private let lastNotifiedVersionKey = "update_notifier.last_notified_version"

    /// 检查更新，返回需要展示的通知内容（无更新返回 nil）
    /// - Parameter force: 手动检查时传 true，忽略已通知记录，有新版本就弹
    func check(force: Bool = false) async -> UpdateNotice? {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else {
            return nil
        }

        do {
            var request = URLRequest(url: url)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("Seal", forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 10

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return nil
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tagName = json["tag_name"] as? String else {
                return nil
            }

            // 本地版本
            let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"

            // 只有远端版本「严格高于」当前版本才提示更新；
            // 回滚、发布顺序错乱或 tag 异常返回旧版本时静默忽略，避免提示下载旧 IPA。
            if Version.compare(tagName, currentVersion) != .orderedDescending {
                return nil
            }

            // 非强制模式：已经通知过这个版本，不重复弹
            if !force {
                let lastNotified = UserDefaults.standard.string(forKey: lastNotifiedVersionKey)
                if lastNotified == tagName {
                    return nil
                }
                // 仅自动检查标记已通知；手动检查不写记录，避免吃掉后续自动弹窗
                UserDefaults.standard.set(tagName, forKey: lastNotifiedVersionKey)
            }

            // 从 Release 读取标题和正文，发版时可自定义
            let releaseName = json["name"] as? String ?? "发现新版本"
            let releaseBody = (json["body"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let message = releaseBody?.isEmpty == false ? releaseBody! : "点击查看详情并更新"

            // 下载跳转地址：优先 Release 详情页，回退到仓库页面
            let downloadURL = (json["html_url"] as? String)
                .flatMap(URL.init(string:))
                ?? URL(string: "https://github.com/\(repo)/releases")

            // 从 attachments 里挑 IPA，供应用内直接下载覆盖安装
            let ipaDownloadURL = Self.ipaDownloadURL(
                from: json["assets"] as? [[String: Any]] ?? []
            )

            return UpdateNotice(
                version: tagName,
                title: releaseName,
                message: message,
                downloadURL: downloadURL,
                ipaDownloadURL: ipaDownloadURL
            )
        } catch {
            return nil
        }
    }

    // MARK: - 更新资产的真实性

    /// Release 声称的版本（`tag_name`）与 IPA 内真实版本是否一致。
    ///
    /// 这是一次**跨源交叉验证**：`tag_name` 来自 GitHub API 的元数据，
    /// `CFBundleShortVersionString` 来自**下载到的二进制本身**。
    /// 只校验下载域名是不够的 —— 同一仓库、同一合法域名下的资产仍然可以被替换，
    /// 那种情况下域名校验完全看不出异常。两边对不上，说明这个包要么不属于这个
    /// Release、要么内容被换过，装下去就是远程代码执行。
    ///
    /// 用 `Version.compare` 而不是字符串相等：tag 可能是 `v1.0.13`，
    /// IPA 内是 `1.0.13`，而 `Version` 已经处理了 `v` 前缀与多段版本号。
    static func advertisedVersion(_ advertised: String, matchesIPAVersion ipaVersion: String) -> Bool {
        Version.compare(advertised, ipaVersion) == .orderedSame
    }

    /// Release 资产的下载直链必须来自 GitHub 官方域名，且必须是 HTTPS。
    ///
    /// `browser_download_url` 来自 API 响应。仓库名虽然是硬编码的，但响应内容本身
    /// 是不可信输入：一旦它指向攻击者的域名，「应用内更新」就会变成远程代码投递通道。
    /// 因此这里独立校验 scheme 与 host，不信任响应里说什么就是什么。
    static func isTrustedDownloadURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "https",
              let host = url.host?.lowercased() else {
            return false
        }
        return host == "github.com"
            || host == "objects.githubusercontent.com"
            || host.hasSuffix(".github.com")
            || host.hasSuffix(".githubusercontent.com")
    }

    /// 确定性地挑出 IPA 直链。
    ///
    /// 旧实现取**第一个**后缀为 `.ipa` 的附件：一次 Release 挂了多个 IPA 时
    /// （不同架构、测试包、或后补的附件）装哪个全看 API 返回顺序 ——
    /// 既不确定，也让「往 Release 里多加一个附件」成为可行的投毒手法。
    /// 现在改为：**恰好一个**才给直链；没有或多个都不给，
    /// 回退到 Release 详情页由用户在浏览器里自己选。
    static func ipaDownloadURL(from assets: [[String: Any]]) -> URL? {
        let candidates = assets.compactMap { attachment -> URL? in
            guard let name = attachment["name"] as? String,
                  name.lowercased().hasSuffix(".ipa"),
                  let raw = attachment["browser_download_url"] as? String,
                  let url = URL(string: raw),
                  isTrustedDownloadURL(url) else {
                return nil
            }
            return url
        }
        guard candidates.count == 1 else { return nil }
        return candidates[0]
    }
}

struct UpdateNotice: Identifiable {
    let id = UUID()
    let version: String
    let title: String
    let message: String
    let downloadURL: URL?
    let ipaDownloadURL: URL?
}
