//
//  Media.swift
//  AltStoreCore
//
//  Created by Riley Testut on 1/31/25.
//  Copyright © 2025 Riley Testut. All rights reserved.
//

import Foundation

extension PatreonAPI
{
    typealias MediaResponse = DataResponse<MediaAttributes, AnyRelationships>
    
    struct MediaAttributes: Decodable
    {
        var file_name: String
        var mimetype: String?
    }
}

extension PatreonAPI
{
    public struct Media
    {
        public var identifier: String
        public var filename: String
        public var mimeType: String?
        
        init(response: PatreonAPI.MediaResponse)
        {
            self.identifier = response.id
            self.filename = response.attributes.file_name
            self.mimeType = response.attributes.mimetype
        }
    }
}
