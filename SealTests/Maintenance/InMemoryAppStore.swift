import Foundation
@testable import Seal

/// 维护作业测试用的内存 `AppStore`。
actor InMemoryAppStore: AppStore {
    private var records: [AppRecord]

    init(records: [AppRecord] = []) {
        self.records = records
    }

    func fetchAll() -> [AppRecord] {
        records
    }

    func save(_ record: AppRecord) {
        records.removeAll { $0.id == record.id }
        records.append(record)
    }

    func delete(id: UUID) {
        records.removeAll { $0.id == id }
    }

    func replaceImportedApp(_ record: AppRecord) -> [AppRecord] {
        let replaced = records.filter {
            $0.originalBundleIdentifier == record.originalBundleIdentifier
        }
        records.removeAll {
            $0.originalBundleIdentifier == record.originalBundleIdentifier
        }
        records.append(record)
        return replaced
    }
}
