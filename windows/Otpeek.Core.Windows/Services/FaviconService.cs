using System.Collections.Concurrent;
using System.Drawing;
using Otpeek.Core.Services.Interfaces;
using Uniffi.Otpeek;

namespace Otpeek.Core.Windows.Services;

/// <summary>
/// <see cref="IFaviconService"/> 구현. 우선순위 소스에서 고화질 로고를 받아
/// %LOCALAPPDATA%\Otpeek\Favicons 에 캐시합니다. iOS/macOS 와 동일한 소스/우선순위.
/// </summary>
public sealed class FaviconService : IFaviconService
{
    private static readonly HttpClient Http = CreateClient();

    /// <summary>파비콘 캐시 폴더(앱·위젯 공유). %LOCALAPPDATA%\Otpeek\Favicons.</summary>
    public static readonly string CacheDir = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "Otpeek", "Favicons");

    private static readonly TimeSpan FailTtl = TimeSpan.FromHours(6);

    private readonly ISettingsService _settings;
    private readonly ConcurrentDictionary<string, Task<string?>> _inflight = new();
    // 최근 실패한 도메인(네거티브 캐시). 매 리로드마다 4-URL 을 다시 때리지 않도록 한다.
    private readonly ConcurrentDictionary<string, DateTime> _failed = new();

    public FaviconService(ISettingsService settings)
    {
        _settings = settings;
        Directory.CreateDirectory(CacheDir);
    }

    private static HttpClient CreateClient()
    {
        var c = new HttpClient { Timeout = TimeSpan.FromSeconds(8) };
        // 일부 로고 서비스는 UA 없는 요청을 거부한다.
        c.DefaultRequestHeaders.TryAddWithoutValidation("User-Agent", "Otpeek/1.0");
        return c;
    }

    public bool Enabled => _settings.Settings.ShowFavicons;

    // ------------------------------------------------------------------
    // 도메인 해석 (iOS/macOS FaviconProvider.domain(for:) 포팅)
    // ------------------------------------------------------------------

    /// 표시 이름이 도메인으로 깔끔히 매핑되지 않는 알려진 서비스.
    /// 부분일치(Contains)이므로 더 구체적인 키("amazon web services")를 먼저 둔다.
    private static readonly (string Key, string Domain)[] Known =
    {
        ("amazon web services", "aws.amazon.com"),
        ("aws", "aws.amazon.com"),
        ("visit japan web", "vjw-lp.digital.go.jp"),
        ("electronic arts", "ea.com"),
        ("google", "google.com"),
        ("github", "github.com"),
        ("gitlab", "gitlab.com"),
        ("amazon", "amazon.com"),
        ("cloudflare", "cloudflare.com"),
        ("discord", "discord.com"),
        ("facebook", "facebook.com"),
        ("twitter", "x.com"),
        ("linkedin", "linkedin.com"),
        ("notion", "notion.so"),
        ("bitwarden", "bitwarden.com"),
        ("tumblr", "tumblr.com"),
        ("pixiv", "pixiv.net"),
        ("nvidia", "nvidia.com"),
        ("mathworks", "mathworks.com"),
        ("mailgun", "mailgun.com"),
        ("proxmox", "proxmox.com"),
        ("plaync", "plaync.com"),
        ("bithumb", "bithumb.com"),
        ("coinrail", "coinrail.co.kr"),
        ("coinnest", "coinnest.co.kr"),
        ("coinlink", "coinlink.co.kr"),
        ("miningpoolhub", "miningpoolhub.com"),
        ("pypi", "pypi.org"),
        ("microsoft", "microsoft.com"),
        ("apple", "apple.com"),
        ("dropbox", "dropbox.com"),
        ("slack", "slack.com"),
        ("steam", "steampowered.com"),
        ("reddit", "reddit.com"),
        ("paypal", "paypal.com"),
        ("instagram", "instagram.com"),
        ("binance", "binance.com"),
        ("coinbase", "coinbase.com"),
        ("upbit", "upbit.com"),
    };

    private static readonly HashSet<string> GenericMailHosts = new(StringComparer.OrdinalIgnoreCase)
    {
        "gmail.com", "googlemail.com", "naver.com", "outlook.com", "hotmail.com",
        "yahoo.com", "icloud.com", "me.com", "proton.me", "protonmail.com",
    };

    public string? DomainFor(OtpAccount account) => Resolve(account)?.Domain;

    public (string Domain, bool Confident)? Resolve(OtpAccount account)
        => ResolveInfo(account.issuer, account.accountName);

    /// <summary>발행처/계정명만으로 도메인만 해석(위젯 캐시 조회 등, 확신여부 불필요).</summary>
    public static string? ResolveDomain(string? issuer, string? accountName)
        => ResolveInfo(issuer, accountName)?.Domain;

    /// <summary>
    /// 도메인 + 확신여부. Confident=true(Known/실도메인/이메일)면 전체 소스, false(단순 추측)면
    /// 브랜드 로고만. 추측은 issuer 가 '한 단어'일 때만(다단어는 오매칭이 잦다).
    /// </summary>
    public static (string Domain, bool Confident)? ResolveInfo(string? issuer, string? accountName)
    {
        issuer = (issuer ?? string.Empty).Trim();
        var name = accountName ?? string.Empty;

        foreach (var source in new[] { issuer, name })
        {
            var lower = source.ToLowerInvariant();
            if (string.IsNullOrEmpty(lower)) continue;

            foreach (var (key, dom) in Known)
                if (lower.Contains(key)) return (dom, true);

            // 이미 도메인처럼 보이는 경우("pixiv.net").
            if (!lower.Contains(' ') && lower.Contains('.') && !lower.Contains('@'))
                return (lower, true);

            // 이메일 계정명 → 일반 메일 호스트가 아니면 그 도메인 사용.
            var at = lower.IndexOf('@');
            if (at >= 0)
            {
                var host = lower[(at + 1)..];
                if (!GenericMailHosts.Contains(host)) return (host, true);
            }
        }

        var words = issuer.ToLowerInvariant().Split(' ', StringSplitOptions.RemoveEmptyEntries);
        if (words.Length == 1) return ($"{words[0]}.com", false);
        return null;
    }

    // ------------------------------------------------------------------
    // 캐시 + 다운로드
    // ------------------------------------------------------------------

    private static string FileFor(string domain)
        => Path.Combine(CacheDir, domain.Replace('/', '_') + ".png");

    public string? CachedIconPath(string domain) => CachedPath(domain);

    /// <summary>도메인의 캐시된 파비콘 파일 경로(없으면 null). 정적 — 위젯에서도 사용.</summary>
    public static string? CachedPath(string domain)
    {
        var f = FileFor(domain);
        return File.Exists(f) && new FileInfo(f).Length > 0 ? f : null;
    }

    public Task<string?> GetIconPathAsync(string domain, bool brandOnly = false, CancellationToken ct = default)
    {
        var cached = CachedIconPath(domain);
        if (cached != null) return Task.FromResult<string?>(cached);
        // 최근 실패한 도메인은 TTL 동안 재시도하지 않는다(다운로드 폭주 방지).
        if (_failed.TryGetValue(domain, out var when) && DateTime.UtcNow - when < FailTtl)
            return Task.FromResult<string?>(null);
        return _inflight.GetOrAdd(domain, d => DownloadAsync(d, brandOnly, ct));
    }

    /// <summary>
    /// 화질 우선순위로 시도: Clearbit(실제 브랜드 로고 256px) → icon.horse(대개 512) →
    /// Google s2 256/128. 이미 충분히 크면(≥128px) 즉시 채택, 모두 작으면 가장 큰 것.
    /// </summary>
    private async Task<string?> DownloadAsync(string domain, bool brandOnly, CancellationToken ct)
    {
        // 추측 도메인(brandOnly)은 Clearbit 만: 없으면 404 → 이니셜(엉뚱한 로고 방지).
        string[] sources = brandOnly
            ? new[] { $"https://logo.clearbit.com/{domain}?size=256&format=png" }
            : new[]
            {
                $"https://logo.clearbit.com/{domain}?size=256&format=png",
                $"https://icon.horse/icon/{domain}",
                $"https://www.google.com/s2/favicons?domain={domain}&sz=256",
                $"https://www.google.com/s2/favicons?domain={domain}&sz=128",
            };

        byte[]? best = null;
        int bestDim = 0;
        try
        {
            foreach (var url in sources)
            {
                byte[]? bytes = await TryFetchAsync(url, ct);
                if (bytes == null) continue;
                int dim = PixelDimension(bytes);
                if (dim >= 128) { best = bytes; break; }      // 선명 → 채택
                // dim==0 은 GDI+ 가 크기를 못 재는 유효 포맷(WEBP 등)일 수 있다. 아직 후보가
                // 없으면 그래도 채택해, dimension 판정 실패로 파비콘이 아예 안 뜨는 걸 막는다.
                if (best == null || dim > bestDim) { best = bytes; bestDim = dim; }
            }

            if (best == null)
            {
                _failed[domain] = DateTime.UtcNow;   // 네거티브 캐시
                return null;
            }
            var f = FileFor(domain);
            await File.WriteAllBytesAsync(f, best, ct);
            _failed.TryRemove(domain, out _);
            return f;
        }
        catch
        {
            _failed[domain] = DateTime.UtcNow;
            return null;
        }
        finally
        {
            _inflight.TryRemove(domain, out _);
        }
    }

    private static async Task<byte[]?> TryFetchAsync(string url, CancellationToken ct)
    {
        try
        {
            using var resp = await Http.GetAsync(url, ct);
            if (!resp.IsSuccessStatusCode) return null;
            var bytes = await resp.Content.ReadAsByteArrayAsync(ct);
            return bytes.Length >= 200 && IsRasterImage(bytes) ? bytes : null;
        }
        catch
        {
            return null;
        }
    }

    /// <summary>OS 가 디코딩 가능한 래스터 이미지인지 매직 바이트로 확인(SVG/HTML 배제).</summary>
    private static bool IsRasterImage(byte[] b)
    {
        if (b.Length < 12) return false;
        if (b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47) return true;   // PNG
        if (b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF) return true;                   // JPEG
        if (b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46) return true;                   // GIF
        if (b[0] == 0x42 && b[1] == 0x4D) return true;                                   // BMP
        if (b[0] == 0x00 && b[1] == 0x00 && b[2] == 0x01 && b[3] == 0x00) return true;   // ICO
        if (b[0] == 0x52 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x46 &&
            b[8] == 0x57 && b[9] == 0x45 && b[10] == 0x42 && b[11] == 0x50) return true; // WEBP
        return false;
    }

    /// <summary>인코딩된 이미지의 최대 픽셀 변(실패 시 0).</summary>
    private static int PixelDimension(byte[] bytes)
    {
        try
        {
            using var ms = new MemoryStream(bytes);
#pragma warning disable CA1416 // Windows 전용(net8.0-windows 타깃)
            using var img = Image.FromStream(ms, useEmbeddedColorManagement: false, validateImageData: false);
            return Math.Max(img.Width, img.Height);
#pragma warning restore CA1416
        }
        catch
        {
            return 0;
        }
    }
}
