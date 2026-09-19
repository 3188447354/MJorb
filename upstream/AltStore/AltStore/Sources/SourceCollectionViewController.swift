//
//  SourceCollectionViewController.swift
//  AltStore
//
//  Created by Caroline Moore on 12/10/25.
//  Copyright © 2025 Riley Testut. All rights reserved.
//

import UIKit

import AltStoreCore
import Roxas

import Nuke

class SourceCollectionViewController: UICollectionViewController
{
    let sourceCollection: SourceCollection
    
    private lazy var dataSource = self.makeDataSource()
    
    private var fetchSourcesResult: Result<Void, Error>?
    private var _fetchSourcesContext: NSManagedObjectContext?
    
    private var placeholderView: RSTPlaceholderView!
    private var retryButton: UIButton!
    
    init(sourceCollection: SourceCollection)
    {
        self.sourceCollection = sourceCollection
        
        let layout = Self.makeLayout()
        super.init(collectionViewLayout: layout)
    }
    
    required init?(coder: NSCoder)
    {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func viewDidLoad()
    {
        super.viewDidLoad()
        
        self.placeholderView = RSTPlaceholderView(frame: .zero)
        self.placeholderView.activityIndicatorView.style = .medium // Fixes appearing black in dark mode
        
        self.dataSource.proxy = self
        self.collectionView.dataSource = self.dataSource
        self.collectionView.prefetchDataSource = self.dataSource
        
        self.collectionView.backgroundColor = .altBackground
        self.collectionView.alwaysBounceVertical = true
        
        self.collectionView.register(AppBannerCollectionViewCell.self, forCellWithReuseIdentifier: RSTCellContentGenericCellIdentifier)
        self.collectionView.register(UICollectionViewListCell.self, forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader, withReuseIdentifier: UICollectionView.elementKindSectionHeader)
       
        let addAllAction = UIAction(title: NSLocalizedString("Add All", comment: ""), image: UIImage(systemName: "plus"), handler: { [weak self] _ in
            self?.addAllSources()
        })
                        
        let addAllButton = UIBarButtonItem(systemItem: .add, menu: UIMenu(children: [addAllAction]))
        addAllButton.tintColor = UIColor.altPrimary
        
        if #available(iOS 26, *)
        {
            addAllButton.style = .prominent
        }
        
        self.navigationItem.rightBarButtonItem = addAllButton
        
        self.retryButton = UIButton(type: .system)
        self.retryButton.titleLabel?.font = UIFont.preferredFont(forTextStyle: .body)
        self.retryButton.setTitle(NSLocalizedString("Try Again", comment: ""), for: .normal)
        self.retryButton.addTarget(self, action: #selector(SourceCollectionViewController.fetchSources), for: .primaryActionTriggered)
        self.placeholderView.stackView.addArrangedSubview(self.retryButton)
        
        self.navigationItem.largeTitleDisplayMode = .never
        
        self.update()
    }
    
    override func viewIsAppearing(_ animated: Bool)
    {
        super.viewIsAppearing(animated)
        
        if self.fetchSourcesResult == nil
        {
            self.fetchSources()
        }
    }
}

private extension SourceCollectionViewController
{
    func update()
    {
        switch self.fetchSourcesResult
        {
        case nil:
            self.placeholderView.textLabel.isHidden = true
            self.placeholderView.detailTextLabel.isHidden = false
            
            self.placeholderView.detailTextLabel.text = NSLocalizedString("Loading…", comment: "")
            
            self.retryButton.isHidden = true
            self.placeholderView.activityIndicatorView.startAnimating()
            
        case .failure(let error):
            self.placeholderView.textLabel.isHidden = false
            self.placeholderView.detailTextLabel.isHidden = false
            
            self.placeholderView.textLabel.text = NSLocalizedString("Unable to Fetch Apps", comment: "")
            self.placeholderView.detailTextLabel.text = error.localizedDescription
            
            self.retryButton.isHidden = false
            self.placeholderView.activityIndicatorView.stopAnimating()
            
        case .success:
            self.placeholderView.textLabel.isHidden = true
            self.placeholderView.detailTextLabel.isHidden = true
            
            self.retryButton.isHidden = true
            self.placeholderView.activityIndicatorView.stopAnimating()
        }
        
        do
        {
            let fetchRequest = Source.fetchRequest()
            let sources = try DatabaseManager.shared.viewContext.fetch(fetchRequest)
            let sourceIDs = Set(sources.map(\.identifier))
            
            let allSourcesAdded = self.dataSource.items.allSatisfy({ sourceIDs.contains($0.identifier) })
                        
            self.navigationItem.rightBarButtonItem?.isHidden = allSourcesAdded
            
            self.collectionView.reloadData()
        }
        catch
        {
            Logger.main.error("Failed to update sources UI. \(error.localizedDescription, privacy: .public)")
        }
    }
    
    @objc
    func fetchSources()
    {
        let finish: (Result<[Source], Error>) -> Void = { [weak self] result in
            self?.fetchSourcesResult = result.map { _ in () }
            
            DispatchQueue.main.async {
                do
                {
                    let sources = try result.get()
                    print("Fetched sources from URLs:", sources.map { $0.identifier })
                    
                    let sectionUpdate = RSTCellContentChange(type: .update, sectionIndex: 0)
                    self?.dataSource.setItems(sources, with: [sectionUpdate])
                }
                catch
                {
                    print("Error fetching sources from URLs:", error)
                    
                    let sectionUpdate = RSTCellContentChange(type: .update, sectionIndex: 0)
                    self?.dataSource.setItems([], with: [sectionUpdate])
                }
                
                self?.update()
            }
        }
        
        let context = DatabaseManager.shared.persistentContainer.newBackgroundSavingViewContext()
        self._fetchSourcesContext = context
        
        let dispatchGroup = DispatchGroup()
        
        var sourcesByURL = [URL: Source]()
        var fetchError: Error?
        
        for source in self.sourceCollection.sources
        {
            dispatchGroup.enter()
            
            AppManager.shared.fetchSource(sourceURL: source.url, managedObjectContext: context) { result in
                // Serialize access to sourcesByURL.
                context.performAndWait {
                    switch result
                    {
                    case .failure(let error):
                        Logger.main.error("Failed to load source \(source.url.absoluteString): \(error.localizedDescription, privacy: .public)")
                        fetchError = error
                        
                    case .success(let source): sourcesByURL[source.sourceURL] = source
                    }
                    
                    dispatchGroup.leave()
                }
            }
        }
        
        dispatchGroup.notify(queue: .main) {
            let sources = self.sourceCollection.sources.compactMap { sourcesByURL[$0.url] }
            
            if let error = fetchError, sources.isEmpty
            {
                finish(.failure(error))
            }
            else
            {
                finish(.success(sources))
            }
        }
    }
    
    func add(@AsyncManaged _ source: Source)
    {
        Task<Void, Never> {
            do
            {
                // Recommended source, so don't need to include warning message.
                try await AppManager.shared.add(source, message: nil, presentingViewController: self)
                
                self.update()
            }
            catch is CancellationError {}
            catch
            {
                let errorTitle = NSLocalizedString("Unable to Add Source", comment: "")
                await self.presentAlert(title: errorTitle, message: error.localizedDescription)
            }
        }
    }
    
    @objc func addAllSources()
    {
        Task<Void, Never> {
            do
            {
                var sources: [Source] = []
                
                for source in self.dataSource.items
                {
                    let isAlreadyAdded = try await source.isAdded
                    if !isAlreadyAdded
                    {
                        sources.append(source)
                    }
                }
                
                let results = await withCollatingTaskGroup(for: sources) { source in
                    try await AppManager.shared.add(source, message: nil, showConfirmationAlert: false, presentingViewController: self)
                }
                
                let successes = results.successes
                let failures = results.failures
                
                self.update()
                        
                if failures.isEmpty
                {
                    let title = AttributedString(localized: "^[\(successes.count) Source](inflect: true) Added")
                    let message = NSLocalizedString("All sources were added successfully.", comment: "")
                    await self.presentAlert(title: String(title.characters), message: message)
                }
                else if successes.isEmpty
                {
                    let errorCode = results.errors.first?.localizedErrorCode ?? ""
                    var errorsMatch = true
                    
                    for (source, error) in failures
                    {
                        Logger.main.error("Failed to add source at URL: \(source.sourceURL, privacy: .public). Message: \(error.localizedDescription, privacy: .public))")
                        
                        if error.localizedErrorCode != errorCode
                        {
                            errorsMatch = false
                        }
                    }
                    
                    let title = AttributedString(localized: "Unable to add ^[\(failures.count) source](inflect: true)")
                    var message = NSLocalizedString("For more details, check the Error Log in settings.", comment: "")
                    
                    if let error = results.errors.first, errorsMatch
                    {
                        message = error.localizedDescription
                    }
                    
                    await self.presentAlert(title: String(title.characters), message: message)
                }
                else
                {
                    for (source, error) in failures
                    {
                        Logger.main.error("Failed to add source at URL: \(source.sourceURL, privacy: .public). Message: \(error.localizedDescription, privacy: .public))")
                    }
                    
                    let title = NSLocalizedString("Some Sources Added", comment: "")
                    let message = AttributedString(localized: "Successfully added ^[\(successes.count) source](inflect: true), but ^[\(failures.count) source](inflect: true) failed.\n\nFor more details, check the Error Log in settings.")
                    await self.presentAlert(title: title, message: String(message.characters))
                }
            }
            catch
            {
                Logger.main.error("Failed to add all sources in collection “\(self.sourceCollection.localizedTitle)”. \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

private extension SourceCollectionViewController
{
    class func makeLayout() -> UICollectionViewCompositionalLayout
    {
        let itemSize = NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1.0),
            heightDimension: .absolute(AppBannerView.standardHeight)
        )
        let item = NSCollectionLayoutItem(layoutSize: itemSize)
        
        let groupSize = NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1.0),
            heightDimension: .absolute(AppBannerView.standardHeight)
        )
        let group = NSCollectionLayoutGroup.horizontal(layoutSize: groupSize, subitems: [item])
        
        let section = NSCollectionLayoutSection(group: group)
        section.contentInsets = NSDirectionalEdgeInsets(top: 15, leading: 0, bottom: 15, trailing: 0)
        section.interGroupSpacing = 0
        
        let headerSize = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1.0), heightDimension: .estimated(80))
        let sectionHeader = NSCollectionLayoutBoundarySupplementaryItem(layoutSize: headerSize, elementKind: UICollectionView.elementKindSectionHeader, alignment: .top)
        sectionHeader.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 10)
        
        section.boundarySupplementaryItems = [sectionHeader]
        
        let layout = UICollectionViewCompositionalLayout(section: section)
        return layout
    }
    
    func makeDataSource() -> RSTArrayCollectionViewPrefetchingDataSource<Source, UIImage>
    {
        let dataSource = RSTArrayCollectionViewPrefetchingDataSource<Source, UIImage>(items: [])
        dataSource.placeholderView = self.placeholderView
        dataSource.cellConfigurationHandler = { [weak self] (cell, source, indexPath) in
            guard let self else { return }
            
            let cell = cell as! AppBannerCollectionViewCell
            self.configure(cell, with: source)
        }
        
        dataSource.prefetchHandler = { (source, indexPath, completionHandler) in
            guard let iconURL = source.effectiveIconURL else { return nil }
            return RSTAsyncBlockOperation() { (operation) in
                ImagePipeline.shared.loadImage(with: iconURL, progress: nil) { result in
                    guard !operation.isCancelled else { return operation.finish() }
                    
                    switch result
                    {
                    case .success(let response): completionHandler(response.image, nil)
                    case .failure(let error): completionHandler(nil, error)
                    }
                }
            }
        }
        
        dataSource.prefetchCompletionHandler = { (cell, image, indexPath, error) in
            let cell = cell as! AppBannerCollectionViewCell
            cell.bannerView.iconImageView.isIndicatingActivity = false
            
            if let image
            {
                cell.bannerView.iconImageView.image = image
                cell.bannerView.iconImageView.backgroundColor = .white
            }
            else if let error = error
            {
                print("Failed to load source icon: \(error.localizedDescription)")
            }
        }
        
        return dataSource
    }
}

private extension SourceCollectionViewController
{
    func configure(_ cell: AppBannerCollectionViewCell, with source: Source)
    {
        cell.bannerView.style = .source
        
        // External margins
        cell.layoutMargins.top = 0
        cell.layoutMargins.bottom = 0
        cell.contentView.layoutMargins.top = 0
        cell.contentView.layoutMargins.bottom = 10
        cell.layoutMargins.left = self.view.layoutMargins.left
        cell.layoutMargins.right = self.view.layoutMargins.right
        cell.contentView.backgroundColor = .altBackground
        
        cell.bannerView.configure(for: source)
        cell.bannerView.subtitleLabel.numberOfLines = 2
        
        if source.subtitle == nil
        {
            let attributedOutput = AttributedString(localized: "^[\(source.apps.count) App](inflect: true)")
            cell.bannerView.subtitleLabel.text = String(attributedOutput.characters)
        }
        
        cell.bannerView.subtitleLabel.minimumScaleFactor = 1.0
        
        cell.bannerView.iconImageView.image = nil
        cell.bannerView.iconImageView.isIndicatingActivity = true
        
        let config = UIImage.SymbolConfiguration(pointSize: 17.0, weight: .medium)
        let image = UIImage(systemName: "plus", withConfiguration: config)?.withTintColor(.white, renderingMode: .alwaysOriginal)
        
        cell.bannerView.button.icon = image // Ensures image persists when alert is presented
        cell.bannerView.button.setTitle(nil, for: .normal)
        cell.bannerView.button.tintColor = .clear
        cell.bannerView.button.contentHorizontalAlignment = .fill
        cell.bannerView.button.contentVerticalAlignment = .fill
        
        cell.bannerView.button.isHidden = false
        
        if #available(iOS 26, *)
        {
            cell.bannerView.button.prefersGlassAppearance = true
        }
        
        // Internal margins (padding)
        cell.bannerView.layoutMargins.left = 16
        
        let action = UIAction(identifier: .addSource) { [weak self] _ in
            self?.add(source)
        }
        cell.bannerView.button.addAction(action, for: .primaryActionTriggered)
        
        Task<Void, Never>(priority: .userInitiated) {
            do
            {
                let isAdded = try await source.isAdded
                if isAdded
                {
                    cell.bannerView.button.isHidden = true
                }
            }
            catch
            {
                Logger.main.error("Failed to determine if source is added. \(error.localizedDescription, privacy: .public)")
            }
        }
    }
    
    func showSourceDetailView(for source: Source)
    {
        let storyboard = UIStoryboard(name: "Sources", bundle: nil)
        
        let sourceDetailViewController = storyboard.instantiateViewController(identifier: "sourceDetailViewController") { coder in
            SourceDetailViewController(source: source, coder: coder)
        }
        
        self.navigationController?.pushViewController(sourceDetailViewController, animated: true)
    }
}

extension SourceCollectionViewController
{
    override func collectionView(_ collectionView: UICollectionView, viewForSupplementaryElementOfKind kind: String, at indexPath: IndexPath) -> UICollectionReusableView
    {
        let headerView = collectionView.dequeueReusableSupplementaryView(ofKind: kind, withReuseIdentifier: kind, for: indexPath) as! UICollectionViewListCell
        
        var configuration = UIListContentConfiguration.plainHeader()
        
        // Title
        let fontDescriptor = UIFontDescriptor.preferredFontDescriptor(withTextStyle: .largeTitle).bolded()
        configuration.textProperties.font = UIFont(descriptor: fontDescriptor, size: 0.0)
        configuration.textProperties.color = .label
        configuration.textProperties.numberOfLines = 2
        configuration.textProperties.adjustsFontSizeToFitWidth = true
        configuration.textProperties.minimumScaleFactor = 0.7
        configuration.text = self.sourceCollection.localizedTitle
        
        // Description
        configuration.secondaryTextProperties.font = UIFont.preferredFont(forTextStyle: .body)
        configuration.secondaryTextProperties.color = .secondaryLabel
        configuration.secondaryTextProperties.numberOfLines = 0
        configuration.secondaryText = self.sourceCollection.localizedDescription
        
        configuration.textToSecondaryTextVerticalPadding = 6
                
        headerView.contentConfiguration = configuration
        
        return headerView
    }
    
    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath)
    {
        collectionView.deselectItem(at: indexPath, animated: true)
        
        let source = self.dataSource.items[indexPath.item]
        self.showSourceDetailView(for: source)
    }
}

@available(iOS 17, *)
#Preview(traits: .portrait) {
    DatabaseManager.shared.startForPreview()
    
    let sourceCollection = SourceCollection(localizedTitle: "Popular Sources That We Really Really Really Really Love",
                                            localizedDescription: "A collection of popular sources on AltStore. A collection of popular sources on AltStore. A collection of popular sources on AltStore.",
                                            emoji: "🦚",
                                            tintColor: .systemPink, sources: [
        .init(url: URL(string: "https://content-download-egs.distro.on.epicgames.com/iOS/altstore/source.json")!),
        .init(url: URL(string: "https://pal.getutm.app/config.json")!),
        .init(url: URL(string: "https://xitrix.github.io/iTorrent/AltStoreEU.json")!),
        .init(url: URL(string: "https://raw.githubusercontent.com/michael-128/qbitcontrol-releases/main/source.json")!),
        .init(url: URL(string: "https://peopledrop.app/apps.json")!)
    ], )
    
    let sourceCollectionViewController = SourceCollectionViewController(sourceCollection: sourceCollection)
    let navigationController = UINavigationController(rootViewController: sourceCollectionViewController)
    return navigationController
}
