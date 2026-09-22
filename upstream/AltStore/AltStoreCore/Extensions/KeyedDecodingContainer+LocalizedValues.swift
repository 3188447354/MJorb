//
//  KeyedDecodingContainer+LocalizedValues.swift
//  AltStoreCore
//
//  Created by Riley Testut on 8/6/24.
//  Copyright © 2024 Riley Testut. All rights reserved.
//

import Foundation

public extension KeyedDecodingContainer
{
    func decodeLocalizedValue<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T?
    {
        guard var localizedValues = try self.decodeIfPresent([String: T].self, forKey: key) else { return nil }
        
        // Convert all keys (language codes) to lowercase.
        localizedValues = localizedValues.map { ($0.lowercased(), $1) }.reduce(into: [String: T]()) { $0[$1.0] = $1.1 }
        
        let localizedValue = Locale.preferredLanguages.compactMap { language in
            let language = language.lowercased()
            
            if let value = localizedValues[language]
            {
                // Exact match (language + dialect)
                return value
            }
            else
            {
                // Fall back by removing components.
                var components = language.split(separator: "-").dropLast()
                while !components.isEmpty
                {
                    let baseLanguage = components.joined(separator: "-")
                    
                    if let value = localizedValues[String(baseLanguage)]
                    {
                        return value
                    }
                    else
                    {
                        components = components.dropLast()
                    }
                }
            }
            
            return nil
        }.first
        
        if let localizedValue
        {
            return localizedValue
        }
        
        // Fall back to base translation.
        let baseValue = localizedValues["base"]
        return baseValue
    }
}
