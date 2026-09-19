//
//  JoinPatreonViewController.swift
//  AltStore
//
//  Created by Riley Testut on 5/3/24.
//  Copyright © 2024 Riley Testut. All rights reserved.
//

import Foundation

import AltStoreCore

class JoinPatreonViewController: UIViewController
{
    @Managed
    private(set) var storeApp: StoreApp
    
    var completionHandler: ((Result<Void, Error>) -> Void)?
    
    @IBOutlet private var textLabel: UILabel!
    @IBOutlet private var imageView: UIImageView!
    @IBOutlet private var stackView: UIStackView!
    
    init(storeApp: StoreApp)
    {
        self.storeApp = storeApp
        
        super.init(nibName: nil, bundle: nil)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func viewDidLoad()
    {
        super.viewDidLoad()
        
        self.title = NSLocalizedString("Join Patreon", comment: "")
        self.view.backgroundColor = .systemBackground
        
        self.textLabel.text = String(format: NSLocalizedString("To download %@, join this creator's Patreon by pressing “Join for free” on the next screen.", comment: ""), self.$storeApp.name)
        
        self.imageView.clipsToBounds = true
        self.imageView.layer.cornerRadius = 15
        
        self.navigationController?.isModalInPresentation = true
        
        let cancelButton = UIBarButtonItem(systemItem: .cancel)
        cancelButton.target = self
        cancelButton.action = #selector(JoinPatreonViewController.cancel)
        self.navigationItem.leftBarButtonItem = cancelButton
        
        let continueButton = UIBarButtonItem(title: NSLocalizedString("Continue", comment: ""), style: .done, target: self, action: #selector(JoinPatreonViewController.joinPatreon))
        self.navigationItem.rightBarButtonItem = continueButton
        
        self.navigationController?.navigationBar.tintColor = self.$storeApp.tintColor
        
        if let sheetController = self.navigationController?.sheetPresentationController
        {
            let customDetent = UISheetPresentationController.Detent.custom { [weak self] context in
                guard let self else { return 350 }
                
                // Ensure stack view has correct height.
                self.stackView.layoutIfNeeded()
                
                return self.stackView.bounds.height + 80
            }
            
            sheetController.detents = [customDetent]
        }
    }
}

private extension JoinPatreonViewController
{
    @objc
    func cancel()
    {
        self.completionHandler?(.failure(CancellationError()))
        
        self.dismiss(animated: true)
    }
    
    @objc
    func joinPatreon()
    {
        self.completionHandler?(.success(()))
        
        self.dismiss(animated: true)
    }
}
