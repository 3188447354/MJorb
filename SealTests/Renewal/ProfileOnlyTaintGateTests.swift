import Foundation
import Testing
@testable import Seal

/// 「描述文件设备操作超时留下的污染」这条状态机的自证。
///
/// **为什么值得单测**：它的两种错法都不崩、不报错，只改行为 ——
///   · `consume()` 若不是一次性的（没清标记）⇒ 每一项续签都白重置一次设备通道；
///   · `markTainted()` 若漏掉 ⇒ 把「可能仍在跑」的上一次注入与本次注入放成并发。
/// 两者在真机上只表现为「变慢了」或「偶发失败」，事后完全看不出来。
///
/// ⚠️ **mutating 调用必须提到 `#expect` 之外**：`#expect` 是宏，会把表达式重写成闭包、
/// 把捕获值绑成不可变的 `$0` ⇒ `#expect(gate.consume())` 编译不过
///（`cannot use mutating member on immutable value`），而该错误只在 `swift-regression`
/// 暴露（`build-package` 不编译测试 target）⇒ 一律写成 `let ok = gate.consume(); #expect(ok)`。
@Suite("描述文件污染标记：一次性消费")
struct ProfileOnlyTaintGateTests {

    @Test("全新闸门不是污染态，且消费返回 false")
    func freshGateIsClean() {
        var gate = ProfileOnlyTaintGate()
        #expect(gate.isTainted == false)
        let consumed = gate.consume()
        #expect(consumed == false)
    }

    @Test("标记后消费返回 true，且**消费即清除**（第二次必须返回 false）")
    func consumeIsOneShot() {
        var gate = ProfileOnlyTaintGate()
        gate.markTainted()
        #expect(gate.isTainted)
        let first = gate.consume()
        #expect(first)
        #expect(gate.isTainted == false)
        // 第二次消费必须为假：否则每项续签都会白重置一次设备通道（多花一次完整重连）。
        let second = gate.consume()
        #expect(second == false)
    }

    @Test("重复标记只算一次污染（消费一次即清）")
    func repeatedMarkingCollapsesToSingleConsume() {
        var gate = ProfileOnlyTaintGate()
        gate.markTainted()
        gate.markTainted()
        let first = gate.consume()
        #expect(first)
        let second = gate.consume()
        #expect(second == false)
    }

    @Test("污染码必须被续签重试侧认出来（否则同一项不会自愈）")
    func profileTimeoutCodesAreRetryable() {
        #expect(DeviceChannelTransientPolicy.profileOperationTimeoutCodes
            == Set(["SEAL-PROFILE-355t", "SEAL-PROFILE-352", "SEAL-PROFILE-353"]))
        for code in DeviceChannelTransientPolicy.profileOperationTimeoutCodes {
            let failure = ImportFailure(title: "", reason: "", recovery: "", code: code)
            #expect(DeviceChannelTransientPolicy.isTransientChannelFailure(failure))
            #expect(RenewalCoordinator.isRetryable(failure))
        }
        // 「读回没读到」（354）不是超时 ⇒ 不得混进来：它不是通道抖动，重试未必更好。
        let readBackMismatch = ImportFailure(
            title: "", reason: "", recovery: "", code: "SEAL-PROFILE-354")
        #expect(DeviceChannelTransientPolicy.isTransientChannelFailure(readBackMismatch) == false)
        #expect(RenewalCoordinator.isRetryable(readBackMismatch) == false)
    }
}
