using Uniffi.Otpeek;

namespace Otpeek.Core.Windows.Services;

/// <summary>
/// Rust 코어의 <see cref="OtpClient"/>를 감싸는 애플리케이션 데이터 계층.
/// DPAPI로 보호된 VMK로 볼트를 열고, 모든 계정/폴더/코드/백업/동기화 작업을 코어에 위임합니다.
/// 코어의 모든 변경 호출은 볼트 파일에 즉시(원자적으로) 반영됩니다.
/// </summary>
public interface IOtpClientService
{
    /// <summary>볼트가 열려 있는지 여부</summary>
    bool IsUnlocked { get; }

    /// <summary>볼트 파일이 디스크에 존재하는지 여부</summary>
    bool VaultExists { get; }

    /// <summary>DPAPI로 보호된 VMK가 저장되어 있는지 여부 (비밀번호 없이 잠금 해제 가능)</summary>
    bool HasStoredKey { get; }

    /// <summary>볼트 내용이 변경되었을 때 발생 (ViewModel이 목록을 새로고침하는 데 사용)</summary>
    event EventHandler? VaultChanged;

    // --- 생명주기 ---

    /// <summary>마스터 비밀번호로 새 볼트를 생성하고 VMK를 DPAPI로 저장</summary>
    void CreateVault(string masterPassword);

    /// <summary>저장된 VMK로 볼트 열기 (비밀번호 불필요)</summary>
    void OpenWithStoredKey();

    /// <summary>마스터 비밀번호로 볼트를 열고 VMK를 DPAPI로 저장 (부트스트랩/키 없음 상황)</summary>
    void OpenWithPassword(string masterPassword);

    /// <summary>백업/원격 blob에서 볼트를 이 기기에 복원하고 VMK를 DPAPI로 저장</summary>
    void RestoreFromBlob(byte[] blob, string masterPassword);

    /// <summary>마스터 비밀번호 변경 (VMK는 재래핑되며 변경되지 않음)</summary>
    void ChangePassword(string oldPassword, string newPassword);

    /// <summary>메모리에서 볼트를 닫음</summary>
    void Lock();

    // --- 계정 (목록은 tombstone 제외, sort_order → issuer 정렬) ---

    IReadOnlyList<OtpAccount> ListAccounts();
    OtpAccount? GetAccount(string id);
    OtpAccount AddAccount(OtpAccount account);

    /// <summary>otpauth:// (1개) 또는 otpauth-migration:// (다수)에서 계정 추가</summary>
    IReadOnlyList<OtpAccount> AddFromUri(string uri);

    OtpAccount UpdateAccount(OtpAccount account);
    void DeleteAccount(string id);

    // --- 폴더 ---

    IReadOnlyList<OtpFolder> ListFolders();
    OtpFolder AddFolder(OtpFolder folder);
    OtpFolder UpdateFolder(OtpFolder folder);
    void DeleteFolder(string id);

    // --- 코드 ---

    /// <summary>현재 시각 기준 코드 (TOTP, 또는 HOTP peek — 카운터 증가 없음)</summary>
    OtpCode Code(string id);

    /// <summary>지정 시각(epoch ms) 기준 코드</summary>
    OtpCode CodeAt(string id, long unixTimeMs);

    /// <summary>HOTP 카운터 증가 후 코드 반환 (영속화됨)</summary>
    OtpCode NextHotp(string id);

    /// <summary>모든(비삭제) 계정의 코드 (지정 시각 기준)</summary>
    IReadOnlyList<AccountCode> CodesAt(long unixTimeMs);

    // --- 백업 / 동기화 ---

    /// <summary>v2 컨테이너로 백업 내보내기 (password로 독립 암호화)</summary>
    byte[] ExportBackup(string password);

    /// <summary>v2 백업 가져오기, 가져온 엔티티 수 반환</summary>
    uint ImportBackup(byte[] data, string password, bool merge);

    /// <summary>레거시 v1 .otpbackup 가져오기</summary>
    uint ImportBackupV1(byte[] data, string password, bool merge);

    /// <summary>WebDAV 동기화 백엔드 구성 (URL/사용자/비밀번호)</summary>
    void ConfigureWebDavSync(string url, string username, string password);

    /// <summary>동기화 백엔드 해제</summary>
    void ClearSync();

    /// <summary>현재 시각 기준 동기화 실행</summary>
    SyncOutcome Sync();
}
