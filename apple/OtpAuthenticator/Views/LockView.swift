import SwiftUI

/// Full-screen lock gate shown when biometric lock is enabled and the app is
/// locked. Auto-prompts on appear; offers a manual retry.
struct LockView: View {
    @EnvironmentObject var lock: AppLock

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)

            Text("OTP Authenticator")
                .font(.title2.weight(.semibold))

            Text("Locked")
                .foregroundColor(.secondary)

            if let error = lock.authError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            Button {
                lock.authenticate()
            } label: {
                Label("Unlock", systemImage: "faceid")
                    .frame(minWidth: 140)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .onAppear { lock.authenticate() }
    }
}

#Preview {
    LockView().environmentObject(AppLock())
}
