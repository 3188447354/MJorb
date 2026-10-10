import Foundation

/// 应用容器在启动前无法加载本地数据时的唯一失败合同。
///
/// Core Data 或文件系统初始化失败并不能证明设备空间不足；这里仅表达已经确认的
/// “本地数据当前不可打开”，避免启动页把底层异常误导成存储空间问题。
enum StartupFailurePolicy {
    static func failure(for error: Error) -> ImportFailure {
        if let failure = error as? ImportFailure {
            return failure
        }

        return ImportFailure(
            title: "无法打开本地数据",
            reason: "Seal 暂时无法读取本机保存的数据。",
            recovery: "关闭后重新打开 Seal；如果仍无法打开，请导出诊断信息后联系作者 MJorb",
            code: "SEAL-APP-001",
            condition: .localStorageWriteFailed,
            action: .restartSeal,
            retryDisposition: .manual,
            operation: .unknown,
            origin: .fileStore
        )
    }
}
