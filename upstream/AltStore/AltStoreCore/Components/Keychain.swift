//
//  Keychain.swift
//  AltStore
//
//  Created by Riley Testut on 6/4/19.
//  Copyright © 2019 Riley Testut. All rights reserved.
//

import Foundation
import KeychainAccess

import AltSign

import MarketplaceKit

@propertyWrapper
public struct KeychainItem<Value>
{
    public let key: String
    
    public var wrappedValue: Value? {
        get {
            switch Value.self
            {
            case is Data.Type: return try? Keychain.shared.keychain.getData(self.key) as? Value
            case is String.Type: return try? Keychain.shared.keychain.getString(self.key) as? Value
            case is Date.Type:
                guard #available(iOS 15, *), let dateString = try? Keychain.shared.keychain.getString(self.key) else { return nil }
                
                let date = try? Date(dateString, strategy: .iso8601)
                return date as? Value
                
            default: return nil
            }
        }
        set {
            switch Value.self
            {
            case is Data.Type: Keychain.shared.keychain[data: self.key] = newValue as? Data
            case is String.Type: Keychain.shared.keychain[self.key] = newValue as? String
            case is Date.Type:
                guard #available(iOS 15, *) else { break }
                        
                let date = newValue as? Date
                Keychain.shared.keychain[self.key] = date?.formatted(.iso8601)
                
            default: break
            }
        }
    }
    
    public init(key: String)
    {
        self.key = key
    }
}

public class Keychain
{
    public static let shared = Keychain()
    
    #if MARKETPLACE
    fileprivate let keychain = KeychainAccess.Keychain(service: "io.altstore.AltStore").accessibility(.afterFirstUnlock).synchronizable(true)
    #else
    fileprivate let keychain = KeychainAccess.Keychain(service: "com.rileytestut.AltStore").accessibility(.afterFirstUnlock).synchronizable(true)
    #endif
    
    @KeychainItem(key: "appleIDEmailAddress")
    public var appleIDEmailAddress: String?
    
    @KeychainItem(key: "appleIDPassword")
    public var appleIDPassword: String?
    
    @KeychainItem(key: "signingCertificatePrivateKey")
    public var signingCertificatePrivateKey: Data?
    
    @KeychainItem(key: "signingCertificateSerialNumber")
    public var signingCertificateSerialNumber: String?
    
    @KeychainItem(key: "signingCertificate")
    public var signingCertificate: Data?
    
    @KeychainItem(key: "signingCertificatePassword")
    public var signingCertificatePassword: String?
    
    @KeychainItem(key: "patreonAccessToken")
    public var patreonAccessToken: String?
    
    @KeychainItem(key: "patreonRefreshToken")
    public var patreonRefreshToken: String?
    
    @KeychainItem(key: "patreonCreatorAccessToken")
    public var patreonCreatorAccessToken: String?
    
    @KeychainItem(key: "patreonAccountID")
    public var patreonAccountID: String?
    
    @KeychainItem(key: "stripeEmailAddress")
    public var stripeEmailAddress: String?
    
    @KeychainItem(key: "palPromoExpiration")
    public var palPromoExpiration: Date?
    
    
    // Open Social Web
    @KeychainItem(key: "mastodonAccessToken")
    public var mastodonAccessToken: String?
    
    @KeychainItem(key: "blueskyAccessToken")
    public var blueskyAccessToken: String?
    
    @KeychainItem(key: "blueskyRefreshToken")
    public var blueskyRefreshToken: String?
    
    @KeychainItem(key: "socialWebAccountID")
    public var socialWebAccountID: String?
    
    private init()
    {
    }
    
    public func reset()
    {
        self.appleIDEmailAddress = nil
        self.appleIDPassword = nil
        self.signingCertificatePrivateKey = nil
        self.signingCertificateSerialNumber = nil
        
        self.stripeEmailAddress = nil
        self.palPromoExpiration = nil
    }
}
