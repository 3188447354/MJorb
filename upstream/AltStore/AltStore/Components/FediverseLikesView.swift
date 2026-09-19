//
//  FediverseLikesView.swift
//  AltStore
//
//  Created by Caroline Moore on 1/5/26.
//  Copyright © 2025 Riley Testut. All rights reserved.
//

import SwiftUI
import AltStoreCore

struct FediverseLikesView: View
{
    @ObservedObject
    var federatedItem: FederatedItem
    
    @State
    private var accounts: [MastodonAPI.Account]?
    
    @State
    private var error: Error?
    
    @Environment(\.openURL)
    private var openURL
    
    @Environment(\.dismiss)
    private var dismiss
    
    var body: some View {
        Group {
            if accounts != nil
            {
                listBody
            }
            else
            {
                ProgressView()
                    .progressViewStyle(.circular)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .navigationTitle(Text("Likes"))
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                if #available(iOS 26, *)
                {
                    SwiftUI.Button(role: .close) {
                        dismiss()
                    }
                }
                else
                {
                    SwiftUI.Button {
                        let federatedURL = federatedItem.resolvedBlueskyURL ?? federatedItem.url
                        openURL(federatedURL)
                    } label: {
                        Image(systemName: "globe")
                    }
                    .tint(Color(uiColor: .altPrimary))
                }
            }
            
            ToolbarItem(placement: .confirmationAction) {
                if #available(iOS 26, *)
                {
                    SwiftUI.Button {
                        let federatedURL = federatedItem.resolvedBlueskyURL ?? federatedItem.url
                        openURL(federatedURL)
                    } label: {
                        Image(systemName: "globe")
                    }
                    .buttonStyle(.glassProminent)
                    .tint(Color(uiColor: .altPrimary))
                }
                else
                {
                    SwiftUI.Button("Done") {
                        dismiss()
                    }
                    .tint(Color(uiColor: .altPrimary))
                }
            }
        }
        .task {
            await fetchAccounts()
        }
    }
    
    private var listBody: some View {
        List {
            ForEach(accounts ?? [], id: \.id) { account in
                AccountRow(account: account)
                    .padding(.vertical, 2)
                    .listRowSeparatorTint(.gray.opacity(0.1))
                    .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
            }
        }
        .listStyle(.plain)
        .overlay {
            if let error
            {
                ContentUnavailableView("Could Not Load Likes", systemImage: "heart", description: Text(error.localizedDescription))
            }
            else if let accounts, accounts.isEmpty
            {
                ContentUnavailableView("No Likes Yet", systemImage: "heart")
            }
        }
    }
    
    private func fetchAccounts() async
    {
        do
        {
            var likedBy = try await MastodonAPI.shared.fetchFavorites(tootID: federatedItem.identifier)
            Logger.main.debug("Fetched likes: \(likedBy.map(\.url), privacy: .public)")
            
            // Explicitly decode all descriptions NOW on main thread.
            // Normally we'd do it lazily, but that can cause us to skip a run loop and break UITableView/List in horrible ways.
            for (index, account) in zip(0..., likedBy) where account.uri.host() != BlueskyAPI.bridgyFedFediverseDomain
            {
                var account = account
                
                if
                    let data = account.note.data(using: .utf8),
                    let attributedString = try? NSAttributedString(data: data, options: [
                        .documentType: NSAttributedString.DocumentType.html,
                        .characterEncoding: String.Encoding.utf8.rawValue
                    ], documentAttributes: nil)
                {
                    account.note = attributedString.string
                }
                else
                {
                    account.note = ""
                }
                                
                likedBy[index] = account
            }
            
            self.accounts = await self.updateBlueskyProfiles(for: likedBy)
        }
        catch
        {
            Logger.main.error("Failed to fetch likes for toot. \(error.localizedDescription, privacy: .public)")
            
            self.error = error
            self.accounts = []
        }
    }
    
    private func updateBlueskyProfiles(for accounts: [MastodonAPI.Account]) async -> [MastodonAPI.Account]
    {
        var accounts = accounts
        
        for (index, account) in accounts.enumerated()
        {
            if account.uri.host() == BlueskyAPI.bridgyFedFediverseDomain
            {
                do
                {
                    let did = account.uri.lastPathComponent
                    let blueskyAccount = try await BlueskyAPI.shared.fetchProfile(did: did)
                    
                    accounts[index].followers_count = blueskyAccount.followersCount
                                        
                    let description = blueskyAccount.description ?? ""
                    accounts[index].note = description
                }
                catch
                {
                    Logger.main.error("Failed to fetch Bluesky profile for \(account.username): \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        
        return accounts
    }
}

private struct AccountRow: View
{
    var account: MastodonAPI.Account
    
    var body: some View {
        Link(destination: account.url) {
            HStack(alignment: .top, spacing: 15) {
                ZStack(alignment: .bottomTrailing) {
                    AsyncImage(url: account.avatar_static) { image in
                        image
                            .resizable()
                            .clipShape(Circle())
                    } placeholder: {
                        Circle().fill(Color.gray)
                    }
                    .frame(width: 42, height: 42)
                    
                    // Platform badge
                    if let badge = platformBadge(for: account.url.host) {
                        badge
                            .resizable()
                            .frame(width: 20, height: 20)
                            .clipShape(Circle())
                            .background(Circle().fill(.tertiary))
                            .offset(x: 3, y: 2)
                    }
                }
                
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        let host = account.uri.host()?.lowercased() ?? ""
                        
                        if host == "bsky.brid.gy" || host == "threads.net" || host == "threads.com"
                        {
                            Text("@" + account.username)
                                .foregroundStyle(.primary)
                                .font(.subheadline.bold())
                        }
                        else
                        {
                            Text("@" + account.username)
                                .foregroundStyle(.primary)
                                .font(.subheadline.bold()) +
                            Text("@\(host)")
                                .foregroundStyle(.tertiary)
                                .font(.subheadline.weight(.medium))
                        }
                    }
                    
                    Text("^[\(account.followers_count) follower](inflect: true)")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                    
                    let bio = account.note.trimmingCharacters(in: .whitespacesAndNewlines)
                    Text(bio)
                        .font(.subheadline)
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)
                }
            }
        }
    }
    
    func platformBadge(for host: String?) -> Image?
    {
        guard let host = host?.lowercased() else { return nil }
        
        switch host
        {
        case "bsky.brid.gy": return Image("BlueskyBadge")
        case "threads.net", "threads.com": return Image("ThreadsBadge")
        default: return Image("MastodonBadge")
        }
    }
}

