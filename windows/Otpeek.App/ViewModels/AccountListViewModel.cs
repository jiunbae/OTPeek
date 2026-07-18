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
public partial class AccountListViewModel : BaseViewModel, IDisposable
{
    private readonly IOtpClientService _client;
    private readonly IClipboardService _clipboardService;
    private readonly ISettingsService _settingsService;
    private readonly IFaviconService _faviconService;
    private readonly DispatcherQueue _dispatcherQueue;
    private System.Threading.CancellationTokenSource? _searchDebounceCts;
    private bool _disposed;

    public ObservableCollection<AccountItemViewModel> Accounts { get; } = new();

    [ObservableProperty]
    private AccountItemViewModel? _selectedAccount;

    [ObservableProperty]
    private string _searchQuery = string.Empty;

    [ObservableProperty]
    private bool _isEmpty = true;

    [ObservableProperty]
    private string _pageTitle = "All Accounts";

    [ObservableProperty]
    private string _emptyTitle = "No accounts yet";

    [ObservableProperty]
    private string _emptyMessage = "Scan a QR code or add an account manually to get started.";

    /// <summary>필터: 특정 폴더 ID (코어 UUID 문자열)</summary>
    public string? FilterFolderId { get; set; }

    /// <summary>필터: 즐겨찾기만 표시</summary>
    public bool ShowFavoritesOnly { get; set; }

    /// <summary>필터: 미분류만 표시</summary>
    public bool ShowUncategorizedOnly { get; set; }

    public event EventHandler<OtpAccount>? EditRequested;
    public event EventHandler<OtpAccount>? DeleteRequested;
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
        if (_disposed) return;
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
                vm.DeleteRequested -= OnItemDeleteRequested;
                vm.Dispose();
            }
            Accounts.Clear();

            if (!_client.IsUnlocked)
            {
                IsEmpty = true;
                EmptyTitle = "Vault is locked";
                EmptyMessage = "Unlock OTPeek to view your accounts.";
                return Task.CompletedTask;
            }

            var allAccounts = _client.ListAccounts();
            IEnumerable<OtpAccount> accounts = allAccounts;

            if (ShowFavoritesOnly)
                accounts = accounts.Where(a => a.isFavorite);
            else if (ShowUncategorizedOnly)
                accounts = accounts.Where(a => a.folderId == null);
            else if (!string.IsNullOrEmpty(FilterFolderId))
                accounts = accounts.Where(a => a.folderId == FilterFolderId);

            // 검색 필터(발행처/계정명, 대소문자 무시).
            if (!string.IsNullOrWhiteSpace(SearchQuery))
            {
                var q = SearchQuery.Trim();
                accounts = accounts.Where(a =>
                    (a.issuer ?? string.Empty).Contains(q, StringComparison.OrdinalIgnoreCase) ||
                    a.accountName.Contains(q, StringComparison.OrdinalIgnoreCase));
            }

            foreach (var account in accounts)
            {
                var vm = new AccountItemViewModel(
                    account,
                    _client,
                    _faviconService,
                    allowClickToCopy: _settingsService.Settings.AutoCopyToClipboard);
                vm.CopyRequested += OnCopyRequested;
                vm.EditRequested += OnItemEditRequested;
                vm.DeleteRequested += OnItemDeleteRequested;
                Accounts.Add(vm);
            }

            IsEmpty = Accounts.Count == 0;
            if (IsEmpty)
            {
                if (allAccounts.Count == 0)
                {
                    EmptyTitle = "No accounts yet";
                    EmptyMessage = "Scan a QR code or add an account manually to get started.";
                }
                else if (!string.IsNullOrWhiteSpace(SearchQuery))
                {
                    EmptyTitle = "No matching accounts";
                    EmptyMessage = "Try a different issuer or account name.";
                }
                else
                {
                    EmptyTitle = "No accounts here";
                    EmptyMessage = "Move an account into this folder or add a new one.";
                }
            }
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

    private void OnItemDeleteRequested(object? sender, EventArgs e)
    {
        if (sender is AccountItemViewModel vm)
            DeleteRequested?.Invoke(this, vm.Account);
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
        // 매 키 입력마다 목록 전체를 재생성하면 깜빡임/타이머 churn/아이콘 재로드가 발생한다.
        // ~250ms 디바운스: 입력이 멎은 뒤에만 한 번 다시 로드한다.
        _searchDebounceCts?.Cancel();
        _searchDebounceCts = new System.Threading.CancellationTokenSource();
        var token = _searchDebounceCts.Token;
        _ = Task.Delay(250, token).ContinueWith(
            _ => _dispatcherQueue.TryEnqueue(() => _ = LoadAccountsAsync()),
            token,
            TaskContinuationOptions.OnlyOnRanToCompletion,
            TaskScheduler.Default);
    }

    private async void OnCopyRequested(object? sender, string code)
    {
        var settings = _settingsService.Settings;
        await _clipboardService.CopyAsync(code, settings.ClipboardClearSeconds);
    }

    // 아이템의 편집 요청을 목록 페이지로 승격해 메인 창 편집 패널을 연다.
    private void OnItemEditRequested(object? sender, EventArgs e)
    {
        if (sender is AccountItemViewModel vm)
            EditRequested?.Invoke(this, vm.Account);
    }

    public void Cleanup()
    {
        if (_disposed) return;
        _disposed = true;
        _searchDebounceCts?.Cancel();
        _searchDebounceCts?.Dispose();
        _client.VaultChanged -= OnVaultChanged;

        foreach (var vm in Accounts)
        {
            vm.CopyRequested -= OnCopyRequested;
            vm.EditRequested -= OnItemEditRequested;
            vm.DeleteRequested -= OnItemDeleteRequested;
            vm.Dispose();
        }
        Accounts.Clear();
    }

    public void Dispose() => Cleanup();
}
