import SwiftUI
import UniformTypeIdentifiers

/// 첫 실행 / 잠금 해제 / 복원 흐름. 데이터 계층이 코어로 바뀌면서 마스터 비밀번호로
/// 볼트를 생성/열기 하는 진입점이 필요해졌다.
struct OnboardingView: View {
    @EnvironmentObject var store: OtpStore

    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var showingRestore = false
    @State private var restorePassword = ""
    @State private var restoreData: Data?
    @State private var showingRestoreImporter = false

    private enum Mode {
        case unlock      // 볼트 있음, VMK 없음
        case migrate     // 볼트 없음, 레거시 데이터 있음
        case create      // 신규 생성
    }

    private var mode: Mode {
        if store.vaultExists { return .unlock }
        if store.hasLegacyData { return .migrate }
        return .create
    }

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 56))
                .foregroundColor(.accentColor)

            Text(title)
                .font(.title)
                .fontWeight(.bold)

            Text(subtitle)
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            VStack(spacing: 12) {
                SecureField(mode == .unlock ? "Master Password" : "Create Master Password", text: $password)
                    .textFieldStyle(.roundedBorder)

                if mode != .unlock {
                    SecureField("Confirm Password", text: $confirmPassword)
                        .textFieldStyle(.roundedBorder)
                }
            }
            .frame(maxWidth: 320)

            if let error = store.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
            }

            Button(action: submit) {
                Text(primaryButtonTitle)
                    .frame(maxWidth: 320)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!isValid)

            if mode != .unlock {
                Button("Restore from Backup / iCloud") {
                    showingRestore = true
                }
                .buttonStyle(.plain)
                .foregroundColor(.accentColor)
            }
        }
        .padding(40)
        #if os(macOS)
        .frame(width: 460, height: 460)
        #endif
        .sheet(isPresented: $showingRestore) { restoreSheet }
    }

    // MARK: - Copy

    private var title: String {
        switch mode {
        case .unlock: return "Unlock Vault"
        case .migrate: return "Set Master Password"
        case .create: return "Welcome"
        }
    }

    private var subtitle: String {
        switch mode {
        case .unlock:
            return "Enter your master password to unlock your accounts on this device."
        case .migrate:
            return "We found \(store.legacyCount) existing account(s). Create a master password to move them into your new encrypted vault."
        case .create:
            return "Create a master password to protect your encrypted vault. It secures backups and syncing across devices."
        }
    }

    private var primaryButtonTitle: String {
        switch mode {
        case .unlock: return "Unlock"
        case .migrate: return "Create & Migrate"
        case .create: return "Create Vault"
        }
    }

    private var isValid: Bool {
        switch mode {
        case .unlock:
            return password.count >= 4
        case .migrate, .create:
            return password.count >= 8 && password == confirmPassword
        }
    }

    private func submit() {
        store.lastError = nil
        switch mode {
        case .unlock: store.unlock(password: password)
        case .migrate: store.createVaultAndMigrate(password: password)
        case .create: store.createVault(password: password)
        }
    }

    // MARK: - Restore

    private var restoreSheet: some View {
        VStack(spacing: 20) {
            Text("Restore from Backup")
                .font(.title2).fontWeight(.semibold)

            Text("Select a vault/backup file and enter its master password.")
                .font(.callout)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Button {
                showingRestoreImporter = true
            } label: {
                Label(restoreData == nil ? "Choose File…" : "File Selected ✓",
                      systemImage: "doc")
            }

            SecureField("Master Password", text: $restorePassword)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 300)

            HStack(spacing: 16) {
                Button("Cancel") { showingRestore = false }
                Button("Restore") {
                    if let data = restoreData {
                        store.restore(blob: data, password: restorePassword)
                        showingRestore = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(restoreData == nil || restorePassword.isEmpty)
            }
        }
        .padding(32)
        #if os(macOS)
        .frame(width: 380, height: 280)
        #endif
        .fileImporter(
            isPresented: $showingRestoreImporter,
            allowedContentTypes: [.data, .item],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                let didAccess = url.startAccessingSecurityScopedResource()
                defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
                restoreData = try? Data(contentsOf: url)
            }
        }
    }
}

#Preview {
    OnboardingView()
        .environmentObject(OtpStore())
}
