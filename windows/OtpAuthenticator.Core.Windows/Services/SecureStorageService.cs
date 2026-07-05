using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using OtpAuthenticator.Core.Services.Interfaces;

namespace OtpAuthenticator.Core.Windows.Services;

/// <summary>
/// Windows 보안 저장소 서비스.
/// v2에서는 계정/시크릿을 Rust 코어 볼트가 관리하므로, 이 서비스는
/// 볼트 마스터 키(VMK)의 DPAPI 보호 저장과 앱 환경설정 파일 저장만 담당합니다.
/// </summary>
public class SecureStorageService : ISecureStorageService
{
    private const string VmkFileName = "vmk.bin";
    private const string VaultFileName = "vault.otpvault";

    // DPAPI 부가 엔트로피 (VMK 보호용). 고정 값으로 사용해도 CurrentUser 스코프로 충분히 보호됨.
    private static readonly byte[] VmkEntropy = Encoding.UTF8.GetBytes("OtpAuthenticator.Vmk.v2");

    private readonly string _dataDirectory;

    public string DataDirectory => _dataDirectory;

    public string VaultPath => Path.Combine(_dataDirectory, VaultFileName);

    public SecureStorageService()
    {
        _dataDirectory = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "OtpAuthenticator");

        Directory.CreateDirectory(_dataDirectory);
    }

    private string VmkPath => Path.Combine(_dataDirectory, VmkFileName);

    // --- VMK ---

    public void SaveVaultKey(byte[] vmk)
    {
        if (vmk == null || vmk.Length == 0)
            throw new ArgumentException("VMK must be non-empty", nameof(vmk));

        byte[] encrypted = ProtectedData.Protect(vmk, VmkEntropy, DataProtectionScope.CurrentUser);
        // 원자적 저장: temp 파일 작성 후 교체
        string tmp = VmkPath + ".tmp";
        File.WriteAllBytes(tmp, encrypted);
        if (File.Exists(VmkPath))
            File.Delete(VmkPath);
        File.Move(tmp, VmkPath);
    }

    public byte[]? LoadVaultKey()
    {
        if (!File.Exists(VmkPath))
            return null;

        try
        {
            byte[] encrypted = File.ReadAllBytes(VmkPath);
            return ProtectedData.Unprotect(encrypted, VmkEntropy, DataProtectionScope.CurrentUser);
        }
        catch
        {
            return null;
        }
    }

    public bool HasVaultKey() => File.Exists(VmkPath);

    public void DeleteVaultKey()
    {
        if (File.Exists(VmkPath))
            File.Delete(VmkPath);
    }

    // --- 앱 환경설정 (평문 비밀 없음) ---

    public async Task SaveEncryptedDataAsync<T>(string filename, T data)
    {
        string json = JsonSerializer.Serialize(data, new JsonSerializerOptions { WriteIndented = false });
        byte[] plainBytes = Encoding.UTF8.GetBytes(json);
        byte[] encryptedBytes = ProtectedData.Protect(plainBytes, null, DataProtectionScope.CurrentUser);

        string filePath = Path.Combine(_dataDirectory, filename);
        await File.WriteAllBytesAsync(filePath, encryptedBytes);
    }

    public async Task<T?> LoadEncryptedDataAsync<T>(string filename)
    {
        string filePath = Path.Combine(_dataDirectory, filename);
        if (!File.Exists(filePath))
            return default;

        try
        {
            byte[] encryptedBytes = await File.ReadAllBytesAsync(filePath);
            byte[] plainBytes = ProtectedData.Unprotect(encryptedBytes, null, DataProtectionScope.CurrentUser);
            string json = Encoding.UTF8.GetString(plainBytes);
            return JsonSerializer.Deserialize<T>(json);
        }
        catch
        {
            return default;
        }
    }

    public Task DeleteEncryptedDataAsync(string filename)
    {
        string filePath = Path.Combine(_dataDirectory, filename);
        if (File.Exists(filePath))
            File.Delete(filePath);
        return Task.CompletedTask;
    }

    // --- 임의 문자열 보호 ---

    public string ProtectString(string plaintext)
    {
        byte[] plainBytes = Encoding.UTF8.GetBytes(plaintext ?? string.Empty);
        byte[] encrypted = ProtectedData.Protect(plainBytes, null, DataProtectionScope.CurrentUser);
        return Convert.ToBase64String(encrypted);
    }

    public string? UnprotectString(string? protectedBase64)
    {
        if (string.IsNullOrEmpty(protectedBase64))
            return null;

        try
        {
            byte[] encrypted = Convert.FromBase64String(protectedBase64);
            byte[] plainBytes = ProtectedData.Unprotect(encrypted, null, DataProtectionScope.CurrentUser);
            return Encoding.UTF8.GetString(plainBytes);
        }
        catch
        {
            return null;
        }
    }
}
