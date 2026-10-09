import Foundation

/// 防止较早的设置页后台读取覆盖较新的删除、清理或刷新结果。
struct SettingsLoadGenerationGate: Sendable {
    private var current = 0

    mutating func issue() -> Int {
        current &+= 1
        return current
    }

    func accepts(_ generation: Int) -> Bool {
        generation == current
    }
}
