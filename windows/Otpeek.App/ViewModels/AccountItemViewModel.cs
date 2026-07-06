using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Microsoft.UI.Dispatching;
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
    private readonly DispatcherQueueTimer _timer;
    private readonly DispatcherQueue _dispatcherQueue;
    private bool _disposed;

    public OtpAccount Account { get; private set; }

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

    public AccountItemViewModel(OtpAccount account, IOtpClientService client)
    {
        Account = account;
        _client = client;

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
