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

    private let legacyAccountsKey = "otp_accounts"
    private let legacyFoldersKey = "otp_folders"
    private let migratedAccountsKey = "migrated_otp_accounts"
    private let migratedFoldersKey = "migrated_otp_folders"
    private let syncEnabledKey = "icloudSyncEnabled"

    private var legacyDefaults: UserDefaults? {
        UserDefaults(suiteName: VaultAccess.appGroupId)
    }

    public init() {
        #if DEBUG
        // App Store 스크린샷용 데모 모드: 실제 볼트 없이 샘플 계정을 보여준다.
        // (라이브 코드는 코어의 순수 함수로 계산되므로 클라이언트가 없어도 표시된다.)
        if ProcessInfo.processInfo.arguments.contains("-otpeekDemo") {
            seedDemoData()
            return
        }
        #endif
        vaultExists = VaultAccess.vaultExists
        detectLegacyData()
        openIfPossible()
    }

    #if DEBUG
    private func seedDemoData() {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        func a(_ issuer: String, _ name: String, _ secret: String, _ i: Int32,
               fav: Bool = false, folder: String? = nil) -> OtpAccount {
            OtpAccount(id: UUID().uuidString, otpType: .totp, secret: secret, issuer: issuer,
                       accountName: name, algorithm: .sha1, digits: 6, period: 30, counter: 0,
                       folderId: folder, isFavorite: fav, sortOrder: i, icon: nil, color: nil,
                       createdAt: now, updatedAt: now, deletedAt: nil)
        }
        func f(_ name: String, _ icon: String, _ color: String, _ i: Int32) -> OtpFolder {
            OtpFolder(id: UUID().uuidString, name: name, icon: icon, color: color,
                      sortOrder: i, createdAt: now, updatedAt: now, deletedAt: nil)
        }
        let work = f("Work", "briefcase.fill", "#5856D6", 0)
        let personal = f("Personal", "house.fill", "#34C759", 1)
        folders = [work, personal]
        accounts = [
            a("GitHub", "octocat", "JBSWY3DPEHPK3PXP", 0, fav: true, folder: work.id),
            a("Google", "you@gmail.com", "KRSXG5CTMVRXEZLU", 1, fav: true, folder: personal.id),
            a("Amazon", "shopping@gmail.com", "MFRGGZDFMZTWQ2LK", 2, folder: work.id),
            a("AWS", "ops@company.com", "NBSWY3DPO5XXE3DE", 3, folder: work.id),
            a("GitLab", "dev@company.com", "GEZDGNBVGY3TQOJQ", 4, folder: work.id),
            a("Slack", "you@company.com", "ONXW2ZLUNBUW4ZY7", 5, folder: personal.id),
            a("Dropbox", "files@gmail.com", "JBSWY3DPEHPK3PXQ", 6, folder: personal.id),
            a("Spotify", "music@gmail.com", "KRSXG5CTMVRXEZLV", 7, folder: personal.id),
            a("Notion", "team@notion.so", "MFRGGZDFMZTWQ2LL", 8),
            a("Reddit", "u/anon", "NBSWY3DPO5XXE3DF", 9),
            a("Discord", "gamer", "GEZDGNBVGY3TQOJR", 10),
        ]
        vaultExists = true
        isReady = true
    }
    #endif

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
    /// 복원 성공 여부를 반환한다(호출부가 성공했을 때만 후속 동작을 하도록).
    @discardableResult
    public func restore(blob: Data, password: String) -> Bool {
        guard let path = VaultAccess.vaultPath else { return false }
        do {
            let client = try OtpClient.restore(vaultPath: path, blob: blob, masterPassword: password)
            KeychainHelper.shared.saveVMK(client.vaultKey())
            lastError = nil
            finishOpen(client)
            return true
        } catch {
            lastError = describe(error)
            return false
        }
    }

    /// iCloud(CloudKit)에서 원격 볼트를 가져와 이 기기로 복원한다(새 기기 부트스트랩).
    ///
    /// 멀티 기기 설정의 정석 경로다. 새 기기에서 "볼트 새로 생성"을 하면 이 기기만의
    /// 랜덤 VMK 가 생겨, 첫 기기가 올린 원격(다른 VMK 로 암호화)을 열 때 `WrongKey` 로
    /// 동기화가 깨진다. 여기서는 원격 blob 을 비밀번호로 열어(open_with_password) 첫 기기의
    /// VMK 를 그대로 복구·저장하므로, 이후 두 기기가 같은 VMK 를 공유해 동기화가 성립한다.
    ///
    /// CloudKit fetch 는 블로킹이므로 메인 스레드 밖에서 수행하고, 복원(상태 변경)만 메인에서 한다.
    public func restoreFromICloud(password: String) {
        guard VaultAccess.vaultPath != nil else {
            lastError = "App Group container unavailable"
            return
        }
        lastError = nil
        isSyncing = true
        lastSyncStatus = "Fetching from iCloud…"
        Task.detached { [weak self] in
            let backend = CloudKitSyncBackend()
            let fetched: Result<RemoteBlob?, Error> = Result { try backend.fetch() }
            await MainActor.run {
                guard let self else { return }
                self.isSyncing = false
                switch fetched {
                case .failure(let error):
                    self.lastError = self.describe(error)
                case .success(nil):
                    self.lastError = "No iCloud vault found yet. Enable iCloud Sync on your first device, then try again."
                case .success(.some(let blob)):
                    // 복원이 실제로 성공했을 때만 동기화를 켠다. (기존 볼트가 있는 기기에서
                    // 비밀번호가 틀리면 restore 는 실패하고 isReady 는 이전 값 그대로이므로,
                    // isReady 를 조건으로 쓰면 실패해도 동기화가 켜지는 버그가 있었다.)
                    if self.restore(blob: blob.data, password: password) {
                        self.setICloudSync(enabled: true)
                    }
                }
            }
        }
    }

    /// 로컬 볼트와 캐시된 VMK 를 지우고 온보딩(복원 가능 상태)으로 되돌린다.
    ///
    /// `WrongKey` 로 동기화가 막힌 기기(원격과 다른 VMK 로 생성됨)를 iCloud 에서 다시
    /// 복원하기 위한 복구 경로다. 원격(iCloud)은 건드리지 않는다.
    /// 주의: 이 기기에만 있고 아직 동기화되지 않은 계정은 사라진다.
    public func resetForRestore() {
        client?.clearSyncBackend()
        client = nil
        isReady = false
        accounts = []
        folders = []
        iCloudSyncEnabled = false
        legacyDefaults?.set(false, forKey: syncEnabledKey)
        KeychainHelper.shared.deleteVMK()
        if let path = VaultAccess.vaultPath {
            try? FileManager.default.removeItem(atPath: path)
        }
        vaultExists = false
        lastError = nil
        lastSyncStatus = "Never synced"
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

    /// 백업/`.otpvault` 파일 가져오기 결과. UI 가 가져온 개수 피드백과 "비밀번호 오류 → 재시도"
    /// 를 구분해서 보여줄 수 있도록 성공(개수) / 비밀번호 오류 / 기타 실패를 나눠서 반환한다.
    public enum ImportOutcome {
        case success(Int)
        case wrongPassword
        case failure(String)
    }

    /// `importBackup` 과 동일하지만 가져온 계정 수와 오류 종류를 함께 돌려준다.
    public func importBackupChecked(data: Data, password: String, merge: Bool) -> ImportOutcome {
        guard let client = client else { return .failure("Vault is not open.") }
        do {
            let count = try client.importBackup(data: data, password: password, merge: merge)
            refresh()
            VaultAccess.notifyChange()
            return .success(Int(count))
        } catch OtpError.WrongPassword {
            return .wrongPassword
        } catch {
            return .failure(describe(error))
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
            var wrongKey = false
            do {
                let outcome = try client.sync(unixTimeMs: now)
                result = "Synced (pushed: \(outcome.pushed), pulled: \(outcome.pulled), changes: \(outcome.mergedChanges))"
            } catch OtpError.WrongKey {
                // 이 기기의 볼트가 원격과 다른 VMK 로 만들어졌다(대개 다른 기기에서 각각 "새로
                // 생성"한 경우). 원격을 이 기기의 키로 열 수 없다. 정석 해법은 이 기기를 iCloud 에서
                // 다시 복원해 원격 VMK 를 공유하는 것이다(설정 → "Reset & Restore from iCloud").
                wrongKey = true
                result = "Sync failed: this device's vault uses a different key than iCloud. Use Settings → \"Restore from iCloud\" to pull the vault from your other device and share the same key."
            } catch {
                result = "Sync failed: \(await self?.describe(error) ?? "error")"
            }
            await MainActor.run {
                self?.isSyncing = false
                self?.lastSyncStatus = result
                if wrongKey { self?.lastError = result }
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
