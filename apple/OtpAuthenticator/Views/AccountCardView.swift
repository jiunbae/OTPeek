import SwiftUI
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// One compact account row (list form). The OTP code is the emphasized element;
/// issuer/account are secondary; the countdown ring is a quiet cue. Click the
/// row to copy. Designed to sit inside a grouped container (see AccountListView).
struct AccountCardView: View {
    let account: OtpAccount
    @EnvironmentObject var appState: AppState
    @State private var isCopied = false
    @State private var showingEditSheet = false
    @State private var showingDeleteAlert = false
    @State private var hovering = false
    // 행 탭 시 코드 복사 여부(설정에서 끌 수 있음). 기본 ON.
    @AppStorage("autoClipboard") private var autoClipboard = true

    /// Freshly computed code, used for the copy action (read-only).
    private var currentCode: String { appState.code(for: account) ?? "------" }

    private var title: String {
        account.issuerText.isEmpty ? account.accountName : account.issuerText
    }

    var body: some View {
        HStack(spacing: 12) {
            AccountIconView(account: account, size: 34)

            // Identity (secondary)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if account.isFavorite {
                        Image(systemName: "star.fill")
                            .font(.system(size: 9))
                            .foregroundColor(.yellow)
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
            .frame(maxWidth: .infinity, alignment: .leading)

            // Code (hero) + countdown. The whole row copies (see below);
            // on copy the ring swaps to a check so digits are never covered.
            OTPTick(account: account,
                    code: { appState.code(for: account, at: $0) ?? "------" }) { code, remaining, progress in
                let urgent = remaining < 10
                HStack(spacing: 10) {
                    if isCopied {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 22))
                            .foregroundColor(.green)
                            .frame(width: 22, height: 22)
                    } else {
                        CountdownRing(progress: progress, remaining: remaining, urgent: urgent, size: 22)
                    }
                    Text(formatOtpCode(code))
                        .font(.system(.title3, design: .monospaced))
                        .fontWeight(.semibold)
                        .monospacedDigit()
                        .lineLimit(1)
                        .fixedSize()
                        .foregroundColor(isCopied ? .green : (urgent ? .red : .primary))
                }
            }
            .fixedSize()

            // Overflow menu (quiet until hover on macOS)
            Menu {
                Button { showingEditSheet = true } label: { Label("Edit", systemImage: "pencil") }
                Button { appState.toggleFavorite(account) } label: {
                    Label(account.isFavorite ? "Remove from Favorites" : "Add to Favorites",
                          systemImage: account.isFavorite ? "star.slash" : "star")
                }
                Divider()
                Button(role: .destructive) { showingDeleteAlert = true } label: {
                    Label("Delete", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            #if os(macOS)
            .opacity(hovering ? 1 : 0.25)
            #endif
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(rowHighlight)
        )
        .contentShape(Rectangle())
        .onTapGesture { if autoClipboard { copyCode() } }
        .help(autoClipboard ? "Click anywhere to copy the code" : "Tap-to-copy is off (enable in Settings)")
        #if os(macOS)
        .onHover { hovering = $0
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        #endif
        .animation(.easeInOut(duration: 0.15), value: isCopied)
        .animation(.easeInOut(duration: 0.12), value: hovering)
        .sheet(isPresented: $showingEditSheet) {
            EditAccountView(account: account)
                .environmentObject(appState)
        }
        .alert("Delete Account", isPresented: $showingDeleteAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { appState.deleteAccount(account) }
        } message: {
            Text("Are you sure you want to delete \(account.displayName)? This action cannot be undone.")
        }
    }

    private var rowHighlight: Color {
        if isCopied { return Color.green.opacity(0.14) }
        #if os(macOS)
        return hovering ? Color.secondary.opacity(0.10) : .clear
        #else
        return .clear
        #endif
    }

    private func copyCode() {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(currentCode, forType: .string)
        #else
        UIPasteboard.general.string = currentCode
        #endif
        withAnimation { isCopied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation { isCopied = false }
        }
    }
}

// MARK: - Preview

#Preview {
    VStack(spacing: 0) {
        AccountCardView(account: OtpAccount(issuer: "Google", accountName: "user@gmail.com", secretKey: "JBSWY3DPEHPK3PXP", isFavorite: true))
        Divider()
        AccountCardView(account: OtpAccount(issuer: "GitHub", accountName: "octocat", secretKey: "JBSWY3DPEHPK3PXP"))
    }
    .environmentObject(AppState())
    .padding()
    .frame(width: 420)
}
