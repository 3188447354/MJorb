//
//  BlueskyAPI.swift
//  AltStore
//
//  Created by Riley Testut on 1/7/26.
//  Copyright © 2026 Riley Testut. All rights reserved.
//

import Foundation
import AuthenticationServices

import AltStoreCore

extension BlueskyAPI
{
    private static let baseURL = URL(string: "https://bsky.social")!
    
    static let bridgyFedHandle = "ap.brid.gy"
    static let bridgyFedFediverseDomain = "bsky.brid.gy"
}

fileprivate extension BlueskyAPI
{
    struct UserTokens: Decodable
    {
        var accessJwt: String
        var refreshJwt: String
        var did: String
        var handle: String
    }
    
    enum AuthorizationType
    {
        case none
        case user
        case refresh
    }
}

struct BlueskyError: ALTLocalizedError
{
    enum Code: Int, ALTErrorCode, CaseIterable
    {
        typealias Error = BlueskyError
        
        case unknown
        case unauthorized
        case http
        
        case invalidDID
        
        case incorrectCredentials
        case personalDataServerNotFound
        
        case postNotFound
        case handleNotFound
    }
    
    static func unknown(file: String = #fileID, line: UInt = #line) -> BlueskyError { BlueskyError(code: .unknown, sourceFile: file, sourceLine: line) }
    static func unauthorized(file: String = #fileID, line: UInt = #line) -> BlueskyError { BlueskyError(code: .unauthorized, sourceFile: file, sourceLine: line) }
    static func http(statusCode: Int, file: String = #fileID, line: UInt = #line) -> BlueskyError { BlueskyError(code: .http, statusCode: statusCode, sourceFile: file, sourceLine: line) }
    
    static func invalidDID(_ did: String, file: String = #fileID, line: UInt = #line) -> BlueskyError { BlueskyError(code: .invalidDID, did: did, sourceFile: file, sourceLine: line) }
    static func incorrectCredentials(file: String = #fileID, line: UInt = #line) -> BlueskyError { BlueskyError(code: .incorrectCredentials, sourceFile: file, sourceLine: line) }
    static func personalDataServerNotFound(file: String = #fileID, line: UInt = #line) -> BlueskyError { BlueskyError(code: .personalDataServerNotFound, sourceFile: file, sourceLine: line) }
    
    static func postNotFound(file: String = #fileID, line: UInt = #line) -> BlueskyError { BlueskyError(code: .postNotFound, sourceFile: file, sourceLine: line) }
    static func handleNotFound(_ handle: String, file: String = #fileID, line: UInt = #line) -> BlueskyError { BlueskyError(code: .handleNotFound, handle: handle, sourceFile: file, sourceLine: line) }
    
    let code: Code
    
    @UserInfoValue
    var statusCode: Int?
    
    @UserInfoValue
    var did: String?
    
    @UserInfoValue
    var handle: String?
    
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
            
        case .invalidDID:
            guard let did else { return String(localized: "The provided DID is invalid.") }
            return String(format: String(localized: "The provided DID %@ is invalid."), did)
            
        case .incorrectCredentials:
            return String(localized: "Incorrect username or password.")
        
        case .personalDataServerNotFound:
            return String(localized: "The Personal Data Server for this user could not be found.")
            
        case .postNotFound:
            return String(localized: "The requested post could not be found.")
            
        case .handleNotFound:
            guard let handle else { return String(localized: "An account with this username could not be found.") }
            return String(localized: "An account with the username @\(handle) could not be found.")
        }
    }
}

class BlueskyAPI
{
    static let shared = BlueskyAPI()
    
    private let session = URLSession(configuration: .default)
    
    private weak var usernameTextField: UITextField?
    private weak var passwordTextField: UITextField?
    private weak var signInAction: UIAlertAction?
    
    private init()
    {
    }
}

extension BlueskyAPI
{
    @MainActor
    func authenticate(presentingViewController: UIViewController) async throws -> SocialWebAccount
    {
        let alertController = UIAlertController(title: String(localized: "Sign in with your Bluesky account"), message: String(localized: "You'll need to generate an app-specific password in your Bluesky settings."), preferredStyle: .alert)
        
        alertController.addTextField { textField in
            textField.placeholder = String(localized: "Username")
            textField.textContentType = .username
            textField.keyboardType = .default
            textField.autocorrectionType = .no
            textField.enablesReturnKeyAutomatically = true
        }
        
        alertController.addTextField { textField in
            textField.placeholder = String(localized: "App Password")
            textField.textContentType = .password
            textField.keyboardType = .default
            textField.autocorrectionType = .no
            textField.enablesReturnKeyAutomatically = true
            textField.isSecureTextEntry = true
        }
        
        let usernameTextField = alertController.textFields![0]
        self.usernameTextField = usernameTextField
        
        let passwordTextField = alertController.textFields![1]
        self.passwordTextField = passwordTextField
        
        NotificationCenter.default.addObserver(self, selector: #selector(BlueskyAPI.textFieldDidChange), name: UITextField.textDidChangeNotification, object: usernameTextField)
        NotificationCenter.default.addObserver(self, selector: #selector(BlueskyAPI.textFieldDidChange), name: UITextField.textDidChangeNotification, object: passwordTextField)
        
        defer {
            NotificationCenter.default.removeObserver(self, name: UITextField.textDidChangeNotification, object: usernameTextField)
            NotificationCenter.default.removeObserver(self, name: UITextField.textDidChangeNotification, object: passwordTextField)
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
            
            presentingViewController.present(alertController, animated: true)
        }
        
        let username = usernameTextField.text ?? ""
        let password = passwordTextField.text ?? ""
        
        let did = try await self.resolveHandle(username)
        let pdsURL = try await self.resolvePDS(did: did)
        
        try await self.logIn(username: username, password: password, pdsURL: pdsURL)
        
        let account = try await self.fetchAccount(did: did, pdsURL: pdsURL)
        let accountURL = URL(string: "https://bsky.app/profile/\(account.handle)")!
        guard let host = pdsURL.host else { throw BlueskyError.unknown() }
        
        Keychain.shared.socialWebAccountID = account.did
        
        let context = DatabaseManager.shared.persistentContainer.newBackgroundContext()
        try await context.perform {
            _ = SocialWebAccount(name: account.displayName ?? "", username: account.handle, identifier: account.did, url: accountURL, avatarURL: account.avatar, domain: host, type: .bluesky, context: context)
            try context.save()
        }
        
        guard let socialWebAccount = DatabaseManager.shared.socialWebAccount() else { throw BlueskyError.unknown() }
        return socialWebAccount
    }
    
    func signOut()
    {
        Keychain.shared.blueskyAccessToken = nil
        Keychain.shared.blueskyRefreshToken = nil
    }
}

extension BlueskyAPI
{
    func fetchPost(uri: String) async throws -> Post?
    {
        let posts = try await self.fetchPosts(uris: [uri])
        return posts.first
    }
    
    func fetchPosts(uris: some Collection<String>) async throws -> [Post]
    {
        var allPosts: [Post] = []
        
        var remainingURIs = Array(uris)
        while !remainingURIs.isEmpty
        {
            let uris = remainingURIs.prefix(25)
            
            let posts = try await self._fetchPosts(uris: Array(uris))
            allPosts += posts
            
            remainingURIs = Array(remainingURIs.dropFirst(uris.count))
        }
        
        return allPosts
    }
    
    private func _fetchPosts(uris: [String]) async throws -> [Post]
    {
        let context = DatabaseManager.shared.persistentContainer.newBackgroundContext()
        let serverURL = try await context.perform {
            guard let socialWebAccount = DatabaseManager.shared.socialWebAccount(in: context), let serverURL = socialWebAccount.serverURL else { throw BlueskyError.unauthorized() }
            return serverURL
        }
        
        var components = URLComponents(string: "/xrpc/app.bsky.feed.getPosts")!
        
        let queryItems = uris.map { URLQueryItem(name: "uris[]", value: $0) }
        components.queryItems = queryItems
        
        let requestURL = components.url(relativeTo: serverURL)!
        let request = URLRequest(url: requestURL)
        
        struct Response: Decodable
        {
            var posts: [Post]
        }
        
        let response: Response = try await self.send(request, authorizationType: .user)
        return response.posts
    }
}

extension BlueskyAPI
{
    func like(_ post: Post) async throws
    {
        let context = DatabaseManager.shared.persistentContainer.newBackgroundContext()
        let (did, domain) = try await context.perform {
            guard let socialWebAccount = DatabaseManager.shared.socialWebAccount(in: context) else { throw BlueskyError.unauthorized() }
            return (socialWebAccount.identifier, socialWebAccount.domain)
        }
                
        guard let requestURL = URL(string: "https://\(domain)/xrpc/com.atproto.repo.createRecord") else { throw BlueskyError.unknown() } // Invalid account
               
        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        
        let requestBody = LikeRequest(repo: did, collection: "app.bsky.feed.like", record: .init(createdAt: .now, subject: .init(uri: post.uri, cid: post.cid)))
        
        let bodyData = try encoder.encode(requestBody)
        request.httpBody = bodyData
        
        struct Response: Decodable
        {
            var uri: String
            var cid: String
        }
        
        let _: Response = try await self.send(request, authorizationType: .user)
    }
    
    func unlike(_ post: Post) async throws
    {
        guard let likeLink = post.viewer?.like else { return } // Not an error, the status is already unliked so just return.
        
        let context = DatabaseManager.shared.persistentContainer.newBackgroundContext()
        let (did, domain) = try await context.perform {
            guard let socialWebAccount = DatabaseManager.shared.socialWebAccount(in: context) else { throw BlueskyError.unauthorized() }
            return (socialWebAccount.identifier, socialWebAccount.domain)
        }
        
        let pdsURL = URL(string: "https://\(domain)")!
        let rkey = (likeLink as NSString).lastPathComponent
                
        let requestURL = pdsURL.appending(path: "/xrpc/com.atproto.repo.deleteRecord")
        
        let requestBody = DeleteRecordRequest(repo: did, collection: "app.bsky.feed.like", rkey: rkey)
        let bodyData = try JSONEncoder().encode(requestBody)
        
        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyData
        
        let _: EmptyResponse = try await self.send(request, authorizationType: .user)
    }
}

extension BlueskyAPI
{
    func fetchProfile(did: String) async throws -> Account
    {
        let publicURL = URL(string: "https://public.api.bsky.app")!
        
        var components = URLComponents(string: "/xrpc/app.bsky.actor.getProfile")!
        components.queryItems = [
            URLQueryItem(name: "actor", value: did),
        ]
        
        let requestURL = components.url(relativeTo: publicURL)!
        let request = URLRequest(url: requestURL)
        
        let account: Account = try await self.send(request, authorizationType: .none)
        return account
    }
    
    func isFollowingAccount(handle: String) async throws -> Bool
    {
        let account = try await self.fetchAccount(handle: handle)
        
        let isFollowing = (account.viewer?.following != nil)
        return isFollowing
    }
    
    func isFollowedByAccount(handle: String) async throws -> Bool
    {
        let account = try await self.fetchAccount(handle: handle)
        
        let isFollowedBy = (account.viewer?.followedBy != nil)
        return isFollowedBy
    }
    
    func fetchAccount(handle: String) async throws -> Account
    {
        let context = DatabaseManager.shared.persistentContainer.newBackgroundContext()
        let serverURL = try await context.perform {
            guard let socialWebAccount = DatabaseManager.shared.socialWebAccount(in: context) else { throw BlueskyError.unauthorized() }
            return socialWebAccount.serverURL
        }
        
        guard let serverURL else { throw BlueskyError.unknown() }
        
        var components = URLComponents(string: "/xrpc/app.bsky.actor.getProfile")!
        components.queryItems = [
            URLQueryItem(name: "actor", value: handle),
        ]
        
        let requestURL = components.url(relativeTo: serverURL)!
        let request = URLRequest(url: requestURL)
        
        let response: Account = try await self.send(request, authorizationType: .user)
        return response
    }
    
    func followAccount(handle: String) async throws
    {
        let context = DatabaseManager.shared.persistentContainer.newBackgroundContext()
        let (did, domain) = try await context.perform {
            guard let socialWebAccount = DatabaseManager.shared.socialWebAccount(in: context) else { throw BlueskyError.unauthorized() }
            return (socialWebAccount.identifier, socialWebAccount.domain)
        }
        
        let destinationAccountHandle = try await self.resolveHandle(handle)
                
        guard let requestURL = URL(string: "https://\(domain)/xrpc/com.atproto.repo.createRecord") else { throw BlueskyError.unknown() } // Invalid account
               
        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        
        let requestBody = FollowRequest(repo: did, collection: "app.bsky.graph.follow", record: .init(createdAt: .now, subject: destinationAccountHandle))
        
        let bodyData = try encoder.encode(requestBody)
        request.httpBody = bodyData
        
        struct Response: Decodable
        {
            var uri: String
            var cid: String
        }
        
        let response: Response = try await self.send(request, authorizationType: .user)
        Logger.main.debug("Successfully followed Bluesky account @\(handle) (\(response.uri))!")
    }
    
    func resolveHandle(_ handle: String) async throws -> String
    {
        var components = URLComponents(string: "/xrpc/com.atproto.identity.resolveHandle")!
        components.queryItems = [
            URLQueryItem(name: "handle", value: handle),
        ]
        
        let requestURL = components.url(relativeTo: BlueskyAPI.baseURL)!
        let request = URLRequest(url: requestURL)
        
        struct Response: Decodable
        {
            var did: String
        }
        
        do
        {
            let response: Response = try await self.send(request, authorizationType: .none)
            return response.did
        }
        catch let error as ErrorResponse where error.errorName == "HandleNotFound"
        {
            throw BlueskyError.handleNotFound(handle)
        }
        catch let error as ErrorResponse where error.errorName == "InvalidRequest"
        {
            // Documentation says HandleNotFound, but in practice if handle doesn't exist we get InvalidRequest :/
            throw BlueskyError.handleNotFound(handle)
        }
    }
    
    func fetchAccountPosts(did: String) async throws -> [Post]
    {
        var allPosts: [Post] = []
        var fetchCursor: String?
        
        repeat
        {
            var components = URLComponents(string: "/xrpc/app.bsky.feed.getAuthorFeed")!
            components.queryItems = [
                URLQueryItem(name: "actor", value: did),
                URLQueryItem(name: "filter", value: "posts_no_replies"),
                URLQueryItem(name: "limit", value: "100"),
            ]
            
            if let fetchCursor
            {
                components.queryItems?.append(URLQueryItem(name: "cursor", value: fetchCursor))
            }
            
            let requestURL = components.url(relativeTo: BlueskyAPI.baseURL)!
            let request = URLRequest(url: requestURL)
            
            let response: FeedResponse = try await self.send(request, authorizationType: .user)
            
            let posts = response.feed.map(\.post)
            allPosts.append(contentsOf: posts)
            
            fetchCursor = response.cursor
            
            if response.feed.isEmpty
            {
                // Stop pagination if empty array is returned.
                break
            }
        }
        while (fetchCursor != nil);
        
        return allPosts
    }
}

private extension BlueskyAPI
{
    func resolvePDS(did: String) async throws -> URL
    {
        let requestURL: URL
        
        if did.hasPrefix("did:plc:")
        {
            requestURL = URL(string: "https://plc.directory/\(did)")!
        }
        else if let range = did.range(of: "did:web:"), range.lowerBound == did.startIndex
        {
            let domain = [range.upperBound...]
            requestURL = URL(string: "https://\(domain)/.well-known/did.json")!
        }
        else
        {
            throw BlueskyError.invalidDID(did)
        }
        
        let request = URLRequest(url: requestURL)
        let response: DIDDocument = try await self.send(request, authorizationType: .none)
        
        guard let service = response.service?.first(where: { $0.type == "AtprotoPersonalDataServer" }), let pdsURL = URL(string: service.serviceEndpoint) else { throw BlueskyError.personalDataServerNotFound() }
        return pdsURL
    }
    
    func logIn(username: String, password: String, pdsURL: URL) async throws
    {
        let requestURL = pdsURL.appendingPathComponent("/xrpc/com.atproto.server.createSession")
        
        struct Request: Encodable
        {
            var identifier: String
            var password: String
        }
        
        let body = Request(identifier: username, password: password)
        let bodyData = try JSONEncoder().encode(body)
        
        var request = URLRequest(url: requestURL)
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpMethod = "POST"
        request.httpBody = bodyData
        
        do
        {
            let response: UserTokens = try await self.send(request, authorizationType: .none)
            Keychain.shared.blueskyAccessToken = response.accessJwt
            Keychain.shared.blueskyRefreshToken = response.refreshJwt
        }
        catch ~BlueskyError.Code.unauthorized
        {
            throw BlueskyError.incorrectCredentials()
        }
    }
    
    func fetchAccount(did: String, pdsURL: URL) async throws -> Account
    {
        var components = URLComponents(string: "/xrpc/app.bsky.actor.getProfile")!
        components.queryItems = [
            URLQueryItem(name: "actor", value: did),
        ]
        
        let requestURL = components.url(relativeTo: pdsURL)!
        let request = URLRequest(url: requestURL)
        
        let account: Account = try await self.send(request, authorizationType: .user)
        return account
    }
    
    func refreshAccessToken() async throws
    {
        let context = DatabaseManager.shared.persistentContainer.newBackgroundContext()
        let domain = try await context.perform {
            guard let socialWebAccount = DatabaseManager.shared.socialWebAccount(in: context) else { throw BlueskyError.unauthorized() }
            return socialWebAccount.domain
        }
        
        guard let requestURL = URL(string: "https://\(domain)/xrpc/com.atproto.server.refreshSession") else { throw BlueskyError.unknown() }
        
        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        
        let response: UserTokens = try await self.send(request, authorizationType: .refresh)
        Keychain.shared.blueskyAccessToken = response.accessJwt
        Keychain.shared.blueskyRefreshToken = response.refreshJwt
    }
}

private extension BlueskyAPI
{
    func send<ResponseType: Decodable>(_ request: URLRequest, authorizationType: AuthorizationType) async throws -> ResponseType
    {
        let decoder = Foundation.JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        
        while true
        {
            // Must go inside while loop to ensure we update headers if needed.
            var request = request
            
            switch authorizationType
            {
            case .none: break
            case .user:
                guard let accessToken = Keychain.shared.blueskyAccessToken else { throw BlueskyError.unauthorized() }
                request.setValue("Bearer " + accessToken, forHTTPHeaderField: "Authorization")
            case .refresh:
                guard let refreshToken = Keychain.shared.blueskyRefreshToken else { throw BlueskyError.unauthorized() }
                request.setValue("Bearer " + refreshToken, forHTTPHeaderField: "Authorization")
            }
            
            let (data, urlResponse) = try await self.session.data(for: request)
            guard let httpResponse = urlResponse as? HTTPURLResponse else { throw BlueskyError.unknown() }
            
            switch httpResponse.statusCode
            {
            case 200...299:
                if ResponseType.self is EmptyResponse.Type
                {
                    // Skip decoding for empty responses
                    return EmptyResponse() as! ResponseType
                }
                
                let response = try decoder.decode(ResponseType.self, from: data)
                return response
                
            case 400:
                let response = try decoder.decode(ErrorResponse.self, from: data)
                if response.errorName == "ExpiredToken"
                {
                    // For some reason, Bluesky returns some ExpiredToken responses as 400 errors.
                    fallthrough
                }
                
                throw response
                
            case 401:
                switch authorizationType
                {
                case .none:
                    throw BlueskyError.unauthorized()
                    
                case .refresh:
                    self.signOut() // If we get 401 error when refreshing tokens, sign out.
                    throw BlueskyError.unauthorized()
                    
                case .user:
                    try await self.refreshAccessToken()
                    continue // Try again
                }
            
            case 429:
                // Rate Limited
                let rateLimitDelay: TimeInterval
                if let delayString = httpResponse.value(forHTTPHeaderField: "Retry-After"), let delay = TimeInterval(delayString)
                {
                    rateLimitDelay = delay
                }
                else
                {
                    rateLimitDelay = 1.0
                }
                
                guard rateLimitDelay <= 60 else {
                    // Assume request failed
                    Logger.main.error("Bluesky API rate limit exceeded. Reset time too far in future: \(rateLimitDelay) seconds")
                    throw BlueskyError.http(statusCode: 429)
                }
                
                Logger.main.info("Bluesky API rate limit exceeded. Retrying request after delay: \(rateLimitDelay) seconds")
                
                try await Task.sleep(for: .seconds(rateLimitDelay))
                
            default:
                let response = try decoder.decode(ErrorResponse.self, from: data)
                throw response
            }
        }
    }
}

private extension BlueskyAPI
{
    @objc func textFieldDidChange(_ notification: Notification)
    {
        let usernameHasText = !(self.usernameTextField?.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let passwordHasText = !(self.passwordTextField?.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        
        if let signIn = self.signInAction
        {
            signIn.isEnabled = usernameHasText && passwordHasText
        }
    }
}

