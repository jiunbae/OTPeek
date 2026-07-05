import SwiftUI

#if os(macOS)
struct MenuBarView: View {
    @EnvironmentObject var appState: AppState
    @State private var copiedAccountId: String?
    @State private var searchText = ""

    private var filteredAccounts: [OtpAccount] {
        if searchText.isEmpty {
            return appState.accounts
        }
        return appState.accounts.filter {
            $0.issuerText.localizedCaseInsensitiveContains(searchText) ||
            $0.accountName.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Search
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Search...", text: $searchText)
                    .textFieldStyle(.plain)

                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(10)
            .background(Color(.controlBackgroundColor))

            Divider()

            // Account List
            if appState.accounts.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "key.slash")
                        .font(.system(size: 32))
                        .foregroundColor(.secondary)

                    Text("No accounts")
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
            } else if filteredAccounts.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 24))
                        .foregroundColor(.secondary)

                    Text("No results")
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 30)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(filteredAccounts) { account in
                            MenuBarAccountRow(
                                account: account,
                                isCopied: copiedAccountId == account.id
                            ) {
                                copyCode(for: account)
                            }
                        }
                    }
                    .padding(8)
                }
                .frame(maxHeight: 400)
            }
        }
        .frame(width: 300)
    }

    private func copyCode(for account: OtpAccount) {
        if let code = appState.code(for: account) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(code, forType: .string)

            copiedAccountId = account.id
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                if copiedAccountId == account.id {
                    copiedAccountId = nil
                }
            }
        }
    }
}

// MARK: - Menu Bar Account Row

struct MenuBarAccountRow: View {
    let account: OtpAccount
    let isCopied: Bool
    let onCopy: () -> Void

    private var currentCode: String {
        account.generateCode() ?? "------"
    }

    private var formattedCode: String {
        let code = currentCode
        let mid = code.count / 2
        return String(code.prefix(mid)) + " " + String(code.suffix(code.count - mid))
    }

    private var remainingSeconds: Int {
        OtpGenerator.getRemainingSeconds(period: account.period)
    }

    private var progress: Double {
        OtpGenerator.getProgress(period: account.period)
    }

    var body: some View {
        HStack(spacing: 10) {
            // Icon
            InitialCircle(
                initial: account.initial,
                color: account.displayColor,
                size: 32
            )

            // Account Info
            VStack(alignment: .leading, spacing: 2) {
                Text(account.issuerText.isEmpty ? account.accountName : account.issuerText)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)

                if !account.issuerText.isEmpty {
                    Text(account.accountName)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            // OTP Code
            VStack(alignment: .trailing, spacing: 3) {
                HStack(spacing: 4) {
                    Text(formattedCode)
                        .font(.system(size: 15, weight: .semibold, design: .monospaced))
                        .foregroundColor(remainingSeconds < 10 ? .red : .primary)

                    if isCopied {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.system(size: 12))
                    }
                }

                // Progress bar
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(Color.secondary.opacity(0.2))
                            .frame(height: 3)

                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(remainingSeconds < 10 ? Color.red : Color.blue)
                            .frame(width: geo.size.width * progress, height: 3)
                    }
                }
                .frame(width: 50, height: 3)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isCopied ? Color.green.opacity(0.1) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            onCopy()
        }
        .onHover { hovering in
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}

#Preview {
    MenuBarView()
        .environmentObject(AppState())
}
#endif
