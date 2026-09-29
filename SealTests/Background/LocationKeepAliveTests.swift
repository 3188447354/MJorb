import CoreLocation
import Foundation
import Testing

@testable import Seal

/// 后台定位保活的**纯逻辑**部分。`CLLocationManager` 那层（授权弹窗、定位回调、后台定位开关）
/// 没法在单测里跑，但它依赖的前提可以：**拿到系统授权状态后 Seal 该做什么**。这三件事判错
/// 不会崩 —— 只会在真机上表现为「定位保活没生效，音频被打断时续签跑一半停了」。
struct LocationKeepAliveTests {
    @Test
    func notDeterminedRequestsAuthorizationInsteadOfStarting() {
        // 首次：必须先发起 `requestAlwaysAuthorization()`，不能直接 start ——
        // 没授权就 `startUpdatingLocation()` 是空转，永远拿不到回调。
        #expect(LocationKeepAlivePolicy.action(for: .notDetermined) == .requestAuthorization)
    }

    @Test
    func anyGrantStartsBackgroundLocation() {
        // 「使用期间」也要启动：`UIBackgroundModes: location` + `allowsBackgroundLocationUpdates`
        // 下，仅前台授权同样能后台定位（只是状态栏会显示蓝条）。切后台续签不能因为它不是
        // 「始终」就放弃这一路保活。
        #expect(LocationKeepAlivePolicy.action(for: .authorizedAlways) == .start)
        #expect(LocationKeepAlivePolicy.action(for: .authorizedWhenInUse) == .start)
    }

    @Test
    func deniedAndRestrictedFallBackToAudioOnly() {
        #expect(LocationKeepAlivePolicy.action(for: .denied) == .unavailable)
        #expect(LocationKeepAlivePolicy.action(for: .restricted) == .unavailable)
    }
}