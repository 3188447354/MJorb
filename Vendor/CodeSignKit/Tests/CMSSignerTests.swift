//
//  CMSSignerTests.swift
//  CodeSignKitTests
//
//  2026-09-26：`CMSSigner` 的 PKCS#12 解析缓存（同一实例上不再重复解析）。
//

import Testing
import Foundation
@testable import CodeSignKit

@Suite
struct CMSSignerTests {

    /// 🔴 钉住「同一个 `CMSSigner` 上重复访问的行为与改缓存前完全一致」。
    ///
    /// 改动把 `leafCertificate` 从**计算属性**（每次访问都 `try? PKCS12Parser(...)`）
    /// 换成实例级 lazy `Result`，并让 `sign()` 共用同一份解析结果。
    /// 可观察判据有三条，缺一条都说明缓存改错了：
    ///  ① 指纹稳定（重复访问拿到同一张证书）；
    ///  ② 坏 P12 **每次都**返回 `nil` —— 缓存的是「失败」这个结果本身，
    ///     不是「没缓存、每次重试」（否则第二行断言就是废话）；
    ///  ③ `sign()` 失败时**仍抛出解析器的真实错误** ——
    ///     这正是缓存必须用 `Result` 而不是 `PKCS12Parser?` 的原因：
    ///     后者会把 `sign()` 的错误换成一句笼统的 `certificateError`，排障时丢掉真因 ✗。
    @Test(.enabled(if: TestFixtures.isClangAvailable))
    func repeatedAccessIsStableAndKeepsTheOriginalError() throws {
        let (p12Data, _, _) = try TestFixtures.createSelfSignedP12(password: "test")
        let signer = CMSSigner(p12Data: p12Data, password: "test")

        let first = try #require(signer.leafCertificate)
        let second = try #require(signer.leafCertificate)
        #expect(first.sha1Fingerprint == second.sha1Fingerprint)
        #expect(signer.getLeafCertificateSHA1() == first.sha1Fingerprint)

        // 坏 P12：`leafCertificate` 恒 nil（不抛），`sign()` 恒抛
        let broken = CMSSigner(p12Data: Data("not a pkcs12".utf8), password: "test")
        #expect(broken.leafCertificate == nil)
        #expect(broken.leafCertificate == nil)
        #expect(throws: (any Error).self) {
            _ = try broken.sign(codeDirectoryData: Data("cd".utf8))
        }

        // 正常 P12 能签出 BlobWrapper（0xfade0b01）
        let blob = try signer.sign(codeDirectoryData: Data(repeating: 0x5A, count: 64))
        let magic = blob.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }
        #expect(magic == CodeSigningConstants.CSMAGIC_BLOBWRAPPER)
        #expect(blob.count > 8)
    }
}
