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

    public let appLock = AppLock()

    // MARK: - Private

    private var client: OtpClient?

    private let legacyAccountsKey = "otp_accounts"
    private let legacyFoldersKey = "otp_folders"
    private let syncEnabledKey = "icloudSyncEnabled"
    private static let legacyBackupMagic = Data("OTPB".utf8)

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
            a("Jira", "team@company.com", "JBSWY3DPEHPK3PXR", 5, folder: work.id),
            a("Figma", "design@company.com", "KRSXG5CTMVRXEZLW", 6, folder: work.id),
            a("Slack", "you@company.com", "ONXW2ZLUNBUW4ZY7", 7, folder: personal.id),
            a("Dropbox", "files@gmail.com", "JBSWY3DPEHPK3PXQ", 8, folder: personal.id),
            a("Spotify", "music@gmail.com", "KRSXG5CTMVRXEZLV", 9, folder: personal.id),
            a("Netflix", "watch@gmail.com", "MFRGGZDFMZTWQ2LM", 10, folder: personal.id),
            a("Steam", "gamer@gmail.com", "NBSWY3DPO5XXE3DG", 11, folder: personal.id),
            a("Notion", "team@notion.so", "MFRGGZDFMZTWQ2LL", 12),
            a("Reddit", "u/anon", "NBSWY3DPO5XXE3DF", 13),
            a("Discord", "gamer", "GEZDGNBVGY3TQOJR", 14),
            a("Twitch", "streamer", "JBSWY3DPEHPK3PXS", 15),
            a("PayPal", "pay@gmail.com", "KRSXG5CTMVRXEZLX", 16),
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
        // 생성/잠금해제/복원 직후 위젯이 "No accounts" 에 머물지 않도록 바로 새로고침.
        VaultAccess.notifyChange()
    }

    /// 새 볼트 생성 (기존 데이터 없음).
    public func createVault(password: String) {
        guard canAccessVault(), !vaultExists, !VaultAccess.vaultExists,
              let path = VaultAccess.vaultPath else { return }
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
        guard canAccessVault() else { return }
        guard let destination = VaultAccess.vaultURL else {
            lastError = "App Group container unavailable."
            return
        }
        let files = FileManager.default
        do {
            guard !files.fileExists(atPath: destination.path) else {
                vaultExists = true
                throw LegacyMigrationError("A vault already exists. Unlock it with its master password.")
            }
            let (accounts, folders) = try readLegacyData()
            let staging = destination.deletingLastPathComponent()
                .appendingPathComponent(".migration-\(UUID().uuidString)", isDirectory: true)
            try files.createDirectory(at: staging, withIntermediateDirectories: false)
            defer { try? files.removeItem(at: staging) }

            let stagedVault = staging.appendingPathComponent(VaultAccess.vaultFileName)
            let staged = try OtpClient.create(vaultPath: stagedVault.path, masterPassword: password)
            try migrateLegacyData(accounts: accounts, folders: folders, into: staged)
            let key = staged.vaultKey()
            let verified = try OtpClient.openWithKey(vaultPath: stagedVault.path, vmk: key)
            guard verified.listAccounts().count == accounts.count,
                  verified.listFolders().count == folders.count else {
                throw LegacyMigrationError("The encrypted vault did not contain all the migrated records.")
            }

            // Both paths are on the same volume. Moving refuses to replace an existing vault.
            try files.moveItem(at: stagedVault, to: destination)
            vaultExists = true
            hasLegacyData = false
            legacyCount = 0
            guard KeychainHelper.shared.saveVMK(key) else {
                lastError = "Migration succeeded, but the vault key could not be saved. Unlock with your master password."
                return
            }
            finishOpen(try OtpClient.openWithKey(vaultPath: destination.path, vmk: key))
            lastError = nil
        } catch {
            vaultExists = files.fileExists(atPath: destination.path)
            lastError = "Migration failed: \(describe(error))"
        }
    }

    /// 볼트는 있으나 VMK 가 없는 경우: 비밀번호로 잠금 해제 후 VMK 재캐시.
    public func unlock(password: String) {
        guard canAccessVault(), let path = VaultAccess.vaultPath else { return }
        do {
            let client = try OtpClient.openWithPassword(vaultPath: path, masterPassword: password)
            KeychainHelper.shared.saveVMK(client.vaultKey())
            lastError = nil
            finishOpen(client)
        } catch {
            lastError = describe(error)
        }
    }

    /// 백업/iCloud 블롭에서 이 기기로 복원 (새 기기 부트스트랩).
    /// 복원 성공 여부를 반환한다(호출부가 성공했을 때만 후속 동작을 하도록).
    @discardableResult
    public func restore(blob: Data, password: String) -> Bool {
        guard canAccessVault(), let path = VaultAccess.vaultPath else { return false }
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
        guard canAccessVault() else { return }
        guard VaultAccess.vaultPath != nil else {
            lastError = "App Group container unavailable"
            return
        }
        lastError = nil
        isSyncing = true
        lastSyncStatus = "Fetching from iCloud…"
        let generation = appLock.lockGeneration
        Task {
            let fetched = await Self.runCloudWork {
                Result { try CloudKitSyncBackend().fetch() }
            }
            isSyncing = false
            guard !appLock.isLocked, generation == appLock.lockGeneration else {
                lastSyncStatus = "Restore interrupted. Unlock OTPeek and try again."
                lastError = lastSyncStatus
                return
            }
            switch fetched {
            case .failure(let error):
                lastError = describe(error)
                lastSyncStatus = "iCloud restore failed."
            case .success(nil):
                lastError = "No iCloud vault found yet. Enable iCloud Sync on your first device, then try again."
                lastSyncStatus = "No iCloud vault found."
            case .success(.some(let blob)):
                if restore(blob: blob.data, password: password) {
                    setICloudSync(enabled: true)
                } else {
                    lastSyncStatus = "iCloud restore failed."
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
        guard canAccessVault() else { return }
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
        // 지워진 볼트의 코드를 위젯이 계속 보여주지 않도록.
        VaultAccess.notifyChange()
    }

    // MARK: - 새로고침

    public func refresh() {
        guard !isSyncing, let client else { return }
        accounts = client.listAccounts()
        folders = client.listFolders()
    }

    /// 위젯 등 외부 프로세스 변경 반영.
    public func reloadFromDisk() {
        guard !isSyncing, let client else { return }
        do {
            try client.reload()
            refresh()
        } catch {
            lastError = describe(error)
        }
    }

    // 기존 호출부 호환 (AppState.loadAccounts / loadFolders)
    public func loadAccounts() { refresh() }
    public func loadFolders() { refresh() }

    // MARK: - 계정 mutation

    public func addAccount(_ account: OtpAccount) {
        perform { _ = try $0.addAccount(account: account) }
    }

    public func addFromUri(_ uri: String) {
        perform { _ = try $0.addFromUri(uri: uri) }
    }

    public func updateAccount(_ account: OtpAccount) {
        perform { client in
            var updated = account
            // An edit sheet may have captured this account before a HOTP copy.
            if account.type == .hotp, let current = client.getAccount(id: account.id) {
                updated.counter = current.counter
            }
            _ = try client.updateAccount(account: updated)
        }
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
        perform { _ = try $0.addFolder(folder: folder) }
    }

    public func updateFolder(_ folder: OtpFolder) {
        perform { _ = try $0.updateFolder(folder: folder) }
    }

    public func deleteFolder(_ folder: OtpFolder) {
        perform { try $0.deleteFolder(id: folder.id) }
    }

    // MARK: - 백업 (SettingsView)

    public func exportBackup(password: String) -> Data? {
        guard canAccessVault() else { return nil }
        guard let client = client else {
            lastError = "Vault is not open."
            return nil
        }
        do {
            let data = try client.exportBackup(password: password)
            lastError = nil
            return data
        } catch {
            lastError = describe(error)
            return nil
        }
    }

    @discardableResult
    public func importBackup(data: Data, password: String, merge: Bool = true) -> Bool {
        guard canAccessVault(), let client else { return false }
        do {
            if data.starts(with: Self.legacyBackupMagic) {
                _ = try client.importBackupV1(data: data, password: password, merge: merge)
            } else {
                _ = try client.importBackup(data: data, password: password, merge: merge)
            }
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
        guard canAccessVault() else { return .failure(lastError ?? "Vault unavailable.") }
        guard let client else { return .failure("Vault is not open.") }
        do {
            // v2 containers begin with "OTPVAULT"; legacy v1 `.otpbackup`
            // files begin with "OTPB". The picker accepts both formats, so
            // route legacy data to its compatible decoder instead of reporting
            // a misleading corrupt-v2 error.
            let count: UInt32
            if data.starts(with: Self.legacyBackupMagic) {
                count = try client.importBackupV1(data: data, password: password, merge: merge)
            } else {
                count = try client.importBackup(data: data, password: password, merge: merge)
            }
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
        guard !appLock.isLocked else { return nil }
        if let local = account.generateCode(at: date) { return local }
        guard let client else { return nil }
        let ms = Int64(date.timeIntervalSince1970 * 1000)
        return (try? client.code(id: account.id, unixTimeMs: ms))?.code
    }

    /// Returns a fresh code for an explicit copy. HOTP must persist the increment first.
    func codeForCopy(accountID: String) throws -> String {
        guard !appLock.isLocked else {
            throw OtpError.Auth(msg: "Unlock OTPeek before copying a code.")
        }
        guard let account = accounts.first(where: { $0.id == accountID }) else {
            throw OtpError.NotFound(id: accountID)
        }
        if account.type == .totp {
            guard let code = account.generateCode() else {
                throw OtpError.InvalidParameter(msg: "Could not generate a TOTP code.")
            }
            return code
        }
        guard canAccessVault(), let client else {
            throw OtpError.Backend(msg: lastError ?? "Vault is not open.")
        }
        guard let current = client.getAccount(id: accountID), current.counter < UInt64.max else {
            throw OtpError.InvalidParameter(msg: "The HOTP counter cannot be advanced.")
        }
        do {
            let code = try client.nextHotp(id: accountID)
            refresh()
            VaultAccess.notifyChange()
            return code.code
        } catch {
            // Refresh the snapshot before retrying an advance from a stale client.
            reloadFromDisk()
            throw error
        }
    }

    // MARK: - iCloud 동기화

    private func restoreSyncPreference() {
        iCloudSyncEnabled = legacyDefaults?.bool(forKey: syncEnabledKey) ?? false
        if iCloudSyncEnabled { client?.setSyncBackend(backend: CloudKitSyncBackend()) }
    }

    public func setICloudSync(enabled: Bool) {
        guard canAccessVault() else { return }
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
        guard canAccessVault(), let client else { return }
        isSyncing = true
        lastSyncStatus = "Syncing…"
        Task {
            let result = await Self.runCloudWork {
                Result { try client.sync(unixTimeMs: Int64(Date().timeIntervalSince1970 * 1000)) }
            }
            isSyncing = false
            switch result {
            case .success(let outcome):
                lastSyncStatus = "Synced (pushed: \(outcome.pushed), pulled: \(outcome.pulled), changes: \(outcome.mergedChanges))"
            case .failure(OtpError.WrongKey):
                let message = "Sync failed: this device's vault uses a different key than iCloud. Use Settings → \"Restore from iCloud\" to pull the vault from your other device and share the same key."
                lastSyncStatus = message
                lastError = message
            case .failure(let error):
                lastSyncStatus = "Sync failed: \(describe(error))"
            }
            reloadFromDisk()
            VaultAccess.notifyChange()
        }
    }

    private static func runCloudWork<Value: Sendable>(_ work: @escaping @Sendable () -> Value) async -> Value {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: work())
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
        guard canAccessVault(), let client else { return }
        do {
            try action(client)
            refresh()
            VaultAccess.notifyChange()
        } catch {
            lastError = describe(error)
        }
    }

    private func canAccessVault() -> Bool {
        guard !appLock.isLocked else {
            lastError = "Unlock OTPeek to access the vault."
            return false
        }
        // Keep vault changes and account actions from racing an iCloud restore or sync.
        guard !isSyncing else {
            lastError = "Wait for iCloud to finish, then try again."
            return false
        }
        return true
    }

    nonisolated private func describe(_ error: Error) -> String {
        if let otp = error as? OtpError { return "\(otp)" }
        return error.localizedDescription
    }

    // MARK: - 레거시 마이그레이션

    private var legacySource: UserDefaults? {
        var candidates = [legacyDefaults, UserDefaults.standard]
        for group in ["group.com.otpauthenticator", "group.com.otpeek"] {
            if FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) != nil {
                candidates.append(UserDefaults(suiteName: group))
            }
        }
        return candidates.compactMap { $0 }.first {
            $0.object(forKey: legacyAccountsKey) != nil || $0.object(forKey: legacyFoldersKey) != nil
        }
    }

    private func detectLegacyData() {
        guard !vaultExists, legacySource != nil else { return }
        do {
            let (accounts, folders) = try readLegacyData()
            legacyCount = accounts.count
            hasLegacyData = !accounts.isEmpty || !folders.isEmpty
        } catch {
            hasLegacyData = true
            lastError = describe(error)
        }
    }

    private func readLegacyData() throws -> ([LegacyAccount], [LegacyFolder]) {
        guard let source = legacySource else {
            throw LegacyMigrationError("The legacy account store could not be found.")
        }
        func decode<T: Decodable>(_ key: String, label: String) throws -> [T] {
            guard let value = source.object(forKey: key) else { return [] }
            guard let data = value as? Data,
                  let records = try? JSONDecoder().decode([T].self, from: data) else {
                throw LegacyMigrationError("The legacy \(label) could not be decoded.")
            }
            return records
        }
        return (try decode(legacyAccountsKey, label: "accounts"),
                try decode(legacyFoldersKey, label: "folders"))
    }

    private func migrateLegacyData(
        accounts: [LegacyAccount], folders: [LegacyFolder], into client: OtpClient
    ) throws {
        var folderIDs = Set<String>()
        for (index, legacy) in folders.enumerated() {
            guard !legacy.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  folderIDs.insert(legacy.id).inserted,
                  let sortOrder = Int32(exactly: legacy.sortOrder ?? 0) else {
                throw LegacyMigrationError("Legacy folder \(index + 1) has an invalid ID or sort order.")
            }
            let folder = OtpFolder(
                id: legacy.id, name: legacy.name, icon: legacy.icon, color: legacy.color,
                sortOrder: sortOrder, createdAt: 0, updatedAt: 0, deletedAt: nil
            )
            do { _ = try client.addFolder(folder: folder) }
            catch { throw LegacyMigrationError("Legacy folder \(index + 1) could not be saved.") }
        }

        var accountIDs = Set<String>()
        for (index, legacy) in accounts.enumerated() {
            let label = "Legacy account \(index + 1)"
            let secret = legacy.secretKey.flatMap { $0.isEmpty ? nil : $0 }
                ?? KeychainHelper.shared.loadLegacySecret(forAccountId: legacy.id)
            guard let secret, !secret.isEmpty else {
                throw LegacyMigrationError("\(label) has no readable secret.")
            }
            let type = legacy.type?.uppercased() ?? "TOTP"
            let algorithm = legacy.algorithm?.uppercased() ?? "SHA1"
            guard !legacy.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  accountIDs.insert(legacy.id).inserted,
                  ["TOTP", "HOTP"].contains(type),
                  let hash = ["SHA1": HashAlgorithm.sha1, "SHA256": .sha256, "SHA512": .sha512][algorithm],
                  let digits = UInt32(exactly: legacy.digits ?? 6), (1...9).contains(digits),
                  let period = UInt32(exactly: legacy.period ?? 30), period > 0,
                  let counter = UInt64(exactly: legacy.counter ?? 0),
                  let sortOrder = Int32(exactly: legacy.sortOrder ?? 0) else {
                throw LegacyMigrationError("\(label) has invalid OTP settings or an invalid ID.")
            }
            let account = OtpAccount(
                id: legacy.id, otpType: type == "HOTP" ? .hotp : .totp, secret: secret,
                issuer: legacy.issuer, accountName: legacy.accountName ?? "", algorithm: hash,
                digits: digits, period: period, counter: counter, folderId: legacy.folderId,
                isFavorite: legacy.isFavorite ?? false, sortOrder: sortOrder,
                icon: nil, color: legacy.color, createdAt: 0, updatedAt: 0, deletedAt: nil
            )
            do { _ = try client.addAccount(account: account) }
            catch { throw LegacyMigrationError("\(label) could not be saved. Check the secret and available storage.") }
        }
    }
}

// MARK: - 레거시 디코딩 모델 (v1 UserDefaults 포맷)
// 날짜(createdAt/lastUsedAt)는 마이그레이션에 불필요하므로 무시한다.

private struct LegacyMigrationError: LocalizedError {
    let message: String

    init(_ message: String) { self.message = message }

    var errorDescription: String? { message }
}

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
