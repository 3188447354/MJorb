import Foundation
import Testing
@testable import Seal

/// 「通道不就绪原因 → 可判读类别」这条映射的自证。
///
/// **为什么值得单测**：它的错法只在真机上表现为「给错下一步动作」——
/// 把「LocalDevVPN 没开」显示成「设备没响应」会让用户去重启 iPhone，
/// 而真正要做的是打开 LocalDevVPN。不崩、不报错、编译也过。
///
/// **为什么吃字符串**：`SealTests` target 没有 Minimuxer 依赖
/// （见 `DeviceChannelTransientPolicy` 的说明）⇒ 只能构造 `rawValue`。
/// 字符串与 `MinimuxerReadyIssue` 的一致性由守卫 R94 钉。
@Suite("通道不就绪原因：分类映射")
struct ChannelReadinessPolicyTests {

    @Test("上游 MinimuxerReadyIssue 的每个 rawValue 都有对应类别")
    func mapsEveryVendorIssueRawValue() {
        #expect(ChannelReadinessPolicy.cause(fromIssueRawValue: "noVPNInterface") == .vpnNotConnected)
        #expect(ChannelReadinessPolicy.cause(fromIssueRawValue: "tunnelUnreachable") == .tunnelUnreachable)
        #expect(ChannelReadinessPolicy.cause(fromIssueRawValue: "notStarted") == .notStarted)
        #expect(ChannelReadinessPolicy.cause(fromIssueRawValue: "usbmuxdNotReady") == .notStarted)
        #expect(ChannelReadinessPolicy.cause(fromIssueRawValue: "heartbeatStale") == .heartbeatStale)
        #expect(ChannelReadinessPolicy.cause(fromIssueRawValue: "noDevice") == .deviceMissing)
    }

    @Test("缺失或认不出的原因一律归为 unknown（不能猜成某个具体动作）")
    func unknownOrMissingIssueIsUnknown() {
        #expect(ChannelReadinessPolicy.cause(fromIssueRawValue: nil) == .unknown)
        #expect(ChannelReadinessPolicy.cause(fromIssueRawValue: "") == .unknown)
        #expect(ChannelReadinessPolicy.cause(fromIssueRawValue: "somethingElse") == .unknown)
        // 大小写敏感：rawValue 是契约，不做模糊匹配（改了契约就该在守卫里红，而不是在这里被吞）
        #expect(ChannelReadinessPolicy.cause(fromIssueRawValue: "NoVPNInterface") == .unknown)
    }

    @Test("分类结果不重复：每个 rawValue 只落进一个类别")
    func eachRawValueMapsToExactlyOneCause() {
        let raws = [
            "noVPNInterface", "tunnelUnreachable", "notStarted",
            "usbmuxdNotReady", "heartbeatStale", "noDevice"
        ]
        let causes = raws.map { ChannelReadinessPolicy.cause(fromIssueRawValue: $0) }
        #expect(Set(causes).count == 5)
    }
}