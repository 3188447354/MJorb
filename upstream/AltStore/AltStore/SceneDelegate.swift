//
//  SceneDelegate.swift
//  AltStore
//
//  Created by Riley Testut on 7/6/20.
//  Copyright © 2020 Riley Testut. All rights reserved.
//

import UIKit
import MarketplaceKit

import AltStoreCore

class SceneDelegate: UIResponder, UIWindowSceneDelegate
{
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions)
    {
        // Use this method to optionally configure and attach the UIWindow `window` to the provided UIWindowScene `scene`.
        // If using a storyboard, the `window` property will automatically be initialized and attached to the scene.
        // This delegate does not imply the connecting scene or session are new (see `application:configurationForConnectingSceneSession` instead).
        guard let _ = (scene as? UIWindowScene) else { return }
        
        if let context = connectionOptions.urlContexts.first
        {
            self.open(context)
        }
        
        if let shortcutItem = connectionOptions.shortcutItem
        {
            self.handle(shortcutItem)
        }
    }

    func sceneWillEnterForeground(_ scene: UIScene)
    {
        // Called as the scene transitions from the background to the foreground.
        // Use this method to undo the changes made on entering the background.
        
        // applicationWillEnterForeground is _not_ called when launching app,
        // whereas sceneWillEnterForeground _is_ called when launching.
        // As a result, DatabaseManager might not be started yet, so just return if it isn't
        // (since all these methods are called separately during app startup).
        guard DatabaseManager.shared.isStarted else { return }
        
        AppManager.shared.update()
        ServerManager.shared.startDiscovering()
        
        PatreonAPI.shared.refreshPatreonAccount()
    }
    
    func sceneDidEnterBackground(_ scene: UIScene)
    {
        // Called as the scene transitions from the foreground to the background.
        // Use this method to save data, release shared resources, and store enough scene-specific state information
        // to restore the scene back to its current state.
        
        guard UIApplication.shared.applicationState == .background else { return }
        
        // Make sure to update AppDelegate.applicationDidEnterBackground() as well.
        
        ServerManager.shared.stopDiscovering()
        
        guard let oneMonthAgo = Calendar.current.date(byAdding: .month, value: -1, to: Date()) else { return }
        
        let midnightOneMonthAgo = Calendar.current.startOfDay(for: oneMonthAgo)
        DatabaseManager.shared.purgeLoggedErrors(before: midnightOneMonthAgo) { result in
            switch result
            {
            case .success: break
            case .failure(let error): print("[ALTLog] Failed to purge logged errors before \(midnightOneMonthAgo).", error)
            }
        }
    }
    
    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>)
    {
        guard let context = URLContexts.first else { return }
        self.open(context)
    }
    
    func windowScene(_ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem, completionHandler: @escaping (Bool) -> Void) 
    {
        self.handle(shortcutItem)
        completionHandler(true)
    }
}

private extension SceneDelegate
{
    func open(_ context: UIOpenURLContext)
    {
        if context.url.isFileURL
        {
            guard context.url.pathExtension.lowercased() == "ipa" else { return }
            
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: AppDelegate.importAppDeepLinkNotification, object: nil, userInfo: [AppDelegate.importAppDeepLinkURLKey: context.url])
            }
        }
        else
        {
            guard let components = URLComponents(url: context.url, resolvingAgainstBaseURL: false) else { return }
            guard let host = components.host?.lowercased() else { return }
            
            switch host
            {
            case "patreon":
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: AppDelegate.openPatreonSettingsDeepLinkNotification, object: nil)
                }
                
            case "appbackupresponse":
                let result: Result<Void, Error>
                
                switch context.url.path.lowercased()
                {
                case "/success": result = .success(())
                case "/failure":
                    let queryItems = components.queryItems?.reduce(into: [String: String]()) { $0[$1.name] = $1.value } ?? [:]
                    guard
                        let errorDomain = queryItems["errorDomain"],
                        let errorCodeString = queryItems["errorCode"], let errorCode = Int(errorCodeString),
                        let errorDescription = queryItems["errorDescription"]
                    else { return }
                    
                    let error = NSError(domain: errorDomain, code: errorCode, userInfo: [NSLocalizedDescriptionKey: errorDescription])
                    result = .failure(error)
                    
                default: return
                }
                
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: AppDelegate.appBackupDidFinish, object: nil, userInfo: [AppDelegate.appBackupResultKey: result])
                }
                
            case "install":
                let queryItems = components.queryItems?.reduce(into: [String: String]()) { $0[$1.name.lowercased()] = $1.value } ?? [:]
                guard let downloadURLString = queryItems["url"], let downloadURL = URL(string: downloadURLString) else { return }
                
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: AppDelegate.importAppDeepLinkNotification, object: nil, userInfo: [AppDelegate.importAppDeepLinkURLKey: downloadURL])
                }
            
            case "source":
                let queryItems = components.queryItems?.reduce(into: [String: String]()) { $0[$1.name.lowercased()] = $1.value } ?? [:]
                guard let sourceURLString = queryItems["url"], let sourceURL = URL(string: sourceURLString) else { return }
                
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: AppDelegate.addSourceDeepLinkNotification, object: nil, userInfo: [AppDelegate.addSourceDeepLinkURLKey: sourceURL])
                }
                
            case "search":
                // Use percent encoded query items to manually replace `+` with spaces before decoding them.
                let queryItems = components.percentEncodedQueryItems?.reduce(into: [String: String]()) { $0[$1.name.lowercased()] = $1.value } ?? [:]
                guard let rawQueryString = queryItems["q"], let queryString = rawQueryString.replacingOccurrences(of: "+", with: " ").removingPercentEncoding else { return }
                                
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: AppDelegate.searchDeepLinkNotification, object: nil, userInfo: [AppDelegate.searchDeepLinkQueryKey: queryString])
                }
                
            case "viewapp":
                let queryItems = components.queryItems?.reduce(into: [String: String]()) { $0[$1.name.lowercased()] = $1.value } ?? [:]
                guard let bundleID = queryItems["bundleid"] else { return }
                                
                DispatchQueue.main.async {
                    let predicate = NSPredicate(format: "%K == %@", #keyPath(StoreApp.bundleIdentifier), bundleID)
                    guard let storeApp = StoreApp.first(satisfying: predicate, in: DatabaseManager.shared.viewContext) else { return }
                    
                    NotificationCenter.default.post(name: AppDelegate.viewAppDeepLinkNotification, object: nil, userInfo: [AppDelegate.viewAppDeepLinkStoreAppKey: storeApp])
                }
                
            case "pal-promo":
                let queryItems = components.queryItems?.reduce(into: [String: String]()) { $0[$1.name.lowercased()] = $1.value } ?? [:]
                guard let session = queryItems["session"], let emailAddress = queryItems["email"] else { return }
                
                self.redeemPALPromo(session: session, emailAddress: emailAddress)
                
            default: break
            }
        }
    }
    
    func handle(_ shortcutItem: UIApplicationShortcutItem)
    {
        guard shortcutItem.type == "io.altstore.FAQAction" else { return }
        
        let faqURL = URL(string: "https://faq.altstore.io")!
        UIApplication.shared.open(faqURL)
    }

    func redeemPALPromo(session: String, emailAddress: String)
    {
        Task<Void, Never> {
            guard var rootViewController = self.window?.rootViewController else { return }
            while let presentedViewController = rootViewController.presentedViewController
            {
                rootViewController = presentedViewController
            }
            
            do
            {
                try await AppMarketplace.shared.redeemPALPromo(session: session, emailAddress: emailAddress)
                
                let alertController = UIAlertController(title: NSLocalizedString("Redeemed PAL Promo", comment: ""), message: NSLocalizedString("You've received 1 month of free access to our “Early Adopter” Patreon tier!\n\nMake sure you have joined our Patreon campaign as a free member and connected your Patreon account in Settings.", comment: ""), preferredStyle: .alert)
                alertController.addAction(UIAlertAction(title: UIAlertAction.ok.title, style: .cancel)) // Cancel style to place it below Connect Account button.
                alertController.addAction(UIAlertAction(title: NSLocalizedString("Connect Patreon Account", comment: ""), style: .default) { _ in
                    NotificationCenter.default.post(name: AppDelegate.openPatreonSettingsDeepLinkNotification, object: nil)
                })
                rootViewController.present(alertController, animated: true)
                
                AppManager.shared.updateAllSources { result in
                    switch result
                    {
                    case .success: break
                    case .failure(let error): Logger.main.error("Failed to update sources after redeeming PAL promo. \(error.localizedDescription, privacy: .public)")
                    }
                }
            }
            catch
            {
                #if DEBUG
                Keychain.shared.stripeEmailAddress = nil
                Keychain.shared.palPromoExpiration = nil
                #endif
                
                let alertController = UIAlertController(title: NSLocalizedString("Unable to Redeem PAL Promo", comment: ""), message: error.localizedDescription, preferredStyle: .alert)
                alertController.addAction(.ok)
                rootViewController.present(alertController, animated: true)
            }
        }
    }
}

extension SceneDelegate: MarketplaceSceneDelegate
{
    func scene(_ scene: UIWindowScene, askedToDisplay option: MarketplaceDisplayOption) 
    {
        switch option
        {
        case .productPage(let appleItemID, _):
            DispatchQueue.main.async {
                let predicate = NSPredicate(format: "%K == %@", #keyPath(StoreApp._marketplaceID), appleItemID.description)
                guard let storeApp = StoreApp.first(satisfying: predicate, in: DatabaseManager.shared.viewContext) else { return }
                
                NotificationCenter.default.post(name: AppDelegate.viewAppDeepLinkNotification, object: nil, userInfo: [AppDelegate.viewAppDeepLinkStoreAppKey: storeApp])
            }
            
        case .searchResults(let query):
            NotificationCenter.default.post(name: AppDelegate.searchDeepLinkNotification, object: nil, userInfo: [AppDelegate.searchDeepLinkQueryKey: query])
            
        case .authentication: break
        @unknown default: break
        }
    }
}
