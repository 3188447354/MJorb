//
//  HTTPHeader.swift
//  AltMarketplace
//
//  Created by Riley Testut on 2/8/24.
//

import Foundation

import MarketplaceKit

struct HTTPHeader: RawRepresentable
{
    let rawValue: String
    
    static let accept = HTTPHeader(rawValue: "Accept")
    static let authorization = HTTPHeader(rawValue: "Authorization")
    
    static func adpURL(for appleItemID: AppleItemID) -> HTTPHeader
    {
        let header = HTTPHeader(rawValue: "alt-adp-" + String(appleItemID))
        return header
    }
    
    static func version(for appleItemID: AppleItemID) -> HTTPHeader
    {
        let header = HTTPHeader(rawValue: "alt-version-" + String(appleItemID))
        return header
    }
    
    static func buildVersion(for appleItemID: AppleItemID) -> HTTPHeader
    {
        let header = HTTPHeader(rawValue: "alt-build-" + String(appleItemID))
        return header
    }
    
    static func bundleID(for appleItemID: AppleItemID) -> HTTPHeader
    {
        let header = HTTPHeader(rawValue: "alt-bundleID-" + String(appleItemID))
        return header
    }
    
    static func assetURL(for assetID: String) -> HTTPHeader
    {
        let header = HTTPHeader(rawValue: "alt-asset-" + assetID)
        return header
    }
}
