//
//  MuxerConstants.swift
//  Minimuxer
//
//  Original Rust Implementation by @jkcoxson
//  Swift Port created by Magesh K on 02/03/26.
//

import Foundation

public enum MuxerConstants {
    public static let lockdowndPort: UInt16 = 62078     // lockdown daemon port
    public static let rsdPort: UInt16 = 49152

    public static let usbmuxdHost = "127.0.0.1"
    public static let usbmuxdPort: UInt16 = 27015       // usbmux daemon port
    public static let usbmuxdSocket = "\(usbmuxdHost):\(usbmuxdPort)"
    
    public static let heartbeatTimeoutMs: UInt32 = 12000
    public static let deviceFetchTimeoutMs: UInt16 = 15000
    public static let deviceFetchSleepMs: UInt32 = 250

    /// 就绪探测（`Minimuxer.ready()` / `Minimuxer.fetchUDIDDetailed()`）用的设备轮询预算。
    ///
    /// ⚠️ **Seal 本地加固（2026-09-20）**：探测**不负责等待** —— 等待由外层重试循环负责
    /// （`MinimuxerInstallChannel.diagnose()` 的 `for attempt in 0..<36` ＋ 500ms 睡眠，
    /// 设计意图是「给 RSD 握手约 18 秒」）。就绪探测里用 15 秒的 `deviceFetchTimeoutMs`
    /// 会让**每一轮**白等 15 秒 ⇒ 把「设计约 18 秒」放大成**最坏 9–18 分钟**。
    ///
    /// 真机证据（构建 184，iOS 17.0–17.3.1 的 lockdown 路径）：用户界面停在「验证中」
    /// **超过 12 分钟**没有任何结论 —— 而那条路径恰好是「设备不可达」，也就是**最坏**路径。
    ///
    /// 取 1000ms ≈ 4 个 `deviceFetchSleepMs` 周期：够覆盖「设备刚出现、muxer 还没回报」的抖动，
    /// 又不会把一轮探测拖成 15 秒。**一次性路径（dump / 安装 / DDI / JIT）继续用 15 秒** ——
    /// 它们没有外层重试，多等是正确的。
    public static let probeDeviceFetchTimeoutMs: UInt16 = 1000
    
    public static let pkgPath = "PublicStaging"
    public static let usbmuxdEnvKey = "USBMUXD_SOCKET_ADDRESS"

    public static let pre17VersionsURL = "https://raw.githubusercontent.com/jkcoxson/JitStreamer/master/versions.json"
    public static let ddiImageURL = "https://raw.githubusercontent.com/doronz88/DeveloperDiskImage/refs/heads/main/PersonalizedImages/Xcode_iOS_DDI_Personalized/Image.dmg"
    public static let ddiTrustcacheURL = "https://raw.githubusercontent.com/doronz88/DeveloperDiskImage/refs/heads/main/PersonalizedImages/Xcode_iOS_DDI_Personalized/Image.dmg.trustcache"
    public static let ddiManifestURL = "https://raw.githubusercontent.com/doronz88/DeveloperDiskImage/refs/heads/main/PersonalizedImages/Xcode_iOS_DDI_Personalized/BuildManifest.plist"
}
