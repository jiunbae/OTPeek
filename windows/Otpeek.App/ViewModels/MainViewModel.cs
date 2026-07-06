using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Uniffi.Otpeek;

namespace Otpeek.App.ViewModels;

/// <summary>
/// 메인 윈도우 ViewModel
/// </summary>
public partial class MainViewModel : BaseViewModel
{
    private readonly AccountListViewModel _accountListViewModel;
    private readonly AccountEditViewModel _accountEditViewModel;

    [ObservableProperty]
    private int _selectedNavigationIndex = 0;

    [ObservableProperty]
    private bool _isAccountEditVisible;

    public AccountListViewModel AccountListViewModel => _accountListViewModel;
    public AccountEditViewModel AccountEditViewModel => _accountEditViewModel;

    public MainViewModel(
        AccountListViewModel accountListViewModel,
        AccountEditViewModel accountEditViewModel)
    {
        _accountListViewModel = accountListViewModel;
        _accountEditViewModel = accountEditViewModel;

        // 이벤트 연결
        _accountListViewModel.AddRequested += OnAddRequested;
        _accountListViewModel.EditRequested += OnEditRequested;
        _accountEditViewModel.Saved += OnAccountSaved;
        _accountEditViewModel.Cancelled += OnEditCancelled;
    }

    /// <summary>
    /// 초기화
    /// </summary>
    [RelayCommand]
    public async Task InitializeAsync()
    {
        await _accountListViewModel.LoadAccountsAsync();
    }

    /// <summary>
    /// 계정 추가 요청
    /// </summary>
    private void OnAddRequested(object? sender, EventArgs e)
    {
        _accountEditViewModel.InitializeForAdd();
        IsAccountEditVisible = true;
    }

    /// <summary>
    /// 계정 편집 요청
    /// </summary>
    private void OnEditRequested(object? sender, OtpAccount account)
    {
        _accountEditViewModel.InitializeForEdit(account);
        IsAccountEditVisible = true;
    }

    /// <summary>
    /// 계정 저장 완료
    /// </summary>
    private async void OnAccountSaved(object? sender, OtpAccount account)
    {
        IsAccountEditVisible = false;
        await _accountListViewModel.LoadAccountsAsync();
    }

    /// <summary>
    /// 편집 취소
    /// </summary>
    private void OnEditCancelled(object? sender, EventArgs e)
    {
        IsAccountEditVisible = false;
    }

    /// <summary>
    /// QR 코드 스캔으로 계정 추가
    /// </summary>
    [RelayCommand]
    public void AddFromQrCode(string uri)
    {
        if (_accountEditViewModel.InitializeFromUri(uri))
        {
            IsAccountEditVisible = true;
        }
    }

    /// <summary>
    /// 네비게이션
    /// </summary>
    [RelayCommand]
    private void Navigate(string destination)
    {
        SelectedNavigationIndex = destination switch
        {
            "accounts" => 0,
            "settings" => 1,
            "backup" => 2,
            _ => 0
        };
    }
}
