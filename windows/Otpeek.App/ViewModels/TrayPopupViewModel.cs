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

    public ObservableCollection<AccountItemViewModel> Accounts { get; } = new();

    [ObservableProperty]
    private bool _isEmpty = true;

    public event EventHandler? OpenMainWindowRequested;
    public event EventHandler? OpenSettingsRequested;
    public event EventHandler? ScanQrRequested;
    public event EventHandler? CloseRequested;

    public TrayPopupViewModel(
        IOtpClientService client,
        IClipboardService clipboardService,
        ISettingsService settingsService)
    {
        _client = client;
        _clipboardService = clipboardService;
        _settingsService = settingsService;
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
                .Take(10);

            foreach (var account in sortedAccounts)
            {
                var vm = new AccountItemViewModel(account, _client);
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

        var settings = _settingsService.Settings;
        await _clipboardService.CopyAsync(vm.CurrentCode, settings.ClipboardClearSeconds);

        CloseRequested?.Invoke(this, EventArgs.Empty);
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
        var settings = _settingsService.Settings;
        await _clipboardService.CopyAsync(code, settings.ClipboardClearSeconds);
    }

    public void Cleanup()
    {
        foreach (var vm in Accounts)
        {
            vm.CopyRequested -= OnCopyRequested;
            vm.Dispose();
        }
        Accounts.Clear();
    }
}
