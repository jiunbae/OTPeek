using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Uniffi.Otp;

namespace OtpAuthenticator.Widget;

/// <summary>
/// 위젯 데이터 제공자.
/// DPAPI로 보호된 VMK로 볼트를 열고(OtpClient.OpenWithKey), CodesAt로 모든 TOTP 코드를
/// 조회합니다. 위젯 프로세스에서는 Argon2를 실행하지 않으며 마스터 비밀번호도 다루지 않습니다.
/// (docs/ARCHITECTURE.md §5.1, §10.5)
/// </summary>
public class OtpWidgetDataProvider
{
    // SecureStorageService와 동일해야 하는 상수
    private static readonly byte[] VmkEntropy = Encoding.UTF8.GetBytes("OtpAuthenticator.Vmk.v2");

    private List<AccountCode> _cachedCodes = new();
    private DateTime _lastRefresh = DateTime.MinValue;
    private static readonly TimeSpan CacheExpiry = TimeSpan.FromSeconds(5);

    /// <summary>
    /// 위젯 데이터 JSON 반환
    /// </summary>
    public string GetWidgetData(int index = 0)
    {
        RefreshIfNeeded();

        if (_cachedCodes.Count == 0)
            return GetEmptyData();

        index = Math.Max(0, Math.Min(index, _cachedCodes.Count - 1));
        var entry = _cachedCodes[index];

        try
        {
            var account = entry.account;
            var otp = entry.code;

            string raw = otp.code;
            string formattedCode = raw.Length == 6
                ? $"{raw[..3]} {raw[3..]}"
                : (raw.Length == 8 ? $"{raw[..4]} {raw[4..]}" : raw);

            long nowMs = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
            long periodMs = Math.Max(1, otp.validUntil - otp.validFrom);
            double progress = Math.Clamp((double)(otp.validUntil - nowMs) / periodMs, 0.0, 1.0);
            int remainingSeconds = (int)Math.Max(0, (otp.validUntil - nowMs) / 1000);

            string issuer = string.IsNullOrEmpty(account.issuer) ? "OTP" : account.issuer!;
            string initial = ComputeInitial(account);

            var data = new
            {
                issuer,
                accountName = account.accountName,
                initial,
                otpCode = formattedCode,
                rawCode = raw,
                timeProgress = progress,
                remainingSeconds,
                progressColor = progress > 0.3 ? "accent" : "attention",
                accountCount = _cachedCodes.Count,
                currentIndex = index + 1,
                hasNext = index < _cachedCodes.Count - 1,
                hasPrev = index > 0
            };

            return JsonSerializer.Serialize(data);
        }
        catch
        {
            return GetEmptyData();
        }
    }

    private static string ComputeInitial(OtpAccount account)
    {
        if (!string.IsNullOrEmpty(account.issuer))
            return account.issuer![..1].ToUpperInvariant();
        if (!string.IsNullOrEmpty(account.accountName))
            return account.accountName[..1].ToUpperInvariant();
        return "?";
    }

    private static string GetEmptyData()
    {
        var data = new
        {
            issuer = "OTP Authenticator",
            accountName = "No accounts",
            initial = "?",
            otpCode = "--- ---",
            rawCode = "",
            timeProgress = 1.0,
            remainingSeconds = 30,
            progressColor = "accent",
            accountCount = 0,
            currentIndex = 0,
            hasNext = false,
            hasPrev = false
        };

        return JsonSerializer.Serialize(data);
    }

    private void RefreshIfNeeded()
    {
        if (DateTime.UtcNow - _lastRefresh < CacheExpiry)
            return;

        try
        {
            byte[]? vmk = LoadVaultKey();
            if (vmk == null)
            {
                _cachedCodes = new List<AccountCode>();
                _lastRefresh = DateTime.UtcNow;
                return;
            }

            using var client = OtpClient.OpenWithKey(VaultPath, vmk);
            long nowMs = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();

            // 즐겨찾기 우선, 그 다음 정렬 순서
            _cachedCodes = client.CodesAt(nowMs)
                .OrderByDescending(c => c.account.isFavorite)
                .ThenBy(c => c.account.sortOrder)
                .ToList();

            _lastRefresh = DateTime.UtcNow;
        }
        catch
        {
            // 로드 실패 시 기존 캐시 유지
        }
    }

    private static string DataDirectory => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "OtpAuthenticator");

    private static string VaultPath => Path.Combine(DataDirectory, "vault.otpvault");

    private static string VmkPath => Path.Combine(DataDirectory, "vmk.bin");

    private static byte[]? LoadVaultKey()
    {
        try
        {
            if (!File.Exists(VmkPath))
                return null;

            byte[] encrypted = File.ReadAllBytes(VmkPath);
            return ProtectedData.Unprotect(encrypted, VmkEntropy, DataProtectionScope.CurrentUser);
        }
        catch
        {
            return null;
        }
    }
}
