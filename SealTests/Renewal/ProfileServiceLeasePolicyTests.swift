import Foundation
import Testing
@testable import Seal

@Suite("profile 服务健康租约")
struct ProfileServiceLeasePolicyTests {
    @Test
    func freshLeaseSkipsAnotherServiceProbe() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let lease = now.addingTimeInterval(-ProfileServiceLeasePolicy.leaseDuration + 1)

        #expect(ProfileServiceLeasePolicy.requiresProbe(lastHealthyAt: lease, now: now) == false)
    }

    @Test
    func expiredOrMissingLeaseRequiresAServiceProbe() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        #expect(ProfileServiceLeasePolicy.requiresProbe(lastHealthyAt: nil, now: now))
        #expect(
            ProfileServiceLeasePolicy.requiresProbe(
                lastHealthyAt: now.addingTimeInterval(-ProfileServiceLeasePolicy.leaseDuration),
                now: now
            )
        )
    }

    @Test
    func onlyTheFirstProbeFailureRebuildsTheRSDConnectionImmediately() {
        #expect(ProfileServiceLeasePolicy.shouldRebuildAfterProbeFailure(hasRebuilt: false))
        #expect(ProfileServiceLeasePolicy.shouldRebuildAfterProbeFailure(hasRebuilt: true) == false)
    }
}
