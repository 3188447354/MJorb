import Foundation
import Testing
@testable import Seal

/// 「本地隧道掉线」判定的自证。
///
/// **为什么值得单测**：它决定「要不要立刻作废通道会话缓存」——
/// 漏判 ⇒ 重试三次都撞同一个死会话（真机表现为「续签怎么点都不成」）；
/// 误判 ⇒ 缓存被无谓作废、每轮多跑一遍诊断（变慢但还成）。
/// 两种都不崩、不报错，只有真机能看出来。
@Suite("本地隧道掉线：判据")
struct DeviceChannelVPNDropPolicyTests {

    @Test("传输层「对端消失」的原文都判为掉线")
    func detectsTunnelDropMarkers() {
        #expect(DeviceChannelVPNDropPolicy.isVPNDrop(detail: "Socket error: Broken pipe"))
        #expect(DeviceChannelVPNDropPolicy.isVPNDrop(detail: "read: connection reset by peer"))
        #expect(DeviceChannelVPNDropPolicy.isVPNDrop(detail: "ECONNRESET (54)"))
        #expect(DeviceChannelVPNDropPolicy.isVPNDrop(detail: "Early EOF while reading response"))
        #expect(DeviceChannelVPNDropPolicy.isVPNDrop(detail: "ENOTCONN: socket is not connected"))
        #expect(DeviceChannelVPNDropPolicy.isVPNDrop(detail: "No route to host"))
    }

    @Test("设备语义错误刻意**不**判为掉线（否则失去区分度、缓存被无谓作废）")
    func deterministicRejectionsAreNotDrops() {
        #expect(DeviceChannelVPNDropPolicy.isVPNDrop(detail: "ApplicationVerificationFailed") == false)
        #expect(DeviceChannelVPNDropPolicy.isVPNDrop(detail: "No space left on device") == false)
        #expect(DeviceChannelVPNDropPolicy.isVPNDrop(detail: "PairingFile") == false)
        #expect(DeviceChannelVPNDropPolicy.isVPNDrop(detail: "MissingPackagePath") == false)
        #expect(DeviceChannelVPNDropPolicy.isVPNDrop(detail: "") == false)
    }

    @Test("Error 重载：ImportFailure 的原始文本在 reason 里，必须能读到")
    func errorOverloadReadsImportFailureReason() {
        // `ImportFailure.errorDescription` 只回 title ⇒ 只查 title 会漏掉真实原因。
        let failure = ImportFailure(
            title: "安装失败",
            reason: "设备返回：read: connection reset by peer",
            recovery: "重试",
            code: "SEAL-INSTALL-702"
        )
        #expect(DeviceChannelVPNDropPolicy.isVPNDrop(failure))
    }

    @Test("Error 重载：NSError 走 localizedDescription / 域码")
    func errorOverloadReadsNSError() {
        let withDescription = NSError(
            domain: "Minimuxer.MinimuxerError",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "connection reset by peer"]
        )
        #expect(DeviceChannelVPNDropPolicy.isVPNDrop(withDescription))

        // 不带任何掉线原文的错误必须为假（域 + 码本身不含 marker）。
        let unrelated = NSError(domain: "Minimuxer.MinimuxerError", code: 0)
        #expect(DeviceChannelVPNDropPolicy.isVPNDrop(unrelated) == false)
    }
}