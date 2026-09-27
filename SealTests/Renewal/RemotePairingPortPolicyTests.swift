import Foundation
import Testing
@testable import Seal

/// RemotePairing 端口自愈判据的自证。
///
/// **为什么值得单测**：它决定「要不要为了换端口而多跑一轮 Bonjour 浏览 + 重建连接」。
/// 漏判 ⇒ 设备换了端口时怎么重试都撞同一个死端口（真机表现为「隧道通、就是连不上」）；
/// 误判 ⇒ 每次普通失败都白跑一轮浏览（变慢、还会无谓拆掉一条好连接）。
/// 两种都不崩、不报错，只有真机能看出来。
@Suite("RemotePairing 端口自愈：判据")
struct RemotePairingPortPolicyTests {

    @Test("只认 `SEAL-INSTALL-710`（隧道在、设备服务端口不可达）")
    func onlyTunnelUnreachableCodeTriggersReprobe() {
        #expect(RemotePairingPortPolicy.shouldReprobe(failureCode: "SEAL-INSTALL-710"))
    }

    @Test("相邻码一律不触发 —— 显式集合，不是 `SEAL-INSTALL-71` 数字区间")
    func siblingCodesDoNotTriggerReprobe() {
        // 709 = 安全握手未完成；702x = 设备语义拒绝；706x = 通道通用失败；701 = VPN 未就绪。
        // 这些换端口都没用，用 `hasPrefix("SEAL-INSTALL-71")` 会把 709 一起算进来。
        for code in ["SEAL-INSTALL-709", "SEAL-INSTALL-708", "SEAL-INSTALL-706b",
                     "SEAL-INSTALL-706t", "SEAL-INSTALL-701", "SEAL-INSTALL-702",
                     "SEAL-INSTALL-702l", "SEAL-INSTALL-702s", "SEAL-INSTALL-702d",
                     "SEAL-INSTALL-702t", "SEAL-PROFILE-352"] {
            #expect(RemotePairingPortPolicy.shouldReprobe(failureCode: code) == false,
                    "\(code) 不该触发端口重查")
        }
        #expect(RemotePairingPortPolicy.shouldReprobe(failureCode: nil) == false)
    }

    @Test("端口层「连不上」的原文触发重查")
    func detectsUnreachableMarkers() {
        #expect(RemotePairingPortPolicy.shouldReprobe(detail: "Socket(Os { code: 61, message: \"Connection refused\" })"))
        #expect(RemotePairingPortPolicy.shouldReprobe(detail: "connect: No route to host"))
        #expect(RemotePairingPortPolicy.shouldReprobe(detail: "Network is unreachable"))
        #expect(RemotePairingPortPolicy.shouldReprobe(detail: "Connection timed out"))
    }

    @Test("设备语义拒绝 / 终态错误**不**触发重查（否则每次失败都白跑一轮 Bonjour）")
    func deviceSemanticRejectionsDoNotTriggerReprobe() {
        #expect(RemotePairingPortPolicy.shouldReprobe(detail: "InstallApp(ApplicationVerificationFailed)") == false)
        #expect(RemotePairingPortPolicy.shouldReprobe(detail: "No space left on device") == false)
        #expect(RemotePairingPortPolicy.shouldReprobe(detail: "MissingPackagePath") == false)
        #expect(RemotePairingPortPolicy.shouldReprobe(detail: "PairingFile") == false)
        #expect(RemotePairingPortPolicy.shouldReprobe(detail: "") == false)
    }

    @Test("发现到不同端口才采纳；相同 / 0 / 没发现都不动")
    func adoptsOnlyChangedPort() {
        #expect(RemotePairingPortPolicy.resolve(current: 49152, discovered: 52100) == 52100)
        // 端口没变 ⇒ 不动（不无谓拆掉一条已经好的 RSD 连接）。
        #expect(RemotePairingPortPolicy.resolve(current: 49152, discovered: 49152) == nil)
        // 0 / nil 都是「没发现」。
        #expect(RemotePairingPortPolicy.resolve(current: 49152, discovered: 0) == nil)
        #expect(RemotePairingPortPolicy.resolve(current: 49152, discovered: nil) == nil)
    }

    @Test("服务类型列表与 `NSBonjourServices` 声明同源（漏声明 ⇒ 浏览静默失效）")
    func serviceTypesAreTheThreeRemotePairingVariants() {
        #expect(RemotePairingPortPolicy.serviceTypes == [
            "_remotepairing._tcp",
            "_remotepairing-pairable-host._tcp",
            "_remotepairing-manual-pairing._tcp"
        ])
    }
}