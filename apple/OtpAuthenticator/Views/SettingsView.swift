import SwiftUI
import WidgetKit
import UniformTypeIdentifiers

#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct SettingsView: View {
    @EnvironmentObject var appState: OtpStore
    @AppStorage("autoClipboard") private var autoClipboard = false
    @AppStorage("showInMenuBar") private var showInMenuBar = true
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @State private var showingWidgetSettings = false
    @State private var showingQRImport = false

    // 백업 비밀번호 입력용
    @State private var showingExportPassword = false
    @State private var showingImportPassword = false
    @State private var backupPassword = ""
    @State private var pendingImportData: Data?

    var body: some View {
        Form {
            Section("General") {
                Toggle("Copy code to clipboard on tap", isOn: $autoClipboard)

                #if os(macOS)
                Toggle("Show in menu bar", isOn: $showInMenuBar)
                Toggle("Launch at login", isOn: $launchAtLogin)
                #endif
            }

            Section("iCloud Sync") {
                Toggle("Sync with iCloud", isOn: Binding(
                    get: { appState.iCloudSyncEnabled },
                    set: { appState.setICloudSync(enabled: $0) }
                ))

                if appState.iCloudSyncEnabled {
                    Button {
                        appState.syncNow()
                    } label: {
                        HStack {
                            Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
                            Spacer()
                            if appState.isSyncing {
                                ProgressView().controlSize(.small)
                            }
                        }
                    }
                    .disabled(appState.isSyncing)

                    LabeledContent("Status", value: appState.lastSyncStatus)
                        .font(.caption)
                }
            }

            Section("Widgets") {
                Button {
                    showingWidgetSettings = true
                } label: {
                    HStack {
                        Label("Widget Settings", systemImage: "square.grid.2x2")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundColor(.secondary)
                    }
                }
                .buttonStyle(.plain)

                Button("Refresh All Widgets") {
                    WidgetCenter.shared.reloadAllTimelines()
                }
            }

            Section("Data") {
                #if os(macOS)
                Button {
                    showingQRImport = true
                } label: {
                    Label("Import from QR Image", systemImage: "qrcode.viewfinder")
                }
                #endif

                Button("Export Encrypted Backup") {
                    backupPassword = ""
                    showingExportPassword = true
                }

                Button("Import Backup") {
                    pickImportFile()
                }
            }

            Section("About") {
                LabeledContent("Version", value: "1.0.0")
                LabeledContent("Accounts", value: "\(appState.accounts.count)")
            }

            #if DEBUG
            Section("Debug") {
                Button("Add Test Account") {
                    let account = OtpAccount(
                        issuer: "Test Service",
                        accountName: "test@example.com",
                        secretKey: "JBSWY3DPEHPK3PXP"
                    )
                    appState.addAccount(account)
                }

                Button("Clear All Accounts", role: .destructive) {
                    for account in appState.accounts {
                        appState.deleteAccount(account)
                    }
                }
            }
            #endif
        }
        .formStyle(.grouped)
        #if os(macOS)
        .frame(width: 400)
        .padding()
        #endif
        .sheet(isPresented: $showingWidgetSettings) {
            WidgetSettingsView()
                .environmentObject(appState)
        }
        #if os(macOS)
        .sheet(isPresented: $showingQRImport) {
            QRImageImportView()
                .environmentObject(appState)
        }
        #endif
        .alert("Backup Password", isPresented: $showingExportPassword) {
            SecureField("Password", text: $backupPassword)
            Button("Cancel", role: .cancel) {}
            Button("Export") { exportBackup() }
        } message: {
            Text("Choose a password to encrypt the backup file.")
        }
        .alert("Backup Password", isPresented: $showingImportPassword) {
            SecureField("Password", text: $backupPassword)
            Button("Cancel", role: .cancel) { pendingImportData = nil }
            Button("Import") { importBackup() }
        } message: {
            Text("Enter the password used to encrypt this backup.")
        }
    }

    // MARK: - Backup export/import (v2 encrypted container)

    private func exportBackup() {
        guard let data = appState.exportBackup(password: backupPassword) else { return }

        #if os(macOS)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "otp_backup.otpvault"
        if panel.runModal() == .OK, let url = panel.url {
            try? data.write(to: url)
        }
        #else
        let activityVC = UIActivityViewController(activityItems: [data], applicationActivities: nil)
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let window = windowScene.windows.first,
           let rootVC = window.rootViewController {
            rootVC.present(activityVC, animated: true)
        }
        #endif
    }

    private func pickImportFile() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url,
           let data = try? Data(contentsOf: url) {
            pendingImportData = data
            backupPassword = ""
            showingImportPassword = true
        }
        #else
        // iOS: document picker integration is left to the host; backup import
        // is primarily driven from the onboarding "Restore" flow.
        #endif
    }

    private func importBackup() {
        guard let data = pendingImportData else { return }
        _ = appState.importBackup(data: data, password: backupPassword, merge: true)
        pendingImportData = nil
    }
}

// MARK: - Preview

#Preview {
    SettingsView()
        .environmentObject(OtpStore())
}
