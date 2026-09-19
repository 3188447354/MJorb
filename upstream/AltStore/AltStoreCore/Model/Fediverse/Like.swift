//
//  Like.swift
//  AltStoreCore
//
//  Created by Riley Testut on 2/6/26.
//  Copyright © 2026 Riley Testut. All rights reserved.
//

import Foundation
import CoreData

@objc(Like)
public class Like: NSManagedObject, Fetchable
{
    /* Properties */
    @NSManaged public var accountID: String
    @NSManaged public var federatedID: String
        
    /* Relationships */
    @NSManaged public var account: SocialWebAccount?
    @NSManaged public var item: FederatedItem?
        
    private override init(entity: NSEntityDescription, insertInto context: NSManagedObjectContext?)
    {
        super.init(entity: entity, insertInto: context)
    }
    
    public init(account: SocialWebAccount, item: FederatedItem, context: NSManagedObjectContext)
    {
        super.init(entity: Like.entity(), insertInto: context)
        
        self.accountID = account.identifier
        self.federatedID = item.identifier
        
        self.account = account
        self.item = item
    }
}

public extension Like
{
    @nonobjc class func fetchRequest() -> NSFetchRequest<Like>
    {
        return NSFetchRequest<Like>(entityName: "Like")
    }
}
