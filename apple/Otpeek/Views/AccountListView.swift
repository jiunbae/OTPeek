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
        #if os(iOS)
        // Photos-style: the nav bar subtitle live-updates to the folder section
        // currently at the top of the viewport (nothing pins inside the content).
        .modifier(NavSubtitleIfAvailable(text: groupByFolder ? currentSection : nil))
        #endif
    }

    /// Name of the folder section currently under the nav bar (groupByFolder only).
    @State private var currentSection: String?

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
        // A native List, but with the section titles rendered as ordinary rows —
        // Photos-style: only the nav bar stays pinned; folder names scroll away with
        // their content, and the nav subtitle live-updates to the section on screen.
        // List is lazy, so off-screen rows and their TimelineViews stay paused.
        GeometryReader { outer in
        let navBarBottom = outer.frame(in: .global).minY
        ScrollViewReader { proxy in
            List {
                if groupByFolder {
                    ForEach(groupedSections) { section in
                        Section {
                            sectionHeaderRow(section.name, icon: section.icon, count: section.accounts.count)
                                .background(GeometryReader { g in
                                    Color.clear.preference(
                                        key: SectionHeaderPositionsKey.self,
                                        value: [SectionHeaderPosition(index: section.index,
                                                                      name: section.name,
                                                                      minY: g.frame(in: .global).minY)])
                                })
                            listRows(section.accounts)
                        }
                    }
                } else {
                    if !showOnlyFavorites && !favorites.isEmpty {
                        Section {
                            sectionHeaderRow("Favorites", icon: "star.fill", count: favorites.count)
                            listRows(favorites)
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
            // Track which folder section sits under the nav bar and mirror it into
            // the nav subtitle (Photos-style). A header has "passed" once its top
            // crosses the nav bar's bottom edge; while no header is on screen the
            // previous value simply stays — which is exactly right mid-section.
            .onPreferenceChange(SectionHeaderPositionsKey.self) { [names = groupedSections.map(\.name)] headers in
                let threshold = navBarBottom + 24
                let newValue: String?
                if let passed = headers.filter({ $0.minY < threshold }).max(by: { $0.index < $1.index }) {
                    newValue = passed.name
                } else if let firstVisible = headers.min(by: { $0.index < $1.index }) {
                    // Before any header passes the bar we're still in the first
                    // on-screen section — never nil, so the subtitle can't blink
                    // in and out (that re-layout fought the large-title expansion
                    // animation and stuttered the bar at the top).
                    newValue = names.indices.contains(firstVisible.index - 1)
                        ? names[firstVisible.index - 1]
                        : names.first
                } else {
                    newValue = nil // no headers on screen → keep the current value
                }
                // Write only real changes, and without an implicit animation so the
                // update doesn't restart the system's title collapse/expand.
                if let newValue, newValue != currentSection {
                    var t = Transaction()
                    t.disablesAnimations = true
                    withTransaction(t) { currentSection = newValue }
                }
            }
            #if DEBUG
            // Screenshot harness: `-otpeekScroll [index]` animates the list to the
            // given account (default: middle) so a headless capture shows a scrolled
            // frame — used to verify the live nav subtitle.
            .task {
                let args = ProcessInfo.processInfo.arguments
                guard let flag = args.firstIndex(of: "-otpeekScroll"),
                      displayedAccounts.count > 3 else { return }
                var index = displayedAccounts.count / 2
                if flag + 1 < args.count, let n = Int(args[flag + 1]) {
                    index = min(max(n, 0), displayedAccounts.count - 1)
                }
                let target = displayedAccounts[index].id
                try? await Task.sleep(nanoseconds: 700_000_000)
                withAnimation(.easeInOut(duration: 0.4)) {
                    proxy.scrollTo(target, anchor: .top)
                }
                // `-otpeekScrollBounce`: scroll back up after a beat, to exercise the
                // return-to-top transition (large-title re-expansion + subtitle).
                if args.contains("-otpeekScrollBounce"), let first = displayedAccounts.first {
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                    withAnimation(.easeInOut(duration: 0.6)) {
                        proxy.scrollTo(first.id, anchor: .top)
                    }
                }
            }
            #endif
        }
        }
    }

    /// The grouped list's sections in display order: favorites first, then each
    /// user folder, then Uncategorized (favorites appear only in Favorites).
    private var groupedSections: [GroupedSection] {
        var sections: [GroupedSection] = []
        func add(_ id: String, _ name: String, _ icon: String, _ accounts: [OtpAccount]) {
            guard !accounts.isEmpty else { return }
            sections.append(GroupedSection(id: id, index: sections.count,
                                           name: name, icon: icon, accounts: accounts))
        }
        add("favorites", "Favorites", "star.fill", favorites)
        for folder in appState.folders {
            add(folder.id, folder.name, folder.iconName,
                displayedAccounts.filter { $0.folderId == folder.id && !$0.isFavorite })
        }
        add("uncategorized", "Uncategorized", "tray",
            displayedAccounts.filter { $0.folderId == nil && !$0.isFavorite })
        return sections
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

    /// Section title as a regular (non-sticky) row: scrolls with its section like
    /// Photos' year/month titles. No opaque background needed since nothing pins.
    private func sectionHeaderRow(_ title: String, icon: String, count: Int) -> some View {
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
        .padding(.top, 18)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden, edges: .top)
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

// MARK: - Folder-grouped section support

/// One display section of the grouped account list.
private struct GroupedSection: Identifiable {
    let id: String
    let index: Int
    let name: String
    let icon: String
    let accounts: [OtpAccount]
}

/// A section-title row's live position, reported so the nav subtitle can follow
/// the section currently under the nav bar (Photos-style).
private struct SectionHeaderPosition: Equatable, Sendable {
    let index: Int
    let name: String
    let minY: CGFloat
}

private struct SectionHeaderPositionsKey: PreferenceKey {
    static let defaultValue: [SectionHeaderPosition] = []
    static func reduce(value: inout [SectionHeaderPosition], nextValue: () -> [SectionHeaderPosition]) {
        value.append(contentsOf: nextValue())
    }
}

#if os(iOS)
/// Applies the iOS 26 nav-bar subtitle when available; no-op on iOS 17–25.
private struct NavSubtitleIfAvailable: ViewModifier {
    let text: String?

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.navigationSubtitle(text ?? "")
        } else {
            content
        }
    }
}
#endif

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
