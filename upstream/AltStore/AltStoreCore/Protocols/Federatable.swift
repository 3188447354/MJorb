//
//  Federatable.swift
//  AltStoreCore
//
//  Created by Riley Testut on 8/25/25.
//  Copyright © 2025 Riley Testut. All rights reserved.
//

import Foundation
import CoreData

public protocol Federatable: NSManagedObject
{
    var federatedID: String? { get }
    var shareURL: URL? { get }
    
    // Relationships
    var federatedItem: FederatedItem? { get set }
}

public extension Federatable
{
    var isFederated: Bool {
        return self.federatedID != nil
    }
}
