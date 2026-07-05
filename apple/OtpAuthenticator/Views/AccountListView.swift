import SwiftUI

struct AccountListView: View {
    @EnvironmentObject var appState: AppState
    var showOnlyFavorites: Bool = false
    var folderId: String? = nil  // nil = all, "uncategorized" = no folder, other = specific folder

    var displayedAccounts: [OtpAccount] {
        var accounts = appState.accounts

        // 폴더 필터링
        if let folderId = folderId {
            if folderId == "uncategorized" {
                accounts = accounts.filter { $0.folderId == nil }
            } else {
                accounts = accounts.filter { $0.folderId == folderId }
            }
        }

        // 즐겨찾기 필터
        if showOnlyFavorites {
            accounts = accounts.filter { $0.isFavorite }
        }

        // 검색 필터
        if !appState.searchText.isEmpty {
            accounts = accounts.filter { account in
                account.issuerText.localizedCaseInsensitiveContains(appState.searchText) ||
                account.accountName.localizedCaseInsensitiveContains(appState.searchText)
            }
        }

        return accounts
    }

    var favorites: [OtpAccount] {
        displayedAccounts.filter { $0.isFavorite }
    }

    var regular: [OtpAccount] {
        displayedAccounts.filter { !$0.isFavorite }
    }

    var body: some View {
        Group {
            if displayedAccounts.isEmpty && appState.accounts.isEmpty {
                EmptyStateView()
            } else if displayedAccounts.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "tray")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)

                    Text("No accounts in this folder")
                        .font(.title3)
                        .foregroundColor(.secondary)

                    Text("Drag accounts here or add new ones")
                        .font(.body)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                accountList
            }
        }
        .searchable(text: $appState.searchText, prompt: "Search accounts")
        .navigationTitle(navigationTitle)
    }

    private var navigationTitle: String {
        if showOnlyFavorites {
            return "Favorites"
        }
        if let folderId = folderId {
            if folderId == "uncategorized" {
                return "Uncategorized"
            }
            if let folder = appState.folders.first(where: { $0.id == folderId }) {
                return folder.name
            }
        }
        return "All Accounts"
    }

    private var accountList: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                // Show favorites section if not already filtering by favorites and has favorites
                if !showOnlyFavorites && !favorites.isEmpty {
                    Section {
                        ForEach(favorites) { account in
                            AccountCardView(account: account)
                                .contextMenu {
                                    accountContextMenu(for: account)
                                }
                        }
                    } header: {
                        SectionHeader(title: "Favorites", icon: "star.fill")
                    }
                }

                // Show regular accounts
                let accountsToShow = showOnlyFavorites ? displayedAccounts : regular
                if !accountsToShow.isEmpty {
                    Section {
                        ForEach(accountsToShow) { account in
                            AccountCardView(account: account)
                                .contextMenu {
                                    accountContextMenu(for: account)
                                }
                        }
                    } header: {
                        if !showOnlyFavorites && !favorites.isEmpty {
                            SectionHeader(title: "Accounts", icon: "list.bullet")
                        }
                    }
                }
            }
            .padding()
        }
    }

    @ViewBuilder
    private func accountContextMenu(for account: OtpAccount) -> some View {
        Button {
            appState.toggleFavorite(account)
        } label: {
            Label(account.isFavorite ? "Remove from Favorites" : "Add to Favorites",
                  systemImage: account.isFavorite ? "star.slash" : "star")
        }

        Divider()

        // Move to folder menu
        Menu {
            Button {
                appState.moveAccount(account, toFolder: nil)
            } label: {
                Label("Uncategorized", systemImage: "tray")
            }

            Divider()

            ForEach(appState.folders) { folder in
                Button {
                    appState.moveAccount(account, toFolder: folder.id)
                } label: {
                    Label(folder.name, systemImage: folder.iconName)
                }
            }
        } label: {
            Label("Move to Folder", systemImage: "folder")
        }

        Divider()

        Button(role: .destructive) {
            appState.deleteAccount(account)
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }
}

// MARK: - Section Header

struct SectionHeader: View {
    let title: String
    let icon: String

    var body: some View {
        HStack {
            Image(systemName: icon)
                .foregroundColor(.secondary)
            Text(title)
                .font(.headline)
                .foregroundColor(.secondary)
            Spacer()
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Empty State

struct EmptyStateView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "lock.shield")
                .font(.system(size: 64))
                .foregroundColor(.secondary)

            Text("No Accounts Yet")
                .font(.title2)
                .fontWeight(.semibold)

            #if os(macOS)
            Text("Add your first account by importing a QR code image or entering manually.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            #else
            Text("Add your first account by scanning a QR code or entering manually.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            #endif

            HStack(spacing: 16) {
                #if os(iOS)
                Button {
                    appState.showingQRScanner = true
                } label: {
                    Label("Scan QR", systemImage: "qrcode.viewfinder")
                }
                .buttonStyle(.bordered)
                #else
                Button {
                    appState.showingQRImageImport = true
                } label: {
                    Label("Import QR Image", systemImage: "qrcode.viewfinder")
                }
                .buttonStyle(.bordered)
                #endif

                Button {
                    appState.showingAddAccount = true
                } label: {
                    Label("Add Account", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Preview

#Preview {
    AccountListView()
        .environmentObject(AppState())
}
