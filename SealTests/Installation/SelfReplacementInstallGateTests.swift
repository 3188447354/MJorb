import Foundation
import Testing
@testable import Seal

/// 自替换安装「单飞」闸门的行为。
///
/// 真机日志（`Seal-log(8)`）里 91 秒内提交了两笔 Seal 自替换安装
/// （`19:43:50` 与 `19:45:51`），而第一笔的 `stageAndInstall` **从未返回**。
/// `Minimuxer.stageAndInstall` 是同步阻塞 FFI，没有取消机制：第二笔会在同一个
/// Bundle ID 上再下发一个 installd 安装命令，正是 R05 要防的「第二次安装」。
///
/// 闸门的判定规则只有两条，但两条都容易写错，所以用行为测试钉住：
/// 1. 已有安装在进行 → 拒绝第二笔；
/// 2. **超时不解锁**（底下那次很可能还在跑），只有安装真的结束才解锁。
///
/// ## 为什么每个调用都要先落到局部变量
///
/// `acquire()` / `release(timedOut:)` 都是 `mutating`，**不能直接写在 `#expect(...)` 里**。
/// `#expect` 是宏，会把表达式重写成闭包、把子表达式绑成 `$0`/`$1`…，mutating 成员作用在
/// 捕获值上编译不过：
///
/// ```
/// error: cannot use mutating member on immutable value: '$0' is immutable
/// ```
///
/// 这个错误**只在 `swift-regression` 出现** —— `build-package` 不编译测试 target，
/// 2026-09-16 实际踩到（一轮 CI 白等 13 分钟）。守卫里有一条通用检查拦这个写法，
/// 别为了「少写一行」把调用挪回 `#expect` 里。
struct SelfReplacementInstallGateTests {
    @Test
    func secondAcquireIsRefusedWhileInFlight() {
        var gate = SelfReplacementInstallGate()
        let first = gate.acquire()
        #expect(first)
        let second = gate.acquire()
        #expect(second == false)
    }

    @Test
    func releaseAfterTheInstallEndedReopensTheGate() {
        var gate = SelfReplacementInstallGate()
        let first = gate.acquire()
        #expect(first)
        gate.release(timedOut: false)
        let second = gate.acquire()
        #expect(second)
    }

    /// 超时只代表「上层不再等待」：同步 FFI 没有取消机制，它很可能仍在设备端执行。
    /// 此时解锁就等于放行第二笔并发安装。
    @Test
    func timeoutKeepsTheGateClosed() {
        var gate = SelfReplacementInstallGate()
        let first = gate.acquire()
        #expect(first)
        gate.release(timedOut: true)
        let second = gate.acquire()
        #expect(second == false)
    }

    /// 一次完整的「提交 → 超时 → 再提交」序列：第二笔必须始终被拒。
    @Test
    func repeatedTimeoutsNeverReopenTheGate() {
        var gate = SelfReplacementInstallGate()
        let first = gate.acquire()
        #expect(first)
        gate.release(timedOut: true)
        gate.release(timedOut: true)
        let second = gate.acquire()
        #expect(second == false)
    }
}
