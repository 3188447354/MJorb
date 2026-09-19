//
//  UpdateFediverseInteractionsOperation.swift
//  AltStore
//
//  Created by Riley Testut on 11/21/25.
//  Copyright © 2025 Riley Testut. All rights reserved.
//

import Foundation
import CoreData

import AltStoreCore

class UpdateFediverseInteractionsOperation: ResultOperation<Void>, @unchecked Sendable
{
    override init()
    {
        super.init()
    }
    
    override func main()
    {
        super.main()

        Task<Void, Never>(priority: .userInitiated) {
            do
            {
                let startTime = CFAbsoluteTimeGetCurrent()
                
                // Don't prefetch yet until we've tested caching
                
                try await self.updateRecentNewsItems()
                try await self.updateAvailableAppUpdates()
                try await self.updateFirstAppForSources()
                
                self.finish(.success(()))
                
                Logger.main.info("Successfully updated initial fediverse interactions in \(CFAbsoluteTimeGetCurrent() - startTime) seconds.")
            }
            catch
            {                
                self.finish(.failure(error))
            }
        }
    }
}

private extension UpdateFediverseInteractionsOperation
{
    func updateRecentNewsItems() async throws
    {
        do
        {
            let context = DatabaseManager.shared.persistentContainer.newBackgroundContext()
            
            let federatedItems = await context.perform {
                let fetchRequest = NewsItem.fetchRequest()
                fetchRequest.predicate = NSPredicate(format: "%K != nil", #keyPath(NewsItem.federatedItem))
                fetchRequest.sortDescriptors = [NSSortDescriptor(keyPath: \NewsItem.date, ascending: false)]
                fetchRequest.fetchLimit = 5
                
                let recentNewsItems = NewsItem.fetch(fetchRequest, in: context)
                let federatedItems = recentNewsItems.compactMap { $0.federatedItem }
                return federatedItems
            }
            
            try await FederationManager.shared.updateInteractions(for: federatedItems, in: context)
        }
        catch
        {
            Logger.main.error("Failed to fetch Fediverse interactions for recent News items. \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }
    
    func updateAvailableAppUpdates() async throws
    {
        do
        {
            let context = DatabaseManager.shared.persistentContainer.newBackgroundContext()
            let federatedItems = await context.perform {
                let fetchRequest = InstalledApp.supportedUpdatesFetchRequest()
                fetchRequest.fetchLimit = MyAppsViewController.maximumCollapsedUpdatesCount
                
                let installedApps = InstalledApp.fetch(fetchRequest, in: context)
                let appVersions = installedApps.compactMap { $0.storeApp?.latestSupportedVersion }
                
                let federatedItems = appVersions.compactMap { $0.federatedItem }
                return federatedItems
            }
            
            try await FederationManager.shared.updateInteractions(for: federatedItems, in: context)
        }
        catch
        {
            Logger.main.error("Failed to fetch Fediverse interactions for available updates. \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }
    
    func updateFirstAppForSources() async throws
    {
        do
        {
            let context = DatabaseManager.shared.persistentContainer.newBackgroundContext()
            
            let federatedItems = try await context.perform {
                let fetchRequest = StoreApp.browseTabFeaturedAppsFetchRequest()
                
                let fetchedResultsController = NSFetchedResultsController(fetchRequest: fetchRequest, managedObjectContext: context, sectionNameKeyPath: #keyPath(StoreApp._source.featuredSortID), cacheName: nil)
                try fetchedResultsController.performFetch()
                
                var storeApps: [StoreApp] = []
                for section in fetchedResultsController.sections ?? []
                {
                    let apps = section.objects as! [StoreApp]
                    
                    if let storeApp = apps.first
                    {
                        // Only fetch interactions for the first app in each section.
                        storeApps.append(storeApp)
                    }
                }
                
                let federatedItems = storeApps.compactMap { $0.federatedItem }
                return federatedItems
            }
            
            try await FederationManager.shared.updateInteractions(for: federatedItems, in: context)
        }
        catch
        {
            Logger.main.error("Failed to fetch Fediverse interactions for first apps in sources. \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }
}
