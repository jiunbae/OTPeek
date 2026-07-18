using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Otpeek.Core.Windows.Services;

namespace Otpeek.Widget;

/// <summary>
/// 위젯 데이터 제공자. v2 볼트를 우선 읽고, 아직 볼트가 없으면 v1 로컬 저장소를 fallback으로 사용합니다.
/// </summary>
public class OtpWidgetDataProvider
{
    public const int MaxVisibleAccounts = 8;
    private const int MaxMediumVisibleAccounts = 5;

    private const string VaultFileName = "vault.otpvault";
    private const string VmkFileName = "vmk.bin";
    private static readonly byte[] VmkEntropy = Encoding.UTF8.GetBytes("Otpeek.Vmk.v2");

    private readonly string _dataDirectory;
    private readonly QuickOtpCodeProvider _codeProvider;
    private readonly object _gate = new();

    private List<QuickOtpCode> _cachedCodes = new();
    private DateTime _lastRefresh = DateTime.MinValue;
    private static readonly TimeSpan CacheExpiry = TimeSpan.FromSeconds(5);

    public OtpWidgetDataProvider()
        : this(Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "Otpeek"))
    {
    }

    internal OtpWidgetDataProvider(string dataDirectory)
    {
        _dataDirectory = dataDirectory;
        _codeProvider = new QuickOtpCodeProvider(dataDirectory);
    }

    /// <summary>
    /// 위젯 데이터 JSON 반환
    /// </summary>
    public string GetWidgetData(
        int index = 0,
        bool copied = false,
        string? copiedAccountId = null)
    {
        lock (_gate)
        {
            RefreshIfNeeded();

            if (_cachedCodes.Count == 0)
                return GetEmptyData();

            index = ClampIndexCore(index);
            var entry = _cachedCodes[index];

            try
            {
                var (icon, hasIcon) = TryLoadFaviconDataUri(entry.Issuer, entry.AccountName);
                int remainingSeconds = CurrentRemainingSeconds(entry);
                bool isHotp = entry.RemainingSeconds == 0 && entry.Progress >= 0.99;
                double timeProgress = CurrentProgress(entry, remainingSeconds);
                var entries = _cachedCodes
                    .Take(MaxVisibleAccounts)
                    .Select((visibleEntry, visibleIndex) =>
                    {
                        var (visibleIcon, visibleHasIcon) = TryLoadFaviconDataUri(
                            visibleEntry.Issuer,
                            visibleEntry.AccountName);
                        int visibleRemainingSeconds = CurrentRemainingSeconds(visibleEntry);
                        bool visibleIsHotp = visibleEntry.RemainingSeconds == 0 &&
                            visibleEntry.Progress >= 0.99;
                        double visibleProgress = CurrentProgress(
                            visibleEntry,
                            visibleRemainingSeconds);
                        bool isCopiedEntry = copied &&
                            string.Equals(
                                visibleEntry.Id,
                                copiedAccountId,
                                StringComparison.Ordinal);

                        return new
                        {
                            accountId = visibleEntry.Id,
                            issuer = string.IsNullOrWhiteSpace(visibleEntry.Issuer)
                                ? "OTP"
                                : visibleEntry.Issuer,
                            accountName = visibleEntry.AccountName,
                            initial = visibleEntry.Initial,
                            icon = visibleIcon,
                            hasIcon = visibleHasIcon,
                            showInMedium = visibleIndex < MaxMediumVisibleAccounts,
                            otpCode = visibleEntry.FormattedCode,
                            progressText = BuildProgressText(visibleProgress),
                            progressColor = !visibleIsHotp && visibleRemainingSeconds < 10
                                ? "attention"
                                : "accent",
                            statusLabel = isCopiedEntry
                                ? "Copied"
                                : visibleIsHotp
                                    ? "HOTP"
                                    : $"{visibleRemainingSeconds}s",
                            statusColor = isCopiedEntry
                                ? "good"
                                : !visibleIsHotp && visibleRemainingSeconds < 10
                                    ? "attention"
                                    : "default"
                        };
                    })
                    .ToList();
                var data = new
                {
                    hasAccount = true,
                    accountId = entry.Id,
                    issuer = string.IsNullOrWhiteSpace(entry.Issuer) ? "OTP" : entry.Issuer,
                    accountName = entry.AccountName,
                    initial = entry.Initial,
                    icon,
                    hasIcon,
                    otpCode = entry.FormattedCode,
                    timeProgress,
                    progressText = BuildProgressText(timeProgress),
                    remainingSeconds,
                    countdownLabel = isHotp ? "HOTP" : $"{remainingSeconds}s",
                    countdownColor = !isHotp && remainingSeconds < 10 ? "attention" : "default",
                    progressColor = !isHotp && remainingSeconds < 10 ? "attention" : "accent",
                    accountCount = _cachedCodes.Count,
                    currentIndex = index + 1,
                    positionLabel = $"{index + 1} / {_cachedCodes.Count}",
                    copyLabel = copied ? "Copied" : "Copy",
                    copyStyle = copied ? "positive" : "default",
                    hasNext = index < _cachedCodes.Count - 1,
                    hasPrev = index > 0,
                    visibleAccountCount = entries.Count,
                    entries
                };

                return JsonSerializer.Serialize(data);
            }
            catch (Exception ex)
            {
                WidgetDiagnostics.LogException("Data", "Build widget data", ex);
                return GetEmptyData();
            }
        }
    }

    /// <summary>
    /// Returns a stable index for the current cache. This is used by widget actions so
    /// repeatedly pressing Next at the final account never creates hidden index debt.
    /// </summary>
    public int ClampIndex(int index)
    {
        lock (_gate)
        {
            RefreshIfNeeded();
            return ClampIndexCore(index);
        }
    }

    /// <summary>Restores the same account after a provider restart or vault reorder.</summary>
    public int ResolveIndex(int fallbackIndex, string? preferredAccountId)
    {
        lock (_gate)
        {
            RefreshIfNeeded();
            if (!string.IsNullOrWhiteSpace(preferredAccountId))
            {
                int matchedIndex = _cachedCodes.FindIndex(code => code.Id == preferredAccountId);
                if (matchedIndex >= 0)
                    return matchedIndex;
            }

            return ClampIndexCore(fallbackIndex);
        }
    }

    public string? GetAccountId(int index)
    {
        lock (_gate)
        {
            RefreshIfNeeded();
            return _cachedCodes.Count == 0 ? null : _cachedCodes[ClampIndexCore(index)].Id;
        }
    }

    /// <summary>
    /// Reopens the vault at click time so Copy never places an expired code from the
    /// rendered card payload onto the clipboard.
    /// </summary>
    public bool TryGetFreshCode(int fallbackIndex, string? expectedAccountId, out string code)
    {
        lock (_gate)
        {
            _lastRefresh = DateTime.MinValue;
            RefreshIfNeeded();
            code = string.Empty;
            if (_cachedCodes.Count == 0)
                return false;

            int index;
            if (!string.IsNullOrWhiteSpace(expectedAccountId))
            {
                index = _cachedCodes.FindIndex(code => code.Id == expectedAccountId);
                if (index < 0)
                    return false;
            }
            else
            {
                index = ClampIndexCore(fallbackIndex);
            }

            code = _cachedCodes[index].Code;
            return code.Length > 0 && code.All(char.IsDigit);
        }
    }

    /// <summary>Forces the next read to reopen the vault and generate fresh codes.</summary>
    public void Invalidate()
    {
        lock (_gate)
            _lastRefresh = DateTime.MinValue;
    }

    /// <summary>
    /// Returns a one-shot delay that lands just after the earliest TOTP boundary used
    /// by either the compact single-account view or the three-account list.
    /// Empty widgets poll slowly so adding the first account is eventually reflected.
    /// </summary>
    public TimeSpan GetNextRefreshDelay(int index)
    {
        lock (_gate)
        {
            RefreshIfNeeded();
            if (_cachedCodes.Count == 0)
                return TimeSpan.FromSeconds(30);

            var visibleEntries = _cachedCodes
                .Take(MaxVisibleAccounts)
                .Append(_cachedCodes[ClampIndexCore(index)])
                .DistinctBy(entry => entry.Id);

            int seconds = visibleEntries
                .Select(entry => entry.RemainingSeconds == 0 && entry.Progress >= 0.99
                    ? 30
                    : Math.Clamp(CurrentRemainingSeconds(entry) + 1, 1, 120))
                .Min();
            return TimeSpan.FromSeconds(seconds);
        }
    }

    private int ClampIndexCore(int index) => _cachedCodes.Count == 0
        ? 0
        : Math.Clamp(index, 0, _cachedCodes.Count - 1);

    private int ResolveIndexCore(int fallbackIndex, string? preferredAccountId)
    {
        if (!string.IsNullOrWhiteSpace(preferredAccountId))
        {
            int matchedIndex = _cachedCodes.FindIndex(code => code.Id == preferredAccountId);
            if (matchedIndex >= 0)
                return matchedIndex;
        }

        return ClampIndexCore(fallbackIndex);
    }

    private int CurrentRemainingSeconds(QuickOtpCode entry)
    {
        int elapsed = _lastRefresh == DateTime.MinValue
            ? 0
            : Math.Max(0, (int)(DateTime.UtcNow - _lastRefresh).TotalSeconds);
        return Math.Max(0, entry.RemainingSeconds - elapsed);
    }

    private static double CurrentProgress(QuickOtpCode entry, int remainingSeconds)
    {
        if (entry.RemainingSeconds == 0 && entry.Progress >= 0.99)
            return 1.0;
        if (entry.Progress <= 0 || entry.RemainingSeconds <= 0)
            return 0.0;

        double estimatedPeriod = entry.RemainingSeconds / entry.Progress;
        return Math.Clamp(remainingSeconds / Math.Max(1.0, estimatedPeriod), 0.0, 1.0);
    }

    private static string BuildProgressText(double progress)
    {
        const int segmentCount = 12;
        int filled = Math.Clamp((int)Math.Round(progress * segmentCount), 0, segmentCount);
        return new string('━', filled) + new string('─', segmentCount - filled);
    }

    /// <summary>
    /// 캐시된 파비콘(앱이 받아둔 것)을 data URI 로 읽어온다. 위젯은 다운로드하지 않고
    /// 캐시만 읽으며, 없거나 Adaptive Cards가 지원하지 않는 형식이면 이니셜로 폴백한다.
    /// 카드 payload가 과도하게 커지지 않도록 크기를 제한한다.
    /// </summary>
    private static (string icon, bool hasIcon) TryLoadFaviconDataUri(string? issuer, string? accountName)
    {
        try
        {
            var domain = FaviconService.ResolveDomain(issuer, accountName);
            if (string.IsNullOrEmpty(domain)) return (string.Empty, false);
            var path = FaviconService.CachedPath(domain);
            if (path == null) return (string.Empty, false);

            var bytes = File.ReadAllBytes(path);
            if (bytes.Length == 0 || bytes.Length > 96_000) return (string.Empty, false);

            string? mimeType = GetAdaptiveCardImageMimeType(bytes);
            if (mimeType == null) return (string.Empty, false);

            return ($"data:{mimeType};base64," + Convert.ToBase64String(bytes), true);
        }
        catch
        {
            return (string.Empty, false);
        }
    }

    private static string? GetAdaptiveCardImageMimeType(ReadOnlySpan<byte> bytes)
    {
        if (bytes.Length >= 8 &&
            bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4E && bytes[3] == 0x47 &&
            bytes[4] == 0x0D && bytes[5] == 0x0A && bytes[6] == 0x1A && bytes[7] == 0x0A)
        {
            return "image/png";
        }

        if (bytes.Length >= 3 && bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF)
            return "image/jpeg";

        if (bytes.Length >= 6 &&
            bytes[0] == (byte)'G' && bytes[1] == (byte)'I' && bytes[2] == (byte)'F' &&
            bytes[3] == (byte)'8' && (bytes[4] == (byte)'7' || bytes[4] == (byte)'9') &&
            bytes[5] == (byte)'a')
        {
            return "image/gif";
        }

        return null;
    }

    private string GetEmptyData()
    {
        bool vaultPresent = File.Exists(Path.Combine(_dataDirectory, VaultFileName));
        bool keyPresent = File.Exists(Path.Combine(_dataDirectory, VmkFileName));
        string emptyMessage = vaultPresent && !keyPresent
            ? "Open OTPeek to unlock the vault"
            : "Add or favorite an account in OTPeek";

        var data = new
        {
            hasAccount = false,
            accountId = string.Empty,
            issuer = "OTPeek",
            accountName = emptyMessage,
            initial = "O",
            icon = string.Empty,
            hasIcon = false,
            otpCode = "--- ---",
            timeProgress = 1.0,
            progressText = BuildProgressText(1.0),
            remainingSeconds = 30,
            countdownLabel = string.Empty,
            countdownColor = "default",
            progressColor = "accent",
            accountCount = 0,
            currentIndex = 0,
            positionLabel = string.Empty,
            copyLabel = "Copy",
            copyStyle = "default",
            hasNext = false,
            hasPrev = false,
            visibleAccountCount = 0,
            entries = Array.Empty<object>()
        };

        return JsonSerializer.Serialize(data);
    }

    private void RefreshIfNeeded()
    {
        if (DateTime.UtcNow - _lastRefresh < CacheExpiry)
            return;

        try
        {
            _cachedCodes = _codeProvider.GetCodes(maxCount: 20).ToList();
            _lastRefresh = DateTime.UtcNow;
            WidgetDiagnostics.Log("Data", $"Refreshed; codeCount={_cachedCodes.Count}, " +
                $"vaultPresent={File.Exists(Path.Combine(_dataDirectory, VaultFileName))}, " +
                $"keyPresent={File.Exists(Path.Combine(_dataDirectory, VmkFileName))}");
        }
        catch (Exception ex)
        {
            WidgetDiagnostics.LogException("Data", "Refresh vault", ex);
            _cachedCodes = new List<QuickOtpCode>();
            _lastRefresh = DateTime.UtcNow;
        }
    }

    /// <summary>
    /// Probes the exact CurrentUser DPAPI VMK path used by the app without logging or
    /// retaining key bytes. A missing vault/key is a valid first-run state.
    /// </summary>
    internal void ValidateStorageAccess()
    {
        string vmkPath = Path.Combine(_dataDirectory, VmkFileName);
        string vaultPath = Path.Combine(_dataDirectory, VaultFileName);
        if (!File.Exists(vmkPath))
        {
            WidgetDiagnostics.Log("Diagnostics", $"Storage probe: vaultPresent={File.Exists(vaultPath)}, keyPresent=False");
            return;
        }

        byte[]? vmk = null;
        try
        {
            byte[] encrypted = File.ReadAllBytes(vmkPath);
            vmk = ProtectedData.Unprotect(encrypted, VmkEntropy, DataProtectionScope.CurrentUser);
            if (vmk.Length != 32)
                throw new CryptographicException("The DPAPI vault key has an unexpected length.");

            WidgetDiagnostics.Log("Diagnostics", $"Storage probe: vaultPresent={File.Exists(vaultPath)}, keyPresent=True, dpapi=True");
        }
        finally
        {
            if (vmk != null)
                CryptographicOperations.ZeroMemory(vmk);
        }
    }
}
