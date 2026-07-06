import SwiftUI

struct EditAccountView: View {
    let account: OtpAccount
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var issuer: String
    @State private var accountName: String
    @State private var isFavorite: Bool
    @State private var color: String

    private let colors = [
        "#512BD4", "#E91E63", "#2196F3", "#4CAF50",
        "#FF9800", "#9C27B0", "#00BCD4", "#795548"
    ]

    init(account: OtpAccount) {
        self.account = account
        _issuer = State(initialValue: account.issuerText)
        _accountName = State(initialValue: account.accountName)
        _isFavorite = State(initialValue: account.isFavorite)
        _color = State(initialValue: account.displayColor)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Account Information") {
                    TextField("Issuer", text: $issuer)
                    TextField("Account Name", text: $accountName)
                }

                Section("Options") {
                    Toggle("Favorite", isOn: $isFavorite)

                    HStack {
                        Text("Color")
                        Spacer()
                        HStack(spacing: 8) {
                            ForEach(colors, id: \.self) { colorHex in
                                Circle()
                                    .fill(Color(hex: colorHex) ?? .blue)
                                    .frame(width: 24, height: 24)
                                    .overlay(
                                        Circle()
                                            .stroke(Color.primary, lineWidth: color == colorHex ? 2 : 0)
                                    )
                                    .onTapGesture {
                                        color = colorHex
                                    }
                            }
                        }
                    }
                }

                Section("Details") {
                    LabeledContent("Type", value: account.type.rawValue)
                    LabeledContent("Algorithm", value: account.algorithm.rawValue)
                    LabeledContent("Digits", value: "\(account.digits)")
                    if account.type == .totp {
                        LabeledContent("Period", value: "\(account.period) seconds")
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Edit Account")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveChanges()
                    }
                    .disabled(!isValid)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 400, minHeight: 400)
        #endif
    }

    private var isValid: Bool {
        !accountName.isEmpty
    }

    private func saveChanges() {
        var updated = account
        let trimmedIssuer = issuer.trimmingCharacters(in: .whitespaces)
        updated.issuer = trimmedIssuer.isEmpty ? nil : trimmedIssuer
        updated.accountName = accountName.trimmingCharacters(in: .whitespaces)
        updated.isFavorite = isFavorite
        updated.color = color

        appState.updateAccount(updated)
        dismiss()
    }
}

// MARK: - Preview

#Preview {
    EditAccountView(
        account: OtpAccount(
            issuer: "Google",
            accountName: "user@gmail.com",
            secretKey: "JBSWY3DPEHPK3PXP"
        )
    )
    .environmentObject(AppState())
}
