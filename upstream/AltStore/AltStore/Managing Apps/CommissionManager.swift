//
//  CommissionManager.swift
//  AltStore
//
//  Created by Riley Testut on 12/18/25.
//  Copyright © 2025 Riley Testut. All rights reserved.
//

import Foundation
import MarketplaceKit

import AltStoreCore

@available(iOS 26.2, *)
extension CommissionManager
{
    private struct RegisterTokenRequest: Encodable
    {
        var externalPurchaseToken: String
        var region: String
    }
    
    private struct LinkTokenRequest: Encodable
    {
        var externalPurchaseToken: String
        var accountID: String
        var membershipID: String
    }
    
    private struct AppleExternalPurchaseToken: Codable
    {
        var externalPurchaseId: String
        var tokenCreationDate: Date
        var appAppleId: Int64
        var bundleId: String
    }
}

@available(iOS 26.2, *)
public class CommissionManager
{
    static var regions: Set<String> { ["jp", "br"] }
    
    static let shared = CommissionManager()
    
    #if STAGING
    private let baseURL = URL(string: "https://dev.altstore.io")!
    #else
    private let baseURL = URL(string: "https://api.altstore.io")!
    #endif
    
    private let session = URLSession(configuration: .ephemeral)
    
    private init()
    {
    }
}

@available(iOS 26.2, *)
extension CommissionManager
{
    func requestCoreTechnologyToken(for region: String) async throws -> String
    {
        let encodedToken = try await TransactionReporting.token(for: .coreTechnology)
        
        let body = RegisterTokenRequest(externalPurchaseToken: encodedToken, region: region)
        let bodyData = try JSONEncoder().encode(body)
        
        let requestURL = self.baseURL.appending(path: "external-purchases")
        
        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.httpBody = bodyData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue("application/json", forHTTPHeaderField: "Accept")
        
        let (_, response) = try await self.session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        
        guard httpResponse.statusCode == 200 || httpResponse.statusCode == 201 else {
            let failureReason = String(format: NSLocalizedString("Failed to retrieve commission token from Apple. Error Code: %@", comment: ""), httpResponse.statusCode as NSNumber)
            throw OperationError.unknown(failureReason: failureReason)
        }
        
        Logger.main.info("Registered token \(encodedToken, privacy: .public) for potential Patreon purchase.")
        
        return encodedToken
    }
    
    func link(token: String, @AsyncManaged with patreonAccount: PatreonAccount) async throws
    {
        let values = await $patreonAccount.perform { account -> (String, String)? in
            guard let altstorePledge = account.pledges.first(where: { $0.campaignURL.absoluteString.lowercased().contains("patreon.com/rileyshane") }) else { return nil }
            return (account.identifier, altstorePledge.identifier)
        }
        
        guard let (accountID, membershipID) = values else { return }
        
        let body = LinkTokenRequest(externalPurchaseToken: token, accountID: accountID, membershipID: membershipID)
        let bodyData = try JSONEncoder().encode(body)
        
        let requestURL = self.baseURL.appending(path: "link-altstore-purchase")
        
        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.httpBody = bodyData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue("application/json", forHTTPHeaderField: "Accept")
        
        let (_, response) = try await self.session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        
        guard httpResponse.statusCode == 200 else {
            let failureReason = String(format: NSLocalizedString("Failed to link commission token with Patreon account. Error Code: %@", comment: ""), httpResponse.statusCode as NSNumber)
            throw OperationError.unknown(failureReason: failureReason)
        }
        
        Logger.main.info("Linked token \(token, privacy: .public) with Patreon account \(accountID, privacy: .public) with membership \(membershipID, privacy: .public)")
    }
}
