//
//  SignedArtifactProfileReader.swift
//  Seal
//
//  从「签名后成品 IPA」回读主应用 embedded.mobileprovision 的 UUID，
//  作为「安装成功后清理设备端旧描述文件时保留刚装 profile」的依据。
//  对齐 SignedArtifactBundleIDReader：只认恰好三段的 Payload -> <App>.app -> embedded.mobileprovision。
//

import Foundation
import ZIPFoundation

enum SignedArtifactProfileReader {
    /// 主应用 embedded.mobileprovision 在 IPA 内的路径段数：Payload / <App>.app / embedded.mobileprovision。
    private static let mainProvisionSegmentCount = 3

    static func embeddedProfileUUID(in ipaData: Data) -> String? {
        guard let archive = try? Archive(data: ipaData, accessMode: .read) else { return nil }
        guard let entry = archive.first(where: { isMainProvision($0.path) }) else { return nil }

        var profileData = Data()
        do {
            _ = try archive.extract(entry) { chunk in
                profileData.append(chunk)
            }
        } catch {
            return nil
        }

        guard profileData.isEmpty == false,
              let details = try? ProvisioningProfileReader().details(from: profileData) else {
            return nil
        }
        return details.uuid
    }

    private static func isMainProvision(_ path: String) -> Bool {
        let segments = path.split(separator: "/")
        guard segments.count == mainProvisionSegmentCount else { return false }
        return segments[0] == "Payload"
            && segments[1].hasSuffix(".app")
            && segments[2] == "embedded.mobileprovision"
    }
}