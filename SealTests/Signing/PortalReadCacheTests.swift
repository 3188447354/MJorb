import Foundation
import Testing
@testable import Seal

/// 批量门户读缓存（2026-10-03）：`fetchTeams` / `ensureDevice` / `fetchAppIDs`
/// 一轮批量里只拉一次。`isPortalReadCacheFresh` 是三处调用点的同源判据。
struct PortalReadCacheTests {
    private let ttl: TimeInterval = 300

    @Test
    func freshWithinTTL() {
        let fetchedAt = Date(timeIntervalSince1970: 2_000_000_000)
        #expect(
            ApplePortalSigningService.isPortalReadCacheFresh(
                fetchedAt: fetchedAt,
                now: fetchedAt.addingTimeInterval(ttl - 1),
                ttl: ttl
            )
        )
    }

    @Test
    func staleAtTTLBoundary() {
        let fetchedAt = Date(timeIntervalSince1970: 2_000_000_000)
        // 恰好 TTL ⇒ 不新鲜（`< ttl`，不是 `<=`）。
        #expect(
            !ApplePortalSigningService.isPortalReadCacheFresh(
                fetchedAt: fetchedAt,
                now: fetchedAt.addingTimeInterval(ttl),
                ttl: ttl
            )
        )
    }

    @Test
    func staleBeyondTTL() {
        let fetchedAt = Date(timeIntervalSince1970: 2_000_000_000)
        #expect(
            !ApplePortalSigningService.isPortalReadCacheFresh(
                fetchedAt: fetchedAt,
                now: fetchedAt.addingTimeInterval(ttl + 60),
                ttl: ttl
            )
        )
    }

    @Test
    func defaultTTLIsFiveMinutes() {
        // 守卫意图：一轮批量通常 1–2 分钟，5 分钟覆盖它绰绰有余；
        // 改 TTL 时必须同步评估「跨轮复用旧列表」的风险。
        let fetchedAt = Date(timeIntervalSince1970: 2_000_000_000)
        #expect(
            ApplePortalSigningService.isPortalReadCacheFresh(
                fetchedAt: fetchedAt,
                now: fetchedAt.addingTimeInterval(5 * 60 - 1)
            )
        )
        #expect(
            !ApplePortalSigningService.isPortalReadCacheFresh(
                fetchedAt: fetchedAt,
                now: fetchedAt.addingTimeInterval(5 * 60 + 1)
            )
        )
    }
}
