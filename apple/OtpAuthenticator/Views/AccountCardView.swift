import SwiftUI
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

struct AccountCardView: View {
    let account: OtpAccount
    @EnvironmentObject var appState: AppState
    @State private var isCopied = false
    @State private var showingEditSheet = false
    @State private var showingDeleteAlert = false

    private var currentCode: String {
        appState.code(for: account) ?? "------"
    }

    private var formattedCode: String {
        let code = currentCode
        let mid = code.count / 2
        return String(code.prefix(mid)) + " " + String(code.suffix(code.count - mid))
    }

    private var progress: Double {
        OtpGenerator.getProgress(period: account.period)
    }

    private var remainingSeconds: Int {
        OtpGenerator.getRemainingSeconds(period: account.period)
    }

    var body: some View {
        HStack(spacing: 16) {
            // Initial Circle
            InitialCircle(
                initial: account.initial,
                color: account.displayColor,
                size: 48
            )

            // Account Info
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(account.issuerText.isEmpty ? account.accountName : account.issuerText)
                        .font(.headline)

                    if account.isFavorite {
                        Image(systemName: "star.fill")
                            .foregroundColor(.yellow)
                            .font(.caption)
                    }
                }

                if !account.issuerText.isEmpty {
                    Text(account.accountName)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            // OTP Code (클릭하여 복사)
            Button {
                copyCode()
            } label: {
                VStack(alignment: .trailing, spacing: 6) {
                    HStack(spacing: 6) {
                        Text(formattedCode)
                            .font(.system(.title2, design: .monospaced))
                            .fontWeight(.bold)
                            .foregroundColor(remainingSeconds < 10 ? .red : .primary)

                        // 체크 아이콘 공간 미리 확보
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.title3)
                            .opacity(isCopied ? 1 : 0)
                    }

                    HStack(spacing: 8) {
                        Text("\(remainingSeconds)s")
                            .font(.caption)
                            .foregroundColor(remainingSeconds < 10 ? .red : .secondary)

                        ProgressView(value: progress)
                            .progressViewStyle(.linear)
                            .tint(remainingSeconds < 10 ? .red : .blue)
                            .frame(width: 60)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isCopied ? Color.green.opacity(0.15) : Color.secondary.opacity(0.08))
                )
            }
            .buttonStyle(.plain)
            #if os(macOS)
            .onHover { hovering in
                if hovering {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }
            #endif
            .animation(.easeInOut(duration: 0.2), value: isCopied)

            // Menu (더보기)
            Menu {
                Button {
                    showingEditSheet = true
                } label: {
                    Label("Edit", systemImage: "pencil")
                }

                Button {
                    appState.toggleFavorite(account)
                } label: {
                    Label(
                        account.isFavorite ? "Remove from Favorites" : "Add to Favorites",
                        systemImage: account.isFavorite ? "star.slash" : "star"
                    )
                }

                Divider()

                Button(role: .destructive) {
                    showingDeleteAlert = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundColor(.secondary)
                    .font(.title3)
            }
            .buttonStyle(.borderless)
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.cardBackground)
                .shadow(color: .black.opacity(0.1), radius: 4, x: 0, y: 2)
        )
        .sheet(isPresented: $showingEditSheet) {
            EditAccountView(account: account)
                .environmentObject(appState)
        }
        .alert("Delete Account", isPresented: $showingDeleteAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                appState.deleteAccount(account)
            }
        } message: {
            Text("Are you sure you want to delete \(account.displayName)? This action cannot be undone.")
        }
    }

    private func copyCode() {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(currentCode, forType: .string)
        #else
        UIPasteboard.general.string = currentCode
        #endif

        withAnimation {
            isCopied = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation {
                isCopied = false
            }
        }
    }
}

// MARK: - Preview

#Preview {
    AccountCardView(
        account: OtpAccount(
            issuer: "Google",
            accountName: "user@gmail.com",
            secretKey: "JBSWY3DPEHPK3PXP"
        )
    )
    .environmentObject(AppState())
    .padding()
}
