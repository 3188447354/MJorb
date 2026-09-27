import Foundation
import Network

/// 经 Bonjour 发现设备 RemotePairing 服务的**端口**（对齐上游 SideStore
/// `BonjourDiscoveryManager.resolveFirstService` 的一次性解析路径）。
///
/// ## 只取端口，不取主机
///
/// 上游连的是发现到的主机；Seal 的 RSD 对端固定是 LocalDevVPN 网关 `10.7.0.1`
///（`Vendor/Minimuxer/RustBridge/src/idevice_support/rsd.rs` 里写死的
/// `SocketAddrV4::new(Ipv4Addr::new(10, 7, 0, 1), port)`）⇒ **只有端口是变量**，
/// 所以这里只回端口，不把「连哪台主机」这件已有答案的事再决定一遍。
///
/// ## 前提：`NSBonjourServices`
///
/// 浏览 Bonjour 服务需要在 `Info.plist` 声明服务类型（见 `project.yml`）；
/// 缺了它 `NWBrowser` **不报错、只是永远没有结果** —— 静默失效，日志上也看不出来。
/// 守卫 R95 会钉住这三个声明与 `RemotePairingPortPolicy.serviceTypes` 一致。
///
/// ## 为什么套一层 `ConnectionHolder`
///
/// `NWConnection` 在 Swift 6 严格并发下不适合直接进 `@Sendable` 回调（本仓
/// `SWIFT_STRICT_CONCURRENCY = complete`）。`LocalNetworkPermissionPrimer`
/// 已有同样形态的先例（`LocalNetworkPermissionProbe` 持有 connection）；
/// 这里复用同一做法，并且**复用现成的 `ContinuationBox`** 做「只恢复一次」，
/// 不再新造第二个锁盒。
enum RemotePairingPortDiscovery {

    /// 一次性解析出的端口；`nil` = 没发现 / 超时 / 解析失败。
    ///
    /// - Parameters:
    ///   - browseTimeout: 浏览（找服务实例）预算。多个服务类型**并发**浏览，取最先命中的。
    ///   - resolveTimeout: 解析（服务实例 → 端口）预算。
    static func discoverPort(
        browseTimeout: TimeInterval = 1.8,
        resolveTimeout: TimeInterval = 1.2
    ) async -> UInt16? {
        guard let endpoint = await firstServiceEndpoint(browseTimeout: browseTimeout) else {
            return nil
        }
        return await resolvePort(of: endpoint, timeout: resolveTimeout)
    }

    // MARK: - 找服务实例

    /// 并发浏览 `RemotePairingPortPolicy.serviceTypes`，返回**最先命中**的服务端点。
    private static func firstServiceEndpoint(browseTimeout: TimeInterval) async -> NWEndpoint? {
        await withTaskGroup(of: NWEndpoint?.self) { group in
            for serviceType in RemotePairingPortPolicy.serviceTypes {
                group.addTask {
                    await browseFirstEndpoint(ofType: serviceType, timeout: browseTimeout)
                }
            }
            // 命中即返回：`withTaskGroup` 会自动取消并等待其余子任务。
            for await endpoint in group {
                if let endpoint { return endpoint }
            }
            return nil
        }
    }

    private static func browseFirstEndpoint(
        ofType rawType: String,
        timeout: TimeInterval
    ) async -> NWEndpoint? {
        let serviceType = rawType.hasSuffix(".") ? String(rawType.dropLast()) : rawType
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: serviceType, domain: nil), using: parameters)

        let endpoint: NWEndpoint? = await withCheckedContinuation { continuation in
            let box = ContinuationBox<NWEndpoint?>(continuation)
            browser.browseResultsChangedHandler = { results, _ in
                // 优先 loopback：设备自身的 RemotePairing 守护进程经 lo0 广播
                //（对齐上游 `isPreferredCandidate` 的 lo0 判据）。
                let candidates: [(isLoopback: Bool, endpoint: NWEndpoint)] = results.compactMap { result in
                    guard case .service = result.endpoint else { return nil }
                    let isLoopback = result.interfaces.contains { $0.type == .loopback }
                    return (isLoopback, result.endpoint)
                }
                guard let match = candidates.first(where: { $0.isLoopback }) ?? candidates.first else {
                    return
                }
                box.resume(returning: match.endpoint)
            }
            browser.stateUpdateHandler = { state in
                if case .failed = state { box.resume(returning: nil) }
            }
            browser.start(queue: .global(qos: .userInitiated))
            Task {
                try? await Task.sleep(for: .seconds(timeout))
                box.resume(returning: nil)
            }
        }
        // 清回调再取消：断开 `browser → handler → box` 的引用，避免留下悬挂回调。
        browser.browseResultsChangedHandler = nil
        browser.stateUpdateHandler = nil
        browser.cancel()
        return endpoint
    }

    // MARK: - 端点 → 端口

    /// 解析服务端点的真实端口。
    ///
    /// `.waiting` 也算成功：`NWConnection` 解析出远端 `host:port` 之后，即便暂时连不上
    ///（设备那个端口本来就没起），**端口也已经拿到了** —— 而我们要的正是端口。
    private static func resolvePort(of endpoint: NWEndpoint, timeout: TimeInterval) async -> UInt16? {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let connection = NWConnection(to: endpoint, using: parameters)
        let holder = ConnectionHolder(connection)

        let port: UInt16? = await withCheckedContinuation { continuation in
            let box = ContinuationBox<UInt16?>(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready, .waiting:
                    guard let remote = holder.connection.currentPath?.remoteEndpoint,
                          case .hostPort(_, let port) = remote else { return }
                    box.resume(returning: port.rawValue)
                case .failed:
                    box.resume(returning: nil)
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
            Task {
                try? await Task.sleep(for: .seconds(timeout))
                box.resume(returning: nil)
            }
        }
        connection.stateUpdateHandler = nil
        connection.cancel()
        return port
    }
}

/// 只为在 `@Sendable` 回调里读 `currentPath` 而持有 `NWConnection`。
///
/// `NWConnection` 本身是线程安全的（Network 框架的并发模型），这里只是把
/// 「非 Sendable 类型进 `@Sendable` 闭包」这件事显式收口到一个点上 ——
/// 与 `LocalNetworkPermissionPrimer.LocalNetworkPermissionProbe` 同一形态。
private final class ConnectionHolder: @unchecked Sendable {
    let connection: NWConnection

    init(_ connection: NWConnection) {
        self.connection = connection
    }
}