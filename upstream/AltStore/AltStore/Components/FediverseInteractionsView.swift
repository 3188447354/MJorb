//
//  FediverseInteractionsView.swift
//  AltStore
//
//  Created by Riley Testut on 11/19/25.
//  Copyright © 2025 Riley Testut. All rights reserved.
//

import UIKit
import SwiftUI
import CoreData

import AltStoreCore

import NukeUI

@Observable
class FediverseInteractionsView: UIView
{
    var shareHandler: ((URL) -> UIViewController?)?
    
    weak var presentingViewController: UIViewController?
    
    private var contentView: UIView!
    
    override init(frame: CGRect)
    {
        super.init(frame: frame)
        
        self.update(with: nil)
    }
    
    required init?(coder: NSCoder)
    {
        super.init(coder: coder)
        
        self.update(with: nil)
    }
    
    func configure(with item: FederatedItem, isOpaque: Bool = false)
    {
        self.update(with: item, isOpaque: isOpaque)
    }
}

private extension FediverseInteractionsView
{
    func update(with item: FederatedItem?, isOpaque: Bool = false)
    {
        self.contentView?.removeFromSuperview()
        
        let hostingConfiguration = UIHostingConfiguration {
            if let item, !UserDefaults.shared.fediverseInteractionsDisabled
            {
                FediverseInteractions(federatedItem: item, isOpaque: isOpaque)
                    .environment(self)
                    .tint(Color(uiColor: self.tintColor))
            }
            else
            {
                EmptyView()
            }
        }.margins(.all, .init(self.directionalLayoutMargins))
        
        self.contentView = hostingConfiguration.makeContentView()
        self.addSubview(self.contentView, pinningEdgesWith: .zero)
    }
}

struct FediverseInteractions: View
{
    @ObservedObject
    var federatedItem: FederatedItem
    
    @State
    var isOpaque: Bool = false
    
    @State
    private var accounts: [SocialWebAccount]?
    
    @State
    private var isShowingLikes = false

    @State
    private var isLiked: Bool = false
    
    @State
    private var likesCount: Int = 0
    
    @Namespace
    private var unionNamespace
    
    @Environment(FediverseInteractionsView.self)
    private var fediverseInteractionsView
    
    private let preferredHeight: CGFloat = 30
    private let maximumAvatars: Int = 5
    private var maximumSlots: Int { maximumAvatars + 1 }
    private var avatarDiameter: Double { preferredHeight } // Same height as View itself
    
    private let hapticGenerator = UINotificationFeedbackGenerator()
    
    /* Like Animation */
    
    // Slots[0...4] = visible avatars, slots[5] = invisible staging area
    @State
    private var slots: [SocialWebAccount?] = Array(repeating: nil, count: 6)

    @State
    private var snapshot: AnimationSnapshot?
    
    @State
    private var rollingState: RollingAnimationState = .idle
    
    @State
    private var rollOffset: Double = 0
    
    @State
    private var rollRotation: Double = 0
    
    @State
    private var avatarShiftOffset: Double = 0
    
    @State
    private var rollingAvatarOpacity: Double = 1.0
    
    var body: some View {
        Group {
            HStack {
                // Interactions
                HStack {
                    // Comment + Like buttons
                    socialButtons
                        .zIndex(3) // Above likes + rolling avatar
                    
                    let avatarSpacing = -(avatarDiameter / 2)
                    
                    ZStack {
                        
                        // Avatars
                        SwiftUI.Button {
                            isShowingLikes = true
                        } label: {
                            HStack(spacing: avatarSpacing) {
                                if hasLoadedSlots
                                {
                                    let accounts = Array(visibleSlots.enumerated().prefix(maximumAvatars)) // We may cache more than the visible number
                                    
                                    ForEach(accounts, id: \.element) { index, account in
                                        if let avatarURL = account.avatarURL
                                        {
                                            LazyImage(url: avatarURL) { state in
                                                if let image = state.image
                                                {
                                                    image
                                                        .background(Color.white)
                                                        .clipShape(.circle)
                                                        .overlay(Circle().stroke(.tint, lineWidth: 1))
                                                        .frame(width: preferredHeight, height: preferredHeight)
                                                }
                                                else if let error = state.error
                                                {
                                                    avatarPlaceholder
                                                        .onAppear {
                                                            Logger.main.error("Failed to fetch Fediverse avatar at \(avatarURL.absoluteString, privacy: .public): \(error.localizedDescription, privacy: .public)")
                                                        }
                                                }
                                                else
                                                {
                                                    avatarPlaceholder
                                                }
                                            }
                                            .zIndex(Double(-index))
                                            .offset(x: index < 4 ? avatarShiftOffset : 0) // Don't shift fifth avatar
                                            .opacity(index == 4 ? 1.0 - (avatarShiftOffset / shiftDistance) : 1.0) // Fade it out instead
                                        }
                                    }
                                }
                                else
                                {
                                    let avatarsCount = min(Int(likesCount), maximumAvatars)
                                    ForEach(0..<avatarsCount, id: \.self) { _ in
                                        avatarPlaceholder
                                    }
                                }
                            }
                            .frame(width: avatarContainerWidth, alignment: .leading) //RST Why?
                        }
                        .accessibilityValue(Text("^[\(likesCount) like](inflect: true)"))
                        .accessibilityHint(Text("Shows all likes"))
                        
                        // Rolling avatar
                        if let currentAccount = DatabaseManager.shared.socialWebAccount(), rollingState.isAnimating, let avatarURL = currentAccount.avatarURL
                        {
                            LazyImage(url: avatarURL) { state in
                                if let image = state.image
                                {
                                    image
                                        .background(Color.white)
                                        .clipShape(.circle)
                                        .overlay(Circle().stroke(.tint, lineWidth: 1))
                                        .frame(width: preferredHeight, height: preferredHeight)
                                }
                                else if let error = state.error
                                {
                                    avatarPlaceholder
                                        .onAppear {
                                            Logger.main.error("Failed to fetch Fediverse avatar at \(avatarURL.absoluteString, privacy: .public): \(error.localizedDescription, privacy: .public)")
                                        }
                                }
                                else
                                {
                                    avatarPlaceholder
                                }
                            }
                            .rotationEffect(.degrees(rollRotation))
                            .offset(x: rollOffset)
                            .opacity(rollingAvatarOpacity)
                            .zIndex(2)
                        }
                    }
                }
                
                Spacer()
                
                shareButton
            }
            .frame(height: preferredHeight)
            .frame(minWidth: 100, maxWidth: .infinity)
        }
        .task(priority: .medium) { @MainActor in
            do
            {
                let context = DatabaseManager.shared.persistentContainer.newBackgroundContext()
                
                let _ = try await FederationManager.shared.fetchLikes(for: federatedItem, limit: maximumAvatars * 2, in: context) // Fetch double the amount we need as buffer
                try await context.perform {
                    try context.save()
                }
            }
            catch let error as URLError where error.code == .cancelled
            {
                // Do nothing
            }
            catch
            {
                Logger.main.error("Failed to fetch likes for \(federatedItem.url, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        .sheet(isPresented: $isShowingLikes) {
            NavigationStack {
                FediverseLikesView(federatedItem: federatedItem)
            }
            .presentationDetents([.medium, .large])
        }
        .task(priority: .medium) {
            do
            {
                let context: NSManagedObjectContext
                if let parentContext = federatedItem.managedObjectContext, federatedItem.objectID.isTemporaryID
                {
                    // Use child context since this a temporary context.
                    context = DatabaseManager.shared.persistentContainer.newBackgroundContext(withParent: parentContext)
                }
                else
                {
                    context = DatabaseManager.shared.persistentContainer.newBackgroundContext()
                }
                
                try await FederationManager.shared.updateInteractions(for: [federatedItem], in: context)
            }
            catch
            {
                Logger.main.error("Failed to update interactions for \(federatedItem.url, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        .onAppear {
            isLiked = federatedItem.isLiked
            likesCount = Int(federatedItem.likesCount)
            accounts = federatedItem.likes.compactMap { $0.account }
        }
        .onChange(of: federatedItem.isLiked) { oldValue, newValue in
            isLiked = newValue
        }
        .onChange(of: federatedItem.likesCount) { oldValue, newValue in
            likesCount = Int(newValue)
        }
        .onChange(of: federatedItem._likes) { oldValue, newValue in
            accounts = federatedItem.likes.compactMap { $0.account }
        }
        .onChange(of: accounts) { oldValue, newValue in
            updateSlots()
        }
        .onChange(of: isLiked) { oldValue, newValue in
            updateSlots()
        }
    }
    
    private var socialButtonContent: some View {
        Group {
            // Like button
            SwiftUI.Button {
                like(federatedItem)
            } label: {
                HStack(spacing: 2) {
                    if isLiked
                    {
                        Image(systemName: "heart.fill")
                    }
                    else
                    {
                        Image(systemName: "heart")
                    }
                    
                    if likesCount > 0
                    {
                        Text("\(likesCount)")
                    }
                }
            }
            .accessibilityLabel(isLiked ? Text("Unlike") : Text("Like"))
            .accessibilityHint(isLiked ? Text("Unlikes this item") : Text("Likes this item"))
        }
    }
    
    private var socialButtons: some View {
        Group {
            if #available(iOS 26, *)
            {
                GlassEffectContainer(spacing: 0) {
                    if isOpaque
                    {
                        // On opaque background
                        HStack(spacing: -10) {
                            socialButtonContent
                        }
                        
                        .buttonStyle(.glassProminent) // Prominent glass
                        .glassEffectUnion(id: "button", namespace: unionNamespace)
                    }
                    else
                    {
                        // On translucent background
                        HStack(spacing: -10) {
                            socialButtonContent
                        }
                        .buttonStyle(.glass) // Regular glass
                        .glassEffectUnion(id: "button", namespace: unionNamespace)
                    }
                }
                .font(.subheadline)
            }
            else
            {
                HStack(spacing: 12) {
                    if isOpaque
                    {
                        socialButtonContent
                            .foregroundStyle(Color.white)
                    }
                    else
                    {
                        socialButtonContent
                            .foregroundStyle(.tint)
                    }
                }
                .padding(.trailing, 5)
            }
        }
    }
    
    private var shareButton: some View {
        Group {
            if #available(iOS 26, *)
            {
                if isOpaque
                {
                    // On opaque background
                    SwiftUI.Button {
                        shareItem()
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .font(.subheadline)
                    .buttonStyle(.glassProminent) // Prominent glass
                    .buttonBorderShape(.circle)
                }
                else
                {
                    // On translucent background
                    SwiftUI.Button {
                        shareItem()
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .font(.subheadline)
                    .buttonStyle(.glass) // Regular glass
                    .buttonBorderShape(.circle)
                }
            }
            else
            {
                SwiftUI.Button {
                    shareItem()
                } label: {
                    if isOpaque
                    {
                        Image(systemName: "square.and.arrow.up")
                            .tint(Color.white)
                    }
                    else
                    {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
        }
    }
    
    private var avatarPlaceholder: some View {
        Group {
            if #available(iOS 26, *), !rollingState.isAnimating
            {
                // Only use glass effect when static to avoid visual bugs
                if isOpaque
                {
                    Circle().fill(.tint)
                        .glassEffect(.clear)
                }
                else
                {
                    Circle().fill(.clear)
                        .stroke(.tint, lineWidth: 1)
                        .glassEffect(.regular)
                }
            }
            else
            {
                if isOpaque
                {
                    Circle().fill(.tint)
                        .stroke(.white.opacity(0.4), lineWidth: 1)
                }
                else
                {
                    Circle().fill(.white.opacity(0.8))
                        .stroke(.tint, lineWidth: 1)
                }
            }
        }
    }
}

private extension FediverseInteractions
{
    func like(_ item: FederatedItem)
    {
        let federatedURL = federatedItem.url
        
        guard let presentingViewController = fediverseInteractionsView.presentingViewController else { return }
        
        Task<Void, Never> {
            let wasLiked = self.isLiked
            self.isLiked.toggle()
            
            do
            {
                if self.isLiked
                {
                    rollIn()
                    
                    try await FederationManager.shared.like(item, presentingViewController: presentingViewController)
                    
                    // Ensure animation finishes before finalizing state.
                    try await Task.sleep(for: .seconds(0.5))
                    
                    finalizeRollIn()
                    
                    if let account = DatabaseManager.shared.socialWebAccount()
                    {
                        let tempLike = Like(account: account, item: federatedItem, context: DatabaseManager.shared.viewContext)
                        
                        let updatedLikes = NSOrderedSet(array: [tempLike] + federatedItem.likes.filter { !$0.accountID.contains(account.identifier) })
                        federatedItem._likes = updatedLikes
                    }
                }
                else
                {
                    rollOut()
                    
                    try await FederationManager.shared.unlike(item, presentingViewController: presentingViewController)
                    
                    // Ensure animation finishes before finalizing state.
                    try await Task.sleep(for: .seconds(0.5))
                    
                    resetAnimationState()
                    
                    if let account = DatabaseManager.shared.socialWebAccount()
                    {
                        let updatedLikes = federatedItem.likes.filter { !$0.accountID.contains(account.identifier) }
                        federatedItem._likes = NSOrderedSet(array: updatedLikes)
                    }
                }
                
                self.hapticGenerator.notificationOccurred(.success)
            }
            catch is CancellationError
            {
                // Ignore
                self.isLiked = wasLiked
            }
            catch
            {
                self.isLiked = wasLiked
                Logger.main.error("Failed to favorite status \(federatedURL). Error: \(error.localizedDescription, privacy: .public)")
                self.hapticGenerator.notificationOccurred(.error)
                
                let itemName: String = if item.newsItem != nil {
                    String(localized: "News Alert")
                } else if item.app != nil {
                    String(localized: "App")
                } else if item.appVersion != nil {
                    String(localized: "App Update")
                } else {
                    String(localized: "Item", comment: "A generic piece of content in an app store (e.g. an app, app update, or news alert).")
                }
                
                if wasLiked
                {
                    // Unlike failed
                    rollBackIn()
                    
                    let toastView = ToastView(text: String(localized: "Unable to Unlike \(itemName)"), detailText: error.localizedDescription)
                    toastView.show(in: presentingViewController)
                }
                else
                {
                    // Like failed
                    rollBackOut()
                    
                    let toastView = ToastView(text: String(localized: "Unable to Like \(itemName)"), detailText: error.localizedDescription)
                    toastView.show(in: presentingViewController)
                }
            }
        }
    }
    
    func show(_ account: MastodonAPI.Account)
    {
        UIApplication.shared.open(account.url, options: [:])
    }
    
    func shareItem()
    {
        let shareURL = self.federatedItem.newsItem?.shareURL ?? self.federatedItem.app?.shareURL ?? self.federatedItem.appVersion?.shareURL ?? self.federatedItem.url
        guard let presentingViewController = self.fediverseInteractionsView.shareHandler?(shareURL) else { return }
        
        // Open federated URL when opening in browser, NOT share link.
        let federatedURL = self.federatedItem.resolvedBlueskyURL ?? self.federatedItem.url
        let safariActivity = SafariActivity(url: federatedURL)
        
        let activityViewController = UIActivityViewController(activityItems: [shareURL], applicationActivities: [safariActivity])
        presentingViewController.present(activityViewController, animated: true)
    }
}

private extension FediverseInteractions
{
    enum RollingAnimationState
    {
        case idle
        case rollingIn
        case rollingOut
        
        var isAnimating: Bool {
            self != .idle
        }
    }
    
    // Snapshot for rollback on failure
    struct AnimationSnapshot
    {
        let slots: [SocialWebAccount?]
        let likesCount: Int
    }
    
    
    enum RollDirection {
        case `in`, out
    }
    
    var animationDuration: TimeInterval { 0.4 }
    var rotationFromRollDistance: Double { (rollInDistance / (avatarDiameter / 2)) * (180 / .pi) } // Calculate starting rotation so rolling avatar ends upright
    
    var rollInDistance: Double { 60 }
    
    var avatarSpacing: CGFloat { -avatarDiameter / 2 }
    var shiftDistance: CGFloat { avatarDiameter + avatarSpacing }
    
    var avatarContainerWidth: CGFloat {
        let totalSpacing = CGFloat(maximumAvatars - 1) * avatarSpacing
        return CGFloat(maximumAvatars) * avatarDiameter + totalSpacing
    }
    
    var avatarContainerLeadingEdge: CGFloat {
        return 2 * avatarSpacing
    }
    
    var visibleSlots: [SocialWebAccount] {
        slots.prefix(5).compactMap { $0 }
    }
    
    var hasLoadedSlots: Bool {
        slots.contains { $0 != nil }
    }
    
    var canRollOut: Bool {
        guard let currentAccount = DatabaseManager.shared.socialWebAccount() else { return false }
        return slots[0]?.identifier.contains(currentAccount.identifier) == true
    }
    
    func updateSlots()
    {
        var accounts = self.accounts ?? []
        if !isLiked, let currentAccount = DatabaseManager.shared.socialWebAccount()
        {
            // Mastodon server sometimes caches like for a while even after unliking,
            // so manually filter out ourselves if we haven't liked this post.
            accounts = accounts.filter { !$0.identifier.contains(currentAccount.identifier) } // contains() checks for direct matches AND indirect Bridgy Fed account matches
        }
        
        var newSlots: [SocialWebAccount?] = Array(repeating: nil, count: maximumSlots)
        for (index, account) in zip(0..., accounts).prefix(maximumSlots) {
            newSlots[index] = account
        }
        slots = newSlots
    }
    
    // MARK: - Animation
    
    func rollIn()
    {
        guard !rollingState.isAnimating else { return }
        guard let _ = DatabaseManager.shared.socialWebAccount() else { return }
        
        // Capture state for potential rollback
        snapshot = AnimationSnapshot(slots: slots, likesCount: likesCount)
        performRollAnimation(direction: .in)
    }
    
    func rollOut()
    {
        guard !rollingState.isAnimating, canRollOut else { return }
        
        snapshot = AnimationSnapshot(slots: slots, likesCount: likesCount)
        slots = Array(slots.dropFirst()) + [nil] // Update slot positions for smooth shift
        performRollAnimation(direction: .out)
    }
    
    // Reverses rollIn (failed like)
    func rollBackOut()
    {
        guard let snapshot else {
            resetAnimationState()
            return
        }
        
        likesCount = snapshot.likesCount
        
        performRollAnimation(direction: .out, fromCurrentPosition: true) {
            self.resetAnimationState()
        }
    }
    
    // Reverses rollOut (failed unlike)
    func rollBackIn()
    {
        guard let snapshot else {
            resetAnimationState()
            return
        }
        
        // Restore slot positions, since rollOut modifies before action is validated
        slots = snapshot.slots
        likesCount = snapshot.likesCount
        
        performRollAnimation(direction: .in, fromCurrentPosition: true) {
            self.resetAnimationState()
        }
    }
    
    func finalizeRollIn()
    {
        if let currentAccount = DatabaseManager.shared.socialWebAccount() {
            slots = [currentAccount] + slots.dropLast()
        }
        resetAnimationState()
    }
    
    func resetAnimationState()
    {
        rollingState = .idle
        rollOffset = 0
        rollRotation = 0
        avatarShiftOffset = 0
        rollingAvatarOpacity = 1.0
        snapshot = nil
    }
    
    func performRollAnimation(direction: RollDirection, fromCurrentPosition: Bool = false, completion: (() -> Void)? = nil)
    {
        let inPosition = avatarContainerLeadingEdge
        let outPosition = avatarContainerLeadingEdge - rollInDistance
        
        // Set initial state (unless rolling back)
        if !fromCurrentPosition
        {
            switch direction
            {
            case .in:
                rollOffset = outPosition
                rollRotation = -rotationFromRollDistance
                avatarShiftOffset = 0
                rollingAvatarOpacity = 1.0
            case .out:
                rollOffset = inPosition
                rollRotation = 0
                avatarShiftOffset = shiftDistance
                rollingAvatarOpacity = 1.0
            }
        }
        
        switch direction
        {
        case .in:
            rollingState = .rollingIn
            withAnimation(.spring(response: animationDuration, dampingFraction: 0.5)) {
                rollOffset = inPosition
                rollRotation = 0
                rollingAvatarOpacity = 1.0
            } completion: {
                completion?()
            }
            withAnimation(.spring(duration: animationDuration, bounce: animationDuration)) {
                avatarShiftOffset = shiftDistance
            }
            
        case .out:
            rollingState = .rollingOut
            withAnimation(.spring(response: animationDuration, dampingFraction: 0.5)) {
                rollOffset = outPosition
                rollRotation = -rotationFromRollDistance
                rollingAvatarOpacity = 0
            } completion: {
                completion?()
            }
            withAnimation(.spring(duration: animationDuration, bounce: animationDuration)) {
                avatarShiftOffset = 0
            }
        }
    }
}
