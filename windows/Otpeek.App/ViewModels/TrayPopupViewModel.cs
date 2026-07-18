using System.Collections.ObjectModel;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Otpeek.Core.Services.Interfaces;
using Otpeek.Core.Windows.Services;

namespace Otpeek.App.ViewModels;

/// <summary>
/// 시스템 트레이 팝업 ViewModel
/// </summary>
public partial class TrayPopupViewModel : BaseViewModel
{
    private readonly IOtpClientService _client;
    private readonly IClipboardService _clipboardService;
    private readonly ISettingsService _settingsService;
    private readonly IFaviconService _faviconService;
    private CancellationTokenSource? _copyFeedbackCts;

    public ObservableCollection<AccountItemViewModel> Accounts { get; } = new();

    [ObservableProperty]
    private bool _isEmpty = true;

    [ObservableProperty]
    private string _copyFeedback = string.Empty;

    [ObservableProperty]
    private bool _isCopyFeedbackVisible;

    public event EventHandler? OpenMainWindowRequested;
    public event EventHandler? OpenSettingsRequested;
    public event EventHandler? ScanQrRequested;
    public event EventHandler? CloseRequested;

    public TrayPopupViewModel(
        IOtpClientService client,
        IClipboardService clipboardService,
        ISettingsService settingsService,
        IFaviconService faviconService)
    {
        _client = client;
        _clipboardService = clipboardService;
        _settingsService = settingsService;
        _faviconService = faviconService;
    }

    /// <summary>
    /// 계정 로드 (즐겨찾기 우선)
    /// </summary>
    [RelayCommand]
    public async Task LoadAccountsAsync()
    {
        await ExecuteAsync(() =>
        {
            foreach (var vm in Accounts)
            {
                vm.CopyRequested -= OnCopyRequested;
                vm.Dispose();
            }
            Accounts.Clear();

            if (!_client.IsUnlocked)
            {
                IsEmpty = true;
                return Task.CompletedTask;
            }

            // 즐겨찾기 우선, 그 다음 정렬 순서 (v2 모델에는 LastUsedAt이 없음)
            var sortedAccounts = _client.ListAccounts()
                .OrderByDescending(a => a.isFavorite)
                .ThenBy(a => a.sortOrder)
                .ThenBy(a => a.issuer ?? string.Empty, StringComparer.OrdinalIgnoreCase)
                .ThenBy(a => a.accountName, StringComparer.OrdinalIgnoreCase)
                .Take(10);

            foreach (var account in sortedAccounts)
            {
                var vm = new AccountItemViewModel(account, _client, _faviconService);
                vm.CopyRequested += OnCopyRequested;
                Accounts.Add(vm);
            }

            IsEmpty = Accounts.Count == 0;
            return Task.CompletedTask;
        });
    }

    [RelayCommand]
    private async Task CopyAndCloseAsync(AccountItemViewModel? vm)
    {
        if (vm == null) return;

        await CopyAccountAsync(vm);

        CloseRequested?.Invoke(this, EventArgs.Empty);
    }

    /// <summary>
    /// Copies the selected account using the configured clipboard timeout and surfaces
    /// non-blocking feedback in the popup. Kept public so the Window's default item-click
    /// action and command-based actions share exactly the same behavior.
    /// </summary>
    public async Task CopyAccountAsync(AccountItemViewModel? vm)
    {
        if (vm == null)
            return;

        try
        {
            string code = vm.GetFreshCode();
            if (string.IsNullOrWhiteSpace(code) || code == "Error")
            {
                ShowCopyFeedback("Could not refresh the code");
                return;
            }

            var settings = _settingsService.Settings;
            await _clipboardService.CopyAsync(code, settings.ClipboardClearSeconds);
            vm.ShowCopiedIndicator();

            string accountLabel = string.IsNullOrWhiteSpace(vm.Issuer)
                ? vm.AccountName
                : vm.Issuer;
            ShowCopyFeedback($"Copied {accountLabel}");
        }
        catch
        {
            ShowCopyFeedback("Could not copy the code");
        }
    }

    [RelayCommand]
    private void OpenMainWindow()
    {
        OpenMainWindowRequested?.Invoke(this, EventArgs.Empty);
        CloseRequested?.Invoke(this, EventArgs.Empty);
    }

    [RelayCommand]
    private void OpenSettings()
    {
        OpenSettingsRequested?.Invoke(this, EventArgs.Empty);
        CloseRequested?.Invoke(this, EventArgs.Empty);
    }

    [RelayCommand]
    private void ScanQr()
    {
        ScanQrRequested?.Invoke(this, EventArgs.Empty);
        CloseRequested?.Invoke(this, EventArgs.Empty);
    }

    private async void OnCopyRequested(object? sender, string code)
    {
        if (sender is AccountItemViewModel vm)
        {
            await CopyAccountAsync(vm);
            return;
        }

        var settings = _settingsService.Settings;
        await _clipboardService.CopyAsync(code, settings.ClipboardClearSeconds);
        ShowCopyFeedback("Code copied");
    }

    private void ShowCopyFeedback(string message)
    {
        _copyFeedbackCts?.Cancel();
        _copyFeedbackCts?.Dispose();
        _copyFeedbackCts = new CancellationTokenSource();
        var token = _copyFeedbackCts.Token;

        CopyFeedback = message;
        IsCopyFeedbackVisible = true;

        _ = DismissCopyFeedbackAsync(token);
    }

    private async Task DismissCopyFeedbackAsync(CancellationToken token)
    {
        try
        {
            await Task.Delay(TimeSpan.FromSeconds(2), token);
            if (!token.IsCancellationRequested)
                IsCopyFeedbackVisible = false;
        }
        catch (TaskCanceledException)
        {
        }
    }

    public void Cleanup()
    {
        _copyFeedbackCts?.Cancel();
        _copyFeedbackCts?.Dispose();
        _copyFeedbackCts = null;

        foreach (var vm in Accounts)
        {
            vm.CopyRequested -= OnCopyRequested;
            vm.Dispose();
        }
        Accounts.Clear();
    }
}
