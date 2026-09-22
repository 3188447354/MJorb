import Foundation
import Testing
@testable import Seal

/// `MaintenanceGate` 的不变量：维护作业永不阻塞前台操作，且随时可被前台操作叫停。
@MainActor
struct MaintenanceGateTests {
    @Test
    func grantsLeaseWhenIdle() throws {
        let gate = MaintenanceGate(coordinator: OperationCoordinator())
        let token = try #require(gate.tryAcquire())
        #expect(gate.isIdle == false)
        #expect(gate.shouldAbort(token) == false)
    }

    @Test
    func skipsWhileForegroundOperationIsActive() throws {
        let coordinator = OperationCoordinator()
        let gate = MaintenanceGate(coordinator: coordinator)
        let foreground = try #require(coordinator.begin(.signing))

        #expect(gate.tryAcquire() == nil)
        #expect(gate.skippedRounds == 1)
        #expect(gate.isIdle == false, "有前台操作时不算空闲")

        coordinator.end(foreground)
        #expect(gate.tryAcquire() != nil, "前台操作结束后应当可以取租约")
    }

    @Test
    func secondMaintenanceJobIsSkippedWhileOneIsRunning() throws {
        let gate = MaintenanceGate(coordinator: OperationCoordinator())
        let first = try #require(gate.tryAcquire())
        #expect(gate.tryAcquire() == nil, "同时只允许一个维护作业")
        gate.end(first)
        #expect(gate.tryAcquire() != nil)
    }

    /// R06 的核心不变量：维护作业持租约期间用户开始操作，作业必须能被叫停。
    @Test
    func abortsOnceForegroundOperationStartsMidJob() throws {
        let coordinator = OperationCoordinator()
        let gate = MaintenanceGate(coordinator: coordinator)
        let token = try #require(gate.tryAcquire())
        #expect(gate.shouldAbort(token) == false)

        let foreground = try #require(coordinator.begin(.installing))
        #expect(gate.shouldAbort(token), "前台操作启动后维护作业必须立即停止")

        coordinator.end(foreground)
        #expect(gate.shouldAbort(token) == false, "前台操作结束后租约应当恢复有效")
    }

    @Test
    func foreignTokenIsAlwaysConsideredAborted() {
        let gate = MaintenanceGate(coordinator: OperationCoordinator())
        #expect(gate.shouldAbort(UUID()), "不属于自己的租约一律视为失效")
    }

    @Test
    func endIsIdempotentAndIgnoresForeignTokens() throws {
        let gate = MaintenanceGate(coordinator: OperationCoordinator())
        let token = try #require(gate.tryAcquire())

        gate.end(UUID())
        #expect(gate.isIdle == false, "别人的 token 不能释放租约")

        gate.end(token)
        #expect(gate.isIdle)

        gate.end(token)
        #expect(gate.isIdle, "重复释放必须无害")
    }
}
