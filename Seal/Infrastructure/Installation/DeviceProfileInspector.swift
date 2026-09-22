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
