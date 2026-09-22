//
//  FetchSourceCollectionsOperation.swift
//  AltStore
//
//  Created by Riley Testut on 1/9/26.
//  Copyright © 2026 Riley Testut. All rights reserved.
//

import Foundation

import AltStoreCore

private extension URL
{
    #if STAGING
    static let sources = URL(string: "https://f000.backblazeb2.com/file/altstore-staging/altstore/recommended-sources.json")!
    #else
    static let sources = URL(string: "https://cdn.altstore.io/file/altstore/altstore/recommended-sources.json")!
    #endif
}

class SourceCollection: NSObject, Decodable
{
    struct SourceReference: Decodable
    {
        var url: URL
    }
    
    var localizedTitle: String
    var localizedDescription: String?
    
    var emoji: String
    var tintColor: UIColor
    
    var sources: [SourceReference]
    
    private enum CodingKeys: String, CodingKey
    {
        case localizedTitle = "title"
        case localizedDescription = "description"
        case emoji
        case tintColor
        case sources
    }
    
    init(localizedTitle: String, localizedDescription: String, emoji: String, tintColor: UIColor, sources: [SourceReference])
    {
        self.localizedTitle = localizedTitle
        self.localizedDescription = localizedDescription
        self.emoji = emoji
        self.tintColor = tintColor
        self.sources = sources
    }
    
    required init(from decoder: any Decoder) throws
    {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        guard let localizedTitle = try container.decodeLocalizedValue(String.self, forKey: .localizedTitle) else {
            throw DecodingError.valueNotFound(String.self, .init(codingPath: decoder.codingPath + [CodingKeys.localizedTitle], debugDescription: "Missing localized title."))
        }
        
        self.localizedTitle = localizedTitle
        self.localizedDescription = try container.decodeLocalizedValue(String.self, forKey: .localizedDescription)
        
        self.emoji = try container.decode(String.self, forKey: .emoji)
        
        let tintColorHex = try container.decode(String.self, forKey: .tintColor)
        
        guard let tintColor = UIColor(hexString: tintColorHex) else {
            throw DecodingError.dataCorruptedError(forKey: .tintColor, in: container, debugDescription: "Hex code is invalid.")
        }
        
        self.tintColor = tintColor
        
        self.sources = try container.decode([SourceReference].self, forKey: .sources)
    }
}

extension FetchSourceCollectionsOperation
{
    private struct Response: Decodable
    {
        var version: Int
        
        var collections: [SourceCollection]?
    }
}

class FetchSourceCollectionsOperation: ResultOperation<[SourceCollection]>, @unchecked Sendable
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
        
        let dataTask = self.session.dataTask(with: .sources) { (data, response, error) in
            do
            {
                if let response = response as? HTTPURLResponse
                {
                    guard response.statusCode != 404 else {
                        self.finish(.failure(URLError(.fileDoesNotExist, userInfo: [NSURLErrorKey: URL.sources])))
                        return
                    }
                }
                
                guard let data = data else { throw error! }
                
                let response = try Foundation.JSONDecoder().decode(Response.self, from: data)
                self.finish(.success(response.collections ?? []))
            }
            catch
            {
                self.finish(.failure(error))
            }
        }
        
        dataTask.resume()
    }
}
