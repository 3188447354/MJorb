import AVFoundation
import Foundation
import Testing

@testable import Seal

/// 后台保活的**纯逻辑**部分。AVFoundation 那一层（会话、播放器、中断通知）没法在
/// 单测里跑，但它依赖的两件事可以：**生成的字节是不是合法 WAV** 与
/// **中断结束后要不要恢复**。这两件事错了都不会崩 —— 只会在真机上表现为
/// 「保活没生效，后台续签跑一半停了」，而日志里只有一句「启动失败」。
struct BackgroundKeepAliveTests {
    @Test
    func silentWAVDataIsARecognizableOneSecondMonoPCMFile() {
        let data = BackgroundKeepAliveAssets.silentWAVData()
        let bytesPerSample = BackgroundKeepAliveAssets.bitsPerSample / 8
        let blockAlign = BackgroundKeepAliveAssets.channels * bytesPerSample
        let payloadSize = BackgroundKeepAliveAssets.sampleRate * blockAlign * BackgroundKeepAliveAssets.seconds

        #expect(data.count == 44 + payloadSize)
        #expect(String(decoding: data[0..<4], as: UTF8.self) == "RIFF")
        #expect(String(decoding: data[8..<12], as: UTF8.self) == "WAVE")
        #expect(String(decoding: data[12..<16], as: UTF8.self) == "fmt ")
        #expect(String(decoding: data[36..<40], as: UTF8.self) == "data")
        // RIFF 块长度 = 文件总长 - 8；data 块长度 = 实际采样字节数。
        #expect(Self.uint32(data, at: 4) == UInt32(data.count - 8))
        #expect(Self.uint32(data, at: 40) == UInt32(payloadSize))
        // fmt 块：PCM / 单声道 / 采样率 / 字节率 / 块对齐 / 位深。
        #expect(Self.uint16(data, at: 20) == 1)
        #expect(Self.uint16(data, at: 22) == UInt16(BackgroundKeepAliveAssets.channels))
        #expect(Self.uint32(data, at: 24) == UInt32(BackgroundKeepAliveAssets.sampleRate))
        #expect(Self.uint32(data, at: 28) == UInt32(BackgroundKeepAliveAssets.sampleRate * blockAlign))
        #expect(Self.uint16(data, at: 32) == UInt16(blockAlign))
        #expect(Self.uint16(data, at: 34) == UInt16(BackgroundKeepAliveAssets.bitsPerSample))
    }

    @Test
    func silentWAVPayloadIsEntirelySilent() {
        let data = BackgroundKeepAliveAssets.silentWAVData()
        let payload = data[44...]
        #expect(payload.isEmpty == false)
        #expect(payload.allSatisfy { $0 == 0 })
    }

    @Test
    func keepAliveResumesOnlyAfterTheInterruptionEnds() {
        // `.began` 时系统已经替我们停了播放，这里不该做任何事；
        // 漏掉 `.ended` 那一侧则意味着**一次来电就能把保活永久打断**，且没有任何日志。
        #expect(BackgroundKeepAlivePolicy.shouldResume(afterInterruption: .ended))
        #expect(BackgroundKeepAlivePolicy.shouldResume(afterInterruption: .began) == false)
    }

    private static func uint16(_ data: Data, at offset: Int) -> UInt16 {
        var value: UInt16 = 0
        for index in 0..<2 {
            value |= UInt16(data[data.startIndex + offset + index]) << (8 * UInt16(index))
        }
        return value
    }

    private static func uint32(_ data: Data, at offset: Int) -> UInt32 {
        var value: UInt32 = 0
        for index in 0..<4 {
            value |= UInt32(data[data.startIndex + offset + index]) << (8 * UInt32(index))
        }
        return value
    }
}
