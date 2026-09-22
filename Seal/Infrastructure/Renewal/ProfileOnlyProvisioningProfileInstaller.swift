import Foundation
@preconcurrency import Minimuxer

/// Serializes profile injection for the entire process. `misagent` uses a
/// process-wide device transport, so two app renewals must never install a
/// profile concurrently.
actor ProfileOnlyProvisioningProfileInstaller {
    static let shared = ProfileOnlyProvisioningProfileInstaller()

    private var isBusy = false
    private var isTainted = false

    func installAndVerify(
        _ materials: [ProfileOnlyProfileMaterial],
        certificateSerialNumber: String
    ) async throws {
        guard isTainted == false else {
            throw failure(
                reason: "上一次描述文件设备操作超时，底层设备通道可能仍在运行。为避免并发注入，请重启 Seal 后再试。",
                code: "SEAL-PROFILE-350"
            )
        }
        guard isBusy == false else {
            throw failure(
                reason: "另一项描述文件续签仍在使用设备通道。",
                code: "SEAL-PROFILE-351"
            )
        }
        isBusy = true
        defer { isBusy = false }

        for material in materials {
            try Task.checkCancellation()
            let injection = await BlockingCall.bounded(seconds: 30) {
                try Minimuxer.installProvisioningProfile(profile: material.data)
            }
            guard let injection else {
                isTainted = true
                throw failure(
                    reason: "注入 \(material.binding.bundleIdentifier) 的描述文件超过 30 秒未返回。",
                    code: "SEAL-PROFILE-352"
                )
            }
            try injection.get()

            let installed: Bool?
            do {
                installed = try await HardTimeout.run(
                    seconds: 30,
                    cancelsWorkOnTimeout: false
                ) {
                    await DeviceProfileInspector.containsProfile(
                        bundleIdentifier: material.binding.bundleIdentifier,
                        profileUUID: material.binding.profileUUID ?? "",
                        certificateSerialNumber: certificateSerialNumber
                    )
                }
            } catch {
                isTainted = true
                throw failure(
                    reason: "设备端读取 \(material.binding.bundleIdentifier) 的描述文件超过 30 秒未完成。",
                    code: "SEAL-PROFILE-353"
                )
            }
            guard installed == true else {
                throw failure(
                    reason: "设备端未能读回本轮注入的 \(material.binding.bundleIdentifier) 描述文件；本地到期日未更新。",
                    code: "SEAL-PROFILE-354"
                )
            }
        }
    }

    private func failure(reason: String, code: String) -> ImportFailure {
        ImportFailure(
            title: "描述文件续签未确认",
            reason: reason,
            recovery: "确认 LocalDevVPN 与设备连接后重试；不要在未确认前删除旧描述文件",
            code: code
        )
    }
}
