import Foundation
import Combine

/// 기존 뷰들이 `AppState` 라는 이름의 EnvironmentObject 를 사용하므로 alias 로 연결.
public typealias AppState = OtpStore

/// 앱 전역 데이터 저장소. Rust 코어의 `OtpClient` 를 감싸고, 모든 변경(mutation)은
/// 코어를 통해 볼트에 즉시 저장한 뒤 목록을 새로고침하고 위젯에 알림을 보낸다.
///
/// - 볼트 잠금 해제: Keychain 의 VMK 로 `openWithKey` (비밀번호 불필요)
/// - VMK 없음/볼트 없음: 온보딩(비밀번호 생성) 또는 레거시 마이그레이션으로 분기
@MainActor
public final class OtpStore: ObservableObject {

    // MARK: - Published (기존 AppState 호환)

    @Published public var accounts: [OtpAccount] = []
    @Published public var folders: [OtpFolder] = []
    @Published public var selectedAccount: OtpAccount?
    @Published public var selectedFolderId: String?      // nil = All Accounts
    @Published public var showingAddAccount = false
    @Published public var showingQRScanner = false
    @Published public var showingQRImageImport = false
    @Published public var showingAddFolder = false
    @Published public var searchText = ""

    // MARK: - Published (온보딩/상태)

    /// 볼트가 열려 정상 사용 가능한 상태.
    @Published public private(set) var isReady = false
    /// 볼트 파일이 이미 존재하는지 (마이그레이션/잠금해제 분기용).
    @Published public private(set) var vaultExists = false
    /// 레거시(v1) 데이터가 존재하는지.
    @Published public private(set) var hasLegacyData = false
    /// 마이그레이션 대상 레거시 계정 수.
    @Published public private(set) var legacyCount = 0
    /// 마지막 오류 메시지 (UI 알림용).
    @Published public var lastError: String?

    // MARK: - Published (iCloud 동기화)

    @Published public var iCloudSyncEnabled = false
    @Published public private(set) var isSyncing = false
    @Published public private(set) var lastSyncStatus = "Never synced"

    /// 온보딩이 필요한 상태(=아직 준비되지 않음).
    public var needsOnboarding: Bool { !isReady }

    // MARK: - Private

    private var client: OtpClient?
    private var timer: Timer?

    private let legacyAccountsKey = "otp_accounts"
    private let legacyFoldersKey = "otp_folders"
    private let migratedAccountsKey = "migrated_otp_accounts"
    private let migratedFoldersKey = "migrated_otp_folders"
    private let syncEnabledKey = "icloudSyncEnabled"

    private var legacyDefaults: UserDefaults? {
        UserDefaults(suiteName: VaultAccess.appGroupId)
    }

    public init() {
        vaultExists = VaultAccess.vaultExists
        detectLegacyData()
        openIfPossible()
        startTimer()
    }

    deinit { timer?.invalidate() }

    // MARK: - 볼트 열기 / 온보딩

    /// VMK 가 있으면 자동으로 볼트를 연다. 실패 시 온보딩으로 남는다.
    private func openIfPossible() {
        guard let path = VaultAccess.vaultPath else {
            lastError = "App Group container unavailable"
            return
        }
        guard vaultExists, let vmk = KeychainHelper.shared.loadVMK() else {
            return  // 온보딩 필요
        }
        do {
            let client = try OtpClient.openWithKey(vaultPath: path, vmk: vmk)
            finishOpen(client)
        } catch {
            lastError = describe(error)
        }
    }

    private func finishOpen(_ client: OtpClient) {
        self.client = client
        self.isReady = true
        self.vaultExists = true
        restoreSyncPreference()
        refresh()
    }

    /// 새 볼트 생성 (기존 데이터 없음).
    public func createVault(password: String) {
        guard let path = VaultAccess.vaultPath else { return }
        do {
            let client = try OtpClient.create(vaultPath: path, masterPassword: password)
            KeychainHelper.shared.saveVMK(client.vaultKey())
            finishOpen(client)
        } catch {
            lastError = describe(error)
        }
    }

    /// 새 볼트 생성 + 레거시 데이터 마이그레이션.
    public func createVaultAndMigrate(password: String) {
        guard let path = VaultAccess.vaultPath else { return }
        do {
            let client = try OtpClient.create(vaultPath: path, masterPassword: password)
            migrateLegacyData(into: client)
            KeychainHelper.shared.saveVMK(client.vaultKey())
            finishOpen(client)
        } catch {
            lastError = describe(error)
        }
    }

    /// 볼트는 있으나 VMK 가 없는 경우: 비밀번호로 잠금 해제 후 VMK 재캐시.
    public func unlock(password: String) {
        guard let path = VaultAccess.vaultPath else { return }
        do {
            let client = try OtpClient.openWithPassword(vaultPath: path, masterPassword: password)
            KeychainHelper.shared.saveVMK(client.vaultKey())
            finishOpen(client)
        } catch {
            lastError = describe(error)
        }
    }

    /// 백업/iCloud 블롭에서 이 기기로 복원 (새 기기 부트스트랩).
    public func restore(blob: Data, password: String) {
        guard let path = VaultAccess.vaultPath else { return }
        do {
            let client = try OtpClient.restore(vaultPath: path, blob: blob, masterPassword: password)
            KeychainHelper.shared.saveVMK(client.vaultKey())
            finishOpen(client)
        } catch {
            lastError = describe(error)
        }
    }

    // MARK: - 새로고침

    public func refresh() {
        guard let client = client else { return }
        accounts = client.listAccounts()
        folders = client.listFolders()
    }

    /// 위젯 등 외부 프로세스 변경 반영.
    public func reloadFromDisk() {
        guard let client = client else { return }
        try? client.reload()
        refresh()
    }

    // 기존 호출부 호환 (AppState.loadAccounts / loadFolders)
    public func loadAccounts() { refresh() }
    public func loadFolders() { refresh() }

    // MARK: - 계정 mutation

    public func addAccount(_ account: OtpAccount) {
        perform { try $0.addAccount(account: account) }
    }

    public func addFromUri(_ uri: String) {
        perform { _ = try $0.addFromUri(uri: uri) }
    }

    public func updateAccount(_ account: OtpAccount) {
        perform { try $0.updateAccount(account: account) }
    }

    public func deleteAccount(_ account: OtpAccount) {
        perform { try $0.deleteAccount(id: account.id) }
    }

    public func toggleFavorite(_ account: OtpAccount) {
        var updated = account
        updated.isFavorite.toggle()
        updateAccount(updated)
    }

    public func moveAccount(_ account: OtpAccount, toFolder folderId: String?) {
        var updated = account
        updated.folderId = folderId
        updateAccount(updated)
    }

    // MARK: - 폴더 mutation

    public func addFolder(_ folder: OtpFolder) {
        perform { try $0.addFolder(folder: folder) }
    }

    public func updateFolder(_ folder: OtpFolder) {
        perform { try $0.updateFolder(folder: folder) }
    }

    public func deleteFolder(_ folder: OtpFolder) {
        perform { try $0.deleteFolder(id: folder.id) }
    }

    // MARK: - 백업 (SettingsView)

    public func exportBackup(password: String) -> Data? {
        guard let client = client else { return nil }
        return try? client.exportBackup(password: password)
    }

    @discardableResult
    public func importBackup(data: Data, password: String, merge: Bool = true) -> Bool {
        guard let client = client else { return false }
        do {
            _ = try client.importBackup(data: data, password: password, merge: merge)
            refresh()
            VaultAccess.notifyChange()
            return true
        } catch {
            lastError = describe(error)
            return false
        }
    }

    // MARK: - 코드 (필요 시 코어 경유)

    /// 계정의 현재 코드. HOTP 는 코어에서 카운터 증가 없이 peek.
    public func code(for account: OtpAccount, at date: Date = Date()) -> String? {
        if let local = account.generateCode(at: date) { return local }
        guard let client = client else { return nil }
        let ms = Int64(date.timeIntervalSince1970 * 1000)
        return (try? client.code(id: account.id, unixTimeMs: ms))?.code
    }

    // MARK: - iCloud 동기화

    private func restoreSyncPreference() {
        iCloudSyncEnabled = legacyDefaults?.bool(forKey: syncEnabledKey) ?? false
        if iCloudSyncEnabled { client?.setSyncBackend(backend: CloudKitSyncBackend()) }
    }

    public func setICloudSync(enabled: Bool) {
        iCloudSyncEnabled = enabled
        legacyDefaults?.set(enabled, forKey: syncEnabledKey)
        guard let client = client else { return }
        if enabled {
            client.setSyncBackend(backend: CloudKitSyncBackend())
            syncNow()
        } else {
            client.clearSyncBackend()
        }
    }

    /// 동기화는 CloudKit 브리지가 블로킹이므로 메인 스레드 밖에서 실행한다.
    public func syncNow() {
        guard let client = client, !isSyncing else { return }
        isSyncing = true
        lastSyncStatus = "Syncing…"
        Task.detached { [weak self] in
            let now = Int64(Date().timeIntervalSince1970 * 1000)
            let result: String
            do {
                let outcome = try client.sync(unixTimeMs: now)
                result = "Synced (pushed: \(outcome.pushed), pulled: \(outcome.pulled), changes: \(outcome.mergedChanges))"
            } catch {
                result = "Sync failed: \(await self?.describe(error) ?? "error")"
            }
            await MainActor.run {
                self?.isSyncing = false
                self?.lastSyncStatus = result
                self?.reloadFromDisk()
            }
        }
    }

    // MARK: - 계산 프로퍼티 (기존 AppState 호환)

    public var filteredAccounts: [OtpAccount] {
        var result = accounts
        if let folderId = selectedFolderId {
            result = result.filter { $0.folderId == folderId }
        }
        if !searchText.isEmpty {
            result = result.filter { account in
                account.issuerText.localizedCaseInsensitiveContains(searchText) ||
                account.accountName.localizedCaseInsensitiveContains(searchText)
            }
        }
        return result
    }

    public var favoriteAccounts: [OtpAccount] { filteredAccounts.filter { $0.isFavorite } }
    public var regularAccounts: [OtpAccount] { filteredAccounts.filter { !$0.isFavorite } }
    public var unfolderedAccounts: [OtpAccount] { accounts.filter { $0.folderId == nil } }

    public func accountCount(inFolder folderId: String) -> Int {
        accounts.filter { $0.folderId == folderId }.count
    }

    // MARK: - 내부 헬퍼

    /// 변경 실행 → 새로고침 → 위젯 알림. 실패 시 lastError 설정.
    private func perform(_ action: (OtpClient) throws -> Void) {
        guard let client = client else { return }
        do {
            try action(client)
            refresh()
            VaultAccess.notifyChange()
        } catch {
            lastError = describe(error)
        }
    }

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.objectWillChange.send() }
        }
    }

    nonisolated private func describe(_ error: Error) -> String {
        if let otp = error as? OtpError { return "\(otp)" }
        return error.localizedDescription
    }

    // MARK: - 레거시 마이그레이션

    private func detectLegacyData() {
        guard !vaultExists,
              let defaults = legacyDefaults,
              let data = defaults.data(forKey: legacyAccountsKey),
              let decoded = try? JSONDecoder().decode([LegacyAccount].self, from: data),
              !decoded.isEmpty else {
            hasLegacyData = false
            legacyCount = 0
            return
        }
        hasLegacyData = true
        legacyCount = decoded.count
    }

    private func migrateLegacyData(into client: OtpClient) {
        guard let defaults = legacyDefaults else { return }

        // 1) 폴더 먼저 삽입하고 (old id -> new id) 매핑 구성
        var folderIdMap: [String: String] = [:]
        if let fdata = defaults.data(forKey: legacyFoldersKey),
           let legacyFolders = try? JSONDecoder().decode([LegacyFolder].self, from: fdata) {
            for lf in legacyFolders {
                let folder = OtpFolder(
                    name: lf.name,
                    icon: lf.icon ?? "folder.fill",
                    color: lf.color ?? "#007AFF",
                    sortOrder: lf.sortOrder ?? 0
                )
                if let created = try? client.addFolder(folder: folder) {
                    folderIdMap[lf.id] = created.id
                }
            }
        }

        // 2) 계정 삽입 (비밀키는 JSON, 없으면 Keychain "secret_<id>" 폴백)
        if let adata = defaults.data(forKey: legacyAccountsKey),
           let legacyAccounts = try? JSONDecoder().decode([LegacyAccount].self, from: adata) {
            for la in legacyAccounts {
                let secret = la.secretKey?.isEmpty == false
                    ? la.secretKey!
                    : (KeychainHelper.shared.loadLegacySecret(forAccountId: la.id) ?? "")
                guard !secret.isEmpty else { continue }

                let account = OtpAccount(
                    issuer: la.issuer ?? "",
                    accountName: la.accountName ?? "",
                    secretKey: secret,
                    type: la.type?.uppercased() == "HOTP" ? .hotp : .totp,
                    algorithm: Self.mapAlgorithm(la.algorithm),
                    digits: la.digits ?? 6,
                    period: la.period ?? 30,
                    counter: la.counter ?? 0,
                    isFavorite: la.isFavorite ?? false,
                    sortOrder: la.sortOrder ?? 0,
                    color: la.color ?? "#512BD4",
                    folderId: la.folderId.flatMap { folderIdMap[$0] }
                )
                _ = try? client.addAccount(account: account)
            }
        }

        // 3) 레거시 키 이름 변경(안전망). 한 릴리스 유지.
        if let adata = defaults.data(forKey: legacyAccountsKey) {
            defaults.set(adata, forKey: migratedAccountsKey)
            defaults.removeObject(forKey: legacyAccountsKey)
        }
        if let fdata = defaults.data(forKey: legacyFoldersKey) {
            defaults.set(fdata, forKey: migratedFoldersKey)
            defaults.removeObject(forKey: legacyFoldersKey)
        }
    }

    private static func mapAlgorithm(_ raw: String?) -> HashAlgorithm {
        switch raw?.uppercased() {
        case "SHA256": return .sha256
        case "SHA512": return .sha512
        default: return .sha1
        }
    }
}

// MARK: - 레거시 디코딩 모델 (v1 UserDefaults 포맷)
// 날짜(createdAt/lastUsedAt)는 마이그레이션에 불필요하므로 무시한다.

private struct LegacyAccount: Decodable {
    let id: String
    let issuer: String?
    let accountName: String?
    let secretKey: String?
    let type: String?
    let algorithm: String?
    let digits: Int?
    let period: Int?
    let counter: Int64?
    let isFavorite: Bool?
    let sortOrder: Int?
    let color: String?
    let folderId: String?
}

private struct LegacyFolder: Decodable {
    let id: String
    let name: String
    let icon: String?
    let color: String?
    let sortOrder: Int?
}
