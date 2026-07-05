import Foundation
import WidgetKit

/// App 과 Widget 확장이 공유하는 볼트 파일 위치 / 프로세스 간 변경 알림 유틸리티.
public enum VaultAccess {

    public static let appGroupId = "group.com.otpauthenticator"
    public static let vaultFileName = "vault.otpvault"

    /// Darwin 알림 이름 — 앱이 변경 후 게시하면 위젯이 타임라인을 새로고침한다.
    public static let changeNotification = "com.otpauthenticator.vault.changed"

    /// App Group 컨테이너 내 볼트 파일 경로.
    public static var vaultURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupId)?
            .appendingPathComponent(vaultFileName)
    }

    public static var vaultPath: String? { vaultURL?.path }

    /// 볼트 파일 존재 여부 (온보딩/마이그레이션 분기용).
    public static var vaultExists: Bool {
        guard let path = vaultPath else { return false }
        return FileManager.default.fileExists(atPath: path)
    }

    // MARK: - 프로세스 간 변경 알림

    /// 앱이 변경(추가/수정/삭제) 후 호출: Darwin 알림 + 위젯 새로고침.
    public static func notifyChange() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterPostNotification(
            center,
            CFNotificationName(changeNotification as CFString),
            nil, nil, true
        )
        WidgetCenter.shared.reloadAllTimelines()
    }
}

// MARK: - 위젯 전용 클라이언트 접근자

/// 위젯 프로세스에서 비밀번호/Argon2 없이 볼트를 여는 헬퍼.
/// Keychain 의 VMK + 공유 볼트 경로로 openWithKey 만 사용한다.
public enum WidgetVault {

    /// VMK 로 볼트를 열어 최신 상태를 반영한 OtpClient 를 반환한다.
    /// 잠금/미설정/키 없음 등 어떤 이유로든 실패하면 nil.
    public static func openClient() -> OtpClient? {
        guard let path = VaultAccess.vaultPath,
              FileManager.default.fileExists(atPath: path),
              let vmk = KeychainHelper.shared.loadVMK() else {
            return nil
        }
        guard let client = try? OtpClient.openWithKey(vaultPath: path, vmk: vmk) else {
            return nil
        }
        // 앱이 방금 저장한 내용을 반영하기 위해 읽기 전에 reload.
        try? client.reload()
        return client
    }

    /// 위젯에 표시할 기본 계정 (즐겨찾기 우선, 없으면 첫 계정).
    public static func firstAccount(from client: OtpClient) -> OtpAccount? {
        let accounts = client.listAccounts()
        return accounts.first(where: { $0.isFavorite }) ?? accounts.first
    }
}
