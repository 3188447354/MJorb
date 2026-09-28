import Foundation
import UserNotifications

/// 「快捷指令触发的后台续签」结束后的系统通知 —— **该不该发 + 说什么**。
///
/// 纯值类型 + 纯计算属性：`AppsViewModel` 是 `@MainActor`、依赖一大堆，测试构造不出来，
/// 所以判据必须落在这里（AGENTS.md §5「纯函数化才能测」）。
struct BackgroundRenewalNotificationResult: Equatable {
    let total: Int
    let succeeded: Int
    let failed: Int
    /// 本轮**根本没执行**、等用户先处理的项（缺可用账号等）。
    let needsAction: Int
    /// Seal 覆盖安装已提交，等新进程读回实际运行身份；既不是成功也不是失败。
    ///
    /// 🔴 **2026-09-28 补**：这个桶原来没被带进通知 ⇒ 正文「已续签 1/3」看不出另外 2 个
    /// 是「待核验」，用户会以为它们失败了。四桶必须一个不少地出现在正文里。
    let awaitingConfirmation: Int

    /// 只要**有项要续签**就发。
    ///
    /// 🔴 **全失败必须发**（2026-09-28 真机实证）：18:41:38 那一轮「共 3，成功 0，失败 3」
    /// （`NSURLErrorDomain -1001` Apple 服务器超时），日志写的是「本轮没有成功续签的项，
    /// 按规则不发」⇒ **用户什么都没收到**。快捷指令续签的全部价值就是「不打开 App 也能续」，
    /// 静默失败会让用户在应用过期那天才发现。
    ///
    /// `total == 0`（没有任何需要续签的项）**刻意不发**：没有结果可报，弹「已续签 0/0」
    /// 是纯噪音，而「快捷指令确实跑过」另有快捷指令自身的反馈。
    var shouldNotify: Bool { total > 0 }

    /// 四桶里只有 `succeeded` 满了才叫「完成」——`needsAction` / `awaitingConfirmation`
    /// 都没进 `succeeded`，所以它们会自然打破「完成」，不需要额外判断。
    private var isFullyClean: Bool { succeeded == total }

    var title: String {
        if isFullyClean { return "Seal 续签完成" }
        if failed > 0 { return succeeded > 0 ? "Seal 续签部分失败" : "Seal 续签失败" }
        // 没有成功、也没有失败（全是未执行 / 待核验）：说「部分完成」会误导（明明 0 个成功）。
        return succeeded > 0 ? "Seal 续签部分完成" : "Seal 续签未完成"
    }

    var body: String {
        var parts = ["已续签 \(succeeded)/\(total) 个应用"]
        if failed > 0 { parts.append("失败 \(failed) 个") }
        if needsAction > 0 { parts.append("未执行 \(needsAction) 个") }
        if awaitingConfirmation > 0 { parts.append("待核验 \(awaitingConfirmation) 个") }
        return parts.joined(separator: "，") + "（快捷指令后台续签）"
    }
}

/// 本轮**根本没跑起来**时的通知。
///
/// 🔴 **只覆盖「不会自动补上」的三种**（2026-09-28 定案）：
/// 让位给 `signingTask` / `batchRefreshTask` 的那一档**刻意不在这里** —— 那一轮本身就会
/// 把应用续完并给出结论（后台轮会自己发通知，手动轮用户就在 App 里看着），再发一条
/// 「未执行」只会重复。而下面三种没有任何一轮会补上，用户点了快捷指令却收不到任何回音，
/// 最容易误判成「续签成功了」。
struct BackgroundRenewalSkippedNotice: Equatable {
    enum Reason: Equatable {
        /// 被**非续签类**操作占着设备通道（导入配对文件、管理证书等）—— 那项操作不会续签。
        case blockedByOtherOperation(String)
        /// 取操作锁等满 30 秒（`beginWaiting` 默认预算）仍没等到。
        case operationLockTimeout(String)
        /// 整轮抛错（`refreshAll` 直接失败）。
        case roundFailed(title: String)
    }

    let reason: Reason

    var title: String {
        switch reason {
        case .roundFailed:
            return "Seal 续签失败"
        case .blockedByOtherOperation, .operationLockTimeout:
            return "Seal 续签未执行"
        }
    }

    var body: String {
        switch reason {
        case .blockedByOtherOperation(let blocker):
            return "\(blocker)正占用设备通道，本轮没有续签。"
                + "稍后重跑一次快捷指令即可（快捷指令后台续签）"
        case .operationLockTimeout(let blocker):
            return "等不到设备通道（\(blocker)占用中），本轮没有续签。"
                + "稍后重跑一次快捷指令即可（快捷指令后台续签）"
        case .roundFailed(let failureTitle):
            return "\(failureTitle)。打开 Seal 查看原因，或稍后重跑快捷指令（快捷指令后台续签）"
        }
    }
}

/// 一次投递的结果，供日志留痕（真机对账用）。
enum BackgroundRenewalNotificationDelivery: Equatable {
    case delivered
    /// 本轮没有任何需要续签的项（`total == 0`）⇒ 按上面那条规则不发。
    case skippedNothingToRenew
    /// 用户没给通知权限 —— 不是错误，只留日志。
    case skippedNotAuthorized
    case failed(String)
}

/// 投递「快捷指令后台续签」的系统通知。
///
/// 🔴 **只服务快捷指令这一条链路**：置位与消费都在 `AppsViewModel` 里成对出现
/// （`refreshAllFromBackgroundTrigger()` 置位、`runBatchRefresh` **入口处**消费并清位），
/// Seal 内手动续签永远走不到这里 —— 用户明确要求「手动续签不要通知」。
///
/// 🔴 **没权限时只留日志、不去 `requestAuthorization()`**：这条链路的价值是
/// 「不打开 App 也能续」，而 `requestAuthorization()` 在后台根本弹不出授权框
/// （系统只在 App 处于前台时才展示），白搭一次调用还可能把 `notDetermined` 变成
/// 一次无效请求。权限由「到期提醒」在设置页正常请求；用户授权后本通知自动生效。
@MainActor
final class BackgroundRenewalNotifier {
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func post(_ result: BackgroundRenewalNotificationResult) async -> BackgroundRenewalNotificationDelivery {
        guard result.shouldNotify else { return .skippedNothingToRenew }
        return await deliver(title: result.title, body: result.body)
    }

    func post(_ notice: BackgroundRenewalSkippedNotice) async -> BackgroundRenewalNotificationDelivery {
        await deliver(title: notice.title, body: notice.body)
    }

    private func deliver(title: String, body: String) async -> BackgroundRenewalNotificationDelivery {
        let settings = await center.notificationSettings()
        let authorization = settings.authorizationStatus
        guard authorization == .authorized
            || authorization == .provisional
            || authorization == .ephemeral else {
            return .skippedNotAuthorized
        }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        // `trigger: nil` = 立即投递。
        // identifier **固定**（不拼时间戳）：一轮只发一条；连续几轮触发时后一条覆盖
        // 前一条，不会在通知中心堆一摞「Seal 续签…」。用户明确要求「每用一次快捷指令
        // 就触发一次通知」，所以这里**不做结果指纹去重** —— 覆盖而非堆积已经足够。
        let request = UNNotificationRequest(
            identifier: Self.identifier,
            content: content,
            trigger: nil
        )
        do {
            try await center.add(request)
            return .delivered
        } catch {
            let nsError = error as NSError
            return .failed("\(nsError.domain) \(nsError.code)")
        }
    }

    static let identifier = "com.mjorb.seal.background-renewal"
}