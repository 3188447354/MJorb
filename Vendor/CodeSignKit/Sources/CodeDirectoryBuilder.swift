//
//  CodeDirectoryBuilder.swift
//  CodeSignKit
//
//  Created by Magesh K on 28/08/26.
//  Copyright © 2026 CodeSignKit. All rights reserved.
//


import Foundation
import Crypto

public final class CodeDirectoryBuilder {


    private let binaryData: Data
    private let codeLimit: Int
    private let bundleIdentifier: String
    private let teamIdentifier: String?
    private let flags: UInt32
    private let hashType: UInt8
    private let hashSize: Int
    private let pageSizeShift: UInt8
    private let execSegBase: UInt64
    private let execSegLimit: UInt64
    private let execSegFlags: UInt64

    private var specialSlots: [UInt32: Data] = [:]

    public init(
        binaryData: Data,
        codeLimit: Int,
        bundleIdentifier: String,
        teamIdentifier: String?,
        flags: UInt32 = 0,
        hashType: UInt8 = CodeSigningConstants.CS_HASHTYPE_SHA256,
        pageSizeShift: UInt8 = 14,
        execSegBase: UInt64 = 0,
        execSegLimit: UInt64 = 0,
        execSegFlags: UInt64 = 0
    ) {
        self.binaryData = binaryData
        self.codeLimit = codeLimit
        self.bundleIdentifier = bundleIdentifier
        self.teamIdentifier = teamIdentifier
        self.flags = flags
        self.hashType = hashType
        self.hashSize = (hashType == CodeSigningConstants.CS_HASHTYPE_SHA1) ? 20 : 32
        self.pageSizeShift = pageSizeShift
        self.execSegBase = execSegBase
        self.execSegLimit = execSegLimit
        self.execSegFlags = execSegFlags
    }

    public func setSpecialSlot(_ slot: UInt32, data: Data) {
        if hashType == CodeSigningConstants.CS_HASHTYPE_SHA256 {
            let digest = SHA256.hash(data: data)
            specialSlots[slot] = Data(digest)
        } else {
            let digest = Insecure.SHA1.hash(data: data)
            specialSlots[slot] = Data(digest)
        }
    }

    public func setSpecialSlotDigest(_ slot: UInt32, digest: Data) {
        specialSlots[slot] = digest
    }

    /// CodeDirectory 的**总字节数** —— 与 `build()` 的返回长度**同源**。
    ///
    /// 🔴 为什么单独开一个：`MachOSigner` 的 **Pass 1** 只需要**长度**（它用来算
    /// `LC_CODE_SIGNATURE` 的偏移与长度），却为此传了一份 `codeLimit` 大小的全零缓冲、
    /// 让 `build()` 把那一大堆零字节**逐页 SHA-256 一遍** ✗。
    /// 长度公式只用到 `codeLimit` / `pageSizeShift` / 特殊槽数量 / 标识串长度，
    /// **与页哈希的值无关** ⇒ 那一整遍哈希可以完全省掉
    ///（对齐 Apple `cdbuilder.cpp` 的 `Builder::size(version)` —— 那本来就是纯算术）。
    ///
    /// ⚠️ 长度必须与 `build()` **完全一致**：算错 ⇒ `LC_CODE_SIGNATURE` 的偏移/长度错
    /// ⇒ iOS 拒绝启动（闪退）。⇒ 两者**共用 `layout()`**，不给「公式写两份、
    /// 日后只改一处」留口子；单测 `sizeMatchesBuildLengthForManyShapes` 钉住这一点。
    public func size() -> Int { layout().totalSize }

    /// 布局计算（尺寸公式的**唯一**出处）。
    private struct Layout {
        let numPages: Int
        let numSpecialSlots: Int
        let identBytes: Data
        let teamBytes: Data
        let identOffset: Int
        let teamOffset: Int
        let actualHashOffset: Int
        let totalSize: Int
    }

    private func layout() -> Layout {
        let pageSize = 1 << Int(pageSizeShift)
        let numPages = (codeLimit + pageSize - 1) / pageSize

        // 1. Calculate max special slot index
        let maxSpecialSlot = specialSlots.keys.max() ?? 0
        let numSpecialSlots = Int(maxSpecialSlot)

        // 2. Prepare strings
        let identBytes = bundleIdentifier.data(using: .utf8)! + Data([0])
        let teamBytes = (teamIdentifier?.data(using: .utf8) ?? Data()) + ((teamIdentifier != nil) ? Data([0]) : Data())

        // 3. Header size calculation (Version 0x20400 header = 88 bytes)
        let headerSize = 88
        let identOffset = headerSize
        let teamOffset = teamIdentifier != nil ? (identOffset + identBytes.count) : 0
        let stringsSize = identBytes.count + (teamIdentifier != nil ? teamBytes.count : 0)

        // 4. hashOffset in CodeDirectory points to the hash of code slot 0!
        let hashOffset = headerSize + stringsSize
        let actualHashOffset = hashOffset + (numSpecialSlots * hashSize)
        let totalSize = actualHashOffset + (numPages * hashSize)

        return Layout(
            numPages: numPages,
            numSpecialSlots: numSpecialSlots,
            identBytes: identBytes,
            teamBytes: teamBytes,
            identOffset: identOffset,
            teamOffset: teamOffset,
            actualHashOffset: actualHashOffset,
            totalSize: totalSize
        )
    }

    public func build() -> Data {
        let layout = layout()
        let pageSize = 1 << Int(pageSizeShift)
        let numPages = layout.numPages
        let numSpecialSlots = layout.numSpecialSlots
        let identBytes = layout.identBytes
        let teamBytes = layout.teamBytes
        let identOffset = layout.identOffset
        let teamOffset = layout.teamOffset
        let actualHashOffset = layout.actualHashOffset
        let totalSize = layout.totalSize

        var cdData = Data(count: totalSize)

        // 5. Write header fields (Big-Endian)
        cdData.writeUInt32BigEndian(CodeSigningConstants.CSMAGIC_CODEDIRECTORY, at: 0)
        cdData.writeUInt32BigEndian(UInt32(totalSize), at: 4)
        cdData.writeUInt32BigEndian(CodeSigningConstants.CS_SUPPORTED_CD_VERSION, at: 8)
        cdData.writeUInt32BigEndian(flags, at: 12) // flags
        cdData.writeUInt32BigEndian(UInt32(actualHashOffset), at: 16)
        cdData.writeUInt32BigEndian(UInt32(identOffset), at: 20)
        cdData.writeUInt32BigEndian(UInt32(numSpecialSlots), at: 24)
        cdData.writeUInt32BigEndian(UInt32(numPages), at: 28)
        cdData.writeUInt32BigEndian(UInt32(codeLimit), at: 32)
        cdData[36] = UInt8(hashSize)
        cdData[37] = hashType
        cdData[38] = 0 // platform
        cdData[39] = pageSizeShift
        cdData.writeUInt32BigEndian(0, at: 40) // spare2
        cdData.writeUInt32BigEndian(0, at: 44) // scatterOffset
        cdData.writeUInt32BigEndian(UInt32(teamOffset), at: 48)

        cdData.writeUInt32BigEndian(0, at: 52) // spare3
        cdData.writeUInt64BigEndian(0, at: 56) // codeLimit64
        cdData.writeUInt64BigEndian(execSegBase, at: 64)
        cdData.writeUInt64BigEndian(execSegLimit, at: 72)
        cdData.writeUInt64BigEndian(execSegFlags, at: 80)

        // 6. Write identifier & team ID strings
        cdData.replaceSubrange(identOffset..<identOffset + identBytes.count, with: identBytes)
        if teamIdentifier != nil && teamOffset > 0 {
            cdData.replaceSubrange(teamOffset..<teamOffset + teamBytes.count, with: teamBytes)
        }

        // 7. Write special slots (slots 1 to N placed backwards from actualHashOffset)
        let emptyHash = Data(repeating: 0, count: hashSize)
        for slot in 1...max(numSpecialSlots, 1) {
            guard slot <= numSpecialSlots else { break }
            let slotData = specialSlots[UInt32(slot)] ?? emptyHash
            let slotOffset = actualHashOffset - (slot * hashSize)
            cdData.replaceSubrange(slotOffset..<slotOffset + hashSize, with: slotData)
        }

        // 8. Hash binary code pages (0..<numPages)
        //
        // 🔴 **零拷贝**（2026-09-26）：原写法是 `binaryData.subdata(in: pageStart..<pageEnd)`
        // ⇒ **每页都新建一份 `Data`**（一次 malloc ＋ memcpy）。200 MB 二进制按 16 KB 页
        // 算约 **1.2 万次** ✗ —— 而这份副本的每一个字节马上就被哈希器吃掉，没有任何用途 ✗。
        // ⇒ 改成在 `binaryData` 自己的裸缓冲区上**取切片**直接喂给哈希器 ✓（不复制）。
        //
        // 哈希值与原实现**逐字节相同**：同一段字节、同一个哈希函数、同样的页边界算式
        //（`pageStart` / `pageEnd` / `codeLimit` 一个字没动）✓。
        // 单测 `pageHashesMatchLegacySubdataImplementation` 逐页比对两者，
        // `sizeMatchesBuildLengthForManyShapes` 钉住长度与 `size()` 一致。
        //
        // ⚠️ 这里用 `update(bufferPointer:)` ＋ `finalize()` 而**不是**
        // `SHA256.hash(bufferPointer:)` —— 后者在 `HashFunction` 的**内部** extension 里
        //（`swift-crypto` 的 `HashFunctions.swift` 中它没有 `public`），
        // 而 `update(bufferPointer:)` 是**协议要求**，两边都保证可见 ✓。
        for i in 0..<numPages {
            let pageStart = i * pageSize
            let pageEnd = min(pageStart + pageSize, codeLimit)

            let pageHash: Data = binaryData.withUnsafeBytes { raw -> Data in
                let page = UnsafeRawBufferPointer(rebasing: raw[pageStart..<pageEnd])
                if hashType == CodeSigningConstants.CS_HASHTYPE_SHA256 {
                    var hasher = SHA256()
                    hasher.update(bufferPointer: page)
                    return Data(hasher.finalize())
                } else {
                    var hasher = Insecure.SHA1()
                    hasher.update(bufferPointer: page)
                    return Data(hasher.finalize())
                }
            }

            let codeOffset = actualHashOffset + (i * hashSize)
            cdData.replaceSubrange(codeOffset..<codeOffset + hashSize, with: pageHash)
        }

        return cdData
    }
}

