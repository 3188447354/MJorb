//
//  HTTPCookieStorage+AltStore.swift
//  AltStore
//
//  Created by Riley Testut on 2/5/25.
//  Copyright © 2025 Riley Testut. All rights reserved.
//

import Roxas

public extension HTTPCookieStorage
{
    static let altstore = HTTPCookieStorage.sharedCookieStorage(forGroupContainerIdentifier: Bundle.main.altstoreAppGroup!) // Should never crash for valid AltStore PAL + Classic builds.
    
    class func migrateLocalPatreonCookiesIfNeeded()
    {
        guard UserDefaults.shared.cookiesMigrationDate == nil else { return }
        
        let cookies = HTTPCookieStorage.shared.cookies(for: URL(string: "https://www.patreon.com")!) ?? []
        for cookie in cookies
        {
            Logger.main.debug("Migrating Patreon cookie to shared container: \(cookie.name, privacy: .public): \(cookie.value, privacy: .private(mask: .hash)) (Expires: \(cookie.expiresDate?.description ?? "nil", privacy: .public))")
            HTTPCookieStorage.altstore.setCookie(cookie)
            HTTPCookieStorage.shared.deleteCookie(cookie)
        }
        
        UserDefaults.shared.cookiesMigrationDate = Date()
    }
}

public extension URLSessionConfiguration
{
    static let sharedCookies: URLSessionConfiguration = {
        let configuration = URLSessionConfiguration.default
        configuration.httpShouldSetCookies = true
        configuration.httpCookieStorage = .altstore
        return configuration
    }()
}

private extension UserDefaults
{
    @NSManaged var cookiesMigrationDate: Date?
}
