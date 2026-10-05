import AVFoundation
import Foundation

/// 静音音频的**运行时生成**（纯逻辑，可单测）。
///
/// 上游 SideStore 就是这么做的（`BackgroundAudioService.swift:53` / `:120-146`）：
/// **不打包音频资源**，每次运行时生成一小段纯 0 的 WAV。好处是不用往仓库里塞二进制，
/// 也不会被第三方签名工具当成「资源」漏签（本项目刚被 `PlugIns` 类漏签坑过）。
enum BackgroundKeepAliveAssets {
    /// 8 kHz / 单声道 / 16 bit —— 1 秒只有 16 KB，解码开销可忽略，
    /// 而 `AVAudioPlayer` 循环播放它时系统只当「有一段音频在放」。
    static let sampleRate = 8_000
    static let channels = 1
    static let bitsPerSample = 16
    static let seconds = 1

    /// 1 秒纯 0 的 PCM WAV。
    ///
    /// ⚠️ **必须写成真正的 WAV 头，不能只塞一段 0 字节** ——
    /// `AVAudioPlayer(contentsOf:)` 会解析失败并抛错，保活静默失效，
    /// 而日志里只会看到「启动失败」，看不出是格式问题。
    static func silentWAVData() -> Data {
        let bytesPerSample = bitsPerSample / 8
        let blockAlign = channels * bytesPerSample
        let byteRate = sampleRate * blockAlign
        let payloadSize = byteRate * seconds

        var data = Data(capacity: 44 + payloadSize)
        data.append(contentsOf: "RIFF".utf8)
        appendLittleEndian(UInt32(36 + payloadSize), to: &data)
        data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8)
        appendLittleEndian(UInt32(16), to: &data) // fmt 块长度
        appendLittleEndian(UInt16(1), to: &data) // 1 = PCM
        appendLittleEndian(UInt16(channels), to: &data)
        appendLittleEndian(UInt32(sampleRate), to: &data)
        appendLittleEndian(UInt32(byteRate), to: &data)
        appendLittleEndian(UInt16(blockAlign), to: &data)
        appendLittleEndian(UInt16(bitsPerSample), to: &data)
        data.append(contentsOf: "data".utf8)
        appendLittleEndian(UInt32(payloadSize), to: &data)
        data.append(Data(count: payloadSize))
        return data
    }

    private static func appendLittleEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { raw in
            data.append(contentsOf: raw)
        }
    }
}

/// 音频中断结束后的处置（纯判据，可单测）。
enum BackgroundKeepAlivePolicy {
    /// 只有 `.ended` 需要重新激活。
    ///
    /// 🔴 **不恢复的话，一次来电或闹钟就能把保活永久打断** ——
    /// 系统会 `setActive(false)`，之后进程照旧在后台，但已经不再受「正在播放音频」保护，
    /// 下一次切后台就被挂起，而日志里**一行异常都没有**（上游 `BackgroundAudioService.swift:79-98`
    /// 专门处理这条，不是可选的润色）。
    /// `.began` 时系统已经替我们停了播放，这里不该做任何事。
    static func shouldResume(afterInterruption type: AVAudioSession.InterruptionType) -> Bool {
        type == .ended
    }

    /// 音频**路由变更**后要不要尝试恢复保活（纯判据，可单测）。
    ///
    /// 判据只在**播放确实已停**时才会被问到（调用方先查 `isRunning == false`），
    /// 所以这里的语义是「这种路由变更是否可能把我们的播放停掉」。
    ///
    /// 🔴 不恢复的话：拔耳机 / 断开蓝牙时系统会 `setActive(false)` 并停掉播放，
    /// 保活从此**静默失效** —— 进程还在后台、日志里一行异常都没有，
    /// 而续签会在无人察觉时被挂起（这正是「锁屏 / 看电视 / 听歌时续签失败」的形态）。
    /// 上游 SideStore **没有**处理路由变更（`BackgroundAudioService.swift` 只监听
    /// `interruptionNotification`）⇒ 这是 Seal 的补强，不是照抄。
    static func shouldReactivate(afterRouteChange reason: AVAudioSession.RouteChangeReason?) -> Bool {
        guard let reason else {
            // 原因读不到（`userInfo` 缺键）时**保守恢复**：漏恢复的代价是保活静默失效，
            // 多恢复一次的代价只是一次无副作用的 `play()`。
            return true
        }
        switch reason {
        case .categoryChange:
            // **我们自己** `setCategory` 就会发这条 —— 而恢复动作里又要 `setCategory`，
            // 一旦恢复失败就会自激（恢复失败 → 又收到 categoryChange → 再恢复…）⇒ 不响应。
            return false
        case .noSuitableRouteForCategory:
            // 当前没有可用输出路由，恢复注定失败（只会刷警告日志）；
            // 等下一次路由变更（例如重新插上耳机）自然会把我们叫回来。
            return false
        case .newDeviceAvailable, .oldDeviceUnavailable, .routeConfigurationChange,
             .override, .wakeFromSleep, .unknown:
            return true
        @unknown default:
            return true
        }
    }
}

/// 保活（重新）启动的原因 —— 决定日志措辞与日志码。
///
/// 🔴 为什么值得单独一个类型：这条链路在后台是**静默**的（后台没有界面、用户看不见），
/// 日志是唯一证据。把四种原因写成同一句「已启动」，真机排障时就分不清
/// 「保活到底有没有被中断过」—— 而这恰恰是判断「续签失败是不是因为进程被挂起」的关键。
enum BackgroundKeepAliveActivationReason: Sendable {
    /// 首次启动（`SealApp.init()` 或 App Intent）。
    case initial
    /// 音频中断（来电 / 闹钟）结束后恢复。
    case interruptionResumed
    /// 音频路由变更（插拔耳机、连断蓝牙）后恢复。
    case routeChanged
    /// 媒体服务被系统重置后恢复。
    case mediaServicesReset

    var successMessage: String {
        switch self {
        case .initial:
            return "后台保活已启动：静音音频无限循环，避免 Seal 在后台被系统挂起"
        case .interruptionResumed:
            return "后台保活已从音频中断中恢复（重新激活会话并继续播放）"
        case .routeChanged:
            return "后台保活已从音频路由变更中恢复（重新激活会话并继续播放）"
        case .mediaServicesReset:
            return "后台保活已从媒体服务重置中恢复（重建播放器并继续播放）"
        }
    }

    var successCode: String {
        switch self {
        case .initial: return "SEAL-BACKGROUND-001"
        case .interruptionResumed: return "SEAL-BACKGROUND-003"
        case .routeChanged: return "SEAL-BACKGROUND-010"
        case .mediaServicesReset: return "SEAL-BACKGROUND-012"
        }
    }

    var failureMessage: String {
        switch self {
        case .initial:
            return "后台保活启动失败：不打开 App 的续签可能被系统挂起，只能在前台完成"
        case .interruptionResumed:
            return "后台保活恢复失败（音频中断后）：下一次切后台起 Seal 会被系统挂起"
        case .routeChanged:
            return "后台保活恢复失败（音频路由变更后）：下一次切后台起 Seal 会被系统挂起"
        case .mediaServicesReset:
            return "后台保活恢复失败（媒体服务重置后）：下一次切后台起 Seal 会被系统挂起"
        }
    }

    var failureCode: String {
        switch self {
        case .initial: return "SEAL-BACKGROUND-002"
        case .interruptionResumed: return "SEAL-BACKGROUND-004"
        case .routeChanged: return "SEAL-BACKGROUND-011"
        case .mediaServicesReset: return "SEAL-BACKGROUND-013"
        }
    }
}

/// 保活启动失败的原因。
enum BackgroundKeepAliveError: LocalizedError {
    /// 系统接受了配置却拒绝播放（`play()` 返回 false）。
    case playbackRejected

    var errorDescription: String? {
        switch self {
        case .playbackRejected:
            return "系统拒绝了静音音频的播放请求"
        }
    }
}

/// 后台保活：靠**静音音频无限循环**让 iOS 不在后台挂起 Seal。
///
/// 🔴 为什么必须有它：「不打开 App 的后台自动续签」里，**触发**（快捷指令 / App Intent）
/// 只负责**点火**。iOS 给后台任务的时间窗只有约 30 秒，而大包续签（抖音 658 MB）
/// 要几分钟到十几分钟 ⇒ 没有保活，进程会被挂起、续签做到一半就停在那里，
/// 而界面上什么都看不到（后台没有界面）。
///
/// ⚠️ **本项目原有的「后台保活」不是这一套**：`SigningCoordinator` 用的是
/// `UIApplication.beginBackgroundTask`（约 30 秒、一次性），只在**已经在前台发起**的
/// 续签里兜底（见 `SigningCoordinator.swift:306-320` / `:1813-1821`）。
/// **没有任何东西能让 Seal 在后台长期活着** —— 那正是本类补的东西。
///
/// 做法对齐上游 SideStore（`SideStore/Core/BackgroundServices/BackgroundAudioService.swift`）：
/// ① `AVAudioSession` 声明 `.playback` ＋ `.mixWithOthers`（不抢占其他 App 的音频）；
/// ② 运行时生成静音 WAV，`numberOfLoops = -1` 无限循环；
/// ③ `volume = 0.01` —— **刻意不是 0**：完全静音时系统可能判定为「没有在播放」而不予保活；
/// ④ 监听 `interruptionNotification`，`.ended` 后重新激活并继续播放。
///
/// 🔴 **在 ④ 之外，Seal 还补了三条自愈**（上游没有，2026-09-27）：保活的失败模式全是
/// 「进程还活着、但音频早停了」—— 而**没有任何通知被漏掉**，只是上游只处理了中断这一种：
///   · `routeChangeNotification`：拔耳机 / 断蓝牙后系统 `setActive(false)` 并停掉播放；
///   · `mediaServicesWereResetNotification`：媒体守护进程重启，**所有音频对象作废**
///     （`AVAudioPlayer` 变无效，必须重建，只 `play()` 不够）；
///   · 以及「保活被停掉后 `start()` 再也不重试」—— 见 `isRunning` 与 `isEnabled` 的区别。
/// 这三条不补，用户报的正是「锁屏 / 看电视 / 听歌时续签不成功」这种查不出原因的形态。
///
/// ⚠️ 本类**只有 `start()`、没有 `stop()`**：保活一旦启动就持续（对齐上游）。
/// 有意不加自动停止 —— 「什么时候可以安全地让进程被挂起」这个问题现在没有答案，
/// 猜错的代价是续签半途而废，而半途而废在后台是**看不见**的。
@MainActor
final class BackgroundKeepAliveService {
    private let logStore: SealLogStore?
    private var player: AVAudioPlayer?
    private var silentAudioURL: URL?
    private var interruptionObserver: NSObjectProtocol?
    private var routeChangeObserver: NSObjectProtocol?
    private var mediaServicesResetObserver: NSObjectProtocol?

    /// 保活是否**真的**在播放静音音频。
    ///
    /// 🔴 判据必须是**真实播放状态**，不能是自己维护的布尔位（2026-09-27）。
    /// 保活的失败模式全是「进程还在、标志位还是 true、但音频早停了」：媒体服务重置、
    /// 路由变更、中断未恢复都会造成这种状态。标志位若仍为 true，`start()` 的幂等闸门
    /// 会把后续**每一次**自愈请求全部挡掉 —— 保活一旦死掉就再也起不来，
    /// 而后台续签会在无人察觉时被挂起。上游同样用真实播放状态
    /// （`BackgroundAudioService.swift:15-17`：`player?.isPlaying ?? false`）。
    var isRunning: Bool { player?.isPlaying == true }

    /// 保活是否**被请求过**（一旦置位不再复位 —— 本类没有 `stop()`）。
    ///
    /// 与 `isRunning` 的区别是「意图」与「事实」：通知回调必须用**意图**判据
    /// （音频已经停了才需要恢复，此时 `isRunning` 已是 false），
    /// 若用事实判据会把该做的恢复全部挡掉 —— 那正是「保活停了就不再自愈」的病根。
    private(set) var isEnabled = false

    init(logStore: SealLogStore? = nil) {
        self.logStore = logStore
    }

    /// 幂等启动。**失败不抛错**（保活失败不该让续签本身失败），但必须留痕 ——
    /// 否则真机上「后台续签跑到一半停了」会变成一个查不出原因的悬案。
    ///
    /// ⚠️ 幂等判据是 `isRunning`（真实播放）而不是一个自维护的布尔位：
    /// 这样「保活已死」时再调 `start()` 会**自愈重建**，而不是被永久挡掉。
    func start() {
        isEnabled = true
        guard isRunning == false else { return }
        reactivate(reason: .initial)
    }

    /// 保活（重新）启动的**唯一实现** —— `start()` 与三种自愈回调都走它。
    ///
    /// ⚠️ **不要为某一种原因另写一份**：同一条规则两份实现，本仓已经踩过五次
    /// （心跳只加在自替换路径、词表一致但取词不同源…）。
    private func reactivate(reason: BackgroundKeepAliveActivationReason) {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            // 每次都重建播放器：媒体服务重置后旧对象已作废，复用它 `play()` 会失败；
            // 而重建一个 16 KB 静音 WAV 的播放器开销可忽略（只在启动 / 自愈时发生）。
            let url = try makeSilentAudioFile()
            let player = try AVAudioPlayer(contentsOf: url)
            player.numberOfLoops = -1
            player.volume = 0.01
            guard player.play() else {
                throw BackgroundKeepAliveError.playbackRejected
            }
            self.player = player
            observeNotifications()
            append(message: reason.successMessage, code: reason.successCode)
        } catch {
            append(
                level: .warning,
                message: "\(reason.failureMessage)（\(error.localizedDescription)）",
                code: reason.failureCode
            )
        }
    }

    private func makeSilentAudioFile() throws -> URL {
        if let silentAudioURL, FileManager.default.fileExists(atPath: silentAudioURL.path) {
            return silentAudioURL
        }
        // 放系统 tmp（`<沙盒>/tmp`），**不放** `Caches/Seal` ——
        // `AppFileStore.init` 每次构造都会把 `Caches/Seal` 删掉，放那里会被删掉。
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "SealBackgroundKeepAlive",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "SealKeepAliveSilence.wav")
        try BackgroundKeepAliveAssets.silentWAVData().write(to: url, options: .atomic)
        silentAudioURL = url
        return url
    }

    /// 注册三种通知（各只注册一次）。
    ///
    /// ⚠️ **`object` 一律传 `nil`**，不能传 `AVAudioSession.sharedInstance()`：
    /// 媒体服务被重置后系统会换一个新的会话实例，用旧实例当过滤器就**再也收不到通知**
    /// —— 而那正是最需要恢复的一种。上游 SideStore 也用的是 `object: nil`
    /// （`BackgroundAudioService.swift:26`）。
    private func observeNotifications() {
        let center = NotificationCenter.default
        if interruptionObserver == nil {
            interruptionObserver = center.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                // ⚠️ 先把原始值取成 `UInt` 再进 `Task`：`Notification` / `userInfo` 在严格并发下
                // 不适合跨隔离域传递，而 `UInt` 是 `Sendable`。
                let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                Task { @MainActor [weak self] in
                    self?.handleInterruption(rawType: rawType)
                }
            }
        }
        if routeChangeObserver == nil {
            routeChangeObserver = center.addObserver(
                forName: AVAudioSession.routeChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                let rawReason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
                Task { @MainActor [weak self] in
                    self?.handleRouteChange(rawReason: rawReason)
                }
            }
        }
        if mediaServicesResetObserver == nil {
            mediaServicesResetObserver = center.addObserver(
                forName: AVAudioSession.mediaServicesWereResetNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.handleMediaServicesReset()
                }
            }
        }
    }

    /// 音频中断：`.ended` 之后重新激活会话并继续播放
    /// （`.began` 时系统已经替我们停了播放，什么都不做）。
    private func handleInterruption(rawType: UInt?) {
        guard isEnabled,
              let rawType,
              let type = AVAudioSession.InterruptionType(rawValue: rawType),
              BackgroundKeepAlivePolicy.shouldResume(afterInterruption: type) else {
            return
        }
        reactivate(reason: .interruptionResumed)
    }

    /// 音频路由变更（插拔耳机、连断蓝牙、切换输出）。
    ///
    /// 只在**播放确实已停**时才恢复（`isRunning == false`）—— 路由变更也可能发生在
    /// 播放未中断时（例如插入耳机后音频被无缝改道），那种情况不该打扰。
    private func handleRouteChange(rawReason: UInt?) {
        guard isEnabled, isRunning == false else { return }
        // 写成闭包而**不是** `flatMap(RouteChangeReason.init(rawValue:))`：后者把可失败
        // 初始化器当函数引用传，重载解析在个别工具链上会报歧义。
        let reason = rawReason.flatMap { AVAudioSession.RouteChangeReason(rawValue: $0) }
        guard BackgroundKeepAlivePolicy.shouldReactivate(afterRouteChange: reason) else { return }
        reactivate(reason: .routeChanged)
    }

    /// 媒体服务被系统重置（媒体守护进程崩溃重启）。
    ///
    /// 🔴 这是最严重的一种：**所有音频对象都被作废**（`AVAudioPlayer` 变成无效对象），
    /// 必须**重建播放器**，只 `play()` 是不够的 ⇒ 先把 `player` 置 nil。
    private func handleMediaServicesReset() {
        guard isEnabled else { return }
        player = nil
        reactivate(reason: .mediaServicesReset)
    }

    private func append(
        level: SealLogEntry.Level = .info,
        message: String,
        code: String
    ) {
        guard let logStore else { return }
        Task {
            try? await logStore.append(
                category: .system,
                level: level,
                message: message,
                code: code
            )
        }
    }

    /// 停止保活：停掉静音音频，移除通知监听。
    ///
    /// 调用时机：续签/签名完成后。快捷指令触发时会重新 start()，
    /// 所以不需要常驻后台也能保证续签成功。
    func stop() {
        isEnabled = false
        player?.stop()
        player = nil
        if let observer = interruptionObserver {
            NotificationCenter.default.removeObserver(observer)
            interruptionObserver = nil
        }
        if let observer = routeChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            routeChangeObserver = nil
        }
        if let observer = mediaServicesResetObserver {
            NotificationCenter.default.removeObserver(observer)
            mediaServicesResetObserver = nil
        }
    }
}
