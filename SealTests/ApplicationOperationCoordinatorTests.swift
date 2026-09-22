import Foundation
import Testing
@testable import Seal

@MainActor
struct ApplicationOperationCoordinatorTests {
    @Test
    func cancelledWaiterNeverAcquiresAnAvailableLease() async {
        let coordinator = OperationCoordinator()
        let waiter = Task { @MainActor in
            await coordinator.beginWaiting(.signing)
        }
        // This test stays on MainActor until cancellation, before the waiter can run.
        waiter.cancel()
        let lease = await waiter.value
        #expect(lease == nil)
        #expect(coordinator.activeLease == nil)
    }

    @Test
    func timedOutWaiterDoesNotReleaseAnotherOperationsLease() async throws {
        let coordinator = OperationCoordinator()
        let first = try #require(coordinator.begin(.signing))
        let second = await coordinator.beginWaiting(.renewing, timeout: 0)
        #expect(second == nil)
        #expect(coordinator.activeLease == first)
        coordinator.end(first)
    }

    @Test
    func conflictingWriteOperationsAreRejectedUntilLeaseEnds() throws {
        let coordinator = OperationCoordinator()
        let first = try #require(coordinator.begin(.signing, appID: UUID()))
        #expect(coordinator.begin(.maintainingStorage) == nil)
        #expect(coordinator.conflictFailure(requested: .maintainingStorage).code == "SEAL-OP-001")

        coordinator.end(first)
        let second = try #require(coordinator.begin(.maintainingStorage))
        #expect(second.kind == .maintainingStorage)
        coordinator.end(second)
    }
}
