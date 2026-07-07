using System.Text.Json;
using Otpeek.Core.Windows.Services;

namespace Otpeek.Widget;

/// <summary>
/// 위젯 데이터 제공자. v2 볼트를 우선 읽고, 아직 볼트가 없으면 v1 로컬 저장소를 fallback으로 사용합니다.
/// </summary>
public class OtpWidgetDataProvider
{
    private readonly QuickOtpCodeProvider _codeProvider = new();

    private List<QuickOtpCode> _cachedCodes = new();
    private DateTime _lastRefresh = DateTime.MinValue;
    private static readonly TimeSpan CacheExpiry = TimeSpan.FromSeconds(5);

    private static void Log(string message)
    {
        try
        {
            var logPath = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "Otpeek", "widget.log");
            Directory.CreateDirectory(Path.GetDirectoryName(logPath)!);
            File.AppendAllText(logPath, $"[{DateTime.Now:yyyy-MM-dd HH:mm:ss}] [Data] {message}\n");
        }
        catch
        {
        }
    }

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
            var (icon, hasIcon) = TryLoadFaviconDataUri(entry.Issuer, entry.AccountName);
            var data = new
            {
                issuer = string.IsNullOrWhiteSpace(entry.Issuer) ? "OTP" : entry.Issuer,
                accountName = entry.AccountName,
                initial = entry.Initial,
                icon,
                hasIcon,
                otpCode = entry.FormattedCode,
                rawCode = entry.Code,
                timeProgress = entry.Progress,
                remainingSeconds = entry.RemainingSeconds,
                progressColor = entry.Progress > 0.3 ? "accent" : "attention",
                accountCount = _cachedCodes.Count,
                currentIndex = index + 1,
                hasNext = index < _cachedCodes.Count - 1,
                hasPrev = index > 0
            };

            return JsonSerializer.Serialize(data);
        }
        catch (Exception ex)
        {
            Log($"GetWidgetData failed: {ex.GetType().Name}: {ex.Message}");
            return GetEmptyData();
        }
    }

    /// <summary>
    /// 캐시된 파비콘(앱이 받아둔 것)을 data URI 로 읽어온다. 위젯은 다운로드하지 않고
    /// 캐시만 읽으며, 없으면 이니셜로 폴백한다. 어댑티브 카드 payload 가 과도하게
    /// 커지지 않도록 크기를 제한한다.
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
            return ("data:image/png;base64," + Convert.ToBase64String(bytes), true);
        }
        catch
        {
            return (string.Empty, false);
        }
    }

    private static string GetEmptyData()
    {
        var data = new
        {
            issuer = "OTPeek",
            accountName = "No accounts",
            initial = "?",
            icon = string.Empty,
            hasIcon = false,
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
            _cachedCodes = _codeProvider.GetCodes(maxCount: 20).ToList();
            _lastRefresh = DateTime.UtcNow;
            Log($"Refreshed {_cachedCodes.Count} OTP code(s)");
        }
        catch (Exception ex)
        {
            Log($"Refresh failed: {ex.GetType().Name}: {ex.Message}");
            _lastRefresh = DateTime.UtcNow;
        }
    }
}
