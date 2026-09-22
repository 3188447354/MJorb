//
//  MastodonAPI+Types.swift
//  AltStore
//
//  Created by Riley Testut on 7/24/25.
//  Copyright © 2025 Riley Testut. All rights reserved.
//

import Foundation
import AuthenticationServices

extension MastodonAPI
{
    struct Toot: Identifiable, Decodable
    {
        var id: String
        var uri: URL
        
        var created_at: Date
        
        var url: URL // Web URL
        
        var replies_count: Int
        var reblogs_count: Int
        var favourites_count: Int
        
        var favourited: Bool? // Only if authenticated
        
        var account: Account
    }
    
    struct Account: Identifiable, Hashable, Decodable
    {
        var id: String
        var username: String
        var display_name: String
        var acct: String
        var note: String // Bio or description
        
        var followers_count: Int
        
        var url: URL
        var uri: URL
        
        var avatar_static: URL
    }
    
    struct AuthResponse: Decodable
    {
        var iss: String
        var sub: String
        var name: String
        var preferred_username: String
        var profile: URL
        var picture: URL
    }
    
    struct ErrorResponse: LocalizedError, Decodable
    {
        var errorName: String
        var errorDescription: String?
        
        private enum CodingKeys: String, CodingKey
        {
            case errorName = "error"
            case errorDescription = "error_description"
        }
    }
    
    class PresentationContextProvider: NSObject, ASWebAuthenticationPresentationContextProviding
    {
        nonisolated override init()
        {
        }
        
        func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor
        {
            //TODO: Properly support multiple scenes.
            
            guard let windowScene = UIApplication.alt_shared?.connectedScenes.lazy.compactMap({ $0 as? UIWindowScene }).first else { return UIWindow() }

            if #available(iOS 15, *), let keyWindow = windowScene.keyWindow
            {
                return keyWindow
            }
            else if let delegate = windowScene.delegate as? UIWindowSceneDelegate,
                    let optionalWindow = delegate.window,
                    let window = optionalWindow
            {
                return window
            }

            return UIWindow()
        }
    }
}
