import SwiftUI
import WidgetKit
import UniformTypeIdentifiers
import CloudKit
import StoreKit

#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct SettingsView: View {
    @EnvironmentObject var appState: OtpStore
    @EnvironmentObject var appLock: AppLock
    @EnvironmentObject var store: StoreManager
    @AppStorage("autoClipboard") private var autoClipboard = true
    @AppStorage("showInMenuBar") private var showInMenuBar = true
    @AppStorage("hideDockIconWhenNoWindows") private var hideDockIconWhenNoWindows = true
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
    @State private var importPasswordMessage = "Enter the password used to encrypt this backup."
    @State private var backupFeedback: BackupFeedback?
    // iOS: 문서 선택기(.fileImporter) 표시 여부. macOS 는 NSOpenPanel 을 직접 띄운다.
    @State private var showingImportPicker = false
    // 기존 iCloud 볼트를 이 기기로 받아오기(로컬 교체). 볼트가 이미 있어도 쓸 수 있는 진입점.
    @State private var showingICloudRestore = false
    @State private var icloudRestorePassword = ""

    // 내보내기 대상: 파일로 저장할지 / 공유 시트(AirDrop 등)로 보낼지.
    private enum ExportDestination { case save, share }
    @State private var exportDestination: ExportDestination = .save

    private struct BackupFeedback {
        let message: String
        let isError: Bool
    }

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
                Button("Cancel", role: .cancel) { backupPassword = "" }
                Button("Export") { exportBackup() }
                    .disabled(backupPassword.isEmpty)
            } message: {
                Text("Choose a password to encrypt the backup file.")
            }
            .alert("Backup Password", isPresented: $showingImportPassword) {
                SecureField("Password", text: $backupPassword)
                Button("Cancel", role: .cancel) {
                    pendingImportData = nil
                    backupPassword = ""
                    importPasswordMessage = "Enter the password used to encrypt this backup."
                }
                Button("Import") { importBackup() }
                    .disabled(backupPassword.isEmpty)
            } message: {
                Text(importPasswordMessage)
            }
            .alert("Restore from iCloud", isPresented: $showingICloudRestore) {
                SecureField("Master Password", text: $icloudRestorePassword)
                Button("Cancel", role: .cancel) { icloudRestorePassword = "" }
                Button("Restore") {
                    appState.restoreFromICloud(password: icloudRestorePassword)
                    icloudRestorePassword = ""
                }
            } message: {
                Text("Downloads your iCloud vault to this device and replaces the local one, adopting the shared key so sync works across devices. Enter the master password from the device where you set up Sync. Accounts that exist only on this device will be replaced.")
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
                // fileImporter 가 닫히는 같은 런루프에서 alert 를 올리면 SwiftUI 가
                // 표시를 삼켜 "다이얼로그가 안 뜨는" 문제가 생긴다. 파일 선택기가
                // 완전히 사라진 뒤 다음 사이클에 비밀번호 alert 를 띄운다.
                presentImportPasswordAfterDismiss()
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
            Form { supportSection }.formStyle(.grouped)
                .tabItem { Label("Support", systemImage: "heart") }
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
            supportSection
            aboutSection
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        #endif
    }

    // MARK: - Support (tips / remove ads / links)

    @ViewBuilder
    private var supportSection: some View {
        Section {
            // 팁(순수 후원). 아무 기능도 잠그지 않는다.
            if store.showTipThanks {
                Label("Thank you for the tip! ☕️", systemImage: "heart.fill")
                    .foregroundColor(.pink)
            }
            ForEach(store.tipProducts, id: \.id) { product in
                Button {
                    Task { await store.purchase(product) }
                } label: {
                    HStack {
                        settingLabel(tipTitle(for: product.id), tipIcon(for: product.id))
                        Spacer()
                        Text(product.displayPrice).foregroundColor(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .disabled(store.isPurchasing)
            }
        } header: {
            Text("Support OTPeek")
        } footer: {
            Text("OTPeek is free and open source. Tips fund development; they don't unlock features.")
        }

        Section {
            Link(destination: URL(string: "https://jiun.dev/OTPeek/")!) {
                settingLabel("Website", "globe")
            }
            Link(destination: URL(string: "https://github.com/jiunbae/OTPeek")!) {
                settingLabel("Source Code on GitHub", "chevron.left.forwardslash.chevron.right")
            }
            Link(destination: URL(string: "https://github.com/jiunbae/OTPeek/issues")!) {
                settingLabel("Report an Issue", "ladybug")
            }
        } header: {
            Text("Links")
        }
    }

    private func tipTitle(for id: String) -> String {
        switch id {
        case StoreManager.tipIDs[0]: return "Espresso Tip"
        case StoreManager.tipIDs[1]: return "Latte Tip"
        default:                     return "Dessert Tip"
        }
    }

    private func tipIcon(for id: String) -> String {
        switch id {
        case StoreManager.tipIDs[0]: return "cup.and.saucer"
        case StoreManager.tipIDs[1]: return "mug"
        default:                     return "birthday.cake"
        }
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
            Toggle(isOn: $hideDockIconWhenNoWindows) {
                settingLabel("Hide Dock icon when no windows are open", "dock.rectangle",
                             detail: "Keeps OTPeek menu-bar only after closing all app windows.")
            }
            .disabled(!showInMenuBar)
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

                // 다른 기기에서 이미 iCloud 동기화를 켠 경우, 이 기기(로컬 볼트가 이미 있어도)로
                // 원격 볼트를 받아오는 진입점. 원격을 비밀번호로 열어 공유 키를 채택하므로
                // 이후 양방향 동기화가 성립한다.
                Button { showingICloudRestore = true } label: {
                    settingLabel("Restore from iCloud", "icloud.and.arrow.down",
                                 detail: "Pull the vault from another device and replace this one.")
                }
                .buttonStyle(.plain)

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
        if let feedback = backupFeedback {
            Section {
                Label(feedback.message,
                      systemImage: feedback.isError
                          ? "exclamationmark.triangle.fill"
                          : "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(feedback.isError ? Color.red : Color.green)
                    .textSelection(.enabled)
            }
        }

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
                backupFeedback = nil
                showingExportPassword = true
            } label: {
                actionRow("Export Encrypted Backup", "square.and.arrow.up")
            }
            .buttonStyle(.plain)

            Button {
                exportDestination = .share
                backupPassword = ""
                backupFeedback = nil
                showingExportPassword = true
            } label: {
                actionRow("Share Backup (AirDrop…)", "paperplane")
            }
            .buttonStyle(.plain)
        } header: {
            Text("Export")
        } footer: {
            Text("Backups are AES-256 encrypted with a password you choose. Keep it somewhere safe — it can't be recovered. On Linux/macOS the otpeek CLI imports the same file: otpeek import <file> --merge.")
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
        #if DEBUG
        // The demo/screenshot build is unsigned and has no iCloud entitlement, so
        // touching CloudKit would trap (not throw). Skip it in demo mode.
        if ProcessInfo.processInfo.arguments.contains("-otpeekDemo") {
            iCloudAvailable = false
            return
        }
        #endif
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
        let password = backupPassword
        let destination = exportDestination
        backupPassword = ""
        showingExportPassword = false

        // AppKit cannot reliably begin a save/share modal while SwiftUI is still
        // dismissing the password alert. Wait for that modal transition to finish.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            guard let data = appState.exportBackup(password: password) else {
                backupFeedback = BackupFeedback(
                    message: appState.lastError ?? "The encrypted backup could not be created.",
                    isError: true)
                return
            }
            switch destination {
            case .save:  saveBackup(data)
            case .share: shareBackup(data)
            }
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
            backupFeedback = BackupFeedback(
                message: "The temporary backup file could not be written: \(error.localizedDescription)",
                isError: true)
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
        presentPanel(panel) { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try data.write(to: url, options: .atomic)
                backupFeedback = BackupFeedback(
                    message: "Encrypted backup saved as \(url.lastPathComponent).",
                    isError: false)
            } catch {
                backupFeedback = BackupFeedback(
                    message: "The backup file could not be saved: \(error.localizedDescription)",
                    isError: true)
            }
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
        if let view = presentationWindow?.contentView {
            picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
        } else {
            backupFeedback = BackupFeedback(
                message: "No active window is available to present the share sheet.",
                isError: true)
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
        backupFeedback = nil
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        let backupTypes = ["otpvault", "otpbackup"]
            .compactMap { UTType(filenameExtension: $0) }
        panel.allowedContentTypes = backupTypes.isEmpty ? [.data] : backupTypes
        presentPanel(panel) { response in
            guard response == .OK, let url = panel.url else { return }
            let didAccess = url.startAccessingSecurityScopedResource()
            defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
            do {
                pendingImportData = try Data(contentsOf: url)
                backupPassword = ""
                importPasswordMessage = "Enter the password used to encrypt this backup."
                presentImportPasswordAfterDismiss()
            } catch {
                pendingImportData = nil
                backupFeedback = BackupFeedback(
                    message: "The selected backup file could not be read: \(error.localizedDescription)",
                    isError: true)
            }
        }
        #else
        backupFeedback = nil
        showingImportPicker = true
        #endif
    }

    #if os(macOS)
    /// Presents an AppKit file panel asynchronously. A sheet is preferred so the
    /// Settings window remains the modal owner; menu-bar-only mode can fall back
    /// to an app-modal panel when no key/main window is available.
    private func presentPanel(_ panel: NSSavePanel,
                              completion: @escaping (NSApplication.ModalResponse) -> Void) {
        if let window = presentationWindow {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }

    private var presentationWindow: NSWindow? {
        NSApp.keyWindow
            ?? NSApp.mainWindow
            ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeKey })
    }
    #endif

    /// Presents the backup-password prompt on the next runloop. Presenting an
    /// `.alert` synchronously from a file-picker completion collides with the
    /// picker's dismissal and SwiftUI silently drops it — so defer past it.
    private func presentImportPasswordAfterDismiss() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            showingImportPassword = true
        }
    }

    private func importBackup() {
        guard let data = pendingImportData else { return }
        let password = backupPassword
        backupPassword = ""
        showingImportPassword = false

        switch appState.importBackupChecked(data: data, password: password, merge: true) {
        case .success(let count):
            pendingImportData = nil
            importPasswordMessage = "Enter the password used to encrypt this backup."
            backupFeedback = BackupFeedback(
                message: "Imported \(count) account\(count == 1 ? "" : "s") successfully.",
                isError: false)
        case .wrongPassword:
            importPasswordMessage = "Incorrect backup password. Please try again."
            backupFeedback = BackupFeedback(
                message: "The backup password was incorrect.",
                isError: true)
            presentImportPasswordAfterDismiss()
        case .failure(let message):
            importPasswordMessage = message
            backupFeedback = BackupFeedback(message: message, isError: true)
            presentImportPasswordAfterDismiss()
        }
    }
}

// MARK: - Preview

#Preview {
    SettingsView()
        .environmentObject(OtpStore())
}
