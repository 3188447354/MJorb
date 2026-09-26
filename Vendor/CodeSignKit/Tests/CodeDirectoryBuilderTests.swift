//
//  CodeDirectoryBuilderTests.swift
//  CodeSignKitTests
//
//  Created by Magesh K on 28/08/26.
//  Copyright © 2026 CodeSignKit. All rights reserved.
//

import Testing
import Foundation
import Crypto
@testable import CodeSignKit

@Suite
struct CodeDirectoryBuilderTests {

    @Test
    func codeDirectoryStructure() throws {
        let dummyCode = Data(repeating: 0x90, count: 16384) // 16KB dummy binary

        let builder = CodeDirectoryBuilder(
            binaryData: dummyCode,
            codeLimit: dummyCode.count,
            bundleIdentifier: "com.example.test",
            teamIdentifier: "TEAM123456",
            hashType: CodeSigningConstants.CS_HASHTYPE_SHA256,
            pageSizeShift: 12 // 4096 bytes per page
        )

        builder.setSpecialSlot(CodeSigningConstants.CSSLOT_INFOSLOT, data: Data("<plist></plist>".utf8))
        builder.setSpecialSlot(CodeSigningConstants.CSSLOT_ENTITLEMENTS, data: Data("<plist></plist>".utf8))

        let cdData = builder.build()
        #expect(cdData.count >= 88)

        // Magic 0xfade0c02
        let magic = cdData.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }
        #expect(magic == CodeSigningConstants.CSMAGIC_CODEDIRECTORY)

        // Version 0x20400
        let version = cdData.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 8, as: UInt32.self).bigEndian }
        #expect(version == CodeSigningConstants.CS_SUPPORTED_CD_VERSION)

        // Hash offset
        let hashOffset = Int(cdData.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 16, as: UInt32.self).bigEndian })
        #expect(hashOffset > 88)

        // Ident offset
        let identOffset = Int(cdData.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 20, as: UInt32.self).bigEndian })
        #expect(identOffset == 88)

        // Num special slots (at least 5 because CSSLOT_ENTITLEMENTS = 5)
        let numSpecialSlots = Int(cdData.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 24, as: UInt32.self).bigEndian })
        #expect(numSpecialSlots >= 5)

        // Num pages (16384 / 4096 = 4 pages)
        let numPages = Int(cdData.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 28, as: UInt32.self).bigEndian })
        #expect(numPages == 4)

        // Code limit (16384)
        let codeLimit = Int(cdData.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 32, as: UInt32.self).bigEndian })
        #expect(codeLimit == 16384)

        // Hash type & size
        #expect(cdData[36] == 32) // SHA256 size
        #expect(cdData[37] == CodeSigningConstants.CS_HASHTYPE_SHA256)
        #expect(cdData[39] == 12) // pageSizeShift
    }

    // MARK: - 2026-09-26：Pass 1 只算尺寸 + 页哈希零拷贝

    /// 🔴 钉住「尺寸与 `build()` 同源」。
    ///
    /// `MachOSigner` 的 Pass 1 改用 `size()`（不再 `build()` 一份全零缓冲）之后，
    /// 两个数字**必须逐位一致** —— 它决定 `LC_CODE_SIGNATURE` 的 `dataoff` / `datasize`，
    /// 差一个字节 ⇒ iOS 拒绝启动（闪退），而 `sign()` 自己**不会报错** ✗。
    /// 形状刻意覆盖：0 / 不满一页 / 恰好一页 / 一页多一字节 / 多页 / 两个 pageSizeShift /
    /// 无团队 ID / 无特殊槽 / 特殊槽不连续（`numSpecialSlots` 取最大值而非个数）。
    @Test
    func sizeMatchesBuildLengthForManyShapes() throws {
        let shapes: [(codeLimit: Int, pageSizeShift: UInt8, team: String?, slots: [UInt32], ident: String)] = [
            (0, 12, nil, [], "a"),
            (1, 12, "T", [1], "com.example"),
            (4095, 12, "TEAM123456", [1, 2, 5], "com.example.demo"),
            (4096, 12, "TEAM123456", [1, 2, 5], "com.example.demo"),
            (4097, 12, nil, [7], "com.example.demo"),
            (16384, 12, "TEAM123456", [1, 2, 3, 5, 7], "com.example.demo"),
            (16384, 14, "TEAM123456", [], "com.example.demo"),
            (100_000, 14, "TEAM123456", [2], "com.example.demo")
        ]

        for shape in shapes {
            for hashType in [CodeSigningConstants.CS_HASHTYPE_SHA256, CodeSigningConstants.CS_HASHTYPE_SHA1] {
                let builder = CodeDirectoryBuilder(
                    binaryData: Data(repeating: 0xA5, count: shape.codeLimit),
                    codeLimit: shape.codeLimit,
                    bundleIdentifier: shape.ident,
                    teamIdentifier: shape.team,
                    hashType: hashType,
                    pageSizeShift: shape.pageSizeShift
                )
                for slot in shape.slots {
                    builder.setSpecialSlot(slot, data: Data(repeating: UInt8(truncatingIfNeeded: slot), count: 17))
                }
                #expect(builder.size() == builder.build().count,
                        "size() 必须等于 build() 的长度（codeLimit=\(shape.codeLimit) hashType=\(hashType)）")
            }
        }
    }

    /// 🔴 钉住 Pass 1 能**传空 `binaryData`** 的前提：尺寸只与 `codeLimit` 有关，**与内容无关**。
    ///
    /// `MachOSigner` 的 Pass 1 因此不再分配 `codeLimit` 字节的全零缓冲、也不再逐页哈希一遍 ✓。
    /// 这条断言一旦失败，就说明尺寸公式里混进了「读 `binaryData`」的东西 —— 那会让 Pass 1
    /// 的估计值与 Pass 2 的实际长度不一致 ⇒ 签名损坏。
    @Test
    func codeDirectorySizeIgnoresBinaryContent() throws {
        let codeLimit = 4096 * 5
        let withZeros = CodeDirectoryBuilder(
            binaryData: Data(count: codeLimit),
            codeLimit: codeLimit,
            bundleIdentifier: "com.example.demo",
            teamIdentifier: "TEAM123456",
            hashType: CodeSigningConstants.CS_HASHTYPE_SHA256,
            pageSizeShift: 12
        )
        let withEmptyBinary = CodeDirectoryBuilder(
            binaryData: Data(),
            codeLimit: codeLimit,
            bundleIdentifier: "com.example.demo",
            teamIdentifier: "TEAM123456",
            hashType: CodeSigningConstants.CS_HASHTYPE_SHA256,
            pageSizeShift: 12
        )
        withZeros.setSpecialSlot(CodeSigningConstants.CSSLOT_REQUIREMENTS, data: Data("req".utf8))
        withEmptyBinary.setSpecialSlot(CodeSigningConstants.CSSLOT_REQUIREMENTS, data: Data("req".utf8))

        #expect(withEmptyBinary.size() == withZeros.size())
        #expect(withEmptyBinary.size() == withZeros.build().count)
    }

    /// 🔴 钉住「零拷贝页哈希 == 原来的 `subdata` 实现」，**逐页逐字节**。
    ///
    /// 这是本轮唯一会碰到**签名字节**的改动 ⇒ 只比长度不够，必须比哈希值本身。
    /// 页边界刻意取 3 整页 + 1 个不满页，覆盖 `pageEnd = min(pageStart + pageSize, codeLimit)`
    /// 的两条分支。
    @Test
    func pageHashesMatchLegacySubdataImplementation() throws {
        let pageSizeShift: UInt8 = 12
        let pageSize = 1 << Int(pageSizeShift)
        let codeLimit = pageSize * 3 + 123
        let numPages = (codeLimit + pageSize - 1) / pageSize

        var payload = Data(count: codeLimit)
        for i in 0..<codeLimit {
            payload[i] = UInt8(truncatingIfNeeded: i &* 31 &+ 7)
        }

        let builder = CodeDirectoryBuilder(
            binaryData: payload,
            codeLimit: codeLimit,
            bundleIdentifier: "com.example.demo",
            teamIdentifier: "TEAM123456",
            hashType: CodeSigningConstants.CS_HASHTYPE_SHA256,
            pageSizeShift: pageSizeShift
        )
        builder.setSpecialSlot(CodeSigningConstants.CSSLOT_REQUIREMENTS, data: Data("req".utf8))
        let produced = builder.build()

        // 从产物里**读回**布局，不重算公式（重算公式就等于把公式抄了第二份 ✗）
        let actualHashOffset = Int(produced.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: 16, as: UInt32.self).bigEndian
        })
        let hashSize = Int(produced[36])
        #expect(hashSize == 32)

        for i in 0..<numPages {
            let pageStart = i * pageSize
            let pageEnd = min(pageStart + pageSize, codeLimit)
            // legacy 实现：先 subdata 复制一份，再哈希
            let legacyHash = Data(SHA256.hash(data: payload.subdata(in: pageStart..<pageEnd)))
            let offset = actualHashOffset + i * hashSize
            let producedHash = produced.subdata(in: offset..<offset + hashSize)
            #expect(producedHash == legacyHash, "第 \(i) 页哈希与 legacy subdata 实现不一致")
        }
    }
}

