import SwiftUI

#if os(macOS)
struct MenuBarView: View {
    @EnvironmentObject var appState: AppState
    @State private var copiedAccountId: String?
    @State private var searchText = ""

    private var matches: [OtpAccount] {
        guard !searchText.isEmpty else { return appState.accounts }
        return appState.accounts.filter {
            $0.issuerText.localizedCaseInsensitiveContains(searchText) ||
            $0.accountName.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var favorites: [OtpAccount] { matches.filter { $0.isFavorite } }
    private var others: [OtpAccount] { matches.filter { !$0.isFavorite } }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
        }
        .frame(width: 320)
    }

    // MARK: - Compact toolbar (search + actions on one row)

    private var toolbar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundColor(.secondary)

            TextField("Search", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))

            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }

            Divider().frame(height: 16)

            Button { openMainWindow() } label: { Image(systemName: "macwindow") }
                .buttonStyle(.plain).help("Open main window")
            SettingsLink { Image(systemName: "gearshape") }
                .buttonStyle(.plain).help("Settings")
            Button { NSApplication.shared.terminate(nil) } label: { Image(systemName: "power") }
                .buttonStyle(.plain).help("Quit OTP Authenticator")
        }
        .font(.system(size: 13))
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    // MARK: - List

    @ViewBuilder
    private var content: some View {
        if appState.accounts.isEmpty {
            emptyState(icon: "key.slash", text: "No accounts")
        } else if matches.isEmpty {
            emptyState(icon: "magnifyingglass", text: "No results")
        } else {
            ScrollView {
                // Non-lazy VStack: every row renders immediately when the popover
                // opens (a LazyVStack in a self-sizing popover defers layout until
                // an interaction — that was why the list only showed after searching).
                VStack(spacing: 2) {
                    if searchText.isEmpty && !favorites.isEmpty {
                        menuSectionHeader("Favorites", icon: "star.fill")
                        ForEach(favorites) { row(for: $0) }
                        if !others.isEmpty {
                            menuSectionHeader("All Accounts", icon: "list.bullet").padding(.top, 4)
                            ForEach(others) { row(for: $0) }
                        }
                    } else {
                        ForEach(matches) { row(for: $0) }
                    }
                }
                .padding(8)
            }
            .frame(height: min(CGFloat(matches.count) * 46 + 20, 420))
        }
    }

    // MARK: - Helpers

    private func row(for account: OtpAccount) -> some View {
        MenuBarAccountRow(
            account: account,
            isCopied: copiedAccountId == account.id,
            code: { appState.code(for: account, at: $0) ?? "------" }
        ) {
            copyCode(for: account)
        }
    }

    private func menuSectionHeader(_ title: String, icon: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 9))
            Text(title.uppercased()).font(.system(size: 10, weight: .semibold))
            Spacer()
        }
        .foregroundColor(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
    }

    private func emptyState(icon: String, text: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 28)).foregroundColor(.secondary)
            Text(text).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
    }

    private func copyCode(for account: OtpAccount) {
        guard let code = appState.code(for: account) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        copiedAccountId = account.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if copiedAccountId == account.id { copiedAccountId = nil }
        }
    }

    private func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.canBecomeKey && !$0.isMiniaturized }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            NSApp.sendAction(#selector(NSApplication.unhide(_:)), to: nil, from: nil)
        }
    }
}

// MARK: - Menu Bar Account Row

struct MenuBarAccountRow: View {
    let account: OtpAccount
    let isCopied: Bool
    let code: (Date) -> String
    let onCopy: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            AccountIconView(account: account, size: 30)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(account.issuerText.isEmpty ? account.accountName : account.issuerText)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if account.isFavorite {
                        Image(systemName: "star.fill").font(.system(size: 8)).foregroundColor(.yellow)
                    }
                }
                if !account.issuerText.isEmpty {
                    Text(account.accountName)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 8)

            // Live code + countdown (redraws only here, once per second).
            OTPTick(account: account, code: code) { code, remaining, progress in
                let urgent = remaining < 10
                HStack(spacing: 8) {
                    if isCopied {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 20)).foregroundColor(.green)
                            .frame(width: 22, height: 22)
                    } else {
                        CountdownRing(progress: progress, remaining: remaining, urgent: urgent, size: 22)
                    }
                    Text(formatOtpCode(code))
                        .font(.system(size: 15, weight: .semibold, design: .monospaced))
                        .monospacedDigit()
                        .lineLimit(1)
                        .fixedSize()
                        .foregroundColor(isCopied ? .green : (urgent ? .red : .primary))
                }
                .fixedSize()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isCopied ? Color.green.opacity(0.14)
                               : (hovering ? Color.secondary.opacity(0.10) : Color.clear))
        )
        .contentShape(Rectangle())
        .onTapGesture { onCopy() }
        .onHover { hovering in
            self.hovering = hovering
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}

#Preview {
    MenuBarView()
        .environmentObject(AppState())
}
#endif
