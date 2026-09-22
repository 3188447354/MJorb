//
//  MastodonAPI.swift
//  AltStore
//
//  Created by Riley Testut on 7/24/25.
//  Copyright © 2025 Riley Testut. All rights reserved.
//

import Foundation
import AuthenticationServices
import CoreData

import AltStoreCore

extension MastodonAPI
{
    #if SANDBOX
    static let instanceURL = URL(string: "https://fedi.alt.store")!
    #else
    static let instanceURL = URL(string: "https://explore.alt.store")!
    #endif
    
    private static let altstoreCallbackURL = URL(string: "altstore://mastodon/callback")!
}

fileprivate extension MastodonAPI
{
    struct ConversationContext: Decodable
    {
        var ancestors: [Toot]
        var descendants: [Toot]
    }
    
    enum AuthorizationType
    {
        case none
        case user
    }
}

struct MastodonError: ALTLocalizedError
{
    enum Code: Int, ALTErrorCode, CaseIterable
    {
        typealias Error = MastodonError
        
        case unknown
        case unauthorized
        case http
        
        case invalidServer
        case tootNotFound
    }
    
    static func unknown(file: String = #fileID, line: UInt = #line) -> MastodonError { MastodonError(code: .unknown, sourceFile: file, sourceLine: line) }
    static func unauthorized(file: String = #fileID, line: UInt = #line) -> MastodonError { MastodonError(code: .unauthorized, sourceFile: file, sourceLine: line) }
    static func http(statusCode: Int, file: String = #fileID, line: UInt = #line) -> MastodonError { MastodonError(code: .http, statusCode: statusCode, sourceFile: file, sourceLine: line) }
    
    static func invalidServer(domain: String, file: String = #fileID, line: UInt = #line) -> MastodonError { MastodonError(code: .invalidServer, domain: domain, sourceFile: file, sourceLine: line) }
    static func tootNotFound(file: String = #fileID, line: UInt = #line) -> MastodonError { MastodonError(code: .tootNotFound, sourceFile: file, sourceLine: line) }
    
    let code: Code
    
    var domain: String?
    
    var statusCode: Int?
    
    var errorFailure: String?
    var errorTitle: String?
    
    var sourceFile: String?
    var sourceLine: UInt?
        
    var errorFailureReason: String {
        switch self.code
        {
        case .unknown: return String(localized: "An unknown error occured.")
        case .unauthorized: return String(localized: "This request requires an authenticated user.")
        case .http:
            guard let statusCode else { return String(localized: "An HTTP error occured.") }
            return String(format: String(localized: "HTTP Status Code: %@"), statusCode as NSNumber)
            
        case .invalidServer:
            guard let domain else { return String(localized: "The provided domain is not a valid Mastodon server.") }
            return String(format: String(localized: "%@ is not a valid Mastodon server."), domain)
            
        case .tootNotFound: return String(localized: "The requested post could not be found.")
        }
    }
}

// Actor to avoid race conditions when caching tasks to avoid duplicate requests.
final actor MastodonAPI: NSObject
{
    static let shared = MastodonAPI()
    
    private let session = URLSession(configuration: .default)
    private let contextProvider = PresentationContextProvider()
    
    private static let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFractionalSeconds, .withInternetDateTime, .withTimeZone]
        return formatter
    }()
    private lazy var dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(abbreviation: "GMT")
        return formatter
    }()
    
    private nonisolated(unsafe) weak var signInAction: UIAlertAction?
    
    private override init()
    {
    }
}

extension MastodonAPI
{
    @MainActor
    func authenticate(presentingViewController: UIViewController) async throws -> SocialWebAccount
    {
        // Ask for user's Mastodon instance
        let alertController = UIAlertController(title: String(localized: "Please enter your Mastodon server."), message: nil, preferredStyle: .alert)
        
        alertController.addTextField { textField in
            textField.placeholder = "mastodon.social"
            textField.textContentType = .URL
            textField.keyboardType = .URL
            textField.autocorrectionType = .no
            textField.enablesReturnKeyAutomatically = true
        }
        
        let domainTextField = alertController.textFields![0]
        
        NotificationCenter.default.addObserver(self, selector: #selector(MastodonAPI.textFieldDidChange), name: UITextField.textDidChangeNotification, object: domainTextField)
        defer {
            NotificationCenter.default.removeObserver(self, name: UITextField.textDidChangeNotification, object: domainTextField)
        }
        
        try await withCheckedThrowingContinuation { continuation in
            let signInAction = UIAlertAction(title: String(localized: "Sign in"), style: .default) { _ in
                continuation.resume()
            }
            signInAction.isEnabled = false
            self.signInAction = signInAction
            alertController.addAction(signInAction)
            
            let cancelAction = UIAlertAction(title: UIAlertAction.cancel.title, style: UIAlertAction.cancel.style) { _ in
                continuation.resume(throwing: CancellationError())
            }
            alertController.addAction(cancelAction)
            
            alertController.preferredAction = signInAction
            presentingViewController.present(alertController, animated: true)
        }
        
        let domain = domainTextField.text ?? ""
        
        // Check domain is valid in case user pressed return key with invalid domain.
        guard self.isValidDomain(domain) else { throw MastodonError.invalidServer(domain: domain) }
        
        guard let serverURL = URL(string: "https://\(domain)") else { throw MastodonError.invalidServer(domain: domain)  }
        
        // Retrieve app client ID + secret from instance
        let appInfo = try await self.registerAppIfNeeded(forDomain: domain)
        
        var components = URLComponents(string: "/oauth/authorize")!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: appInfo.appClientID),
            URLQueryItem(name: "redirect_uri", value: MastodonAPI.altstoreCallbackURL.absoluteString),
            URLQueryItem(name: "scope", value: "profile+read+write"), //TODO: Finalize granular scopes
        ]
        
        let requestURL = components.url(relativeTo: serverURL)!
        
        let callbackURL = try await withCheckedThrowingContinuation { continuation in
            let authSession = ASWebAuthenticationSession(url: requestURL, callbackURLScheme: MastodonAPI.altstoreCallbackURL.scheme!) { (callbackURL, error) in
                let result = Result(callbackURL, error)
                continuation.resume(with: result)
            }
            
            authSession.presentationContextProvider = self.contextProvider
            authSession.start()
        }
        
        guard
            let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
            let codeQueryItem = components.queryItems?.first(where: { $0.name == "code" }),
            let code = codeQueryItem.value
        else {
            throw MastodonError.unknown()
        }
        
        let accessToken = try await self.fetchAccessToken(oauthCode: code, serverURL: serverURL, clientID: appInfo.appClientID, clientSecret: appInfo.appClientSecret)
        Keychain.shared.mastodonAccessToken = accessToken
        
        let context = DatabaseManager.shared.persistentContainer.newBackgroundContext()
        
        let account = try await self.fetchAccount(serverURL: serverURL, into: context)
        let objectID = account.objectID
        
        try await context.perform {
            let account = context.object(with: objectID) as! SocialWebAccount // Redundant but necessary to silence "non-Sendable SocialWebAccount" warning.
            Keychain.shared.socialWebAccountID = account.identifier
            try context.save()
        }
        
        // On MainActor already, so fetch from view context.
        guard let socialWebAccount = DatabaseManager.shared.socialWebAccount(in: DatabaseManager.shared.viewContext) else { throw MastodonError.unknown() }
        return socialWebAccount
    }
    
    func signOut()
    {
        Keychain.shared.mastodonAccessToken = nil
    }
}

extension MastodonAPI
{
    func fetchToots(ids: Set<String>, serverURL: URL = MastodonAPI.instanceURL) async throws -> [Toot]
    {        
        let fetchLimit = 100
        var fetchedToots: [Toot] = []
        
        var statusIDs = Array(ids)
        while !statusIDs.isEmpty
        {
            let statuses = statusIDs.prefix(fetchLimit)
            statusIDs.removeFirst(statuses.count)
            
            let toots = try await self._fetchToots(ids: Set(statuses), serverURL: serverURL)
            fetchedToots += toots
        }
        
        return fetchedToots
    }
    
    private func _fetchToots(ids: Set<String>, serverURL: URL = MastodonAPI.instanceURL) async throws -> [Toot]
    {
        let fetchLimit = 100
        
        guard !ids.isEmpty else { return [] }
        
        var endpoint = serverURL.appendingPathComponent("api/v1/statuses").absoluteString + "?limit=\(fetchLimit)"
        for id in ids
        {
            endpoint += "&id[]=\(id)"
        }
        
        guard let requestURL = URL(string: endpoint) else { throw MastodonError.unknown() }
        
        var request = URLRequest(url: requestURL)
        request.httpMethod = "GET"
        
        let authorizationType: AuthorizationType = (serverURL == MastodonAPI.instanceURL) ? .none : .user
        let toots: [Toot] = try await self.send(request, authorizationType: authorizationType)
        return toots
    }
    
    func resolve(_ tootURL: URL, toServer serverURL: URL) async throws -> Toot?
    {
        var components = URLComponents(string: "/api/v2/search")!
        components.queryItems = [
            URLQueryItem(name: "q", value: tootURL.absoluteString),
            URLQueryItem(name: "resolve", value: "true"),
        ]
        
        guard let requestURL = components.url(relativeTo: serverURL) else { throw MastodonError.unknown() }
        
        let request = URLRequest(url: requestURL)
        
        struct Response: Decodable
        {
            var statuses: [Toot]
        }
        
        let response: Response = try await self.send(request, authorizationType: .user)
        
        let toot = response.statuses.first
        return toot
    }
}

extension MastodonAPI
{
    func fetchFavorites(tootID: String, limit: Int? = 80) async throws -> [Account]
    {
        let startTime = CFAbsoluteTimeGetCurrent()
        
        // TODO: Support more than 80 likes per status via Link HTTP Header
        // https://github.com/apple/swift-http-structured-headers
        
        var endpoint = MastodonAPI.instanceURL.appendingPathComponent("api/v1/statuses/\(tootID)/favourited_by").absoluteString
        if let limit
        {
            endpoint += "?limit=\(limit)"
        }
        
        guard let requestURL = URL(string: endpoint) else { throw MastodonError.unknown() }
        
        var request = URLRequest(url: requestURL)
        request.httpMethod = "GET"
        
        let accounts: [Account] = try await self.send(request, authorizationType: .none)
        
        Logger.main.debug("Fetched all favorites for post \(tootID) in \(CFAbsoluteTimeGetCurrent() - startTime) seconds.")
        
        return accounts
    }
}

extension MastodonAPI
{
    func favorite(tootID: String, tootURL: URL) async throws
    {
        let context = DatabaseManager.shared.persistentContainer.newBackgroundContext()
        let serverURL = try await context.perform {
            guard let account = DatabaseManager.shared.socialWebAccount(in: context) else { throw MastodonError.unauthorized() }
            return account.serverURL
        }
        
        guard let serverURL else { throw MastodonError.unknown() }

        guard let resolvedToot = try await self.resolve(tootURL, toServer: serverURL) else { throw MastodonError.tootNotFound() }
        
        let components = URLComponents(string: "/api/v1/statuses/\(resolvedToot.id)/favourite")!
        
        let requestURL = components.url(relativeTo: serverURL)!
        
        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        
        let toot: Toot = try await self.send(request, authorizationType: .user)
        Logger.main.debug("Favorited Toot: \(toot.id)")
    }
    
    func unfavorite(tootID: String, tootURL: URL) async throws
    {
        let context = DatabaseManager.shared.persistentContainer.newBackgroundContext()
        let serverURL = try await context.perform {
            guard let account = DatabaseManager.shared.socialWebAccount(in: context) else { throw MastodonError.unauthorized() }
            return account.serverURL
        }
        
        guard let serverURL else { throw MastodonError.unknown() }
        
        guard let resolvedToot = try await self.resolve(tootURL, toServer: serverURL) else { throw MastodonError.tootNotFound() }
        
        let components = URLComponents(string: "/api/v1/statuses/\(resolvedToot.id)/unfavourite")!
        
        let requestURL = components.url(relativeTo: serverURL)!
        
        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        
        let toot: Toot = try await self.send(request, authorizationType: .user)
        Logger.main.debug("Unfavorited Toot: \(toot.id)")
    }
}

private extension MastodonAPI
{
    func fetchAccessToken(oauthCode: String, serverURL: URL, clientID: String, clientSecret: String) async throws -> String
    {
        guard let encodedRedirectURI = (MastodonAPI.altstoreCallbackURL.absoluteString as NSString).addingPercentEncoding(withAllowedCharacters: .alphanumerics),
              let encodedOauthCode = (oauthCode as NSString).addingPercentEncoding(withAllowedCharacters: .alphanumerics)
        else { throw MastodonError.unknown() }
        
        let body = "code=\(encodedOauthCode)&grant_type=authorization_code&client_id=\(clientID)&client_secret=\(clientSecret)&redirect_uri=\(encodedRedirectURI)"
        
        guard let requestURL = URL(string: "/oauth/token", relativeTo: serverURL) else { throw URLError(.badURL, userInfo: [NSURLErrorKey: serverURL, NSURLErrorFailingURLErrorKey: serverURL]) }
        
        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.httpBody = body.data(using: .utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        
        struct Response: Decodable
        {
            var access_token: String
        }
        
        let response: Response = try await self.send(request, authorizationType: .none)
        return response.access_token
    }
    
    func registerAppIfNeeded(forDomain domain: String) async throws -> iCloudAPI.ServerRecord
    {
        if let record = try await iCloudAPI.shared.fetchMastodonServer(domain: domain)
        {
            return record
        }
        
        guard let instanceURL = URL(string: "https://\(domain)") else { throw MastodonError.invalidServer(domain: domain) }
                
        let requestURL = instanceURL.appending(path: "/api/v1/apps")
        
        struct Request: Encodable
        {
            var client_name: String
            var redirect_uris: [String]
            var scopes: String
            var website: String
        }
        
        let requestBody = Request(client_name: "AltStore", redirect_uris: [MastodonAPI.altstoreCallbackURL.absoluteString], scopes: "profile read write", website: "https://altstore.io")
        let bodyData = try JSONEncoder().encode(requestBody)
        
        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyData
        
        struct Response: Decodable
        {
            var id: String
            var client_id: String
            var client_secret: String
        }
        
        let response: Response = try await self.send(request, authorizationType: .none)
        
        let record = try await iCloudAPI.shared.registerApp(id: response.id, clientID: response.client_id, clientSecret: response.client_secret, domain: domain)
        return record
    }
    
    func fetchAccount(serverURL: URL, into context: NSManagedObjectContext) async throws -> SocialWebAccount
    {
        do
        {
            do
            {
                guard let components = URLComponents(string: "/oauth/userinfo"), let requestURL = components.url(relativeTo: serverURL) else { throw MastodonError.unknown() }
                
                let request = URLRequest(url: requestURL)
                let account: AuthResponse = try await self.send(request, authorizationType: .user)
                
                let socialWebAccount = try await context.perform {
                    // Might be different than web URL (e.g. alt.store vs explore.alt.store)
                    guard let host = URL(string: account.sub)?.host() else { throw MastodonError.unknown() }
                    
                    let socialWebAccount = SocialWebAccount(name: account.name, username: account.preferred_username, identifier: account.sub, url: account.profile, avatarURL: account.picture, domain: host, type: .mastodon, context: context)
                    return socialWebAccount
                }
                
                return socialWebAccount
            }
            catch let error as MastodonError where error.code == .unauthorized
            {
                self.signOut()
                throw error
            }
            catch let error as DecodingError
            {
                let nsError = error as NSError
                guard let codingPath = nsError.userInfo[ALTNSCodingPathKey] as? [CodingKey] else { throw error }
                
                let rawComponents = codingPath.map { $0.intValue?.description ?? $0.stringValue }
                let pathDescription = rawComponents.joined(separator: " > ")
                                    
                let localizedDescription = nsError.localizedDebugDescription ?? nsError.localizedDescription
                let debugDescription = localizedDescription + " Path: " + pathDescription
                
                var userInfo = nsError.userInfo
                userInfo[NSDebugDescriptionErrorKey] = debugDescription
                throw NSError(domain: nsError.domain, code: nsError.code, userInfo: userInfo)
            }
        }
        catch
        {
            let nsError = (error as NSError)
            Logger.main.error("Failed to fetch Mastodon account. \(nsError.localizedDebugDescription ?? nsError.localizedDescription, privacy: .public)")
            
            throw error
        }
    }
    
    func send<ResponseType: Decodable>(_ request: URLRequest, authorizationType: AuthorizationType) async throws -> ResponseType
    {
        var request = request
        
        switch authorizationType
        {
        case .none: break
        case .user:
            guard let accessToken = Keychain.shared.mastodonAccessToken else { throw MastodonError.unauthorized() }
            request.setValue("Bearer " + accessToken, forHTTPHeaderField: "Authorization")
        }
        
        while true
        {
            let (data, urlResponse) = try await self.session.data(for: request)
            guard let httpResponse = urlResponse as? HTTPURLResponse else { throw MastodonError.unknown() }
            
            let decoder = Foundation.JSONDecoder()
            decoder.dateDecodingStrategy = .custom({ decoder in
                let container = try decoder.singleValueContainer()
                let text = try container.decode(String.self)
                
                // Full ISO8601 Format.
                if let date = MastodonAPI.iso8601Formatter.date(from: text)
                {
                    return date
                }
                
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Date is in invalid format.")
            })
            
            switch httpResponse.statusCode
            {
            case 200...299:
                let response = try decoder.decode(ResponseType.self, from: data)
                return response
                
            case 401:
                throw MastodonError.unauthorized()
                
            case 429:
                // Rate Limited
                let rateLimitDelay: TimeInterval
                if let resetDateString = httpResponse.value(forHTTPHeaderField: "X-RateLimit-Reset"), let resetDate = MastodonAPI.iso8601Formatter.date(from: resetDateString)
                {
                    let serverDate: Date
                    if let dateString = httpResponse.value(forHTTPHeaderField: "Date")
                    {
                        serverDate = self.dateFormatter.date(from: dateString) ?? Date()
                    }
                    else
                    {
                        serverDate = Date()
                    }
                    
                    rateLimitDelay = max(1.0, resetDate.timeIntervalSince(serverDate))
                }
                else
                {
                    rateLimitDelay = 1.0
                }
                
                guard rateLimitDelay <= 60 else {
                    // Assume request failed
                    Logger.main.error("Mastodon API rate limit exceeded. Reset time too far in future: \(rateLimitDelay) seconds")
                    throw MastodonError.http(statusCode: 429)
                }
                
                Logger.main.info("Mastodon API rate limit exceeded. Retrying request after delay: \(rateLimitDelay) seconds")
                
                try await Task.sleep(for: .seconds(rateLimitDelay))
                
            default:
                let response = try decoder.decode(ErrorResponse.self, from: data)
                throw response
            }
        }
    }
}

private extension MastodonAPI
{
    @MainActor
    @objc func textFieldDidChange(_ notification: Notification)
    {
        guard let textField = notification.object as? UITextField, let signInAction else { return }
        
        let text = textField.text ?? ""
        
        let isValidDomain = self.isValidDomain(text)
        signInAction.isEnabled = isValidDomain
    }
    
    nonisolated func isValidDomain(_ domain: String) -> Bool
    {
        let hasPeriodSeparator = domain.split(separator: ".").count > 1
        let isUsername = domain.contains("@")
        
        let isValidDomain = hasPeriodSeparator && !isUsername
        return isValidDomain
    }
}
