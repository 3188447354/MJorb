//
//  UpdateRemoteFlagsOperation.swift
//  AltStore
//
//  Created by Riley Testut on 2/26/26.
//  Copyright © 2026 Riley Testut. All rights reserved.
//

import Foundation

import AltStoreCore

import Roxas

private extension URL
{
    #if MARKETPLACE
    
    #if STAGING
    static let flags = URL(string: "https://f000.backblazeb2.com/file/altstore-staging/altstore/marketplace-flags.json")!
    #else
    static let flags = URL(string: "https://cdn.altstore.io/file/altstore/altstore/marketplace-flags.json")!
    #endif
    
    #elseif STAGING
    static let flags = URL(string: "https://f000.backblazeb2.com/file/altstore-staging/altstore/classic-flags.json")!
    #else
    static let flags = URL(string: "https://cdn.altstore.io/file/altstore/altstore/classic-flags.json")!
    #endif
}

class UpdateRemoteFlagsOperation: ResultOperation<Void>, @unchecked Sendable
{
    private let session: URLSession
    
    override init()
    {
        let configuration = URLSessionConfiguration.default
        
        if UserDefaults.standard.responseCachingDisabled
        {
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.urlCache = nil
        }
        
        self.session = URLSession(configuration: configuration)
    }
    
    override func main()
    {
        super.main()
        
        let dataTask = self.session.dataTask(with: .flags) { (data, response, error) in
            do
            {
                if let response = response as? HTTPURLResponse
                {
                    guard response.statusCode != 404 else {
                        self.finish(.failure(URLError(.fileDoesNotExist, userInfo: [NSURLErrorKey: URL.flags])))
                        return
                    }
                }
                
                guard let data = data else { throw error! }
                guard let response = try JSONSerialization.jsonObject(with: data) as? NSDictionary, let flags = response.object(forKey: "flags") as? [String: Any] else { throw OperationError.unknown() }
                
                for (key, value) in flags
                {
                    if value is NSNull
                    {
                        // Treat NSNull as removing value for key
                        UserDefaults.shared.removeObject(forKey: key)
                    }
                    else
                    {
                        UserDefaults.shared.set(value, forKey: key)
                    }
                }
                
                self.finish(.success(()))
            }
            catch
            {
                self.finish(.failure(error))
            }
        }
        
        dataTask.resume()
    }
}
