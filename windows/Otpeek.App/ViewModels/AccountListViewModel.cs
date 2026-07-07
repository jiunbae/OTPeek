using System.Collections.ObjectModel;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Microsoft.UI.Dispatching;
using Otpeek.Core.Services.Interfaces;
using Otpeek.Core.Windows.Services;
using Uniffi.Otpeek;

namespace Otpeek.App.ViewModels;

/// <summary>
/// 계정 목록 ViewModel
/// </summary>
public partial class AccountListViewModel : BaseViewModel
{
    private readonly IOtpClientService _client;
    private readonly IClipboardService _clipboardService;
    private readonly ISettingsService _settingsService;
    private readonly IFaviconService _faviconService;
    private readonly DispatcherQueue _dispatcherQueue;

    public ObservableCollection<AccountItemViewModel> Accounts { get; } = new();

    [ObservableProperty]
    private AccountItemViewModel? _selectedAccount;

    [ObservableProperty]
    private string _searchQuery = string.Empty;

    [ObservableProperty]
    private bool _isEmpty = true;

    /// <summary>필터: 특정 폴더 ID (코어 UUID 문자열)</summary>
    public string? FilterFolderId { get; set; }

    /// <summary>필터: 즐겨찾기만 표시</summary>
    public bool ShowFavoritesOnly { get; set; }

    /// <summary>필터: 미분류만 표시</summary>
    public bool ShowUncategorizedOnly { get; set; }

    public event EventHandler<OtpAccount>? EditRequested;
    public event EventHandler? AddRequested;

    public AccountListViewModel(
        IOtpClientService client,
        IClipboardService clipboardService,
        ISettingsService settingsService,
        IFaviconService faviconService)
    {
        _client = client;
        _clipboardService = clipboardService;
        _settingsService = settingsService;
        _faviconService = faviconService;
        _dispatcherQueue = DispatcherQueue.GetForCurrentThread();

        // 볼트 변경 시(잠금 해제/동기화/외부 변경) 목록 새로고침
        _client.VaultChanged += OnVaultChanged;
    }

    private void OnVaultChanged(object? sender, EventArgs e)
    {
        _dispatcherQueue.TryEnqueue(() => _ = LoadAccountsAsync());
    }

    /// <summary>
    /// 계정 목록 로드
    /// </summary>
    [RelayCommand]
    public async Task LoadAccountsAsync()
    {
        await ExecuteAsync(() =>
        {
            // 기존 ViewModel 정리
            foreach (var vm in Accounts)
            {
                vm.CopyRequested -= OnCopyRequested;
                vm.EditRequested -= OnItemEditRequested;
                vm.Dispose();
            }
            Accounts.Clear();

            if (!_client.IsUnlocked)
            {
                IsEmpty = true;
                return Task.CompletedTask;
            }

            IEnumerable<OtpAccount> accounts = _client.ListAccounts();

            if (ShowFavoritesOnly)
                accounts = accounts.Where(a => a.isFavorite);
            else if (ShowUncategorizedOnly)
                accounts = accounts.Where(a => a.folderId == null);
            else if (!string.IsNullOrEmpty(FilterFolderId))
                accounts = accounts.Where(a => a.folderId == FilterFolderId);

            foreach (var account in accounts)
            {
                var vm = new AccountItemViewModel(account, _client, _faviconService);
                vm.CopyRequested += OnCopyRequested;
                vm.EditRequested += OnItemEditRequested;
                Accounts.Add(vm);
            }

            IsEmpty = Accounts.Count == 0;
            return Task.CompletedTask;
        });
    }

    [RelayCommand]
    private void AddAccount()
    {
        AddRequested?.Invoke(this, EventArgs.Empty);
    }

    [RelayCommand]
    private void EditAccount(AccountItemViewModel? vm)
    {
        if (vm != null)
            EditRequested?.Invoke(this, vm.Account);
    }

    [RelayCommand]
    private async Task DeleteAccountAsync(AccountItemViewModel? vm)
    {
        if (vm == null) return;

        await ExecuteAsync(() =>
        {
            _client.DeleteAccount(vm.Account.id);
            // VaultChanged 이벤트가 목록을 새로고침합니다.
            return Task.CompletedTask;
        });
    }

    [RelayCommand]
    private async Task ToggleFavoriteAsync(AccountItemViewModel? vm)
    {
        if (vm == null) return;

        await ExecuteAsync(() =>
        {
            var updated = vm.Account with { isFavorite = !vm.Account.isFavorite };
            _client.UpdateAccount(updated);
            return Task.CompletedTask;
        });
    }

    partial void OnSearchQueryChanged(string value)
    {
        // TODO: 필터링 구현
    }

    private async void OnCopyRequested(object? sender, string code)
    {
        var settings = _settingsService.Settings;
        await _clipboardService.CopyAsync(code, settings.ClipboardClearSeconds);
    }

    // 아이템의 편집 요청을 목록 이벤트로 승격(MainViewModel 이 편집 화면을 연다).
    private void OnItemEditRequested(object? sender, EventArgs e)
    {
        if (sender is AccountItemViewModel vm)
            EditRequested?.Invoke(this, vm.Account);
    }

    public void Cleanup()
    {
        foreach (var vm in Accounts)
        {
            vm.CopyRequested -= OnCopyRequested;
            vm.EditRequested -= OnItemEditRequested;
            vm.Dispose();
        }
        Accounts.Clear();
    }
}
