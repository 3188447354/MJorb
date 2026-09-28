import Foundation
import UserNotifications

/// 「快捷指令触发的后台续签」完成后的系统通知 —— **文案与「该不该发」的判据**。
///
/// 纯值类型 + 纯计算属性：`AppsViewModel` 是 `@MainActor`、依赖一大堆，测试构造不出来，
/// 所以判据必须落在这里（AGENTS.md §5「纯函数化才能测」）。
struct BackgroundRenewalNotificationResult: Equatable {
    let total: Int
    let succeeded: Int
    let failed: Int
    let needsAction: Int

    /// 只有**至少一项真的续签成功**才发通知。
    ///
    /// 🔴 全失败 / 一项都没执行时**刻意不发**：那属于「用户需要处理」的情况，界面与日志里
    /// 已有明确引导；锁屏时弹一条「续签失败」既不解决问题，又会和「续签成功」这条通知的
    /// 语义混在一起。这条通知的唯一职责是**让用户知道后台那一轮真的成了**。
    var shouldNotify: Bool { succeeded > 0 }

    var title: String {
        failed == 0 && needsAction == 0 ? "Seal 续签完成" : "Seal 续签部分完成"
    }

    var body: String {
        var parts = ["已续签 \(succeeded)/\(total) 个应用"]
        if failed > 0 { parts.append("失败 \(failed) 个") }
        if needsAction > 0 { parts.append("未执行 \(needsAction) 个") }
        return parts.joined(separator: "，") + "（快捷指令后台续签）"
    }
}

/// 一次投递的结果，供日志留痕（真机对账用）。
enum BackgroundRenewalNotificationDelivery: Equatable {
    case delivered
    /// 本轮没有成功的项 ⇒ 按上面那条规则不发。
    case skippedNoSuccess
    /// 用户没给通知权限 —— 不是错误，只留日志。
    case skippedNotAuthorized
    case failed(String)
}

/// 投递「快捷指令后台续签成功」的系统通知。
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
        guard result.shouldNotify else { return .skippedNoSuccess }

        let settings = await center.notificationSettings()
        let authorization = settings.authorizationStatus
        guard authorization == .authorized
            || authorization == .provisional
            || authorization == .ephemeral else {
            return .skippedNotAuthorized
        }

        let content = UNMutableNotificationContent()
        content.title = result.title
        content.body = result.body
        content.sound = .default

        // `trigger: nil` = 立即投递。
        // identifier **固定**（不拼时间戳）：同一轮只发一条；连续几轮触发时后一条覆盖
        // 前一条，不会在通知中心堆一摞「Seal 续签完成」。
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