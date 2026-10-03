//
//  FastSHA256Tests.swift
//  CodeSignKitTests
//
//  钉住 `FastSHA256` 与 swift-crypto 参照输出逐字节一致。
//  在 macOS CI（`canImport(CryptoKit)` 为真）上，这条测的是 CryptoKit 分支；
//  在 Linux 上测的是 swift-crypto 分支（恒等，烟雾测试）。

import Testing
import Foundation
import Crypto
@testable import CodeSignKit

@Suite
struct FastSHA256Tests {

    /// 参照实现：永远走 swift-crypto（与平台无关）。
    private func reference(_ data: Data) -> Data {
        Data(Crypto.SHA256.hash(data: data))
    }

    @Test
    func hashMatchesReferenceForVariousInputs() {
        let inputs: [Data] = [
            Data(),                                              // 空
            Data("a".utf8),                                      // 1 字节
            Data(repeating: 0x90, count: 16384),                 // 正好一页
            Data(repeating: 0xFF, count: 16385),                 // 跨页边界
            Data((0..<100_000).map { UInt8($0 & 0xFF) }),        // 100KB 伪随机
        ]
        for input in inputs {
            #expect(FastSHA256.hash(data: input) == reference(input))
        }
    }

    @Test
    func hashPageMatchesReference() {
        let backing = Data((0..<65536).map { UInt8(($0 * 31 + 7) & 0xFF) })
        let cases: [Range<Int>] = [
            0..<16384,      // 整页
            0..<1,          // 1 字节
            16383..<16385,  // 跨页
            100..<50000,    // 大块
        ]
        for range in cases {
            let pageHash = backing.withUnsafeBytes { raw -> Data in
                let page = UnsafeRawBufferPointer(rebasing: raw[range])
                return FastSHA256.hashPage(page)
            }
            #expect(pageHash == reference(Data(backing[range])))
        }
    }

    @Test
    func hashPageOfEmptyBufferMatchesEmptyHash() {
        let empty = Data()
        let pageHash = empty.withUnsafeBytes { raw -> Data in
            FastSHA256.hashPage(UnsafeRawBufferPointer(rebasing: raw[0..<0]))
        }
        #expect(pageHash == reference(Data()))
    }
}
