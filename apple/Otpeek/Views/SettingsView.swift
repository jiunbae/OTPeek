import SwiftUI
import WidgetKit
import UniformTypeIdentifiers
import CloudKit

#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct SettingsView: View {
    @EnvironmentObject var appState: OtpStore
    @EnvironmentObject var appLock: AppLock
    @AppStorage("autoClipboard") private var autoClipboard = true
    @AppStorage("showInMenuBar") private var showInMenuBar = true
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("showFavicons", store: UserDefaults.appGroup) private var showFavicons = true
    @AppStorage(AppLock.enabledKey) private var biometricLockEnabled = false
    @AppStorage(AppLock.timeoutKey) private var autoLockMinutes = 5
    @State private var showingWidgetSettings = false
    @State private var showingQRImport = false

    /// iCloud/CloudKit availability for this build+account. nil = still checking.
    @State private var iCloudAvailable: Bool?

    // 백업 비밀번호 입력용
    @State private var showingExportPassword = false
    @State private var showingImportPassword = false
    @State private var backupPassword = ""
    @State private var pendingImportData: Data?
    // iOS: 문서 선택기(.fileImporter) 표시 여부. macOS 는 NSOpenPanel 을 직접 띄운다.
    @State private var showingImportPicker = false
    // WrongKey(다른 VMK) 복구용 "Reset & Restore from iCloud" 확인 다이얼로그.
    @State private var showingResetConfirm = false

    // 내보내기 대상: 파일로 저장할지 / 공유 시트(AirDrop 등)로 보낼지.
    private enum ExportDestination { case save, share }
    @State private var exportDestination: ExportDestination = .save

    var body: some View {
        content
            .task { await checkICloudAvailability() }
            .sheet(isPresented: $showingWidgetSettings) {
                WidgetSettingsView().environmentObject(appState)
            }
            #if os(macOS)
            .sheet(isPresented: $showingQRImport) {
                QRImageImportView().environmentObject(appState)
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
            .alert("Reset & Restore from iCloud", isPresented: $showingResetConfirm) {
                Button("Cancel", role: .cancel) {}
                Button("Reset", role: .destructive) { appState.resetForRestore() }
            } message: {
                Text("This removes this device's local vault so you can restore it from iCloud with your master password, sharing the same key. Accounts that exist only on this device and haven't synced will be lost. Your iCloud copy is not affected.")
            }
            #if os(iOS)
            .fileImporter(
                isPresented: $showingImportPicker,
                allowedContentTypes: [.data, .item],
                allowsMultipleSelection: false
            ) { result in
                guard case .success(let urls) = result, let url = urls.first else { return }
                let didAccess = url.startAccessingSecurityScopedResource()
                defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
                guard let data = try? Data(contentsOf: url) else { return }
                pendingImportData = data
                backupPassword = ""
                showingImportPassword = true
            }
            #endif
    }

    // MARK: - Platform shell

    @ViewBuilder
    private var content: some View {
        #if os(macOS)
        TabView {
            Form { generalSection }.formStyle(.grouped)
                .tabItem { Label("General", systemImage: "gearshape") }
            Form { securitySection }.formStyle(.grouped)
                .tabItem { Label("Security", systemImage: "lock") }
            Form { syncSection }.formStyle(.grouped)
                .tabItem { Label("Sync", systemImage: "icloud") }
            Form { backupSection }.formStyle(.grouped)
                .tabItem { Label("Backup", systemImage: "externaldrive") }
            Form { aboutSection }.formStyle(.grouped)
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 500, height: 420)
        .scenePadding([.top, .horizontal])
        #else
        Form {
            generalSection
            securitySection
            syncSection
            backupSection
            aboutSection
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        #endif
    }

    // MARK: - Security

    @ViewBuilder
    private var securitySection: some View {
        Section {
            Toggle(isOn: $biometricLockEnabled) {
                settingLabel("Require Touch ID / Face ID", "faceid",
                             detail: "Lock the app; unlock with biometrics or your device password.")
            }
            .tint(.green)
            .onChange(of: biometricLockEnabled) { _, _ in appLock.settingsChanged() }
            .disabled(!AppLock.biometryAvailable())

            if biometricLockEnabled {
                Picker(selection: $autoLockMinutes) {
                    Text("Immediately").tag(0)
                    Text("After 1 minute").tag(1)
                    Text("After 5 minutes").tag(5)
                    Text("After 15 minutes").tag(15)
                    Text("After 1 hour").tag(60)
                } label: {
                    settingLabel("Auto-lock", "clock")
                }

                Button { appLock.lockNow() } label: {
                    actionRow("Lock Now", "lock.fill")
                }
                .buttonStyle(.plain)
            }

            if !AppLock.biometryAvailable() {
                Label("No Touch ID / Face ID or device passcode is set up on this device.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        } header: {
            Text("Security")
        } footer: {
            Text("Codes stay hidden behind the lock screen. This is separate from your vault master password.")
        }
    }

    // MARK: - General

    @ViewBuilder
    private var generalSection: some View {
        Section {
            Toggle(isOn: $autoClipboard) {
                settingLabel("Copy code to clipboard on tap", "doc.on.doc",
                             detail: "Tapping a code also copies it.")
            }
            Toggle(isOn: $showFavicons) {
                settingLabel("Show website icons", "globe",
                             detail: "Fetches service favicons (cached locally).")
            }
            #if os(macOS)
            Toggle(isOn: $showInMenuBar) {
                settingLabel("Show in menu bar", "menubar.arrow.up.rectangle")
            }
            Toggle(isOn: $launchAtLogin) {
                settingLabel("Launch at login", "power")
            }
            #endif
        } header: {
            Text("General")
        }

        Section {
            Button { showingWidgetSettings = true } label: {
                navRow("Widget Settings", "square.grid.2x2")
            }
            .buttonStyle(.plain)

            Button { WidgetCenter.shared.reloadAllTimelines() } label: {
                actionRow("Refresh All Widgets", "arrow.clockwise")
            }
            .buttonStyle(.plain)
        } header: {
            Text("Widgets")
        }
    }

    // MARK: - Sync

    @ViewBuilder
    private var syncSection: some View {
        Section {
            switch iCloudAvailable {
            case nil:
                HStack {
                    settingLabel("Sync with iCloud", "arrow.triangle.2.circlepath")
                    Spacer()
                    ProgressView().controlSize(.small)
                }

            case .some(true):
                Toggle(isOn: Binding(
                    get: { appState.iCloudSyncEnabled },
                    set: { appState.setICloudSync(enabled: $0) }
                )) {
                    settingLabel("Sync with iCloud", "arrow.triangle.2.circlepath",
                                 detail: "Encrypted vault syncs across your devices.")
                }
                .tint(.green)

                if appState.iCloudSyncEnabled {
                    Button { appState.syncNow() } label: {
                        HStack {
                            actionRow("Sync Now", "arrow.triangle.2.circlepath")
                            Spacer()
                            if appState.isSyncing { ProgressView().controlSize(.small) }
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(appState.isSyncing)

                    LabeledContent("Status") {
                        Text(appState.lastSyncStatus)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.trailing)
                    }
                    .font(.caption)

                    Button(role: .destructive) { showingResetConfirm = true } label: {
                        actionRow("Reset & Restore from iCloud", "arrow.triangle.2.circlepath.icloud",
                                  tint: .red)
                    }
                    .buttonStyle(.plain)
                }

            case .some(false):
                Toggle(isOn: .constant(false)) {
                    settingLabel("Sync with iCloud", "arrow.triangle.2.circlepath")
                }
                .tint(.green)
                .disabled(true)

                Label {
                    Text("iCloud isn't available for this app. Sign in to iCloud, or rebuild with the iCloud capability and a CloudKit container enabled.")
                } icon: {
                    Image(systemName: "exclamationmark.icloud").foregroundColor(.orange)
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }
        } header: {
            Text("iCloud Sync")
        } footer: {
            Text("Only encrypted data leaves your device — codes and secrets are never uploaded in the clear.")
        }
    }

    // MARK: - Backup

    @ViewBuilder
    private var backupSection: some View {
        Section {
            #if os(macOS)
            Button { showingQRImport = true } label: {
                actionRow("Import from QR Image", "qrcode.viewfinder")
            }
            .buttonStyle(.plain)
            #endif

            Button { pickImportFile() } label: {
                actionRow("Import Backup File", "square.and.arrow.down")
            }
            .buttonStyle(.plain)
        } header: {
            Text("Import")
        }

        Section {
            Button {
                exportDestination = .save
                backupPassword = ""
                showingExportPassword = true
            } label: {
                actionRow("Export Encrypted Backup", "square.and.arrow.up")
            }
            .buttonStyle(.plain)

            Button {
                exportDestination = .share
                backupPassword = ""
                showingExportPassword = true
            } label: {
                actionRow("Share Backup (AirDrop…)", "paperplane")
            }
            .buttonStyle(.plain)
        } header: {
            Text("Export")
        } footer: {
            Text("Backups are AES-256 encrypted with a password you choose. Keep it somewhere safe — it can't be recovered.")
        }
    }

    // MARK: - About

    @ViewBuilder
    private var aboutSection: some View {
        Section {
            LabeledContent("Version", value: "1.0.0")
            LabeledContent("Accounts", value: "\(appState.accounts.count)")
            LabeledContent("Folders", value: "\(appState.folders.count)")
        } header: {
            Text("About")
        }

        #if DEBUG
        Section {
            Button {
                appState.addAccount(OtpAccount(
                    issuer: "Test Service",
                    accountName: "test@example.com",
                    secretKey: "JBSWY3DPEHPK3PXP"
                ))
            } label: {
                actionRow("Add Test Account", "plus.circle")
            }
            .buttonStyle(.plain)

            Button(role: .destructive) {
                for account in appState.accounts { appState.deleteAccount(account) }
            } label: {
                actionRow("Clear All Accounts", "trash", tint: .red)
            }
            .buttonStyle(.plain)
        } header: {
            Text("Debug")
        }
        #endif
    }

    // MARK: - Row builders (consistent alignment)

    /// A toggle/label row: icon + title, with an optional secondary detail line.
    private func settingLabel(_ title: String, _ icon: String, detail: String? = nil) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(.tint)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                if let detail {
                    Text(detail).font(.caption).foregroundColor(.secondary)
                }
            }
        }
    }

    /// A tappable action row: icon + title, accent-tinted, full width.
    private func actionRow(_ title: String, _ icon: String, tint: Color = .accentColor) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 13)).frame(width: 20)
            Text(title)
            Spacer(minLength: 0)
        }
        .foregroundStyle(tint)
        .contentShape(Rectangle())
    }

    /// A navigation-style row (opens a sheet): title + trailing chevron.
    private func navRow(_ title: String, _ icon: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 13)).foregroundStyle(.tint).frame(width: 20)
            Text(title).foregroundStyle(.primary)
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption).foregroundColor(.secondary)
        }
        .contentShape(Rectangle())
    }

    // MARK: - iCloud availability

    /// Probes CloudKit for this build+account. Reports unavailable (rather than
    /// showing a dead toggle) when the app lacks the iCloud entitlement/container
    /// or the user isn't signed into iCloud.
    private func checkICloudAvailability() async {
        let container = CKContainer(identifier: CloudKitSyncBackend.containerIdentifier)
        do {
            let status = try await container.accountStatus()
            iCloudAvailable = (status == .available)
        } catch {
            iCloudAvailable = false
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
        panel.nameFieldStringValue = "otpeek_backup.otpvault"
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
        showingImportPicker = true
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
