//
//  Minimuxer.swift
//  Minimuxer
//
//  Original Rust Implementation by @jkcoxson
//  Swift Port created by Magesh K on 02/03/26.
//

import Foundation
import RustBridge
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public struct Minimuxer {
    public static func describeError(_ error: MinimuxerError) -> String {
        return error.description
    }

    /// 当前配对文件决定的传输协议。RemotePairing 走 RSD 合并安装；Lockdown 必须走
    /// AFC 暂存 + installation_proxy，不能调用仅支持 RSD 的 Rust 合并入口。
    public static var isRemotePairing: Bool { Muxer.isrppairing }
    
    public static func bindTunnelConfig(_ binding: TunnelConfigBinding) {
        IfaceScanner.shared.bindTunnelConfig(binding)
    }
    
    public static func ready() -> Bool {
        
        let deviceIP: String
        do {
            if Muxer.isrppairing {
                deviceIP = "10.7.0.1"
            } else {
                deviceIP = try DeviceEndpoint.shared.ip()
            }

        } catch {
            print("[minimuxer] minimuxer not ready: device endpoint not initialized")
            return false
        }
        
        let deviceConnection = testDeviceConnection(ifaddr: deviceIP)
        if Muxer.isrppairing {
            return deviceConnection
        }

        /// 统一的不就绪诊断行。抽成局部函数只为**保持两个分支的字段完全一致**
        /// （排查时少一个字段就要重新猜一轮）。
        func reportNotReady(deviceExists: String) {
            print(
                "minimuxer not ready: " +
                "conn=\(deviceConnection) " +
                "dev=\(deviceExists) " +
                "hb=\(Heartbeat.lastBeatSuccessful) " +
                "dmg=\(Mounter.dmgMounted) " +
                "started=\(Muxer.started) " +
                "ready=\(Muxer.usbmuxdReady)"
            )
        }

        // ⚠️ **判据顺序有意义**（Seal 本地加固，2026-09-20）：`Device.getFirstDevice()` 是这里
        // **最贵**的一步（默认轮询 15 秒），而原先那个 guard 是**逻辑与** ⇒ 先把便宜且已经
        // 为假的判据算完、直接返回，语义**完全不变**，但把「隧道没通时每轮都要白跑一趟
        // 15 秒的阻塞探测」降到「每轮约 0 秒」。
        // 原实现**无条件**先跑 `getFirstDevice()`，于是**最坏的那条路径**（设备不可达）
        // 反而最慢：外层 `offThread(5 秒)` 只截断**等待**（名义上限 ≈ 3.4 分钟），
        // 但每轮都会遗弃一个还要再跑 15 秒的阻塞 FFI、持续占着协作线程池 ⇒
        // 真机「验证中」卡 **12 分钟以上**（构建 184 已复现，见 `DEBUG_LOG.md`）。
        guard deviceConnection, Heartbeat.lastBeatSuccessful, Muxer.started, Muxer.usbmuxdReady else {
            reportNotReady(deviceExists: "unknown")
            return false
        }

        // 前置条件都成立、只差设备本身 ⇒ 用**短预算**探测：探测不负责等待，
        // 等待由外层那 36 轮重试负责（见 `MuxerConstants.probeDeviceFetchTimeoutMs`）。
        let deviceExists: Bool
        do {
            _ = try Device.getFirstDevice(timeoutMs: MuxerConstants.probeDeviceFetchTimeoutMs)
            deviceExists = true
        } catch {
            deviceExists = false
        }
        guard deviceExists else {
            reportNotReady(deviceExists: "\(deviceExists)")
            return false
        }
        
        if #available(iOS 26.4, *) {
            if !IfaceScanner.shared.vpnPatched() {
                print("[minimuxer] WARN: VPN subnet not patched")
            }
        }
        return true
    }

    public static func setDebug(_ debug: Bool) {
        rustBridgeSetDebug(debug)
    }

    public static func start(pairingFile: String, logPath: String) throws {
        try startWithLogger(pairingFile: pairingFile, logPath: logPath, isConsoleLoggingEnabled: true)
    }

    public static func startWithLogger(pairingFile: String, logPath: String, isConsoleLoggingEnabled: Bool) throws {
        try Muxer.start(pairingFile: pairingFile, logPath: logPath)
    }

    public static func reset() {
        // ⚠️ **必须在 `Muxer.reset()` 之前读**（Seal 本地加固，2026-09-21）✗ ——
        // `Muxer.reset()` 内部的 `teardownLocked()` 会把 `_isrppairing` 清成 `false`，
        // 之后再问就**恒为假** ⇒ 下面那条「清掉 Rust 的 RSD 缓存连接」永远不执行 ✗。
        // 而本仓三处注释都写着它是清死连接的唯一杠杆（`Install.resetProvider()` 只清
        // Swift 侧对象，清不掉 Rust 的会话缓存）⇒ 真机上表现为「重试一直复用死连接」。
        let wasRemotePairing = Muxer.isrppairing
        Muxer.reset()
        DeviceEndpoint.shared.clear()
        Install.resetProvider()
        Provision.resetProvider()
        JIT.resetProvider()
        Mounter.resetProvider()
        // RSD 缓存连接可能已随隧道断开；不复位会让重试一直复用死连接
        if wasRemotePairing {
            RustIdevice.invalidateConnection()
        }
    }

    public static func retargetUsbmuxdAddr() {
        Muxer.retargetUsbmuxdAddr()
    }

    public static func fetchUDID() -> String? {
        print("[minimuxer] Getting UDID for first device")
        guard Muxer.started else {
            print("[minimuxer] ERROR: minimuxer has not started!")
            return nil
        }
        let udid: String?
        if Muxer.isrppairing {
            udid = RustIdevice.fetchUDID()
        } else {
            udid = (try? Device.getFirstDevice())?.getUDID()
        }

        if let udid = udid {
            print("[minimuxer] UDID: \(udid)")
        } else {
            print("[minimuxer] ERROR: Failed to get UDID")
        }
        return udid
    }

    /// 不吞错的 UDID 获取：会话未启动、RSD 通道的 Rust IdeviceError（设备未认可配对 /
    /// 隧道不可达 / 握手失败）、经典通道取不到标识都会原样抛出，供通道诊断精准分类。
    public static func fetchUDIDDetailed() throws -> String {
        guard Muxer.started else {
            print("[minimuxer] ERROR: minimuxer has not started!")
            throw NSError(
                domain: "minimuxer",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "minimuxer has not started"]
            )
        }
        if Muxer.isrppairing {
            return try RustIdevice.fetchUDIDDetailed()
        }
        // 短预算（Seal 本地加固，2026-09-20）：本函数只被**探测**路径调用 ——
        // `MinimuxerInstallChannel.readyDeviceIdentifier()`（跑在 36 轮重试循环里）与
        // `probeCachedSessionIfStale()`（外层 `offThread(5 秒)` 兜底）。
        // 两处外层都已经有等待与重试 ⇒ 内层再烧 15 秒会把「约 18 秒」放大成「十几分钟」。
        // ⚠️ `Device.getFirstDevice(...)` 这段**保持单行**：守卫 R61 用 squashed 文本断言它 ✓。
        guard let udid = try Device.getFirstDevice(timeoutMs: MuxerConstants.probeDeviceFetchTimeoutMs)
            .getUDID(), udid.isEmpty == false else {
            throw NSError(
                domain: "minimuxer",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "lockdown returned no device identifier"]
            )
        }
        return udid
    }

    public static func testDeviceConnection(ifaddr: String?) -> Bool {
        guard let ip = ifaddr, ip.isEmpty == false else { return false }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = Muxer.isrppairing
            ? MuxerConstants.rsdPort.bigEndian
            : MuxerConstants.lockdowndPort.bigEndian
        guard inet_pton(AF_INET, ip, &addr.sin_addr) == 1 else { return false }

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        let flags = fcntl(fd, F_GETFL, 0)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
            return false
        }

        let connectResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if connectResult == 0 { return true }
        guard errno == EINPROGRESS else { return false }

        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let pollResult = poll(&pfd, 1, 500)
        guard pollResult > 0,
              (pfd.revents & Int16(POLLOUT)) != 0,
              (pfd.revents & Int16(POLLERR | POLLHUP | POLLNVAL)) == 0 else {
            return false
        }

        var socketError: Int32 = 0
        var socketErrorLength = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(
            fd,
            SOL_SOCKET,
            SO_ERROR,
            &socketError,
            &socketErrorLength
        ) == 0 else {
            return false
        }
        return socketError == 0
    }

    public static func yeetAppAfc(bundleId: String, ipaBytes: Data) throws {
        try Install.yeetAppAfc(bundleId: bundleId, ipaBytes: ipaBytes)
    }

    public static func installIpa(bundleId: String) throws {
        try Install.installIpa(bundleId: bundleId)
    }

    /// OTA：生成本地 HTTPS 证书，返回 JSON（ca_pem/cert_pem/key_pem）
    public static func otaIdentityGenerate() throws -> String {
        try RustIdevice.otaIdentityGenerate()
    }

    /// OTA：配置服务器资源
    public static func otaConfigure(
        caPem: String, certPem: String, keyPem: String,
        caProfilePath: String, manifestPath: String, ipaPath: String
    ) throws {
        try RustIdevice.otaConfigure(
            caPem: caPem, certPem: certPem, keyPem: keyPem,
            caProfilePath: caProfilePath, manifestPath: manifestPath, ipaPath: ipaPath
        )
    }

    /// OTA：启动 HTTPS 服务器，返回端口
    public static func otaServe() throws -> UInt16 {
        try RustIdevice.otaServe()
    }

    /// 上传+安装合并调用：**安装主链路**（同一缓存隧道会话内完成两段，见 install.rs 会话不变量）
    public static func stageAndInstall(
        bundleId: String,
        ipaBytes: Data
    ) throws {
        try RustIdevice.stageAndInstall(
            bundleId: bundleId,
            ipaBytes: ipaBytes
        )
    }

    /// 带 AFC 上传进度（0-1）的合并调用，供 UI 展示真实传输百分比。
    public static func stageAndInstall(
        bundleId: String,
        ipaBytes: Data,
        progress: @escaping (Double) -> Void
    ) throws {
        try RustIdevice.stageAndInstall(
            bundleId: bundleId,
            ipaBytes: ipaBytes,
            progress: progress
        )
    }

    public static func removeApp(bundleId: String) throws {
        try Install.removeApp(bundleId: bundleId)
    }

    public static func lookupApp(bundleId: String) -> String? {
        if Muxer.isrppairing {
            return try? RustIdevice.lookupApp(bundleId: bundleId)
        }
        guard let device = try? Device.getFirstDevice(),
              let inst = RustInstProxy.connect(
                device: device.internalInstance,
                label: "minimuxer-lookup-app"
              ) else {
            return nil
        }
        return inst.lookup(appId: bundleId)
    }

    public static func isAppInstalled(bundleId: String) throws -> Bool {
        if Muxer.isrppairing {
            return try RustIdevice.lookupApp(bundleId: bundleId) != nil
        }
        guard let device = try? Device.getFirstDevice(),
              let inst = RustInstProxy.connect(
                device: device.internalInstance,
                label: "minimuxer-lookup-app"
              ) else {
            throw NSError(
                domain: "Minimuxer",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "Device not found"]
            )
        }
        return inst.lookup(appId: bundleId) != nil
    }
    public static func debugApp(appId: String) throws {
        try JIT.debugApp(appId: appId)
    }

    public static func attachDebugger(pid: UInt32) throws {
        try JIT.attachDebugger(pid: pid)
    }

    public static func startAutoMounter(docsPath: String) {
        Mounter.startAutoMounter(docsPath: docsPath)
    }

    public static func installProvisioningProfile(profile: Data) throws {
        try Provision.installProvisioningProfile(profile: profile)
    }

    public static func removeProvisioningProfile(id: String) throws {
        try Provision.removeProvisioningProfile(id: id)
    }

    public static func dumpProfiles(docsPath: String) throws -> String {
        return try Provision.dumpProfiles(docsPath: docsPath)
    }
}
