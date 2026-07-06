import SwiftUI

/// 외부에서 열린 `.otpvault` 파일을 현재 볼트로 가져오는 시트 (Path C).
/// 볼트가 이미 열려 있는 상태에서만 사용된다(신규 설치는 온보딩 복원 흐름이 담당).
struct ImportVaultView: View {
    @EnvironmentObject var appState: OtpStore
    @EnvironmentObject var incoming: IncomingVaultFile
    @Environment(\.dismiss) private var dismiss

    /// 열린 파일의 원본 데이터.
    let data: Data

    @State private var password = ""
    /// 병합(merge)을 기본값 ON 으로. 끄면 볼트를 통째로 교체한다.
    @State private var merge = true
    @State private var errorMessage: String?
    @State private var importedCount: Int?

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "square.and.arrow.down.on.square")
                .font(.system(size: 44))
                .foregroundColor(.accentColor)

            Text("Import Backup")
                .font(.title2).fontWeight(.semibold)

            if let count = importedCount {
                // 성공 피드백: 가져온 계정 수.
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 36))
                        .foregroundColor(.green)
                    Text("Imported \(count) account\(count == 1 ? "" : "s").")
                        .font(.body)
                        .multilineTextAlignment(.center)
                }
                Button("Done") { finish() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return)
            } else {
                Text("Enter the master password for this backup file to import its accounts.")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)

                SecureField("Master Password", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 300)
                    .onSubmit(runImport)

                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Merge with existing accounts", isOn: $merge)
                    Text(merge
                         ? "Keeps your current accounts and adds/updates from the file. May resurrect accounts you previously deleted."
                         : "Replaces your entire vault with the file's contents. Existing accounts not in the file are removed.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: 300)

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundColor(.red)
                        .multilineTextAlignment(.center)
                }

                HStack(spacing: 16) {
                    Button("Cancel") { finish() }
                        .keyboardShortcut(.escape)
                    Button("Import") { runImport() }
                        .buttonStyle(.borderedProminent)
                        .disabled(password.isEmpty)
                        .keyboardShortcut(.return)
                }
            }
        }
        .padding(32)
        #if os(macOS)
        .frame(width: 400)
        #endif
    }

    private func runImport() {
        guard !password.isEmpty else { return }
        errorMessage = nil
        switch appState.importBackupChecked(data: data, password: password, merge: merge) {
        case .success(let count):
            importedCount = count
        case .wrongPassword:
            // 친절한 오류 + 재시도(시트 유지, 비밀번호만 비움).
            errorMessage = "Incorrect password. Please try again."
            password = ""
        case .failure(let message):
            errorMessage = message
        }
    }

    private func finish() {
        incoming.pendingData = nil
        dismiss()
    }
}

#Preview {
    ImportVaultView(data: Data())
        .environmentObject(OtpStore())
        .environmentObject(IncomingVaultFile.shared)
}
