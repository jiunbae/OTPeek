namespace OtpAuthenticator.Core.Services.Interfaces;

/// <summary>
/// 보안 저장소 서비스 인터페이스.
/// v2에서 계정/시크릿은 Rust 코어 볼트에 저장되므로, 이 서비스는
/// (1) 볼트 마스터 키(VMK)의 DPAPI 보호 저장, (2) 앱 환경설정 파일의 DPAPI 저장,
/// (3) 임의 문자열(WebDAV 비밀번호 등)의 DPAPI 보호만 담당합니다.
/// </summary>
public interface ISecureStorageService
{
    /// <summary>
    /// 데이터 디렉토리 경로 (%LOCALAPPDATA%\OtpAuthenticator)
    /// </summary>
    string DataDirectory { get; }

    /// <summary>
    /// 볼트 파일 경로 (%LOCALAPPDATA%\OtpAuthenticator\vault.otpvault)
    /// </summary>
    string VaultPath { get; }

    // --- VMK (Vault Master Key) ---

    /// <summary>
    /// VMK(32바이트)를 DPAPI(CurrentUser)로 보호하여 vmk.bin에 저장
    /// </summary>
    void SaveVaultKey(byte[] vmk);

    /// <summary>
    /// 저장된 VMK를 복호화하여 반환. 없거나 복호화 실패 시 null
    /// </summary>
    byte[]? LoadVaultKey();

    /// <summary>
    /// vmk.bin 존재 여부
    /// </summary>
    bool HasVaultKey();

    /// <summary>
    /// 저장된 VMK 삭제
    /// </summary>
    void DeleteVaultKey();

    // --- 앱 환경설정 (평문 비밀 없음) ---

    /// <summary>
    /// 앱 환경설정 데이터를 DPAPI로 암호화하여 파일에 저장
    /// </summary>
    Task SaveEncryptedDataAsync<T>(string filename, T data);

    /// <summary>
    /// DPAPI 암호화된 환경설정 데이터 로드. 없으면 default
    /// </summary>
    Task<T?> LoadEncryptedDataAsync<T>(string filename);

    /// <summary>
    /// 환경설정 데이터 파일 삭제
    /// </summary>
    Task DeleteEncryptedDataAsync(string filename);

    // --- 임의 문자열 보호 (WebDAV 비밀번호 등) ---

    /// <summary>
    /// 문자열을 DPAPI(CurrentUser)로 보호하고 Base64 문자열로 반환
    /// </summary>
    string ProtectString(string plaintext);

    /// <summary>
    /// <see cref="ProtectString"/>로 보호된 Base64 문자열을 복호화. 실패 시 null
    /// </summary>
    string? UnprotectString(string? protectedBase64);
}
