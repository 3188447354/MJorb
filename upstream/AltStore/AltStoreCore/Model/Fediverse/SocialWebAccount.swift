//
//  SocialWebAccount.swift
//  AltStoreCore
//
//  Created by Riley Testut on 1/6/26.
//  Copyright © 2026 Riley Testut. All rights reserved.
//

import Foundation
import CoreData

extension SocialWebAccount
{
    public enum AccountType: String
    {
        case mastodon
        case bluesky
        
        public var localizedName: String {
            switch self
            {
            case .mastodon: return String(localized: "Mastodon")
            case .bluesky: return String(localized: "Bluesky")
            }
        }
    }
}

@objc(SocialWebAccount)
public class SocialWebAccount: NSManagedObject, Fetchable
{
    /* Properties */
    @NSManaged public var name: String
    @NSManaged public var username: String
    @NSManaged public var identifier: String
    @NSManaged public var url: URL
    @NSManaged public var avatarURL: URL?
    
    // Mastodon instance OR Bluesky PDS
    @NSManaged public var domain: String
    
    /* Relationships */
    @NSManaged public var likes: NSSet /* Like */
    public var allLikes: Set<Like> {
        return self.likes as! Set<Like>
    }
    
    @nonobjc public var type: AccountType {
        return AccountType(rawValue: self._type)!
    }
    @NSManaged @objc(type) internal private(set) var _type: String
        
    private override init(entity: NSEntityDescription, insertInto context: NSManagedObjectContext?)
    {
        super.init(entity: entity, insertInto: context)
    }
    
    public init(name: String, username: String, identifier: String, url: URL, avatarURL: URL?, domain: String, type: AccountType, context: NSManagedObjectContext)
    {
        super.init(entity: SocialWebAccount.entity(), insertInto: context)
        
        self.name = name
        self.username = username
        self.identifier = identifier
        self.url = url
        self.avatarURL = avatarURL
        self.domain = domain
        self._type = type.rawValue
    }
}

public extension SocialWebAccount
{
    var displayUsername: String {
        switch self.type
        {
        case .mastodon:
            let username = "@" + self.username + "@" + self.domain
            return username
            
        case .bluesky:
            let username = "@" + self.username
            return username
        }
    }
    
    var serverURL: URL? {
        // TODO: Validate this in initializer so this can be non-optional.
        let serverURL = URL(string: "https://" + self.domain)
        return serverURL
    }
}

public extension SocialWebAccount
{
    @nonobjc class func fetchRequest() -> NSFetchRequest<SocialWebAccount>
    {
        return NSFetchRequest<SocialWebAccount>(entityName: "SocialWebAccount")
    }
}
