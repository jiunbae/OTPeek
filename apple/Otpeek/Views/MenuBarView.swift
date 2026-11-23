import SwiftUI

#if os(macOS)
struct MenuBarView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var appLock: AppLock
    @State private var copiedAccount: (id: String, code: String)?
    @State private var copyError: String?
    @State private var showingCopyError = false
    @State private var searchText = ""
    @FocusState private var searchIsFocused: Bool

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
        Group {
            if appLock.isLocked {
                // Lock gate: the popover is its own window, so it must honor the
                // app lock too — otherwise codes stay visible after "Lock Now".
                lockedContent
            } else {
                VStack(spacing: 0) {
                    toolbar
                    Divider()
                    content
                }
                .background(MenuBarFocusObserver { focusSearchField() })
                .onAppear { focusSearchField() }
                .onDisappear {
                    copiedAccount = nil
                    copyError = nil
                    showingCopyError = false
                }
                .alert("Couldn’t Copy Code", isPresented: $showingCopyError) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(copyError ?? "")
                }
            }
        }
        .frame(width: 320)
    }

    private var lockedContent: some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.fill")
                .font(.system(size: 30))
                .foregroundColor(.secondary)
            Text("OTPeek is locked")
                .font(.system(size: 13, weight: .medium))
            if let error = appLock.authError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
            }
            Button("Unlock") { appLock.authenticate() }
                .keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .onAppear { appLock.authenticate() }
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
                .focused($searchIsFocused)

            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }

            Divider().frame(height: 16)

            Button { openMainWindow() } label: { Image(systemName: "macwindow") }
                .buttonStyle(.plain).help("Open main window")
            Button { openSettingsWindow() } label: { Image(systemName: "gearshape") }
                .buttonStyle(.plain).help("Settings")
            Button { NSApplication.shared.terminate(nil) } label: { Image(systemName: "power") }
                .buttonStyle(.plain).help("Quit OTPeek")
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
            copiedCode: copiedAccount?.id == account.id ? copiedAccount?.code : nil,
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
        do {
            let code = try appState.copyCodeToClipboard(accountID: account.id)
            copiedAccount = (account.id, code)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                if copiedAccount?.id == account.id, copiedAccount?.code == code {
                    copiedAccount = nil
                }
            }
        } catch {
            copyError = error.localizedDescription
            showingCopyError = true
        }
    }

    private func openMainWindow() {
        DockIconController.shared.showDockIconForWindow()
        if !DockIconController.shared.focusMainWindow() {
            // `openWindow` doesn't resolve inside the detached status-item popover;
            // use the action captured from the live main-window scene instead.
            WindowActions.shared.openMain?()
            DockIconController.shared.focusMainWindowSoon()
        }
    }

    private func openSettingsWindow() {
        // SwiftUI's openSettings action (captured from the main scene) — the
        // legacy showSettingsWindow: selector stopped working on current macOS.
        WindowActions.shared.openSettingsWindow()
    }

    private func focusSearchField() {
        DispatchQueue.main.async {
            searchIsFocused = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            searchIsFocused = true
        }
    }
}

private struct MenuBarFocusObserver: NSViewRepresentable {
    let onWindowBecameKey: () -> Void

    func makeNSView(context: Context) -> MenuBarFocusObserverView {
        let view = MenuBarFocusObserverView()
        view.onWindowBecameKey = onWindowBecameKey
        return view
    }

    func updateNSView(_ nsView: MenuBarFocusObserverView, context: Context) {
        nsView.onWindowBecameKey = onWindowBecameKey
        nsView.attachToWindow()
    }
}

private final class MenuBarFocusObserverView: NSView {
    var onWindowBecameKey: (() -> Void)?

    private weak var observedWindow: NSWindow?
    private var observer: NSObjectProtocol?

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        attachToWindow()
        triggerFocus()
    }

    func attachToWindow() {
        guard observedWindow !== window else { return }
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }

        observedWindow = window
        guard let window else { return }
        observer = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.triggerFocus()
        }
    }

    private func triggerFocus() {
        DispatchQueue.main.async { [weak self] in
            self?.onWindowBecameKey?()
        }
    }
}

// MARK: - Menu Bar Account Row

struct MenuBarAccountRow: View {
    let account: OtpAccount
    let copiedCode: String?
    private var isCopied: Bool { copiedCode != nil }
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
                let urgent = account.type == .totp && remaining < 10
                HStack(spacing: 8) {
                    if isCopied {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 20)).foregroundColor(.green)
                            .frame(width: 22, height: 22)
                    } else if account.type == .totp {
                        CountdownRing(progress: progress, remaining: remaining, urgent: urgent, size: 22)
                    }
                    Text(formatOtpCode(account.type == .hotp ? copiedCode ?? code : code))
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
    let store = AppState()
    MenuBarView()
        .environmentObject(store)
        .environmentObject(store.appLock)
}
#endif
