//
//  iCloudAPI.swift
//  AltStore
//
//  Created by Riley Testut on 8/25/25.
//  Copyright © 2025 Riley Testut. All rights reserved.
//

import Foundation
import CloudKit

import AltStoreCore

extension iCloudAPI
{
    enum Container
    {
        case sources
        case mastodon
    }
}

final class iCloudAPI
{
    static let shared = iCloudAPI()
    
    private let sourcesContainer = CKContainer(identifier: "iCloud.io.altstore.AltStore.Sources")
    private let mastodonContainer = CKContainer(identifier: "iCloud.io.altstore.AltStore.Mastodon")
    
    private init()
    {
    }
}

extension iCloudAPI
{
    func fetchSource(id: String) async throws -> SourceRecord?
    {
        let predicate = NSPredicate(format: "%K == %@", #keyPath(SourceFields.sourceID), id)
        let query = CKQuery(recordType: SourceRecord.recordType, predicate: predicate)
        
        let results = try await self._fetchRecords(of: SourceRecord.self, query: query, container: .sources)
        return results.first
    }
    
    func fetchNewsItems(@AsyncManaged for source: Source) async throws -> [NewsItemRecord]
    {
        let sourceID = await $source.identifier
        
        let predicate = NSPredicate(format: "%K == %@", #keyPath(NewsItemFields.sourceID), sourceID)
        let sortDescriptor = NSSortDescriptor(keyPath: \NewsItemFields.date, ascending: false)
        
        let query = CKQuery(recordType: NewsItemRecord.recordType, predicate: predicate)
        query.sortDescriptors = [sortDescriptor]
        
        let results = try await self._fetchRecords(of: NewsItemRecord.self, query: query, container: .sources)
        return results
    }
    
    func fetchApps(@AsyncManaged for source: Source) async throws -> [AppRecord]
    {
        let sourceID = await $source.identifier
        
        let predicate = NSPredicate(format: "%K == %@", #keyPath(AppFields.sourceID), sourceID)
        let sortDescriptor = NSSortDescriptor(keyPath: \AppFields.date, ascending: false)
        
        let query = CKQuery(recordType: AppRecord.recordType, predicate: predicate)
        query.sortDescriptors = [sortDescriptor]
        
        let results = try await self._fetchRecords(of: AppRecord.self, query: query, container: .sources)
        return results
    }
    
    func fetchAppVersions(@AsyncManaged for source: Source) async throws -> [AppVersionRecord]
    {
        let sourceID = await $source.identifier
        
        let predicate = NSPredicate(format: "%K == %@", #keyPath(AppVersionFields.sourceID), sourceID)
        let sortDescriptor = NSSortDescriptor(keyPath: \AppVersionFields.date, ascending: false)
        
        let query = CKQuery(recordType: AppVersionRecord.recordType, predicate: predicate)
        query.sortDescriptors = [sortDescriptor]
        
        let results = try await self._fetchRecords(of: AppVersionRecord.self, query: query, container: .sources)
        return results
    }
}

extension iCloudAPI
{
    func fetchMastodonServer(domain: String) async throws -> ServerRecord?
    {
        let predicate = NSPredicate(format: "%K == %@", #keyPath(ServerFields.domain), domain.lowercased())
        let query = CKQuery(recordType: ServerRecord.recordType, predicate: predicate)
        
        let results = try await self._fetchRecords(of: ServerRecord.self, query: query, container: .mastodon)
        return results.first
    }
    
    func registerApp(id: String, clientID: String, clientSecret: String, domain: String) async throws -> ServerRecord
    {
        let record = CKRecord(recordType: ServerFields.recordType)
        record[#keyPath(ServerFields.domain)] = domain.lowercased()
        record[#keyPath(ServerFields.appID)] = id
        record[#keyPath(ServerFields.appClientID)] = clientID
        record[#keyPath(ServerFields.appClientSecret)] = clientSecret
        
        let savedRecord = try await self.mastodonContainer.publicCloudDatabase.save(record)
        
        let serverRecord = ServerRecord(record: savedRecord)
        return serverRecord
    }
}

private extension iCloudAPI
{
    func _fetchRecords<Fields: CloudRecordFields>(of recordType: CloudRecord<Fields>.Type, query: CKQuery, container: Container) async throws -> [CloudRecord<Fields>]
    {
        var results: [(CKRecord.ID, Result<CKRecord, Error>)] = []
        var fetchCursor: CKQueryOperation.Cursor? = nil
        
        let container = switch container {
        case .sources: self.sourcesContainer
        case .mastodon: self.mastodonContainer
        }
        
        repeat
        {
            let fetchResults: [(CKRecord.ID, Result<CKRecord, any Error>)]
            
            if let tempCursor = fetchCursor
            {
                let (results, cursor) = try await withCheckedThrowingContinuation { continuation in
                    container.publicCloudDatabase.fetch(withCursor: tempCursor) { result in
                        continuation.resume(with: result)
                    }
                }
                
                fetchResults = results
                fetchCursor = cursor
            }
            else
            {
                let (results, cursor) = try await withCheckedThrowingContinuation { continuation in
                    container.publicCloudDatabase.fetch(withQuery: query) { result in
                        continuation.resume(with: result)
                    }
                }
                
                fetchResults = results
                fetchCursor = cursor
            }
            
            for (recordID, result) in fetchResults
            {
                results.append((recordID, result))
            }
        } while (fetchCursor != nil);
        
        var records: [CloudRecord<Fields>] = []
        
        for (recordID, result) in results
        {
            do
            {
                let record = try result.get()
                
                let cloudRecord = CloudRecord<Fields>(record: record)
                records.append(cloudRecord)
            }
            catch
            {
                Logger.main.error("Failed to fetch \(Fields.recordType, privacy: .public) record \(recordID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        
        return records
    }
}
