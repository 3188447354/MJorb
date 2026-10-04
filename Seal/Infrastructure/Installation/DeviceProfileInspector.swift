//
//  DeviceProfileInspector.swift
//  Seal
//
//  只读枚举设备端描述文件引用的证书序列号，供「清理不可用证书」判定
//  「这张证书是否还有 App 在设备上靠它运行」。与 DeviceProfileCleaner 共用
//  misagent dump 通道，但绝不删除任何文件。
//

import Foundation
@preconcurrency import Minimuxer

struct DeviceProfileInspector: Sendable {
    enum ProfileServiceProbeOutcome: Sendable {
        case ready
        case failed
        /// `BlockingCall` 超时并不表示 Rust FFI 已停止；调用方必须走污染闸门，
        /// 不能在同一传输上立即发起第二次 misagent 调用。
        case timedOut
    }

    /// 只验证 misagent 的 profile 服务可以完成 `copy_all`，不解析、判断或改动任何 profile。
    ///
    /// RemotePairing 下的 `dumpProfiles` 与 `installProvisioningProfile` 都通过 Rust 的
    /// `connect_to_rsd_services::<MisagentClient>()`。因此这里是实际写入服务的无副作用预热，
    /// 而不是仅凭 UDID/TCP 推断通道可用。
    static func probeProfileService() async -> ProfileServiceProbeOutcome {
        let fileManager = FileManager.default
        let workingDir = fileManager.temporaryDirectory
            .appendingPathComponent("seal-profile-probe-\(UUID().uuidString)", isDirectory: true)
        let outcome = await BlockingCall.bounded(seconds: 8) {
            _ = try Provision.dumpProfiles(docsPath: workingDir.path)
        }
        // 只有 FFI 确认结束后才能删目录。超时时底层仍可能写入，提前删除会让
        // 原本只读的健康探测变成新的 I/O 竞争；残留临时目录由系统的临时目录清理。
        guard let outcome else { return .timedOut }
        defer { try? fileManager.removeItem(at: workingDir) }
        do {
            try outcome.get()
            return .ready
        } catch {
            return .failed
        }
    }

    /// 安装后核对设备 profile 存储里是否出现本轮 Seal 的精确身份。
    /// `nil` 表示设备通道或解析不可用；`false` 表示成功枚举但目标身份不存在。
    static func containsProfile(
        bundleIdentifier: String,
        profileUUID: String,
        certificateSerialNumber: String
    ) async -> Bool? {
        let fileManager = FileManager.default
        let workingDir = fileManager.temporaryDirectory
            .appendingPathComponent("seal-profile-verify-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: workingDir) }

        guard let dumpDir = try? Provision.dumpProfiles(docsPath: workingDir.path),
              let profileURLs = try? fileManager.contentsOfDirectory(
                at: URL(fileURLWithPath: dumpDir),
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
              ) else { return nil }

        let expectedSerial = SigningCertificateSelectionPolicy.normalizedSerialNumber(
            certificateSerialNumber
        )
        let reader = ProvisioningProfileReader()
        var parsed = 0
        var handledUUIDs = Set<String>()
        for fileURL in profileURLs {
            guard let data = try? Data(contentsOf: fileURL),
                  let details = try? reader.details(from: data) else { continue }
            if let uuid = details.uuid, handledUUIDs.insert(uuid).inserted == false { continue }
            parsed += 1
            guard details.bundleIdentifier?.caseInsensitiveCompare(bundleIdentifier) == .orderedSame,
                  details.uuid?.caseInsensitiveCompare(profileUUID) == .orderedSame else { continue }
            return details.certificateSerialNumbers.contains {
                SigningCertificateSelectionPolicy.normalizedSerialNumber($0) == expectedSerial
            }
        }
        return parsed > 0 ? false : nil
    }

    /// 安装后从设备端读回的 profile 必须与本轮门户结果逐项一致。
    /// UUID/证书一致还不足以证明 UI 所展示的创建与到期时间属于本轮文件。
    static func containsProfile(
        matching binding: ProvisioningProfileBinding,
        certificateSerialNumber: String
    ) async -> Bool? {
        guard let profileUUID = binding.profileUUID, profileUUID.isEmpty == false else { return false }
        let fileManager = FileManager.default
        let workingDir = fileManager.temporaryDirectory
            .appendingPathComponent("seal-profile-verify-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: workingDir) }

        guard let dumpDir = try? Provision.dumpProfiles(docsPath: workingDir.path),
              let profileURLs = try? fileManager.contentsOfDirectory(
                at: URL(fileURLWithPath: dumpDir),
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
              ) else { return nil }

        let expectedSerial = SigningCertificateSelectionPolicy.normalizedSerialNumber(certificateSerialNumber)
        let reader = ProvisioningProfileReader()
        var parsed = 0
        var handledUUIDs = Set<String>()
        for fileURL in profileURLs {
            guard let data = try? Data(contentsOf: fileURL),
                  let details = try? reader.details(from: data) else { continue }
            if let uuid = details.uuid, handledUUIDs.insert(uuid).inserted == false { continue }
            parsed += 1
            guard details.bundleIdentifier?.caseInsensitiveCompare(binding.bundleIdentifier) == .orderedSame,
                  details.uuid?.caseInsensitiveCompare(profileUUID) == .orderedSame,
                  details.creationDate == binding.creationDate,
                  details.expirationDate == binding.expirationDate,
                  details.certificateSerialNumbers.contains(where: {
                      SigningCertificateSelectionPolicy.normalizedSerialNumber($0) == expectedSerial
                  }) else { continue }
            return true
        }
        return parsed > 0 ? false : nil
    }

    /// 批量核验：一次 dump + 全量 CMS 解析，核验全部 bindings。
    /// 按输入顺序返回每个 binding 的核验结果（`nil` = dump 不可用，`false` = 枚举成功但未找到）。
    /// 供 `installAndVerify` 一次注入全部后统一核验，避免每份 profile 各做一次秒级 dump。
    static func containsProfiles(
        matching bindings: [ProvisioningProfileBinding],
        certificateSerialNumber: String
    ) async -> [Bool?] {
        let fileManager = FileManager.default
        let workingDir = fileManager.temporaryDirectory
            .appendingPathComponent("seal-profile-verify-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: workingDir) }

        guard let dumpDir = try? Provision.dumpProfiles(docsPath: workingDir.path),
              let profileURLs = try? fileManager.contentsOfDirectory(
                at: URL(fileURLWithPath: dumpDir),
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
              ) else { return bindings.map { _ in nil } }

        let expectedSerial = SigningCertificateSelectionPolicy.normalizedSerialNumber(certificateSerialNumber)
        let reader = ProvisioningProfileReader()
        // 一次解析全部，建 (bundleID.lowercased, uuid.lowercased) -> (creation, expiration, serials) 索引
        var index: [String: (creation: Date?, expiration: Date?, serials: [String])] = [:]
        var parsed = 0
        var handledUUIDs = Set<String>()
        for fileURL in profileURLs {
            guard let data = try? Data(contentsOf: fileURL),
                  let details = try? reader.details(from: data) else { continue }
            if let uuid = details.uuid, handledUUIDs.insert(uuid).inserted == false { continue }
            parsed += 1
            guard let bid = details.bundleIdentifier?.lowercased(),
                  let uuid = details.uuid?.lowercased() else { continue }
            index["\(bid)|\(uuid)"] = (details.creationDate, details.expirationDate, details.certificateSerialNumbers)
        }
        guard parsed > 0 else { return bindings.map { _ in nil } }

        return bindings.map { binding in
            guard let profileUUID = binding.profileUUID, profileUUID.isEmpty == false,
                  let entry = index["\(binding.bundleIdentifier.lowercased())|\(profileUUID.lowercased())"] else {
                return false
            }
            guard entry.creation == binding.creationDate,
                  entry.expiration == binding.expirationDate,
                  entry.serials.contains(where: {
                      SigningCertificateSelectionPolicy.normalizedSerialNumber($0) == expectedSerial
                  }) else { return false }
            return true
        }
    }

    /// 设备端全部描述文件引用的证书序列号集合（已归一化，见 DEBUG_LOG 坑位 1）。
    ///
    /// 返回 `nil` 表示**无法核验**（未连接设备/隧道不可用/dump 或解析失败），
    /// 调用方必须按「未核验」降级处理，绝不能当成「设备上没有引用」。
    /// 返回空集仅当设备端确实一份描述文件都没有。
    static func referencedCertificateSerials() async -> Set<String>? {
        let fileManager = FileManager.default
        let workingDir = fileManager.temporaryDirectory
            .appendingPathComponent("seal-profile-inspect-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: workingDir) }

        let dumpDir: String
        do {
            dumpDir = try Provision.dumpProfiles(docsPath: workingDir.path)
        } catch {
            return nil
        }

        let dumpURL = URL(fileURLWithPath: dumpDir)
        guard let profileURLs = try? fileManager.contentsOfDirectory(
            at: dumpURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        // 设备端确实没有描述文件：空集是有效结论（没有任何证书被引用）。
        if profileURLs.isEmpty { return [] }

        let reader = ProvisioningProfileReader()
        var serials = Set<String>()
        var parsed = 0
        var handledUUIDs = Set<String>()
        for fileURL in profileURLs {
            // 与 DeviceProfileCleaner 同约定：不按扩展名过滤，misagent 返回的是 CMS
            // 包裹的二进制，识别一律交给 ProvisioningProfileReader 解 CMS。
            guard let data = try? Data(contentsOf: fileURL),
                  let details = try? reader.details(from: data) else { continue }
            // LockDown 路径同一 profile 会落 raw + plist 两份，按 UUID 去重
            if let uuid = details.uuid, handledUUIDs.insert(uuid).inserted == false { continue }
            parsed += 1
            for serial in details.certificateSerialNumbers {
                serials.insert(SigningCertificateSelectionPolicy.normalizedSerialNumber(serial))
            }
        }
        // 目录里有文件却一份都解析不出来 = 核验失败，不是「没有引用」。
        return parsed > 0 ? serials : nil
    }
}
