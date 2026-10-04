import Foundation
import Compression
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Assets.car 解析器：从编译后的 asset catalog 提取 App 图标。
///
/// 策略：启发式扫描（不走 B-tree）。
/// 直接找所有 CSI 头，选最大的正方形（通常 1024x1024 就是 AppIcon）。
enum AssetCatalogParser {

    /// 从 Assets.car 数据提取最大的正方形图标，返回 PNG 数据。
    /// 找不到时返回 nil（调用方回退到占位图）。
    static func extractAppIcon(from carData: Data) -> Data? {
        // 1. 找所有 CSI 头（magic "ISTC" = CTSI 小端）
        let csiPositions = findCSIHeaders(in: carData)
        guard !csiPositions.isEmpty else { return nil }

        // 2. 解析每个 CSI，找最大的正方形
        var best: (width: Int, payloadOffset: Int, payloadSize: Int)?
        for pos in csiPositions {
            guard let info = parseCSIHeader(carData, at: pos) else { continue }
            // 只要正方形，且 layout=12（位图）、pixelFormat=BGRA
            guard info.width == info.height, info.width > 0,
                  info.layout == 12, info.pixelFormat == "BGRA" else { continue }
            let area = info.width * info.height
            if best == nil || area > best!.width * best!.width {
                best = (info.width, info.payloadOffset, info.payloadSize)
            }
        }
        guard let selected = best else { return nil }

        // 3. 提 payload，LZVN 解压
        let expectedSize = selected.width * selected.width * 4  // BGRA
        guard selected.payloadOffset + selected.payloadSize <= carData.count else { return nil }
        let compressed = carData[selected.payloadOffset..<selected.payloadOffset + selected.payloadSize]
        guard let bgra = decompressLZVN(compressed, expectedSize: expectedSize) else {
            // 尝试按原始 ARGB 处理（未压缩的情况）
            guard compressed.count >= expectedSize else { return nil }
            return bgraToPNG(Data(compressed.prefix(expectedSize)), width: selected.width, height: selected.width)
        }
        return bgraToPNG(bgra, width: selected.width, height: selected.width)
    }

    // MARK: - CSI 扫描

    private static func findCSIHeaders(in data: Data) -> [Int] {
        var positions: [Int] = []
        var pos = 0
        // "ISTC" = CTSI 小端
        let magic: [UInt8] = [0x49, 0x53, 0x54, 0x43]
        while pos + 4 <= data.count {
            if data[pos] == magic[0] && data[pos+1] == magic[1]
                && data[pos+2] == magic[2] && data[pos+3] == magic[3] {
                positions.append(pos)
                pos += 4
            } else {
                pos += 1
            }
        }
        return positions
    }

    private struct CSIInfo {
        let width: Int
        let height: Int
        let layout: Int
        let pixelFormat: String
        let payloadOffset: Int
        let payloadSize: Int
    }

    private static func parseCSIHeader(_ data: Data, at pos: Int) -> CSIInfo? {
        // CSI header 184 字节（已用真机文件验证偏移）
        guard pos + 184 <= data.count else { return nil }
        let width = Int(data.u32LE(at: pos + 12))
        let height = Int(data.u32LE(at: pos + 16))
        // pixelFormat 在 offset 24，4 字节 ASCII（"BGRA"）
        let pfData = data[pos+24..<pos+28]
        let pixelFormat = String(data: pfData, encoding: .ascii) ?? ""
        let layout = Int(data.u32LE(at: pos + 36))
        // tvlLength 在 offset 168
        let tvlLength = Int(data.u32LE(at: pos + 168))
        // payload 大小在 offset 180
        let payloadSize = Int(data.u32LE(at: pos + 180))

        // payload 在 184 + tvlLength 之后，是 MLEC 包裹
        let mlecStart = pos + 184 + tvlLength
        guard mlecStart + 40 <= data.count else { return nil }
        // MLEC 头 40 字节，压缩数据从 MLEC+40 开始
        // （基于 OmoFun.ipa 的 Assets.car 反推）
        let payloadOffset = mlecStart + 40
        // payloadSize 用 CSI 头里的值减去 MLEC 头
        let actualPayloadSize = min(payloadSize - 40 - tvlLength, data.count - payloadOffset)
        guard actualPayloadSize > 0 else { return nil }

        return CSIInfo(
            width: width,
            height: height,
            layout: layout,
            pixelFormat: pixelFormat,
            payloadOffset: payloadOffset,
            payloadSize: actualPayloadSize
        )
    }

    // MARK: - LZVN 解压

    // COMPRESSION_LZVN 在某些 Swift 工具链下不在作用域，本地定义兜底（值为 4，见 <compression.h>）
    private static let lzvnAlgorithm = compression_algorithm(4)

    private static func decompressLZVN(_ data: Data, expectedSize: Int) -> Data? {
        // 用 Compression.framework 的 LZVN 解压
        // 注意：需要 iOS 9+，公开 API
        let dstCapacity = expectedSize
        var dst = Data(count: dstCapacity)

        let result: Int = data.withUnsafeBytes { srcPtr in
            dst.withUnsafeMutableBytes { dstPtr in
                guard let srcBase = srcPtr.baseAddress, let dstBase = dstPtr.baseAddress else { return 0 }
                return compression_decode_buffer(
                    dstBase.assumingMemoryBound(to: UInt8.self),
                    dstCapacity,
                    srcBase.assumingMemoryBound(to: UInt8.self),
                    data.count,
                    nil,
                    lzvnAlgorithm
                )
            }
        }
        guard result == expectedSize else { return nil }
        return dst
    }

    // MARK: - BGRA -> PNG

    private static func bgraToPNG(_ bgra: Data, width: Int, height: Int) -> Data? {
        let bytesPerRow = width * 4
        guard bgra.count >= bytesPerRow * height else { return nil }

        guard let provider = CGDataProvider(data: bgra as CFData) else { return nil }
        // BGRA 对应 kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little
        guard let cgImage = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else { return nil }

        let pngData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            pngData as CFMutableData,
            UTType.png.identifier as CFString,
            1, nil
        ) else { return nil }
        CGImageDestinationAddImage(dest, cgImage, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return pngData as Data
    }
}

// MARK: - Data 扩展

private extension Data {
    func u32LE(at offset: Int) -> UInt32 {
        guard offset + 4 <= count else { return 0 }
        return UInt32(self[offset])
            | (UInt32(self[offset + 1]) << 8)
            | (UInt32(self[offset + 2]) << 16)
            | (UInt32(self[offset + 3]) << 24)
    }
}
