//
//  Benefit.swift
//  AltStore
//
//  Created by Riley Testut on 8/21/19.
//  Copyright © 2019 Riley Testut. All rights reserved.
//

import Foundation

extension PatreonAPI
{
    // PatreonAPI stopped returning full benefit metadata as of July 2024, so treat it like AnyItemResponse.
    // struct BenefitAttributes: Decodable
    // {
    //     var title: String
    // }
    
    typealias BenefitResponse = AnyItemResponse
}

extension PatreonAPI
{
    public struct Benefit: Hashable
    {
        public var identifier: ALTPatreonBenefitID
        
        internal init(response: BenefitResponse)
        {
            self.identifier = ALTPatreonBenefitID(response.id)
        }
    }
}
