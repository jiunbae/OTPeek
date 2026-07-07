using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;
using Otpeek.App.ViewModels;

namespace Otpeek.App.Views;

/// <summary>
/// 계정 목록 페이지
/// </summary>
public sealed partial class AccountListPage : Page
{
    public AccountListViewModel ViewModel { get; }

    public AccountListPage()
    {
        this.InitializeComponent();
        ViewModel = App.Services.GetRequiredService<AccountListViewModel>();

        // 이벤트 연결
        AddButton.Click += OnAddButtonClick;
        ScanQrButton.Click += OnScanQrButtonClick;
        SearchBox.TextChanged += OnSearchTextChanged;

        // ViewModel 상태 바인딩
        ViewModel.PropertyChanged += OnViewModelPropertyChanged;

        // Add Account 이벤트 연결
        ViewModel.AddRequested += OnAddRequested;
    }

    protected override async void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);

        // Handle navigation parameters
        if (e.Parameter is AccountListNavigationArgs args)
        {
            ViewModel.FilterFolderId = args.FolderId;
            ViewModel.ShowFavoritesOnly = args.ShowFavoritesOnly;
            ViewModel.ShowUncategorizedOnly = args.ShowUncategorizedOnly;
        }
        else
        {
            // Reset filters for "All Accounts"
            ViewModel.FilterFolderId = null;
            ViewModel.ShowFavoritesOnly = false;
            ViewModel.ShowUncategorizedOnly = false;
        }

        await ViewModel.LoadAccountsAsync();
    }

    protected override void OnNavigatedFrom(NavigationEventArgs e)
    {
        base.OnNavigatedFrom(e);
        // 리소스 정리하지 않음 (다시 돌아올 수 있으므로)
    }

    private void OnViewModelPropertyChanged(object? sender, System.ComponentModel.PropertyChangedEventArgs e)
    {
        switch (e.PropertyName)
        {
            case nameof(ViewModel.IsEmpty):
                EmptyState.Visibility = ViewModel.IsEmpty ? Visibility.Visible : Visibility.Collapsed;
                AccountListView.Visibility = ViewModel.IsEmpty ? Visibility.Collapsed : Visibility.Visible;
                break;

            case nameof(ViewModel.IsLoading):
                LoadingRing.IsActive = ViewModel.IsLoading;
                break;
        }
    }

    private async void OnAddButtonClick(object sender, RoutedEventArgs e)
    {
        await ShowManualAddDialogAsync();
    }

    private async void OnScanQrButtonClick(object sender, RoutedEventArgs e)
    {
        await ShowQrScannerDialogAsync();
    }

    private void OnSearchTextChanged(AutoSuggestBox sender, AutoSuggestBoxTextChangedEventArgs args)
    {
        // 사용자가 입력한 경우에만 검색어 갱신(프로그램적 변경 제외).
        if (args.Reason == AutoSuggestionBoxTextChangeReason.UserInput)
            ViewModel.SearchQuery = sender.Text;
    }

    private async void OnAddRequested(object? sender, EventArgs e)
    {
        await ShowManualAddDialogAsync();
    }

    private async Task ShowQrScannerDialogAsync()
    {
        var dialog = new QrScannerDialog
        {
            XamlRoot = this.XamlRoot
        };

        var result = await dialog.ShowAsync();

        if (result == ContentDialogResult.Primary && dialog.AddedAccount != null)
        {
            await ViewModel.LoadAccountsAsync();
        }
    }

    private async Task ShowManualAddDialogAsync()
    {
        var dialog = new ManualAddDialog
        {
            XamlRoot = this.XamlRoot
        };

        var result = await dialog.ShowAsync();

        if (result == ContentDialogResult.Primary && dialog.AddedAccount != null)
        {
            await ViewModel.LoadAccountsAsync();
        }
    }
}
