using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Otpeek.Core.Windows;
using Otpeek.Core.Windows.Services;
using Uniffi.Otpeek;

namespace Otpeek.App.ViewModels;

/// <summary>
/// 계정 아이템 ViewModel (OTP 코드 표시용).
/// 코드 생성은 Rust 코어를 통해 수행합니다 (TOTP는 오프-볼트 free function,
/// HOTP는 볼트를 통한 카운터 증가).
/// </summary>
public partial class AccountItemViewModel : ObservableObject, IDisposable
{
    private readonly IOtpClientService _client;
    private readonly IFaviconService? _favicon;
    private readonly DispatcherQueueTimer _timer;
    private readonly DispatcherQueue _dispatcherQueue;
    private readonly bool _allowClickToCopy;
    private long _lastTotpTimeStep = -1;
    private bool _disposed;

    public OtpAccount Account { get; private set; }

    /// <summary>서비스 로고(파비콘). null 이면 색상 이니셜로 폴백.</summary>
    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(HasIcon))]
    [NotifyPropertyChangedFor(nameof(IconVisibility))]
    [NotifyPropertyChangedFor(nameof(InitialVisibility))]
    private ImageSource? _iconSource;

    /// <summary>로고가 로드되었는지(아이콘 vs 이니셜 표시 전환).</summary>
    public bool HasIcon => IconSource != null;

    // Window(트레이 팝업)의 x:Bind 는 {StaticResource 컨버터} 를 못 쓰므로(Window 는
    // FrameworkElement 가 아님) Visibility 를 VM 에서 직접 노출한다. Page/Window 공통.
    public Visibility IconVisibility => HasIcon ? Visibility.Visible : Visibility.Collapsed;
    public Visibility InitialVisibility => HasIcon ? Visibility.Collapsed : Visibility.Visible;

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(FormattedCode))]
    private string _currentCode = "------";

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(CodeBrush))]
    [NotifyPropertyChangedFor(nameof(RemainingText))]
    private int _remainingSeconds;

    [ObservableProperty]
    private double _progress = 1.0;

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(CodeBrush))]
    private bool _isCopied;

    public string Issuer => string.IsNullOrEmpty(Account.issuer) ? string.Empty : Account.issuer!;
    public string AccountName => Account.accountName;
    public string Initial => Account.Initial();
    public bool IsFavorite => Account.isFavorite;
    public string FavoriteActionText => Account.isFavorite ? "Remove from Favorites" : "Add to Favorites";
    public string FavoriteGlyph => Account.isFavorite ? "\uE735" : "\uE734";
    public string CopyToolTip => _allowClickToCopy
        ? "Click to copy"
        : "Click-to-copy is disabled in Settings";
    public string RemainingText => Account.otpType == OtpType.Totp
        ? $"{Math.Max(0, RemainingSeconds)}s"
        : "HOTP";
    public string? Color => Account.color;
    public string Id => Account.id;
    public Visibility HotpVisibility => Account.otpType == OtpType.Hotp
        ? Visibility.Visible
        : Visibility.Collapsed;
    public Visibility TotpVisibility => Account.otpType == OtpType.Totp
        ? Visibility.Visible
        : Visibility.Collapsed;
    public Brush InitialBrush => new SolidColorBrush(ParseColor(Account.color));
    public Brush CodeBrush => new SolidColorBrush(
        IsCopied
            ? Microsoft.UI.Colors.ForestGreen
            : RemainingSeconds is > 0 and < 10
                ? Microsoft.UI.Colors.OrangeRed
                : Microsoft.UI.Colors.Gray);

    /// <summary>
    /// 복사 요청 이벤트
    /// </summary>
    public event EventHandler<string>? CopyRequested;

    /// <summary>편집 요청 이벤트(목록이 편집 화면을 연다).</summary>
    public event EventHandler? EditRequested;

    /// <summary>삭제 확인 UI를 목록 페이지에 요청합니다.</summary>
    public event EventHandler? DeleteRequested;

    public AccountItemViewModel(
        OtpAccount account,
        IOtpClientService client,
        IFaviconService? favicon = null,
        bool allowClickToCopy = true)
    {
        Account = account;
        _client = client;
        _favicon = favicon;
        _allowClickToCopy = allowClickToCopy;

        _dispatcherQueue = DispatcherQueue.GetForCurrentThread();

        _timer = _dispatcherQueue.CreateTimer();
        _timer.Interval = TimeSpan.FromSeconds(1);
        _timer.Tick += OnTimerTick;

        UpdateCode(forceCodeGeneration: true);

        // TOTP인 경우 타이머 시작
        if (account.otpType == OtpType.Totp)
        {
            _timer.Start();
        }

        _ = LoadIconAsync();
    }

    /// <summary>
    /// 계정을 도메인으로 매핑해 로고를 비동기 로드(캐시 우선). 실패/미설정 시 이니셜 유지.
    /// </summary>
    private async Task LoadIconAsync()
    {
        try
        {
            if (_favicon is null || !_favicon.Enabled) return;
            var resolved = _favicon.Resolve(Account);
            if (resolved is null) return;
            var (domain, confident) = resolved.Value;
            if (string.IsNullOrEmpty(domain)) return;

            var path = _favicon.CachedIconPath(domain)
                       ?? await _favicon.GetIconPathAsync(domain, brandOnly: !confident);
            if (string.IsNullOrEmpty(path)) return;

            _dispatcherQueue.TryEnqueue(async () =>
            {
                if (_disposed) return;
                // 파일경로 Uri 로 BitmapImage 를 만들면 (1) MSIX 패키지 모드에서 로드가 막히고
                // (2) 디코드가 비동기라 실패해도 IconSource 가 이미 세팅돼 이니셜이 숨겨진 채
                // "빈 흰 타일" 이 남는다. 스트림으로 디코드까지 마친 뒤에만 아이콘으로 전환한다.
                try
                {
                    using var stream = await Windows.Storage.Streams.FileRandomAccessStream
                        .OpenAsync(path, Windows.Storage.FileAccessMode.Read);
                    var bmp = new BitmapImage();
                    await bmp.SetSourceAsync(stream);
                    if (!_disposed) IconSource = bmp;
                }
                catch
                {
                    if (!_disposed) IconSource = null; // 실패 시 이니셜 폴백 유지
                }
            });
        }
        catch
        {
            // 네트워크/파일 오류는 조용히 무시(이니셜 폴백).
        }
    }

    private void OnTimerTick(DispatcherQueueTimer sender, object args)
    {
        UpdateCode();
    }

    private void UpdateCode(bool forceCodeGeneration = false)
    {
        try
        {
            if (Account.otpType == OtpType.Totp)
            {
                long nowSecs = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
                int period = (int)Account.period;
                if (period <= 0)
                    throw new InvalidOperationException("TOTP period must be greater than zero.");

                long timeStep = nowSecs / period;
                if (forceCodeGeneration || timeStep != _lastTotpTimeStep)
                {
                    CurrentCode = OtpeekMethods.GenerateTotpNow(
                        Account.secret, Account.algorithm, Account.digits, Account.period, nowSecs);
                    _lastTotpTimeStep = timeStep;
                }

                RemainingSeconds = period - (int)(nowSecs % period);
                Progress = (double)RemainingSeconds / period;
            }
            else
            {
                // HOTP: 현재 카운터 기준 peek (증가 없음)
                var code = _client.Code(Account.id);
                CurrentCode = code.code;
                RemainingSeconds = 0;
                Progress = 1.0;
            }
        }
        catch
        {
            CurrentCode = "Error";
        }
    }

    /// <summary>
    /// Regenerates the selected value immediately before copying so a click on a TOTP
    /// boundary cannot use the previous timer tick.
    /// </summary>
    public string GetFreshCode()
    {
        UpdateCode(forceCodeGeneration: true);
        return CurrentCode;
    }

    /// <summary>
    /// 코드 복사
    /// </summary>
    [RelayCommand]
    private void CopyCode()
    {
        if (!_allowClickToCopy) return;
        CopyRequested?.Invoke(this, CurrentCode);
        ShowCopiedIndicator();
    }

    /// <summary>편집 화면 열기 요청.</summary>
    [RelayCommand]
    private void Edit() => EditRequested?.Invoke(this, EventArgs.Empty);

    /// <summary>즐겨찾기 토글(코어에 저장 → VaultChanged 로 목록 새로고침).</summary>
    [RelayCommand]
    private void ToggleFavorite()
    {
        try { _client.UpdateAccount(Account with { isFavorite = !Account.isFavorite }); }
        catch { /* 저장 실패는 무시 */ }
    }

    /// <summary>계정 삭제(코어 tombstone → VaultChanged 로 목록 새로고침).</summary>
    [RelayCommand]
    private void Delete()
    {
        DeleteRequested?.Invoke(this, EventArgs.Empty);
    }

    /// <summary>
    /// HOTP 카운터 증가 및 새 코드 생성
    /// </summary>
    [RelayCommand]
    private void GenerateNextCode()
    {
        if (Account.otpType != OtpType.Hotp)
            return;

        try
        {
            var code = _client.NextHotp(Account.id);
            CurrentCode = code.code;

            // 증가된 카운터를 반영한 최신 계정으로 갱신
            var updated = _client.GetAccount(Account.id);
            if (updated != null)
                Account = updated;
        }
        catch
        {
            CurrentCode = "Error";
        }
    }

    /// <summary>
    /// 복사 표시 (잠깐 표시 후 숨김)
    /// </summary>
    public async void ShowCopiedIndicator()
    {
        IsCopied = true;
        await Task.Delay(2000);
        IsCopied = false;
    }

    /// <summary>
    /// 코드 포맷팅 (3~4자리씩 분리)
    /// </summary>
    public string FormattedCode
    {
        get
        {
            if (CurrentCode.Length == 6)
                return $"{CurrentCode[..3]} {CurrentCode[3..]}";
            if (CurrentCode.Length == 7)
                return $"{CurrentCode[..3]} {CurrentCode[3..]}";
            if (CurrentCode.Length == 8)
                return $"{CurrentCode[..4]} {CurrentCode[4..]}";
            return CurrentCode;
        }
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;

        _timer.Stop();
        _timer.Tick -= OnTimerTick;
    }

    private static Windows.UI.Color ParseColor(string? hex)
    {
        const string fallback = "#0078D4";
        hex = string.IsNullOrWhiteSpace(hex) ? fallback : hex.Trim();
        if (hex.StartsWith('#')) hex = hex[1..];

        if (hex.Length == 6 && uint.TryParse(hex, System.Globalization.NumberStyles.HexNumber,
                System.Globalization.CultureInfo.InvariantCulture, out uint rgb))
        {
            return Windows.UI.Color.FromArgb(255, (byte)(rgb >> 16), (byte)(rgb >> 8), (byte)rgb);
        }

        return Windows.UI.Color.FromArgb(255, 0, 120, 212);
    }
}
