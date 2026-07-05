using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using OtpAuthenticator.Core.Services.Interfaces;
using Uniffi.Otp;
using OtpHashAlgorithm = Uniffi.Otp.HashAlgorithm;

namespace OtpAuthenticator.Core.Windows.Services;

/// <summary>
/// v1 앱의 로컬 계정 저장소를 v2 볼트로 마이그레이션합니다.
///
/// v1 저장 방식(재현 대상):
///  - 계정 메타데이터: <c>%LOCALAPPDATA%\OtpAuthenticator\accounts.dat</c>
///    = DPAPI(CurrentUser, entropy=null)로 보호된 <c>List&lt;AccountData&gt;</c> JSON.
///  - 각 계정의 Base32 시크릿: PasswordVault("OtpAuthenticator", "secret_{id}")
///    또는 DPAPI 폴백 파일 <c>secrets\{base64safe(key)}.dat</c> (entropy = UTF8(key)).
///
/// 참고: 태스크 지시서는 레거시 파일명을 accounts.json으로 언급하지만, 실제 v1 코드는
/// accounts.dat를 사용합니다. 두 이름을 모두 확인하며, 마이그레이션 후
/// <c>{원본이름}.migrated</c>로 이름을 변경합니다.
/// </summary>
public interface ILegacyMigrationService
{
    /// <summary>마이그레이션 대상 레거시 데이터가 존재하는지 여부</summary>
    bool HasLegacyData();

    /// <summary>
    /// 레거시 계정을 열린 볼트로 가져오고 레거시 파일을 .migrated로 이름 변경합니다.
    /// </summary>
    /// <returns>가져온 계정 수</returns>
    int Migrate(IOtpClientService client);
}

/// <summary>
/// <see cref="ILegacyMigrationService"/> 구현.
/// </summary>
public sealed class LegacyMigrationService : ILegacyMigrationService
{
    private const string ResourceName = "OtpAuthenticator";
    private const string SecretsPrefix = "secret_";

    private readonly ISecureStorageService _secureStorage;

    public LegacyMigrationService(ISecureStorageService secureStorage)
    {
        _secureStorage = secureStorage;
    }

    private string DataDir => _secureStorage.DataDirectory;

    private IEnumerable<string> CandidateFiles()
    {
        yield return Path.Combine(DataDir, "accounts.dat");
        yield return Path.Combine(DataDir, "accounts.json");
    }

    public bool HasLegacyData() => CandidateFiles().Any(File.Exists);

    public int Migrate(IOtpClientService client)
    {
        string? legacyFile = CandidateFiles().FirstOrDefault(File.Exists);
        if (legacyFile == null)
            return 0;

        var legacyAccounts = ReadLegacyAccounts(legacyFile);
        int imported = 0;

        foreach (var data in legacyAccounts)
        {
            string? secret = LoadSecretKey(data.Id);
            if (string.IsNullOrEmpty(secret))
                continue; // 시크릿이 없으면 코드를 만들 수 없으므로 건너뜀

            var account = OtpAccountExtensions.NewAccount(
                secret: secret,
                type: data.Type == 1 ? OtpType.Hotp : OtpType.Totp,
                issuer: data.Issuer,
                accountName: string.IsNullOrEmpty(data.AccountName) ? data.Issuer : data.AccountName,
                algorithm: data.Algorithm switch
                {
                    1 => OtpHashAlgorithm.Sha256,
                    2 => OtpHashAlgorithm.Sha512,
                    _ => OtpHashAlgorithm.Sha1
                },
                digits: (uint)(data.Digits <= 0 ? 6 : data.Digits),
                period: (uint)(data.Period <= 0 ? 30 : data.Period),
                counter: (ulong)(data.Counter < 0 ? 0 : data.Counter))
                with
            {
                isFavorite = data.IsFavorite,
                sortOrder = data.SortOrder,
                color = data.Color,
                icon = data.IconPath
            };

            client.AddAccount(account);
            imported++;
        }

        // 레거시 파일 이름 변경 (안전망으로 유지)
        RenameLegacy(legacyFile);
        return imported;
    }

    private static List<LegacyAccountData> ReadLegacyAccounts(string path)
    {
        try
        {
            byte[] encrypted = File.ReadAllBytes(path);
            byte[] plain = ProtectedData.Unprotect(encrypted, null, DataProtectionScope.CurrentUser);
            string json = Encoding.UTF8.GetString(plain);
            return JsonSerializer.Deserialize<List<LegacyAccountData>>(json) ?? new List<LegacyAccountData>();
        }
        catch
        {
            return new List<LegacyAccountData>();
        }
    }

    private string? LoadSecretKey(Guid accountId)
    {
        // 1) PasswordVault 시도
        try
        {
            var vault = new global::Windows.Security.Credentials.PasswordVault();
            var credential = vault.Retrieve(ResourceName, $"{SecretsPrefix}{accountId}");
            credential.RetrievePassword();
            return credential.Password;
        }
        catch
        {
            // 2) DPAPI 폴백 파일
            try
            {
                string key = $"{SecretsPrefix}{accountId}";
                string safeKey = Convert.ToBase64String(Encoding.UTF8.GetBytes(key))
                    .Replace('/', '_')
                    .Replace('+', '-');

                string filePath = Path.Combine(DataDir, "secrets", $"{safeKey}.dat");
                if (!File.Exists(filePath))
                    return null;

                byte[] encrypted = File.ReadAllBytes(filePath);
                byte[] plain = ProtectedData.Unprotect(
                    encrypted, Encoding.UTF8.GetBytes(key), DataProtectionScope.CurrentUser);
                return Encoding.UTF8.GetString(plain);
            }
            catch
            {
                return null;
            }
        }
    }

    private static void RenameLegacy(string legacyFile)
    {
        try
        {
            string target = legacyFile + ".migrated";
            if (File.Exists(target))
                File.Delete(target);
            File.Move(legacyFile, target);
        }
        catch
        {
            // 이름 변경 실패는 치명적이지 않음 (다음 실행에서 볼트가 존재하므로 재마이그레이션 안 함)
        }
    }

    /// <summary>
    /// v1 accounts.dat의 계정 메타데이터 DTO (시크릿 제외). 삭제된 Core.Models와 독립적으로
    /// 자체 정의합니다. enum은 v1에서 정수로 직렬화되었습니다 (Type: Totp=0/Hotp=1,
    /// Algorithm: Sha1=0/Sha256=1/Sha512=2).
    /// </summary>
    private sealed class LegacyAccountData
    {
        public Guid Id { get; set; }
        public string Issuer { get; set; } = string.Empty;
        public string AccountName { get; set; } = string.Empty;
        public int Type { get; set; }
        public int Algorithm { get; set; }
        public int Digits { get; set; }
        public int Period { get; set; }
        public long Counter { get; set; }
        public string? IconPath { get; set; }
        public string? Color { get; set; }
        public int SortOrder { get; set; }
        public bool IsFavorite { get; set; }
        public DateTime CreatedAt { get; set; }
        public DateTime? LastUsedAt { get; set; }
        public string? Notes { get; set; }
        public Guid? FolderId { get; set; }
    }
}
