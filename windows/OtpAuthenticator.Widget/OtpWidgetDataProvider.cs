using System.Text.Json;
using OtpAuthenticator.Core.Windows.Services;

namespace OtpAuthenticator.Widget;

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
                "OtpAuthenticator", "widget.log");
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
            var data = new
            {
                issuer = string.IsNullOrWhiteSpace(entry.Issuer) ? "OTP" : entry.Issuer,
                accountName = entry.AccountName,
                initial = entry.Initial,
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
