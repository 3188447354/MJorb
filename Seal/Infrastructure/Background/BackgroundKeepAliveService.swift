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
/// ⚠️ 本类**只有 `start()`、没有 `stop()`**：保活一旦启动就持续（对齐上游）。
/// 有意不加自动停止 —— 「什么时候可以安全地让进程被挂起」这个问题现在没有答案，
/// 猜错的代价是续签半途而废，而半途而废在后台是**看不见**的。
@MainActor
final class BackgroundKeepAliveService {
    private let logStore: SealLogStore?
    private var player: AVAudioPlayer?
    private var silentAudioURL: URL?
    private var interruptionObserver: NSObjectProtocol?

    /// 是否已经在跑。幂等启动靠它（`SealApp.init()` 与快捷指令都会调 `start()`）。
    private(set) var isRunning = false

    init(logStore: SealLogStore? = nil) {
        self.logStore = logStore
    }

    /// 幂等启动。**失败不抛错**（保活失败不该让续签本身失败），但必须留痕 ——
    /// 否则真机上「后台续签跑到一半停了」会变成一个查不出原因的悬案。
    func start() {
        guard isRunning == false else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            let url = try makeSilentAudioFile()
            let player = try AVAudioPlayer(contentsOf: url)
            player.numberOfLoops = -1
            player.volume = 0.01
            guard player.play() else {
                throw BackgroundKeepAliveError.playbackRejected
            }
            self.player = player
            isRunning = true
            observeInterruptions()
            append(
                message: "后台保活已启动：静音音频无限循环，避免 Seal 在后台被系统挂起",
                code: "SEAL-BACKGROUND-001"
            )
        } catch {
            append(
                level: .warning,
                message: "后台保活启动失败（\(error.localizedDescription)）："
                    + "不打开 App 的续签可能被系统挂起，只能在前台完成",
                code: "SEAL-BACKGROUND-002"
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

    private func observeInterruptions() {
        guard interruptionObserver == nil else { return }
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
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

    private func handleInterruption(rawType: UInt?) {
        guard isRunning,
              let rawType,
              let type = AVAudioSession.InterruptionType(rawValue: rawType),
              BackgroundKeepAlivePolicy.shouldResume(afterInterruption: type) else {
            return
        }
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            player?.play()
            append(
                message: "后台保活已从音频中断中恢复（重新激活会话并继续播放）",
                code: "SEAL-BACKGROUND-003"
            )
        } catch {
            append(
                level: .warning,
                message: "后台保活恢复失败（\(error.localizedDescription)）："
                    + "下一次切后台起 Seal 会被系统挂起",
                code: "SEAL-BACKGROUND-004"
            )
        }
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
}
