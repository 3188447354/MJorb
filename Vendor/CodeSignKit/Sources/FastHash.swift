//
//  FastHash.swift
//  CodeSignKit
//
//  平台最优的 SHA-256：Apple 平台用 CryptoKit（走 ARMv8 SHA 硬件指令），
//  Linux（CI `signer-tests`）继续用 swift-crypto。输出逐字节一致。
//
//  为什么需要（2026-10-03）：CodeSignKit 全仓 `import Crypto`（swift-crypto），
//  它的 SHA-256 是纯 Swift 实现；Apple 平台的 `CryptoKit.SHA256` 会走硬件加速，
//  快一个数量级。页哈希（`CodeDirectoryBuilder.build()`，每 16KB 一页，
//  200MB 二进制约 1.2 万次）与资源哈希（`CodeResourcesBuilder`，全树文件）
//  是签名里最大的两块 CPU 开销，且与证书/平台无关 ⇒ 加速它们对**每次**签名都生效
//  （命中与否无关 —— 这正是它比「签名缓存」更普适的地方）。
//
//  上游兼容：只新增本文件 + 替换两处内部调用点，不改任何 public API；
//  `#if canImport(CryptoKit)` 保证 Linux 行为与上游一字不差。

import Foundation

#if canImport(CryptoKit)
import CryptoKit
#endif
import Crypto

/// 平台最优 SHA-256（内部用）。
///
/// ⚠️ 引用时必须写全限定名（`Crypto.SHA256` / `CryptoKit.SHA256`）——
/// 本文件同时 import 了 `Crypto` 与 `CryptoKit`（Apple 平台），裸写 `SHA256` 有歧义。
enum FastSHA256 {
    /// 单次哈希（小数据 / 资源文件用）。
    static func hash(data: Data) -> Data {
        #if canImport(CryptoKit)
        return Data(CryptoKit.SHA256.hash(data: data))
        #else
        return Data(Crypto.SHA256.hash(data: data))
        #endif
    }

    /// 页哈希（`CodeDirectoryBuilder` 的页循环用）。
    ///
    /// `page` 是 `binaryData` 裸缓冲区上的切片（零拷贝，见 `build()` 的注释）——
    /// 这里用 `bytesNoCopy` 包一层喂给 CryptoKit，**不复制**；同步调用，
    /// `binaryData` 在整个 `build()` 期间活着，`.none` 析构安全。
    static func hashPage(_ page: UnsafeRawBufferPointer) -> Data {
        #if canImport(CryptoKit)
        var hasher = CryptoKit.SHA256()
        if let baseAddress = page.baseAddress, page.count > 0 {
            let pageData = Data(
                bytesNoCopy: UnsafeMutableRawPointer(mutating: baseAddress),
                count: page.count,
                deallocator: .none
            )
            hasher.update(data: pageData)
        }
        return Data(hasher.finalize())
        #else
        var hasher = Crypto.SHA256()
        hasher.update(bufferPointer: page)
        return Data(hasher.finalize())
        #endif
    }
}
