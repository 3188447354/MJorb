//
//  SafariActivity.swift
//  AltStore
//
//  Created by Caroline Moore on 2/6/26.
//  Copyright © 2026 Riley Testut. All rights reserved.
//

class SafariActivity: UIActivity
{
    private(set) var url: URL?
    
    init(url: URL? = nil)
    {
        self.url = url
    }
    
    override var activityType: UIActivity.ActivityType? {
        return UIActivity.ActivityType("com.altstore.safari-activity")
    }
    
    override var activityTitle: String? {
        return String(localized: "Open in Browser")
    }
    
    override var activityImage: UIImage? {
        return UIImage(systemName: "safari")
    }
    
    override func canPerform(withActivityItems activityItems: [Any]) -> Bool
    {
        guard let activityURL = activityItems.first(where: { $0 is URL }) as? URL else { return false }
        
        if self.url == nil
        {
            // Only set url if we didn't pass in a URL in init()
            self.url = activityURL
        }
        
        return true
    }
    
    override func perform()
    {
        guard let url else {
            activityDidFinish(false)
            return
        }
        
        UIApplication.shared.open(url, options: [:]) { _ in
            self.activityDidFinish(true)
        }
    }
}
