import Foundation

protocol AppStore: Actor {
    func fetchAll() throws -> [AppRecord]
    func save(_ record: AppRecord) throws
    func replaceImportedApp(_ record: AppRecord) throws -> [AppRecord]
    func commitInstalledReplacement(_ record: AppRecord, replacing replacedID: UUID) throws
    func delete(id: UUID) throws
}
