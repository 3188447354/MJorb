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
    /// 设备注入的串行排队尾（2026-10-04 并行续签）。
    ///
    /// `misagent` 是进程级传输，多项续签的注入必须串行。旧实现用 `isBusy` 抛
    /// `SEAL-PROFILE-351` 直接失败；并行后多项会同时到达 ⇒ 改为排队等待。
    /// 实现是标准 async mutex：每项把前一项的完成当门闩，挂到队尾。
    private var injectTail: Task<Void, Never>?
    /// misagent 保活心跳任务（2026-10-04 通道优化）。
    ///
    /// `misagent` 空闲一段时间后会变冷，下次注入要重新建服务连接（~数秒）。
    /// App 在前台存活时定期轻量 `prepareProfileService`，保持热状态。
    /// 失败不标记污染（`prewarmProfileService` 已保证），不干扰注入（`isBusy` 保护）。
    private var keepaliveTask: Task<Void, Never>?
    /// 保活间隔：5 分钟。misagent 空闲超时是分钟级，这个频率足够保持热状态，
    /// 又不会频繁唤醒设备。
    private static let keepaliveIntervalNanoseconds: UInt64 = 300_000_000_000

    /// 启动 misagent 保活心跳。App 回到前台时调用。
    ///
    /// 幂等：已在跑则直接返回。
    func startKeepalive(using channel: any InstallChannel) {
        guard keepaliveTask == nil else { return }
        keepaliveTask = Task { [weak self] in
            while true {
                try? await Task.sleep(nanoseconds: Self.keepaliveIntervalNanoseconds)
                guard let self else { return }
                // 保活只是轻量预热：失败不抛、不标记污染、不干扰注入。
                try? await self.prewarmProfileService(using: channel)
            }
        }
    }

    /// 停止 misagent 保活心跳。App 进后台时调用。
    func stopKeepalive() {
        keepaliveTask?.cancel()
        keepaliveTask = nil
    }

    /// 标记通道已污染（供 `SigningCoordinator` 在 `SEAL-PROFILE-363` 为
    /// `.unavailable` 时调用）。
    ///
    /// 2026-10-03 真机：后台冷启动时设备枚举不可用（363），但代码仍拿这条坏通道
    /// 去注入 ⇒ 30 秒超时 ⇒ 8/16 秒退避 ⇒ 重试 ⇒ 一轮烧掉 59 秒。
    /// 363 的 `.unavailable` 已经证明通道坏了，提前标记后 `installAndVerify`
    /// 会在**拿锁后、注入前**就重置通道，省掉在坏通道上的无效尝试。
    /// ⚠️ 只在 `.unavailable` 时调：`.mismatched`（设备上没有这份 profile）不是
    /// 通道问题，重置帮不上忙。
    func markTainted() {
        taint.markTainted()
    }

    /// 与 Apple Portal 请求并行预热实际执行 profile 注入的设备服务。
    /// 正在写入时不另起探测，避免和 `misagent` 的进程级传输竞争。
    ///
    /// ⚠️ 预热失败**不标记污染**（2026-10-04）：预热只是后台优化，跑在坏通道上
    /// 失败是预期的；若它标记污染，会与 `renewProfilesOnly` 的污染消费竞态 ——
    /// 消费后、注入前预热才标记 ⇒ `installAndVerify` 误报 `SEAL-PROFILE-350`
    /// （调用方明明已重置通道）。真正的注入失败仍由 `installAndVerify` 自己标记。
    func prewarmProfileService(using channel: any InstallChannel) async throws {
        guard isBusy == false else { return }
        try await ensureProfileService(using: channel, markTaintOnFailure: false)
    }

    func installAndVerify(
        _ materials: [ProfileOnlyProfileMaterial],
        certificateSerialNumber: String,
        channel: any InstallChannel,
        // 污染自愈时留痕（`SEAL-PROFILE-355`），由调用方传入日志闭包。
        onTaintHealed: @Sendable () async -> Void = {}
    ) async throws {
        // ── 串行排队（2026-10-04）──
        // 旧行为：`isBusy` 为真直接抛 `SEAL-PROFILE-351`。
        // 并行续签后多项的 Portal 准备会同时完成、同时到达注入 ⇒ 排队等待轮到自己，
        // 而不是让第二项直接失败。`misagent` 仍是同一时间只有一项在写。
        let predecessor = injectTail
        let gate = Task<Void, Never> { _ = await predecessor?.value }
        injectTail = gate
        await gate.value
        try Task.checkCancellation()
        isBusy = true
        defer { isBusy = false }

        // ── 拿锁后自愈污染（2026-10-04）──
        // 「消费 + 重置 + 注入」在串行临界区里原子完成（R93② 钉住）：
        // 排队等待期间，另一项的注入可能失败并标记污染，或 363 提前标记了污染。
        // 在这里消费 + 重置通道，注入继续，不丢一轮。
        if taint.consume() {
            await channel.reset()
            _ = try await channel.start()
            await onTaintHealed()
        }

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

    private func ensureProfileService(using channel: any InstallChannel, markTaintOnFailure: Bool = true) async throws {
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
            // ⚠️ 预热调用传 `markTaintOnFailure: false`（见 `prewarmProfileService`）。
            if markTaintOnFailure,
               let failure = error as? ImportFailure,
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
