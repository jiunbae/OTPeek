import SwiftUI
import WidgetKit

struct WidgetSettingsView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var widgetAccounts: [OtpAccount] = []
    #if os(iOS)
    @State private var editMode: EditMode = .inactive
    #endif

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Select accounts to show in widgets. The first account or your favorite will be shown in the quick widget.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }

                Section("Widget Accounts") {
                    if widgetAccounts.isEmpty {
                        Text("No accounts available")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(widgetAccounts) { account in
                            WidgetAccountRow(
                                account: account,
                                onToggleFavorite: {
                                    toggleFavorite(account)
                                }
                            )
                        }
                        .onMove(perform: moveAccounts)
                        .onDelete(perform: deleteFromWidget)
                    }
                }

                Section("Available Accounts") {
                    ForEach(availableAccounts) { account in
                        HStack {
                            InitialCircle(initial: account.initial, color: account.displayColor, size: 32)

                            VStack(alignment: .leading) {
                                Text(account.issuerText.isEmpty ? account.accountName : account.issuerText)
                                    .font(.headline)
                                if !account.issuerText.isEmpty {
                                    Text(account.accountName)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }

                            Spacer()

                            Button {
                                addToWidget(account)
                            } label: {
                                Image(systemName: "plus.circle.fill")
                                    .foregroundColor(.green)
                            }
                        }
                    }
                }

                Section {
                    Button("Refresh Widgets") {
                        WidgetCenter.shared.reloadAllTimelines()
                    }

                    Button("Reset to Default") {
                        resetWidgetOrder()
                    }
                    .foregroundColor(.red)
                }
            }
            .navigationTitle("Widget Settings")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        saveAndDismiss()
                    }
                }

                #if os(iOS)
                ToolbarItem(placement: .topBarLeading) {
                    EditButton()
                }
                #endif
            }
            #if os(iOS)
            .environment(\.editMode, $editMode)
            #endif
            .onAppear {
                loadWidgetAccounts()
            }
        }
        #if os(macOS)
        .frame(minWidth: 400, minHeight: 500)
        #endif
    }

    private var availableAccounts: [OtpAccount] {
        let widgetIds = Set(widgetAccounts.map { $0.id })
        return appState.accounts.filter { !widgetIds.contains($0.id) }
    }

    private func loadWidgetAccounts() {
        // Load accounts with widget order
        widgetAccounts = appState.accounts.sorted { $0.sortOrder < $1.sortOrder }
    }

    private func moveAccounts(from source: IndexSet, to destination: Int) {
        widgetAccounts.move(fromOffsets: source, toOffset: destination)
        updateSortOrder()
    }

    private func deleteFromWidget(at offsets: IndexSet) {
        widgetAccounts.remove(atOffsets: offsets)
        updateSortOrder()
    }

    private func addToWidget(_ account: OtpAccount) {
        widgetAccounts.append(account)
        updateSortOrder()
    }

    private func toggleFavorite(_ account: OtpAccount) {
        if let index = widgetAccounts.firstIndex(where: { $0.id == account.id }) {
            widgetAccounts[index].isFavorite.toggle()
        }
    }

    private func updateSortOrder() {
        for (index, var account) in widgetAccounts.enumerated() {
            account.sortOrder = Int32(index)
            appState.updateAccount(account)
        }
    }

    private func resetWidgetOrder() {
        widgetAccounts = appState.accounts
        for (index, var account) in widgetAccounts.enumerated() {
            account.sortOrder = Int32(index)
            account.isFavorite = false
            appState.updateAccount(account)
        }
    }

    private func saveAndDismiss() {
        updateSortOrder()
        WidgetCenter.shared.reloadAllTimelines()
        dismiss()
    }
}

// MARK: - Widget Account Row

struct WidgetAccountRow: View {
    let account: OtpAccount
    let onToggleFavorite: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            InitialCircle(initial: account.initial, color: account.displayColor, size: 36)

            VStack(alignment: .leading, spacing: 2) {
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
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            Button {
                onToggleFavorite()
            } label: {
                Image(systemName: account.isFavorite ? "star.fill" : "star")
                    .foregroundColor(account.isFavorite ? .yellow : .gray)
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Preview

#Preview {
    WidgetSettingsView()
        .environmentObject(AppState())
}
