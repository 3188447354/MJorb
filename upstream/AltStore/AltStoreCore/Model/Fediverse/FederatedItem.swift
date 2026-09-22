//
//  FederatedItem.swift
//  AltStoreCore
//
//  Created by Riley Testut on 1/12/26.
//  Copyright © 2026 Riley Testut. All rights reserved.
//

import Foundation
import CoreData

@objc(FederatedItem)
public class FederatedItem: NSManagedObject, Fetchable
{
    /* Properties */
    @NSManaged public var identifier: String
    @NSManaged public var date: Date
    
    @NSManaged public var uri: URL
    @NSManaged public var url: URL // Web URL
    
    @NSManaged public var resolvedFediverseID: String?
    @NSManaged public var resolvedFediverseURL: URL?
    
    @NSManaged public var resolvedBlueskyID: String?
    @NSManaged public var resolvedBlueskyURL: URL?
    
    // State
    @NSManaged public var isLiked: Bool
    @NSManaged public var likesCount: Int32
    @NSManaged public var boostsCount: Int32
    @NSManaged public var commentsCount: Int32
    
    /* Relationships */
    @NSManaged public var newsItem: NewsItem?
    @NSManaged public var app: StoreApp?
    @NSManaged public var appVersion: AppVersion?
    
    @nonobjc public var likes: [Like] {
        return _likes.array as! [Like]
    }
    @NSManaged @objc(likes) public var _likes: NSOrderedSet
        
    private override init(entity: NSEntityDescription, insertInto context: NSManagedObjectContext?)
    {
        super.init(entity: entity, insertInto: context)
    }
    
    public init(identifier: String, date: Date, uri: URL, url: URL, isLiked: Bool = false, likesCount: Int32 = 0, boostsCount: Int32 = 0, commentsCount: Int32 = 0, context: NSManagedObjectContext)
    {
        super.init(entity: FederatedItem.entity(), insertInto: context)
        
        self.identifier = identifier
        self.date = date
        self.uri = uri
        self.url = url
        
        self.isLiked = isLiked
        self.likesCount = likesCount
        self.boostsCount = boostsCount
        self.commentsCount = commentsCount
    }
    
    public class func makePlaceholder(identifier: String, uri: URL, url: URL, in context: NSManagedObjectContext) -> FederatedItem
    {
        let placeholder = FederatedItem(entity: FederatedItem.entity(), insertInto: context)
        placeholder.identifier = identifier
        placeholder.uri = uri
        placeholder.url = url
        
        // Do NOT explicitly set values, use defaults to avoid overwriting existing data.
        // placeholder.isLiked = false
        // placeholder.likesCount = 0
        // placeholder.boostsCount = 0
        // placeholder.commentsCount = 0
        
        return placeholder
    }
}

public extension FederatedItem
{
    func setLikes(_ array: [Like])
    {
        let likes = NSOrderedSet(array: array)
                
        // Iterating self._likes directly results in hard-to-debug crashes due to uncaught exception '*** _oset_getObjectsRange: range {16, 2} extends beyond bounds [0 .. 9]'
        // for case let like as Like in self._likes
        
        for like in self.likes
        {
            if likes.contains(like)
            {
                like.item = self
            }
            else
            {
                like.item = nil
            }
        }
        
        self._likes = likes
    }
}

public extension FederatedItem
{
    @nonobjc class func fetchRequest() -> NSFetchRequest<FederatedItem>
    {
        return NSFetchRequest<FederatedItem>(entityName: "FederatedItem")
    }
}
