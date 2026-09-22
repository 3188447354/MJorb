//
//  FederationManager.swift
//  AltStore
//
//  Created by Riley Testut on 1/8/26.
//  Copyright © 2026 Riley Testut. All rights reserved.
//

import Foundation
import CoreData

import AltStoreCore

actor FederationManager
{
    static let shared = FederationManager()
        
    // Cache whether or not we've fetched likes + interactions since app launch / explicit cache reset.
    private var didCacheLikes = [String: Date]()
    private var didCacheInteractions = [String: Date]()
        
    private init()
    {
    }
    
    func resetCache()
    {
        self.didCacheLikes.removeAll()
        self.didCacheInteractions.removeAll()
    }
}

extension FederationManager
{
    @MainActor @discardableResult
    func authenticate(presentingViewController: UIViewController) async throws -> SocialWebAccount
    {
        let mastodonAction = UIAlertAction(title: NSLocalizedString("Mastodon", comment: ""), style: .default)
        let blueskyAction = UIAlertAction(title: NSLocalizedString("Bluesky", comment: ""), style: .default)
        
        let selectedAction = try await presentingViewController.presentConfirmationAlert(title: NSLocalizedString("Sign in with…", comment: ""), message: "", actions: [mastodonAction, blueskyAction])
        
        let account: SocialWebAccount
        if selectedAction == mastodonAction
        {
            account = try await MastodonAPI.shared.authenticate(presentingViewController: presentingViewController)
        }
        else if selectedAction == blueskyAction
        {
            account = try await BlueskyAPI.shared.authenticate(presentingViewController: presentingViewController)
            
            // Bluesky users must be bridged to the Fediverse via Bridgy Fed.
            let bridgyFed = try await BlueskyAPI.shared.fetchAccount(handle: BlueskyAPI.bridgyFedHandle)
            let isBridged = (bridgyFed.viewer?.following != nil) || (bridgyFed.viewer?.followedBy != nil) // Check if following OR followed by Bridgy Fed account.
            if !isBridged
            {
                let title = String(localized: "Would you like to bridge your Bluesky account to the fediverse?")
                let message = String(localized: "This will allow you to like apps in AltStore.")
                
                let bridgeAction = UIAlertAction(title: String(localized: "Bridge Account"), style: .default)
                let laterAction = UIAlertAction(title: String(localized: "Later"), style: .cancel)
                
                do
                {
                    _ = try await presentingViewController.presentConfirmationAlert(title: title, message: message, primaryAction: bridgeAction, cancelAction: laterAction)
                    
                    try await BlueskyAPI.shared.followAccount(handle: BlueskyAPI.bridgyFedHandle)
                }
                catch is CancellationError
                {
                    // Ignore if cancelled, we'll prompt them to bridge later.
                }
            }
        }
        else
        {
            throw CancellationError()
        }
        
        Logger.main.info("Authenticated \(account.type.rawValue) account: \(account.name)")
        
        // Reset cache to ensure we resolve all posts now that we're logged in.
        await self.resetCache()
        
        return account
    }
    
    func signOut() async
    {
        let context = DatabaseManager.shared.persistentContainer.newBackgroundContext()
        await context.perform {
            do
            {
                // Don't delete any SocialWebAccounts, we'll just remove the references in Keychain below.
                // let accounts = SocialWebAccount.all(in: context)
                // accounts.forEach { context.delete($0) }
                
                let federatedItems = FederatedItem.all(in: context)
                federatedItems.forEach { item in
                    item.isLiked = false
                    item.resolvedFediverseID = nil
                    item.resolvedFediverseURL = nil
                    item.resolvedBlueskyID = nil
                    item.resolvedBlueskyURL = nil
                }
                
                try context.save()
            }
            catch
            {
                Logger.main.error("Failed to reset state for cached FederatedItems. \(error.localizedDescription, privacy: .public)")
                
                // Ignore error, it doesn't really matter if this fails.
                // throw error
            }
        }
        
        await MastodonAPI.shared.signOut()
        BlueskyAPI.shared.signOut()
        
        Keychain.shared.socialWebAccountID = nil
        
        self.resetCache()
    }
}

extension FederationManager
{
    func like(@AsyncManaged _ federatedItem: FederatedItem, presentingViewController: UIViewController?) async throws
    {
        do
        {
            let context = DatabaseManager.shared.persistentContainer.newBackgroundContext()
            let accountType = try await context.perform {
                guard let socialWebAccount = DatabaseManager.shared.socialWebAccount(in: context) else { throw BlueskyError.unauthorized() }
                return socialWebAccount.type
            }
            
            let (statusID, federatedURL) = await $federatedItem.perform { ($0.identifier, $0.url) }
                        
            switch accountType
            {
            case .mastodon: try await MastodonAPI.shared.favorite(tootID: statusID, tootURL: federatedURL)
            case .bluesky:
                let post = try await self.blueskyPost(for: federatedItem)
                try await BlueskyAPI.shared.like(post)
            }
            
            let objectID = federatedItem.objectID
            try await context.perform {
                let federatedItem = context.object(with: objectID) as! FederatedItem
                federatedItem.isLiked = true
                federatedItem.likesCount += 1
                try context.save()
            }
            
            Logger.main.debug("Successfully liked status at URL \(federatedURL)")
        }
        catch let error as MastodonError where error.code == .unauthorized
        {
            if let presentingViewController
            {
                // Prompt to log in
                try await self.authenticate(presentingViewController: presentingViewController)
            }
            else
            {
                throw MastodonError.unauthorized()
            }
            
            // Try again
            try await self.like(federatedItem, presentingViewController: presentingViewController)
        }
        catch let error as BlueskyError where error.code == .unauthorized
        {
            if let presentingViewController
            {
                // Prompt to log in
                try await self.authenticate(presentingViewController: presentingViewController)
            }
            else
            {
                throw BlueskyError.unauthorized()
            }
            
            // Try again
            try await self.like(federatedItem, presentingViewController: presentingViewController)
        }
    }
    
    func unlike(@AsyncManaged _ federatedItem: FederatedItem, presentingViewController: UIViewController?) async throws
    {
        do
        {
            let context = DatabaseManager.shared.persistentContainer.newBackgroundContext()
            let accountType = try await context.perform {
                guard let socialWebAccount = DatabaseManager.shared.socialWebAccount(in: context) else { throw BlueskyError.unauthorized() }
                return socialWebAccount.type
            }
            
            let (statusID, federatedURL) = await $federatedItem.perform { ($0.identifier, $0.url) }
                        
            switch accountType
            {
            case .mastodon: try await MastodonAPI.shared.unfavorite(tootID: statusID, tootURL: federatedURL)
            case .bluesky:
                let post = try await self.blueskyPost(for: federatedItem)
                try await BlueskyAPI.shared.unlike(post)
            }
            
            let objectID = federatedItem.objectID
            try await context.perform {
                let federatedItem = context.object(with: objectID) as! FederatedItem
                federatedItem.isLiked = false
                federatedItem.likesCount = max(federatedItem.likesCount - 1, 0) // Prevent negative counts
                try context.save()
            }
            
            Logger.main.debug("Successfully unliked status at URL \(federatedURL)")
        }
        catch let error as MastodonError where error.code == .unauthorized
        {
            if let presentingViewController
            {
                // Prompt to log in
                try await self.authenticate(presentingViewController: presentingViewController)
            }
            else
            {
                throw MastodonError.unauthorized()
            }
            
            // Try again
            try await self.unlike(federatedItem, presentingViewController: presentingViewController)
        }
        catch let error as BlueskyError where error.code == .unauthorized
        {
            if let presentingViewController
            {
                // Prompt to log in
                try await self.authenticate(presentingViewController: presentingViewController)
            }
            else
            {
                throw BlueskyError.unauthorized()
            }
            
            // Try again
            try await self.unlike(federatedItem, presentingViewController: presentingViewController)
        }
    }
}

extension FederationManager
{
    func fetchLikes(@AsyncManaged for federatedItem: FederatedItem, limit: Int? = nil, in context: NSManagedObjectContext = DatabaseManager.shared.persistentContainer.newBackgroundContext()) async throws -> [Like]
    {
        let tootID = await $federatedItem.identifier
        let objectID = federatedItem.objectID
        
        if self.didCacheLikes.keys.contains(tootID)
        {
            return await context.perform {
                let federatedItem = context.object(with: objectID) as! FederatedItem
                return federatedItem.likes
            }
        }
        
        let favorites = try await MastodonAPI.shared.fetchFavorites(tootID: tootID, limit: limit)
        
        let likes = await context.perform {
            let federatedItem = context.object(with: objectID) as! FederatedItem
            let likesByAccountID: [String: Like] = federatedItem.likes.reduce(into: [:]) { $0[$1.accountID] = $1 }
            
            let likes = favorites.compactMap { account -> Like? in
                if let like = likesByAccountID[account.uri.absoluteString]
                {
                    if like.account?.avatarURL == nil
                    {
                        // Use existing like, but update with avatar URL.
                        like.account?.avatarURL = account.avatar_static
                    }
                    
                    return like
                }
                else
                {
                    guard let host = account.uri.host()?.lowercased() else { return nil }
                    
                    let accountID = account.uri.absoluteString
                    let socialWebAccount: SocialWebAccount
                    
                    if accountID == Keychain.shared.socialWebAccountID, let existingAccount = DatabaseManager.shared.socialWebAccount(in: context)
                    {
                        // Use existing social web account, but update with avatar URL.
                        existingAccount.avatarURL = account.avatar_static
                        socialWebAccount = existingAccount
                    }
                    else
                    {
                        let type: SocialWebAccount.AccountType = switch host {
                        case BlueskyAPI.bridgyFedFediverseDomain: .bluesky
                        default: .mastodon
                        }
                        
                        socialWebAccount = SocialWebAccount(name: account.display_name, username: account.username, identifier: accountID, url: account.url, avatarURL: account.avatar_static, domain: host, type: type, context: context)
                    }
                    
                    let like = Like(account: socialWebAccount, item: federatedItem, context: context)
                    return like
                }
            }
            
            federatedItem.setLikes(likes)
            
            return likes
        }
        
        self.didCacheLikes[tootID] = .now
        
        return likes
    }
}

extension FederationManager
{
    func updateInteractions(for federatedItems: some Collection<FederatedItem>, in context: NSManagedObjectContext = DatabaseManager.shared.persistentContainer.newBackgroundContext()) async throws
    {
        // TODO: Clean this up 😬
        
        var allItems = [(NSManagedObjectID, String)]()
        var resolvedItems = [(NSManagedObjectID, String)]()
        var unresolvedItems = [(NSManagedObjectID, String)]()
        
        for federatedItem in federatedItems
        {
            @AsyncManaged
            var federatedItem = federatedItem
            
            let (objectID, identifier, fediverseID, blueskyID) = await $federatedItem.perform { ($0.objectID, $0.identifier, $0.resolvedFediverseID, $0.resolvedBlueskyID) }
            
            if let fediverseID
            {
                resolvedItems.append((objectID, fediverseID))
            }
            else if let blueskyID
            {
                resolvedItems.append((objectID, blueskyID))
            }
            else
            {
                unresolvedItems.append((objectID, identifier))
            }
            
            allItems.append((objectID, identifier))
        }
        
        // Resolve Items
        
        let accountInfo = await context.perform { () -> (SocialWebAccount.AccountType, URL)? in
            guard let socialWebAccount = DatabaseManager.shared.socialWebAccount(in: context), let serverURL = socialWebAccount.serverURL else { return nil }
            return (socialWebAccount.type, serverURL)
        }
        
        if let serverURL = accountInfo?.1, accountInfo?.0 == .mastodon
        {
            // Signed-in to Mastodon, so resolve all unresolved items into our local server.
            
            let unresolvedItems = unresolvedItems
            async let resolvedToots = await withCollatingTaskGroup(for: unresolvedItems.map(\.0)) { objectID in
                let federatedURL = await context.perform {
                    let federatedItem = context.object(with: objectID) as! FederatedItem
                    return federatedItem.url
                }
                
                guard let resolvedToot = try await MastodonAPI.shared.resolve(federatedURL, toServer: serverURL) else { throw MastodonError.tootNotFound() }
                return resolvedToot
            }
            
            let tootIDs = Set(resolvedItems.lazy.map(\.1).filter { self.didCacheInteractions[$0] == nil }) // Filter out posts we've already fetched interactions for.
            async let toots = MastodonAPI.shared.fetchToots(ids: tootIDs, serverURL: serverURL)
            
            let successes = await resolvedToots.successes
            let errors = await resolvedToots.failures
            
            let tootsByID = try await toots.reduce(into: [:]) { $0[$1.id] = $1 }
            
            await context.perform {
                for (objectID, resolvedToot) in successes
                {
                    let federatedItem = context.object(with: objectID) as! FederatedItem
                    federatedItem.update(with: resolvedToot)
                    federatedItem.resolvedFediverseID = resolvedToot.id // Newly resolved, so assign ID
                    federatedItem.resolvedFediverseURL = resolvedToot.url
                }
                
                for (objectID, identifier) in resolvedItems
                {
                    guard let toot = tootsByID[identifier] else { continue }
                    
                    let federatedItem = context.object(with: objectID) as! FederatedItem
                    federatedItem.update(with: toot)
                }
                
                for (objectID, error) in errors
                {
                    let federatedItem = context.object(with: objectID) as! FederatedItem
                    Logger.main.error("Failed to update Fediverse interactions for status \(federatedItem.url, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
            
            for tootID in tootIDs
            {
                self.didCacheInteractions[tootID] = .now
            }
        }
        else if accountInfo?.0 == .bluesky
        {
            // Signed-in to Bluesky, so resolve all unresolved items to their bridged Bluesky post.
            
            let unresolvedItems = unresolvedItems
            async let likes = await withCollatingTaskGroup(for: unresolvedItems.map(\.0)) { objectID in
                let (federatedURL, federatedURI) = await context.perform {
                    let federatedItem = context.object(with: objectID) as! FederatedItem
                    return (federatedItem.url, federatedItem.uri)
                }
                                
                guard let post = try await self.bridgedPost(forTootAtURL: federatedURL, tootURI: federatedURI) else { throw BlueskyError.postNotFound() }
                return post
            }
            
            
            // Fetch ALL toots, there is no resolving into user's server
            let tootIDs = Set(allItems.lazy.map(\.1).filter { self.didCacheInteractions[$0] == nil }) // Filter out posts we've already fetched interactions for.
            async let toots = MastodonAPI.shared.fetchToots(ids: tootIDs)
            
            
            let postURIs = Set(resolvedItems.map(\.1))
            async let alreadyResolvedPosts = BlueskyAPI.shared.fetchPosts(uris: postURIs)
            
            let postSuccesses = await likes.successes
            let postErrors = await likes.failures
            
            let postsByURI = try await alreadyResolvedPosts.reduce(into: [:]) { $0[$1.uri] = $1 }
            let tootsByID = try await toots.reduce(into: [:]) { $0[$1.id] = $1 }
                        
            await context.perform {
                for (objectID, post) in postSuccesses
                {
                    let federatedItem = context.object(with: objectID) as! FederatedItem
                    federatedItem.update(with: post)
                }
                
                for (objectID, identifier) in allItems
                {
                    guard let toot = tootsByID[identifier] else { continue }
                    
                    let federatedItem = context.object(with: objectID) as! FederatedItem
                    federatedItem.update(with: toot)
                }
                
                for (objectID, identifier) in resolvedItems
                {
                    guard let post = postsByURI[identifier] else { continue }
                    
                    let federatedItem = context.object(with: objectID) as! FederatedItem
                    federatedItem.update(with: post)
                }
                
                for (objectID, error) in postErrors
                {
                    guard !(error._domain == BlueskyError.errorDomain && error._code == BlueskyError.Code.postNotFound.rawValue) else { continue }
                    guard !(error._domain == URLError.errorDomain && error._code == URLError.cancelled.rawValue) else { continue }
                    
                    let federatedItem = context.object(with: objectID) as! FederatedItem
                    Logger.main.error("Failed to update Fediverse interactions for bridged status \(federatedItem.url, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
            
            for tootID in tootIDs
            {
                self.didCacheInteractions[tootID] = .now
            }
        }
        else
        {
            // Not signed-in, no need to resolve.
            
            let tootIDs = Set(unresolvedItems.lazy.map(\.1).filter { self.didCacheInteractions[$0] == nil }) // Filter out posts we've already fetched interactions for.
            
            let toots = try await MastodonAPI.shared.fetchToots(ids: tootIDs)
            let tootsByID = toots.reduce(into: [:]) { $0[$1.id] = $1 }
            
            await context.perform {
                for (objectID, identifier) in unresolvedItems
                {
                    guard let toot = tootsByID[identifier] else { continue }
                    
                    let federatedItem = context.object(with: objectID) as! FederatedItem
                    federatedItem.update(with: toot)
                }
            }
            
            for tootID in tootIDs
            {
                self.didCacheInteractions[tootID] = .now
            }
        }
        
        try await context.perform {
            try context.save()
        }
    }
}

// Bluesky bridging
private extension FederationManager
{
    func blueskyPost(@AsyncManaged for federatedItem: FederatedItem) async throws -> BlueskyAPI.Post
    {
        let bridgedPost: BlueskyAPI.Post
                
        if let uri = await $federatedItem.resolvedBlueskyID
        {
            guard let post = try await BlueskyAPI.shared.fetchPost(uri: uri) else { throw BlueskyError.postNotFound() }
            bridgedPost = post
        }
        else
        {
            bridgedPost = try await self.resolveBlueskyPost(for: federatedItem)
        }
        
        return bridgedPost
    }
    
    func resolveBlueskyPost(@AsyncManaged for federatedItem: FederatedItem) async throws -> BlueskyAPI.Post
    {
        let (tootURL, tootURI) = await $federatedItem.perform { ($0.url, $0.uri) }
        guard let bridgedPost = try await self.bridgedPost(forTootAtURL: tootURL, tootURI: tootURI) else { throw BlueskyError.postNotFound() }
        
        let context = DatabaseManager.shared.persistentContainer.newBackgroundContext()
        try await context.perform {
            let federatedItem = context.object(with: federatedItem.objectID) as! FederatedItem
            federatedItem.update(with: bridgedPost)
            try context.save()
        }
        
        return bridgedPost
    }
    
    func bridgedPost(forTootAtURL tootURL: URL, tootURI: URL) async throws -> BlueskyAPI.Post?
    {
        guard let bridgyFedURL = URL(string: "https://ap.brid.gy/convert/bsky/\(tootURI.absoluteString)") else { throw BlueskyError.postNotFound() }
        
        do
        {
            let (_, urlResponse) = try await URLSession.shared.data(from: bridgyFedURL)
            guard let httpResponse = urlResponse as? HTTPURLResponse else { throw BlueskyError.unknown() }
            
            switch httpResponse.statusCode
            {
            case 200...299:
                guard let linkHeader = httpResponse.allHeaderFields["Link"] as? String else { throw BlueskyError.postNotFound() }
                guard let openingBracket = linkHeader.firstIndex(of: "<"), let closingBracket = linkHeader.lastIndex(of: ">") else { throw BlueskyError.postNotFound() }
                
                let postID = String(linkHeader[linkHeader.index(after: openingBracket) ..< closingBracket])
                
                let post = try await BlueskyAPI.shared.fetchPost(uri: postID)
                return post
                
            default: throw BlueskyError.http(statusCode: httpResponse.statusCode)
            }
        }
        catch
        {
            Logger.main.error("Failed to fetch bridged Bluesky post via Bridgy Fed, falling back to fetching account posts. \(error.localizedDescription, privacy: .public)")
            
            let username = tootURL.pathComponents[1].dropFirst() // Remove @
            
            let preferredBlueskyUsername: String
            let fallbackBlueskyUsername = "\(username).alt.store.ap.brid.gy"
            
            if username == "altstore"
            {
                preferredBlueskyUsername = "alt.store"
            }
            else
            {
                preferredBlueskyUsername = "\(username).alt.store"
            }
            
            let did: String
            
            do
            {
                did = try await BlueskyAPI.shared.resolveHandle(preferredBlueskyUsername)
            }
            catch let error as BlueskyError where error.code == .handleNotFound
            {
                did = try await BlueskyAPI.shared.resolveHandle(fallbackBlueskyUsername)
            }
            
            let posts = try await BlueskyAPI.shared.fetchAccountPosts(did: did) //TODO: Only fetch up until we find a match.
            
            let bridgedPost = posts.first { $0.record.bridgyOriginalUrl == tootURL }
            return bridgedPost
        }
    }
}

private extension FederatedItem
{
    func update(with toot: MastodonAPI.Toot)
    {
        self.date = toot.created_at
        self.url = toot.url
        self.uri = toot.uri
        
        self.likesCount = Int32(toot.favourites_count)
        self.boostsCount = Int32(toot.reblogs_count)
        self.commentsCount = Int32(toot.replies_count)
        
        if let isLiked = toot.favourited
        {
            self.isLiked = isLiked
        }
        else
        {
            // Do nothing if not authenticated
        }
    }
    
    func update(with post: BlueskyAPI.Post)
    {
        self.resolvedBlueskyID = post.uri
        
        let sanitizedURI = post.uri.replacingOccurrences(of: "at://", with: "")
        let components = sanitizedURI.split(separator: "/")
        
        if let profileDID = components.first, let rkey = components.last
        {
            let url = URL(string: "https://bsky.app/profile/\(profileDID)/post/\(rkey)")
            self.resolvedBlueskyURL = url
        }
        
        if let viewer = post.viewer
        {
            self.isLiked = (viewer.like != nil)
        }
        else
        {
            // Do nothing if not authenticated
        }
    }
}
