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
    private int _remainingSeconds;

    [ObservableProperty]
    private double _progress = 1.0;

    [ObservableProperty]
    private bool _isCopied;

    public string Issuer => string.IsNullOrEmpty(Account.issuer) ? string.Empty : Account.issuer!;
    public string AccountName => Account.accountName;
    public string Initial => Account.Initial();
    public bool IsFavorite => Account.isFavorite;
    public string? Color => Account.color;
    public string Id => Account.id;

    /// <summary>
    /// 복사 요청 이벤트
    /// </summary>
    public event EventHandler<string>? CopyRequested;

    /// <summary>편집 요청 이벤트(목록이 편집 화면을 연다).</summary>
    public event EventHandler? EditRequested;

    public AccountItemViewModel(OtpAccount account, IOtpClientService client, IFaviconService? favicon = null)
    {
        Account = account;
        _client = client;
        _favicon = favicon;

        _dispatcherQueue = DispatcherQueue.GetForCurrentThread();

        _timer = _dispatcherQueue.CreateTimer();
        _timer.Interval = TimeSpan.FromSeconds(1);
        _timer.Tick += OnTimerTick;

        UpdateCode();

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
            var domain = _favicon.DomainFor(Account);
            if (string.IsNullOrEmpty(domain)) return;

            var path = _favicon.CachedIconPath(domain) ?? await _favicon.GetIconPathAsync(domain);
            if (string.IsNullOrEmpty(path)) return;

            _dispatcherQueue.TryEnqueue(() =>
            {
                if (_disposed) return;
                try { IconSource = new BitmapImage(new Uri(path)); }
                catch { /* 손상 캐시 등은 무시하고 이니셜 유지 */ }
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

    private void UpdateCode()
    {
        try
        {
            if (Account.otpType == OtpType.Totp)
            {
                long nowSecs = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
                CurrentCode = OtpeekMethods.GenerateTotpNow(
                    Account.secret, Account.algorithm, Account.digits, Account.period, nowSecs);

                int period = (int)Account.period;
                RemainingSeconds = period - (int)(nowSecs % period);
                Progress = period > 0 ? (double)RemainingSeconds / period : 0;
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
    /// 코드 복사
    /// </summary>
    [RelayCommand]
    private void CopyCode()
    {
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
        try { _client.DeleteAccount(Account.id); }
        catch { /* 삭제 실패는 무시 */ }
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
}
