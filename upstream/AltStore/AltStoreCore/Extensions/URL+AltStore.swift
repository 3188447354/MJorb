//
//  URL+AltStore.swift
//  AltStoreCore
//
//  Created by Riley Testut on 11/2/23.
//  Copyright © 2023 Riley Testut. All rights reserved.
//

import Foundation

public extension URL
{
#if STAGING
static let marketplaceDomain = "https://dev.altstore.io"
#else
static let marketplaceDomain = "https://api.altstore.io"
#endif
    
    func normalizedForInstallURL() -> String
    {
        // AWS has trouble parsing URLs with encoded `/`, so we replace them with '|' before encoding.
        // This technically breaks any URLs with '|' in them, but YOLO.
        let encodedADPLink = self.absoluteString.replacingOccurrences(of: "/", with: "|")
        return encodedADPLink
    }
    
    static func installURL(for adpURL: URL) -> URL?
    {
        let encodedADPLink = adpURL.normalizedForInstallURL()
        
        var components = URLComponents(string: URL.marketplaceDomain)!
        components.path += "/install/" + encodedADPLink // Assigning path will implicitly percent-encode it

        let redirectURL = components.url
        return redirectURL
    }
    
    func normalized() throws -> String
    {
        // Based on https://encyclopedia.pub/entry/29841

        guard var components = URLComponents(url: self, resolvingAgainstBaseURL: true) else { throw URLError(.badURL, userInfo: [NSURLErrorKey: self, NSURLErrorFailingURLErrorKey: self]) }
        
        if components.scheme == nil && components.host == nil
        {
            // Special handling for URLs without explicit scheme & incorrectly assumed to have nil host (e.g. "altstore.io/my/path")
            guard let updatedComponents = URLComponents(string: "https://" + self.absoluteString) else { throw URLError(.cannotFindHost, userInfo: [NSURLErrorKey: self, NSURLErrorFailingURLErrorKey: self]) }
            components = updatedComponents
        }
        
        // 1. Don't use percent encoding
        guard let host = components.host else { throw URLError(.cannotFindHost, userInfo: [NSURLErrorKey: self, NSURLErrorFailingURLErrorKey: self]) }
        
        // 2. Ignore scheme
        var normalizedURL = host
        
        // 3. Add port (if not default)
        if let port = components.port, port != 80 && port != 443
        {
            normalizedURL += ":" + String(port)
        }
        
        // 4. Add path without fragment or query parameters
        // 5. Remove duplicate slashes
        let path = components.path.replacingOccurrences(of: "//", with: "/") // Only remove duplicate slashes from path, not entire URL.
        normalizedURL += path // path has leading `/`
        
        // 6. Convert to lowercase
        normalizedURL = normalizedURL.lowercased()
        
        // 7. Remove trailing `/`
        if normalizedURL.hasSuffix("/")
        {
            normalizedURL.removeLast()
        }
        
        // 8. Remove leading "www"
        if normalizedURL.hasPrefix("www.")
        {
            normalizedURL.removeFirst(4)
        }
        
        return normalizedURL
    }
}
