import Foundation
import Security

/// Keychain 헬퍼 — v2 에서는 오직 VMK(Vault Master Key)만 저장한다.
/// 계정 비밀키는 모두 코어의 암호화 볼트 파일 안에 있으므로 Keychain 에 없다.
///
/// - account: "vmk"
/// - access group: 위젯과 공유되는 App Group (기존 entitlements 와 동일)
/// - accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
public final class KeychainHelper {

    public static let shared = KeychainHelper()

    private let service = "com.otpeek"
    private let accessGroup = "group.com.otpeek"
    private let vmkAccount = "vmk"
    // 마이그레이션 시 기존 계정 비밀키를 읽기 위한 legacy 키 접두사
    private let legacySecretPrefix = "secret_"

    private init() {}

    // MARK: - VMK

    /// VMK 저장 (기존 값 교체)
    @discardableResult
    public func saveVMK(_ vmk: Data) -> Bool {
        delete(vmkAccount)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: vmkAccount,
            kSecValueData as String: vmk,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrAccessGroup as String: accessGroup
        ]
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
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
        guard let data = load(account: legacySecretPrefix + id) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 마이그레이션 완료 후 legacy 비밀키 정리
    @discardableResult
    public func deleteLegacySecret(forAccountId id: String) -> Bool {
        return delete(legacySecretPrefix + id)
    }

    // MARK: - Private

    private func load(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecAttrAccessGroup as String: accessGroup
        ]
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
