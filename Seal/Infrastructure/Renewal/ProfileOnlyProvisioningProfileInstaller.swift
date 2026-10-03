import Foundation
@preconcurrency import Minimuxer

/// 「上一次描述文件设备操作是否留下了污染」的**纯状态机**（可单测）。
///
/// ## 为什么抽成值类型，而不是 actor 的私有 `Bool`
///
/// `installAndVerify` 要调 `Minimuxer`，而 `SealTests` target 看不到 Minimuxer
/// ⇒ 判定若留在 actor 的私有状态里就**永远测不到**。这条判定的两种错法都不报错、
/// 只改行为：`consume()` 若不是一次性的 ⇒ 每一项续签都白重置一次设备通道；
/// 污染若被漏掉 ⇒ 把「可能仍在跑」的上一次注入与本次注入放成并发。
struct ProfileOnlyTaintGate {
    private(set) var isTainted = false

    /// 记录「上一次设备操作超时 —— 底层同步 FFI 没有取消机制、可能仍在后台跑」。
    mutating func markTainted() {
        isTainted = true
    }

    /// 读取并**清除**污染标记；返回清除前是否处于污染态。
    ///
    /// 「读取 + 清除」必须是**一个**操作：写成
    /// `if isTainted { reset(); isTainted = false }` 会让两个并发调用都看到 `true`、
    /// 各自重置一次设备通道（而重置本身要拆掉正在用的连接）。
    mutating func consume() -> Bool {
        let wasTainted = isTainted
        isTainted = false
        return wasTainted
    }
}

/// Serializes profile injection for the entire process. `misagent` uses a
/// process-wide device transport, so two app renewals must never install a
/// profile concurrently.
actor ProfileOnlyProvisioningProfileInstaller {
    static let shared = ProfileOnlyProvisioningProfileInstaller()

    private var isBusy = false
    private var taint = ProfileOnlyTaintGate()
    /// 门户请求期间预热的 profile 服务任务。写入会加入同一任务，避免 `dumpProfiles`
    /// 与真实注入并发使用 misagent。
    private var inFlightPreparation: Task<Void, Error>?

    /// 读取并清除「上一次设备操作超时」的污染标记（原子）。
    ///
    /// 🔴 **为什么必须能消费**（2026-09-27 真机）：这个标记原来是**永久**闸门 ——
    /// 一次 `SEAL-PROFILE-352`（注入超时）就把本进程后续**全部** profile-only 续签
    /// 挡在 `SEAL-PROFILE-350` 上，直到用户重启 Seal。而批量续签与后台保活都让进程
    /// **跨轮存活**（保活就是为此而设）⇒ 一次通道抖动 = **成片失败** ——
    /// 这正是用户报的「续签有问题」。
    ///
    /// 调用方拿到 `true` 时**必须先重置设备通道、再重新 `start()`，然后才注入**
    /// （见 `SigningCoordinator.renewProfilesOnly`）：超时的那次同步 FFI 无法取消、
    /// 可能仍在后台跑，而 `Minimuxer.reset()` 会把它的传输作废 ⇒ 之后在**新**传输上
    /// 注入才是安全的；而 `reset()` 同时把「远程配对」状态与描述文件 provider 一并清掉
    /// ⇒ **不重新 `start()` 的话下一次注入会退回 USB 传输、必然连不上**。
    /// 清标记、重置、重建三者必须成套出现（源码守卫 R93 钉住）。
    func consumeTaintIfAny() -> Bool {
        taint.consume()
    }

    /// 标记通道已污染（供 `SigningCoordinator` 在 `SEAL-PROFILE-363` 为
    /// `.unavailable` 时调用）。
    ///
    /// 2026-10-03 真机：后台冷启动时设备枚举不可用（363），但代码仍拿这条坏通道
    /// 去注入 ⇒ 30 秒超时 ⇒ 8/16 秒退避 ⇒ 重试 ⇒ 一轮烧掉 59 秒。
    /// 363 的 `.unavailable` 已经证明通道坏了，提前标记后 `renewProfilesOnly`
    /// 会在**第一次注入前**就重置通道，省掉在坏通道上的无效尝试。
    /// ⚠️ 只在 `.unavailable` 时调：`.mismatched`（设备上没有这份 profile）不是
    /// 通道问题，重置帮不上忙。
    func markTainted() {
        taint.markTainted()
    }

    /// 与 Apple Portal 请求并行预热实际执行 profile 注入的设备服务。
    /// 正在写入时不另起探测，避免和 `misagent` 的进程级传输竞争。
    func prewarmProfileService(using channel: any InstallChannel) async throws {
        guard isBusy == false else { return }
        try await ensureProfileService(using: channel)
    }

    func installAndVerify(
        _ materials: [ProfileOnlyProfileMaterial],
        certificateSerialNumber: String,
        channel: any InstallChannel
    ) async throws {
        guard taint.isTainted == false else {
            // **安全网**：调用方必须先 `consumeTaintIfAny()` 并在为真时重置设备通道。
            // 走到这里说明调用点漏了那一步（R93 钉住「消费必须排在注入之前」）。
            // 宁可 fail closed 报错，也不在「传输可能仍被占用」时并发注入。
            throw failure(
                reason: "上一次描述文件设备操作超时留下的传输可能仍被占用，且调用方未先重置设备通道。",
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

        // 这道门验证的是真正执行注入的 misagent 服务，不是 profile-only 的资格。
        // 其短时租约让签名入口预热的结果可复用；过期或失效则在写入前重建一次。
        try await ensureProfileService(using: channel)

        for material in materials {
            try Task.checkCancellation()
            try await inject(material, using: channel)

            let installed: Bool?
            do {
                installed = try await HardTimeout.run(
                    seconds: 30,
                    cancelsWorkOnTimeout: false
                ) {
                    await DeviceProfileInspector.containsProfile(
                        matching: material.binding,
                        certificateSerialNumber: certificateSerialNumber
                    )
                }
            } catch {
                taint.markTainted()
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

    private func ensureProfileService(using channel: any InstallChannel) async throws {
        do {
            if let inFlightPreparation {
                try await inFlightPreparation.value
                return
            }

            let task = Task<Void, Error> { try await channel.prepareProfileService() }
            inFlightPreparation = task
            defer { inFlightPreparation = nil }
            try await task.value
        } catch {
            // `dumpProfiles` 的有界等待超时后，Rust FFI 仍可能占着 misagent。
            // 复用既有污染闸门：下一轮先 reset + start，不能在旧传输上立即重试。
            if let failure = error as? ImportFailure,
               DeviceChannelTransientPolicy.profileOperationTimeoutCodes.contains(failure.code) {
                taint.markTainted()
            }
            throw error
        }
    }

    /// 注入所用的 misagent 服务可能在健康探测与真正写入之间瞬时掉线。
    /// 同一 UUID 的 profile 注入是幂等的，因此只对明确的通道瞬时失败立即重建一次，
    /// 避免把可恢复的冷 RSD 会话交给外层 8 秒退避；超时仍按污染路径处理。
    private func inject(
        _ material: ProfileOnlyProfileMaterial,
        using channel: any InstallChannel
    ) async throws {
        var recoveredConnection = false

        while true {
            let injection = await BlockingCall.bounded(seconds: 30) {
                try Minimuxer.installProvisioningProfile(profile: material.data)
            }
            guard let injection else {
                taint.markTainted()
                throw failure(
                    reason: "注入 \(material.binding.bundleIdentifier) 的描述文件超过 30 秒未返回。",
                    code: "SEAL-PROFILE-352"
                )
            }

            do {
                try injection.get()
                return
            } catch {
                guard recoveredConnection == false,
                      DeviceChannelTransientPolicy.isTransientChannelFailure(error) else {
                    throw error
                }
                recoveredConnection = true
                await channel.invalidateProfileServiceConnection()
                try await channel.prepareProfileService()
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
