//
//  AppVersionValues.swift
//  AltMarketplace
//
//  Created by Riley Testut on 2/3/25.
//  Copyright © 2025 Riley Testut. All rights reserved.
//

import Foundation
import AltStoreCore

struct AppVersionValues
{
    var bundleID: String
    var adpURL: URL
    var version: String
    var buildVersion: String
    
    var assetURLs: [String: URL]?
    
    init?(_ appVersion: AltStoreCore.AppVersion)
    {
        // Make sure we provide the redirect ADP URL that goes through our server.
        // This allows us to handle custom Patreon post + assetURLs logic.
        guard let adpURL = URL.installURL(for: appVersion.downloadURL), let buildVersion = appVersion.buildVersion else { return nil }
        
        self.bundleID = appVersion.bundleIdentifier
        self.adpURL = adpURL
        self.version = appVersion.version
        self.buildVersion = buildVersion
        self.assetURLs = appVersion.assetURLs
    }
}
