//
//  Device.swift
//  Minimuxer
//
//  Original Rust Implementation by @jkcoxson
//  Swift Port created by Magesh K on 02/03/26.
//

import Foundation
import RustBridge

public final class Device {
    private let rustDevice: RustDevice

    init(rustDevice: RustDevice) { self.rustDevice = rustDevice }

    /// 取第一个设备；带**可显式指定的轮询预算**。
    ///
    /// - Parameter timeoutMs: 本次最多轮询多少毫秒。默认沿用 `deviceFetchTimeoutMs`（15 秒）——
    ///   对**一次性**路径（dump / 安装 / DDI / JIT）是对的：它们没有外层重试，宁可多等。
    ///
    ///   ⚠️ **就绪探测必须显式传短预算**（`MuxerConstants.probeDeviceFetchTimeoutMs`）。
    ///   `Minimuxer.ready()` / `Minimuxer.fetchUDIDDetailed()` 跑在一个
    ///   「36 轮 × 500ms」的**外层重试循环**里（`MinimuxerInstallChannel.diagnose()`），
    ///   外层已经在重试、内层再各烧 15 秒，会把「设计约 18 秒」放大成**最坏 9–18 分钟**。
    ///   真机证据（2026-09-20，构建 184，iOS 17.0–17.3.1 lockdown 路径）：界面停在
    ///   「验证中」**超过 12 分钟**没有任何结论，而那条路径恰好是「设备不可达」的**最坏**形态。
    ///
    ///   **判据：有外层重试的地方，内层预算必须短 —— 重试本身就是等待。**
    public static func getFirstDevice(
        timeoutMs: UInt16 = MuxerConstants.deviceFetchTimeoutMs
    ) throws -> Device {
        var remaining = timeoutMs
        let sleep = MuxerConstants.deviceFetchSleepMs

        while remaining > 0 {
            if let rd = RustDevice.fetchFirst() {
                return Device(rustDevice: rd)
            }
            Thread.sleep(forTimeInterval: Double(sleep) / 1000.0)
            remaining = remaining >= UInt16(sleep) ? remaining - UInt16(sleep) : 0
        }
        print("[minimuxer] ERROR: Couldn't fetch first device (timed out after \(timeoutMs)ms)")
        throw MinimuxerError.NoDevice
    }

    public func getUDID() -> String? { rustDevice.getUDID() }
    internal var internalInstance: RustDevice { rustDevice }
}
