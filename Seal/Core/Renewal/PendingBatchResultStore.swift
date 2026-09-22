import Foundation

/// 供启动期自替换对账使用的批量结果存储。
///
/// 旧进程只能写入“等待新进程确认”；只有运行中新包的身份已经通过核验时，
/// 这里才把 Seal 项结算为成功或失败。
actor PendingBatchResultStore {
    private let fileURL: URL
    private let userDefaultsKey = "seal.pendingBatchRefreshResult"

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func settleSeal(to state: BatchRefreshSession.Item.State) throws -> [UUID: RefreshQueueItem.State] {
        let filePayload: [String: Any]?
        if let data = try? Data(contentsOf: fileURL),
           let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            filePayload = payload
        } else {
            filePayload = nil
        }
        guard let payload = filePayload ?? UserDefaults.standard.dictionary(forKey: userDefaultsKey),
              let updated = PendingBatchResultPayload.settlingSeal(in: payload, to: state),
              JSONSerialization.isValidJSONObject(updated) else { return [:] }

        let data = try JSONSerialization.data(withJSONObject: updated, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: fileURL, options: .atomic)
        UserDefaults.standard.set(updated, forKey: userDefaultsKey)
        return PendingBatchResultPayload.settledQueueStates(from: updated)
    }
}
