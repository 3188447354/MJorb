//
//  UIViewController+OpenApp.swift
//  AltStore
//
//  Created by Riley Testut on 3/5/24.
//  Copyright © 2024 Riley Testut. All rights reserved.
//

import UIKit

import AltStoreCore

extension UIViewController
{
    func open(_ installedApp: InstalledApp)
    {
        #if MARKETPLACE

        let marketplaceAppViewController = InstallMarketplaceAppViewController(action: .open(installedApp), isRedownload: false)
        
        let navigationController = UINavigationController(rootViewController: marketplaceAppViewController)
        self.present(navigationController, animated: true)
                
        #else

        UIApplication.shared.open(installedApp.openAppURL) { success in
            guard !success else { return }
            
            let toastView = ToastView(error: OperationError.openAppFailed(name: installedApp.name))
            toastView.show(in: self)
        }

        #endif
    }
}
