import Foundation
import Security

/// Keychain 헬퍼 — VMK(Vault Master Key)와 WebDAV 연결 정보를 저장한다.
/// 계정 비밀키는 모두 코어의 암호화 볼트 파일 안에 있으므로 Keychain 에 없다.
///
/// - account: "vmk"
/// - access group: 위젯과 공유되는 App Group (기존 entitlements 와 동일)
/// - accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
public final class KeychainHelper {

    public static let shared = KeychainHelper()

    private let service = "com.otpeek"
    private let accessGroup = "group.com.otpeek.app"
    private let vmkAccount = "vmk"
    private let webDAVAccount = "webdav-configuration"
    // 마이그레이션 시 기존 계정 비밀키를 읽기 위한 legacy 키 접두사
    private let legacySecretPrefix = "secret_"

    private init() {}

    // MARK: - VMK

    /// VMK 저장 (기존 값 교체)
    @discardableResult
    public func saveVMK(_ vmk: Data) -> Bool {
        save(vmk, account: vmkAccount)
    }

    func saveWebDAVConfiguration(_ configuration: WebDAVConfiguration) -> Bool {
        guard let data = try? JSONEncoder().encode(configuration) else { return false }
        return save(data, account: webDAVAccount)
    }

    func loadWebDAVConfiguration() -> WebDAVConfiguration? {
        load(account: webDAVAccount).flatMap { try? JSONDecoder().decode(WebDAVConfiguration.self, from: $0) }
    }

    @discardableResult
    func deleteWebDAVConfiguration() -> Bool {
        delete(webDAVAccount)
    }

    private func save(_ data: Data, account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        guard status == errSecItemNotFound else { return status == errSecSuccess }
        let item = query.merging(attributes) { _, new in new }
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    /// VMK 조회
    public func loadVMK() -> Data? {
        return load(account: vmkAccount)
    }

    /// VMK 삭제 (로그아웃/재부트스트랩 시)
    @discardableResult
    public func deleteVMK() -> Bool {
        return delete(vmkAccount)
    }

    // MARK: - Legacy secret 읽기 (마이그레이션 전용)

    /// 기존 v1 앱이 "secret_<id>" 로 저장한 비밀키를 읽는다.
    public func loadLegacySecret(forAccountId id: String) -> String? {
        let account = legacySecretPrefix + id
        if let data = load(account: account),
           let secret = String(data: data, encoding: .utf8), !secret.isEmpty {
            return secret
        }
        return load(account: account, service: "com.otpauthenticator", accessGroup: nil)
            .flatMap { String(data: $0, encoding: .utf8) }
    }

    /// 마이그레이션 완료 후 legacy 비밀키 정리
    @discardableResult
    public func deleteLegacySecret(forAccountId id: String) -> Bool {
        return delete(legacySecretPrefix + id)
    }

    // MARK: - Private

    private func load(account: String) -> Data? {
        load(account: account, service: service, accessGroup: accessGroup)
    }

    private func load(account: String, service: String, accessGroup: String?) -> Data? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return status == errSecSuccess ? (result as? Data) : nil
    }

    @discardableResult
    private func delete(_ account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
