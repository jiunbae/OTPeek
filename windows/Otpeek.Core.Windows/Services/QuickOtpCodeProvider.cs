using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Uniffi.Otpeek;
using OtpHashAlgorithm = Uniffi.Otpeek.HashAlgorithm;

namespace Otpeek.Core.Windows.Services;

public sealed record QuickOtpCode(
    string Id,
    string Issuer,
    string AccountName,
    string Initial,
    string Code,
    string FormattedCode,
    int RemainingSeconds,
    double Progress,
    bool IsFavorite,
    int SortOrder);

/// <summary>
/// Reads OTP codes for quick surfaces such as widgets and tray menus.
/// It prefers the v2 vault, then falls back to the v1 local store when no vault is available.
/// </summary>
public sealed class QuickOtpCodeProvider
{
    private const string VmkFileName = "vmk.bin";
    private const string VaultFileName = "vault.otpvault";
    private const string ResourceName = "Otpeek";
    private const string SecretsPrefix = "secret_";

    private static readonly byte[] VmkEntropy = Encoding.UTF8.GetBytes("Otpeek.Vmk.v2");
    private static readonly JsonSerializerOptions JsonOptions = new() { PropertyNameCaseInsensitive = true };

    private readonly string _dataDirectory;

    public QuickOtpCodeProvider()
        : this(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Otpeek"))
    {
    }

    public QuickOtpCodeProvider(string dataDirectory)
    {
        _dataDirectory = dataDirectory;
    }

    public IReadOnlyList<QuickOtpCode> GetCodes(int maxCount = 10)
    {
        // The presence of the v2 vault is the migration boundary. An empty vault is a
        // valid state (for example, after the user deleted every account), and a vault
        // that cannot currently be opened must fail closed. Falling back merely because
        // no codes were returned could resurrect secrets from *.migrated legacy files.
        string vaultPath = Path.Combine(_dataDirectory, VaultFileName);
        var codes = File.Exists(vaultPath)
            ? LoadVaultCodes()
            : LoadLegacyCodes();

        return codes
            .OrderByDescending(c => c.IsFavorite)
            .ThenBy(c => c.SortOrder)
            .Take(maxCount)
            .ToList();
    }

    private List<QuickOtpCode> LoadVaultCodes()
    {
        string vaultPath = Path.Combine(_dataDirectory, VaultFileName);
        string vmkPath = Path.Combine(_dataDirectory, VmkFileName);
        if (!File.Exists(vaultPath) || !File.Exists(vmkPath))
            return new List<QuickOtpCode>();

        try
        {
            byte[] encrypted = File.ReadAllBytes(vmkPath);
            byte[] vmk = ProtectedData.Unprotect(encrypted, VmkEntropy, DataProtectionScope.CurrentUser);
            long nowMs = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();

            using var client = OtpClient.OpenWithKey(vaultPath, vmk);
            return client.CodesAt(nowMs)
                .Select(c => FromVaultCode(c, nowMs))
                .ToList();
        }
        catch
        {
            return new List<QuickOtpCode>();
        }
    }

    private static QuickOtpCode FromVaultCode(AccountCode accountCode, long nowMs)
    {
        var account = accountCode.account;
        var code = accountCode.code;
        long periodMs = Math.Max(1, code.validUntil - code.validFrom);
        double progress = Math.Clamp((double)(code.validUntil - nowMs) / periodMs, 0.0, 1.0);
        int remainingSeconds = (int)Math.Max(0, (code.validUntil - nowMs) / 1000);
        string issuer = account.issuer ?? string.Empty;
        string accountName = account.accountName;

        return new QuickOtpCode(
            account.id,
            issuer,
            accountName,
            ComputeInitial(issuer, accountName),
            code.code,
            FormatCode(code.code),
            remainingSeconds,
            progress,
            account.isFavorite,
            account.sortOrder);
    }

    private List<QuickOtpCode> LoadLegacyCodes()
    {
        string? legacyFile = LegacyAccountFiles().FirstOrDefault(File.Exists);
        if (legacyFile == null)
            return new List<QuickOtpCode>();

        try
        {
            byte[] encrypted = File.ReadAllBytes(legacyFile);
            byte[] plain = ProtectedData.Unprotect(encrypted, null, DataProtectionScope.CurrentUser);
            string json = Encoding.UTF8.GetString(plain);
            var accounts = JsonSerializer.Deserialize<List<LegacyAccountData>>(json, JsonOptions) ?? new List<LegacyAccountData>();

            long nowSecs = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
            var codes = new List<QuickOtpCode>();

            foreach (var account in accounts)
            {
                string? secret = LoadLegacySecret(account.Id);
                if (string.IsNullOrWhiteSpace(secret))
                    continue;

                var code = GenerateLegacyCode(account, secret, nowSecs);
                if (string.IsNullOrWhiteSpace(code.Code))
                    continue;

                string issuer = account.Issuer ?? string.Empty;
                string accountName = string.IsNullOrWhiteSpace(account.AccountName) ? issuer : account.AccountName;
                codes.Add(new QuickOtpCode(
                    account.Id.ToString(),
                    issuer,
                    accountName,
                    ComputeInitial(issuer, accountName),
                    code.Code,
                    FormatCode(code.Code),
                    code.RemainingSeconds,
                    code.Progress,
                    account.IsFavorite,
                    account.SortOrder));
            }

            return codes;
        }
        catch
        {
            return new List<QuickOtpCode>();
        }
    }

    private IEnumerable<string> LegacyAccountFiles()
    {
        yield return Path.Combine(_dataDirectory, "accounts.dat");
        yield return Path.Combine(_dataDirectory, "accounts.json");
        yield return Path.Combine(_dataDirectory, "accounts.dat.migrated");
        yield return Path.Combine(_dataDirectory, "accounts.json.migrated");
    }

    private (string Code, int RemainingSeconds, double Progress) GenerateLegacyCode(LegacyAccountData account, string secret, long nowSecs)
    {
        uint digits = (uint)(account.Digits <= 0 ? 6 : account.Digits);
        var algorithm = account.Algorithm switch
        {
            1 => OtpHashAlgorithm.Sha256,
            2 => OtpHashAlgorithm.Sha512,
            _ => OtpHashAlgorithm.Sha1
        };

        if (account.Type == 1)
        {
            string code = GenerateHotp(secret, algorithm, digits, (ulong)Math.Max(0, account.Counter));
            return (code, 0, 1.0);
        }

        uint period = (uint)(account.Period <= 0 ? 30 : account.Period);
        try
        {
            string code = OtpeekMethods.GenerateTotpNow(secret, algorithm, digits, period, nowSecs);
            int remainingSeconds = (int)(period - (nowSecs % period));
            double progress = period > 0 ? (double)remainingSeconds / period : 1.0;
            return (code, remainingSeconds, progress);
        }
        catch
        {
            return (string.Empty, 0, 0);
        }
    }

    private string? LoadLegacySecret(Guid accountId)
    {
        string key = $"{SecretsPrefix}{accountId}";

        try
        {
            var vault = new global::Windows.Security.Credentials.PasswordVault();
            var credential = vault.Retrieve(ResourceName, key);
            credential.RetrievePassword();
            if (!string.IsNullOrWhiteSpace(credential.Password))
                return credential.Password;
        }
        catch
        {
        }

        try
        {
            string safeKey = Convert.ToBase64String(Encoding.UTF8.GetBytes(key))
                .Replace('/', '_')
                .Replace('+', '-');
            string filePath = Path.Combine(_dataDirectory, "secrets", $"{safeKey}.dat");
            if (!File.Exists(filePath))
                return null;

            byte[] encrypted = File.ReadAllBytes(filePath);
            byte[] plain = ProtectedData.Unprotect(encrypted, Encoding.UTF8.GetBytes(key), DataProtectionScope.CurrentUser);
            return Encoding.UTF8.GetString(plain);
        }
        catch
        {
            return null;
        }
    }

    private static string GenerateHotp(string secret, OtpHashAlgorithm algorithm, uint digits, ulong counter)
    {
        byte[] secretBytes = DecodeBase32(secret);
        byte[] counterBytes = BitConverter.GetBytes(counter);
        if (BitConverter.IsLittleEndian)
            Array.Reverse(counterBytes);

        using HMAC hmac = algorithm switch
        {
            OtpHashAlgorithm.Sha256 => new HMACSHA256(secretBytes),
            OtpHashAlgorithm.Sha512 => new HMACSHA512(secretBytes),
            _ => new HMACSHA1(secretBytes)
        };

        byte[] hash = hmac.ComputeHash(counterBytes);
        int offset = hash[^1] & 0x0f;
        int binary =
            ((hash[offset] & 0x7f) << 24) |
            ((hash[offset + 1] & 0xff) << 16) |
            ((hash[offset + 2] & 0xff) << 8) |
            (hash[offset + 3] & 0xff);

        int modulo = (int)Math.Pow(10, Math.Clamp(digits, 1, 9));
        int otp = binary % modulo;
        return otp.ToString(new string('0', (int)Math.Clamp(digits, 1, 9)));
    }

    private static byte[] DecodeBase32(string value)
    {
        string input = new(value
            .Where(c => !char.IsWhiteSpace(c) && c != '=' && c != '-')
            .Select(char.ToUpperInvariant)
            .ToArray());

        var output = new List<byte>();
        int buffer = 0;
        int bitsLeft = 0;

        foreach (char c in input)
        {
            int val = c switch
            {
                >= 'A' and <= 'Z' => c - 'A',
                >= '2' and <= '7' => c - '2' + 26,
                _ => throw new FormatException("Invalid Base32 character.")
            };

            buffer = (buffer << 5) | val;
            bitsLeft += 5;

            if (bitsLeft >= 8)
            {
                output.Add((byte)((buffer >> (bitsLeft - 8)) & 0xff));
                bitsLeft -= 8;
            }
        }

        return output.ToArray();
    }

    public static string FormatCode(string code)
    {
        if (code.Length == 6)
            return $"{code[..3]} {code[3..]}";
        if (code.Length == 8)
            return $"{code[..4]} {code[4..]}";
        return code;
    }

    private static string ComputeInitial(string? issuer, string? accountName)
    {
        if (!string.IsNullOrWhiteSpace(issuer))
            return issuer[..1].ToUpperInvariant();
        if (!string.IsNullOrWhiteSpace(accountName))
            return accountName[..1].ToUpperInvariant();
        return "?";
    }

    private sealed class LegacyAccountData
    {
        public Guid Id { get; set; }
        public string? Issuer { get; set; }
        public string AccountName { get; set; } = string.Empty;
        public int Type { get; set; }
        public int Algorithm { get; set; }
        public int Digits { get; set; }
        public int Period { get; set; }
        public long Counter { get; set; }
        public int SortOrder { get; set; }
        public bool IsFavorite { get; set; }
    }
}
