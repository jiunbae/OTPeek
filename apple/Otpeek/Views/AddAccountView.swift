import SwiftUI

struct AddAccountView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var issuer = ""
    @State private var accountName = ""
    @State private var secretKey = ""
    @State private var otpType: OtpType = .totp
    @State private var algorithm: HashAlgorithm = .sha1
    @State private var digits = 6
    @State private var period = 30
    @State private var showingError = false
    @State private var errorMessage = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Account Information") {
                    TextField("Issuer (e.g., Google, GitHub)", text: $issuer)
                    TextField("Account Name (e.g., email)", text: $accountName)
                    SecureField("Secret Key", text: $secretKey)
                        #if os(iOS)
                        .textInputAutocapitalization(.characters)
                        #endif
                        .autocorrectionDisabled()
                }

                Section("Advanced Options") {
                    Picker("Type", selection: $otpType) {
                        Text("TOTP (Time-based)").tag(OtpType.totp)
                        Text("HOTP (Counter-based)").tag(OtpType.hotp)
                    }

                    Picker("Algorithm", selection: $algorithm) {
                        Text("SHA1").tag(HashAlgorithm.sha1)
                        Text("SHA256").tag(HashAlgorithm.sha256)
                        Text("SHA512").tag(HashAlgorithm.sha512)
                    }

                    Picker("Digits", selection: $digits) {
                        Text("6").tag(6)
                        Text("7").tag(7)
                        Text("8").tag(8)
                    }

                    if otpType == .totp {
                        Picker("Period", selection: $period) {
                            Text("30 seconds").tag(30)
                            Text("60 seconds").tag(60)
                        }
                    }
                }

                Section {
                    HStack {
                        Spacer()

                        if !secretKey.isEmpty {
                            VStack(spacing: 8) {
                                Text(previewCode)
                                    .font(.system(.largeTitle, design: .monospaced))
                                    .fontWeight(.bold)

                                Text("Preview")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        } else {
                            Text("Enter secret key to preview")
                                .foregroundColor(.secondary)
                        }

                        Spacer()
                    }
                    .padding(.vertical, 8)
                } header: {
                    Text("Preview")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Add Account")
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
                    Button("Add") {
                        addAccount()
                    }
                    .disabled(!isValid)
                }
            }
            .alert("Error", isPresented: $showingError) {
                Button("OK") {}
            } message: {
                Text(errorMessage)
            }
        }
        #if os(macOS)
        .frame(minWidth: 400, minHeight: 500)
        #endif
    }

    private var isValid: Bool {
        !accountName.isEmpty && !secretKey.isEmpty && isValidSecretKey
    }

    private var isValidSecretKey: Bool {
        let cleaned = secretKey.uppercased().replacingOccurrences(of: " ", with: "")
        let base32Chars = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567=")
        return cleaned.unicodeScalars.allSatisfy { base32Chars.contains($0) }
    }

    private var previewCode: String {
        let account = OtpAccount(
            issuer: issuer,
            accountName: accountName,
            secretKey: secretKey,
            type: otpType,
            algorithm: algorithm,
            digits: digits,
            period: period
        )
        return account.generateCode() ?? "------"
    }

    private func addAccount() {
        guard isValid else {
            errorMessage = "Please fill in all required fields with valid data."
            showingError = true
            return
        }

        let account = OtpAccount(
            issuer: issuer.trimmingCharacters(in: .whitespaces),
            accountName: accountName.trimmingCharacters(in: .whitespaces),
            secretKey: secretKey.uppercased().replacingOccurrences(of: " ", with: ""),
            type: otpType,
            algorithm: algorithm,
            digits: digits,
            period: period
        )

        appState.addAccount(account)
        dismiss()
    }
}

// MARK: - Preview

#Preview {
    AddAccountView()
        .environmentObject(AppState())
}
