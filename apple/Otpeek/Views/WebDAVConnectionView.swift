import SwiftUI

struct WebDAVConnectionView: View {
    let joining: Bool
    var keepsLocalVault = false
    var savedConfiguration: WebDAVConfiguration? = nil
    let onContinue: (WebDAVConfiguration, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var endpoint = ""
    @State private var username = ""
    @State private var password = ""
    @State private var masterPassword = ""
    @State private var error: String?
    @State private var confirmingJoin = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("HTTPS WebDAV URL", text: $endpoint)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        #endif
                    TextField("WebDAV Username", text: $username)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                    SecureField("WebDAV Password", text: $password)
                    if joining {
                        SecureField("Vault Master Password", text: $masterPassword)
                    }
                } footer: {
                    Text(joining
                         ? "Use the same WebDAV file URL and vault master password as your first device."
                         : "Use the same HTTPS vault file URL on Apple, Windows, and the CLI. A collection URL uses otpeek-vault.otpvault.")
                }
                if let error {
                    Text(error).foregroundStyle(.red)
                }
                if !joining {
                    Text("Connecting WebDAV switches this vault from iCloud to WebDAV.")
                        .foregroundStyle(.secondary)
                } else if keepsLocalVault {
                    Text("Your local accounts will be merged into the shared vault. If the two vaults use different keys, OTPeek keeps an encrypted recovery copy on this device.")
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(keepsLocalVault ? "Join WebDAV Vault" : (joining ? "Restore from WebDAV" : "Connect WebDAV"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(keepsLocalVault ? "Join" : (joining ? "Restore" : "Connect")) {
                        if keepsLocalVault {
                            confirmingJoin = true
                        } else {
                            submit()
                        }
                    }
                        .disabled(endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                  || (joining && masterPassword.isEmpty))
                }
            }
            .alert("Join the shared WebDAV vault?", isPresented: $confirmingJoin) {
                Button("Keep Local Accounts and Join") { submit() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This device will use the shared vault’s master password and sync its merged accounts to the WebDAV server.")
            }
            .onAppear {
                guard let savedConfiguration else { return }
                endpoint = savedConfiguration.url.absoluteString
                username = savedConfiguration.username
                password = savedConfiguration.password
            }
        }
        #if os(macOS)
        .frame(width: 460, height: keepsLocalVault ? 400 : (joining ? 350 : 330))
        #endif
    }

    private func submit() {
        do {
            let configuration = try WebDAVConfiguration(endpoint: endpoint, username: username, password: password)
            onContinue(configuration, masterPassword)
            password = ""
            masterPassword = ""
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
