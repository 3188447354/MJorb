//
//  NewsCollectionViewCell.swift
//  AltStore
//
//  Created by Riley Testut on 8/29/19.
//  Copyright © 2019 Riley Testut. All rights reserved.
//

import UIKit
import AltStoreCore

class NewsCollectionViewCell: UICollectionViewCell
{
    @IBOutlet var titleLabel: UILabel!
    @IBOutlet var captionLabel: UILabel!
    @IBOutlet var imageView: UIImageView!
    @IBOutlet var contentBackgroundView: UIView!
    
    @IBOutlet var fediverseInteractionsView: FediverseInteractionsView!
    
    override func awakeFromNib()
    {
        super.awakeFromNib()
        
        let descriptor = UIFontDescriptor.preferredFontDescriptor(withTextStyle: .title2).bolded()
        self.titleLabel.font = UIFont(descriptor: descriptor, size: 0.0)
        
        self.contentView.preservesSuperviewLayoutMargins = true
        
        self.contentBackgroundView.layer.cornerRadius = 30
        self.contentBackgroundView.clipsToBounds = true
        
        self.imageView.layer.cornerRadius = 30
        self.imageView.clipsToBounds = true
        
        self.fediverseInteractionsView.layoutMargins = .zero
    }
    
    func configure(with newsItem: NewsItem)
    {
        self.titleLabel.text = newsItem.title
        self.captionLabel.text = newsItem.caption
        self.contentBackgroundView.backgroundColor = newsItem.effectiveTintColor
        
        // Set text color to default iOS text color if tintColor is undefined
        let textColor = newsItem.tintColor != nil ? UIColor.white : UIColor.label
        self.titleLabel.textColor = textColor
        self.captionLabel.textColor = textColor
    }
}
