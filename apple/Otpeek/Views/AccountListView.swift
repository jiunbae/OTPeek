import SwiftUI

struct AccountListView: View {
    @EnvironmentObject var appState: AppState
    var showOnlyFavorites: Bool = false
    var folderId: String? = nil  // nil = all, "uncategorized" = no folder, other = specific folder
    var searchable: Bool = true  // iOS puts search in its own tab, so the other tabs pass false
    var titleOverride: String? = nil
    var groupByFolder: Bool = false  // iOS All tab: one scroll, grouped into folder sections

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
        .modifier(ConditionalSearchable(active: searchable))
        .navigationTitle(titleOverride ?? navigationTitle)
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
        // A native List gives iOS-standard section headers — the system's own sticky
        // material headers, separators and insets — instead of the custom ones a
        // ScrollView needs (which read as "floating"). List is lazy too, so off-screen
        // rows (and their per-row TimelineViews) stay paused.
        ScrollViewReader { proxy in
            List {
                if groupByFolder {
                    if !favorites.isEmpty {
                        Section {
                            listRows(favorites)
                        } header: {
                            sectionHeader("Favorites", icon: "star.fill", count: favorites.count)
                        }
                    }
                    folderSections
                } else {
                    if !showOnlyFavorites && !favorites.isEmpty {
                        Section {
                            listRows(favorites)
                        } header: {
                            sectionHeader("Favorites", icon: "star.fill", count: favorites.count)
                        }
                    }
                    // "All Accounts" header removed — redundant with the tab/nav title.
                    let rest = showOnlyFavorites ? displayedAccounts : regular
                    if !rest.isEmpty {
                        Section { listRows(rest) }
                    }
                }
            }
            .listStyle(.plain)
            #if DEBUG
            // Screenshot harness: `-otpeekScroll` animates the list to a mid account so
            // a captured frame shows the native sticky header pinned mid-scroll.
            .task {
                guard ProcessInfo.processInfo.arguments.contains("-otpeekScroll"),
                      displayedAccounts.count > 3 else { return }
                let target = displayedAccounts[displayedAccounts.count / 2].id
                try? await Task.sleep(nanoseconds: 700_000_000)
                withAnimation(.easeInOut(duration: 0.4)) {
                    proxy.scrollTo(target, anchor: .top)
                }
            }
            #endif
        }
    }

    /// Folder-grouped sections for the iOS All tab: each user folder, then
    /// Uncategorized. List gives the section headers native sticky behavior.
    @ViewBuilder
    private var folderSections: some View {
        ForEach(appState.folders) { folder in
            let items = displayedAccounts.filter { $0.folderId == folder.id && !$0.isFavorite }
            if !items.isEmpty {
                Section {
                    listRows(items)
                } header: {
                    sectionHeader(folder.name, icon: folder.iconName, count: items.count)
                }
            }
        }
        let uncategorized = displayedAccounts.filter { $0.folderId == nil && !$0.isFavorite }
        if !uncategorized.isEmpty {
            Section {
                listRows(uncategorized)
            } header: {
                sectionHeader("Uncategorized", icon: "tray", count: uncategorized.count)
            }
        }
    }

    @ViewBuilder
    private func listRows(_ accounts: [OtpAccount]) -> some View {
        ForEach(accounts) { account in
            AccountCardView(account: account)
                .id(account.id)
                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 12))
                .listRowSeparator(.visible)
                .contextMenu { accountContextMenu(for: account) }
        }
    }

    private func sectionHeader(_ title: String, icon: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
            Text("\(count)")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Capsule().fill(Color.secondary.opacity(0.15)))
            Spacer()
        }
        .foregroundColor(.secondary)
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Opaque background so the pinned (sticky) header occludes rows scrolling
        // under it — custom List headers don't get the system's background for free.
        .background(.background)
        .listRowInsets(EdgeInsets())
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

// MARK: - Conditional Searchable

/// Applies `.searchable` only when requested. On iOS the search field lives in a
/// dedicated tab, so the All/Favorites/Folders lists opt out; macOS keeps it.
private struct ConditionalSearchable: ViewModifier {
    @EnvironmentObject var appState: AppState
    let active: Bool

    func body(content: Content) -> some View {
        if active {
            content.searchable(text: $appState.searchText, prompt: "Search accounts")
        } else {
            content
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
