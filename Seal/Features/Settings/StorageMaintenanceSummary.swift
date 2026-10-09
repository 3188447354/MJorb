import Foundation

enum StorageMaintenanceSummary {
    static func temporaryCacheCleared(freedBytes: Int64) -> String {
        resultText(prefix: "已清理临时缓存", freedBytes: freedBytes)
    }

    static func unusedFilesCleared(freedBytes: Int64) -> String {
        resultText(prefix: "已清理未使用文件", freedBytes: freedBytes)
    }

    static func signedPackagesCleared(freedBytes: Int64) -> String {
        resultText(prefix: "已清理签名包", freedBytes: freedBytes)
    }

    private static func resultText(prefix: String, freedBytes: Int64) -> String {
        let freed = max(0, freedBytes)
        guard freed > 0 else {
            return "\(prefix)。没有发现可释放的空间。"
        }
        return "\(prefix)，已释放 \(freed.sealFormattedByteCount)。"
    }
}
