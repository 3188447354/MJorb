//
//  BlueskyAPI+Types.swift
//  AltStore
//
//  Created by Riley Testut on 1/7/26.
//  Copyright © 2026 Riley Testut. All rights reserved.
//

import Foundation

extension BlueskyAPI
{
    struct Account: Decodable
    {
        struct Viewer: Decodable
        {
            var following: String?
            var followedBy: String?
        }
        
        var did: String
        var handle: String
        var displayName: String?
        var avatar: URL?
        
        var description: String?
        var followersCount: Int
        
        var viewer: Viewer?
    }
    
    struct DIDDocument: Decodable
    {
        struct Service: Decodable
        {
            let id: String?
            let type: String
            let serviceEndpoint: String
        }
        
        var id: String
        var service: [Service]?
    }
    
    struct Post: Decodable
    {
        struct Record: Decodable
        {
            var type: String
            var text: String
            var createdAt: Date
            
            var bridgyOriginalUrl: URL?
            var bridgyOriginalText: String?
            
            private enum CodingKeys: String, CodingKey
            {
                case type = "$type"
                case text
                case createdAt
                case bridgyOriginalUrl
                case bridgyOriginalText
            }
        }
        
        struct Viewer: Decodable
        {
            var like: String?
            var bookmarked: Bool?
        }
        
        var uri: String
        var cid: String
        var record: Record
        var viewer: Viewer?
    }
    
    struct Like: Decodable
    {
        struct Subject: Decodable
        {
            var uri: String
        }
        
        var uri: String
        var subject: Subject
    }
    
    struct LikeRequest: Encodable
    {
        struct Record: Encodable
        {
            struct Subject: Encodable
            {
                var uri: String
                var cid: String
            }
            
            var createdAt: Date
            var subject: Subject
        }
        
        var repo: String
        var collection: String
        
        var record: Record
    }
    
    struct FollowRequest: Encodable
    {
        struct Record: Encodable
        {
            var createdAt: Date
            var subject: String
        }
        
        var repo: String
        var collection: String
        
        var record: Record
    }
    
    struct DeleteRecordRequest: Encodable
    {
        var repo: String
        var collection: String
        var rkey: String
    }
    
    struct FeedResponse: Decodable
    {
        struct FeedItem: Decodable
        {
            var post: Post
        }
        
        var feed: [FeedItem]
        var cursor: String?
    }
    
    struct EmptyResponse: Decodable
    {
    }
        
    struct ErrorResponse: LocalizedError, Decodable
    {
        var errorName: String
        var errorDescription: String?
        
        private enum CodingKeys: String, CodingKey
        {
            case errorName = "error"
            case errorDescription = "message"
        }
    }
}
