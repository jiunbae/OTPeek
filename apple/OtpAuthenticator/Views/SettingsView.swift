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

    // 내보내기 대상: 파일로 저장할지 / 공유 시트(AirDrop 등)로 보낼지.
    private enum ExportDestination { case save, share }
    @State private var exportDestination: ExportDestination = .save

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
                    exportDestination = .save
                    backupPassword = ""
                    showingExportPassword = true
                }

                Button {
                    exportDestination = .share
                    backupPassword = ""
                    showingExportPassword = true
                } label: {
                    Label("Share Backup (AirDrop…)", systemImage: "square.and.arrow.up")
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
        switch exportDestination {
        case .save:  saveBackup(data)
        case .share: shareBackup(data)
        }
    }

    /// 내보낸 컨테이너를 임시 디렉터리에 이름 있는 `.otpvault` 파일로 쓴다.
    /// 공유 시트/AirDrop 은 원시 Data 보다 파일 URL 일 때 확장자·파일명이 유지된다.
    private func writeTempBackup(_ data: Data) -> URL? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("OTP Backup.otpvault")
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    private func saveBackup(_ data: Data) {
        #if os(macOS)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "otp_backup.otpvault"
        if let type = UTType(filenameExtension: "otpvault") {
            panel.allowedContentTypes = [type]
        }
        if panel.runModal() == .OK, let url = panel.url {
            try? data.write(to: url)
        }
        #else
        // iOS 에는 저장 패널이 없다: 공유 시트의 "파일에 저장"으로 저장한다.
        shareBackup(data)
        #endif
    }

    private func shareBackup(_ data: Data) {
        guard let url = writeTempBackup(data) else { return }
        #if os(macOS)
        let picker = NSSharingServicePicker(items: [url])
        if let view = NSApp.keyWindow?.contentView {
            picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
        }
        #else
        let activityVC = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let window = windowScene.windows.first,
           let rootVC = window.rootViewController {
            // iPad: 팝오버 앵커가 없으면 크래시하므로 화면 중앙에 앵커.
            activityVC.popoverPresentationController?.sourceView = rootVC.view
            activityVC.popoverPresentationController?.sourceRect = CGRect(
                x: rootVC.view.bounds.midX, y: rootVC.view.bounds.midY, width: 0, height: 0)
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
