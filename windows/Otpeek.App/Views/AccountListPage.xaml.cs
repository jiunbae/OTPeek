using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;
using Otpeek.App.ViewModels;
using Otpeek.Core.Windows.Services;
using Uniffi.Otpeek;

namespace Otpeek.App.Views;

/// <summary>
/// 계정 목록 페이지
/// </summary>
public sealed partial class AccountListPage : Page
{
    public AccountListViewModel ViewModel { get; }
    private readonly IOtpClientService _client;

    public AccountListPage()
    {
        this.InitializeComponent();
        ViewModel = App.Services.GetRequiredService<AccountListViewModel>();
        _client = App.Services.GetRequiredService<IOtpClientService>();

        // 이벤트 연결
        AddButton.Click += OnAddButtonClick;
        ScanQrButton.Click += OnScanQrButtonClick;
        SearchBox.TextChanged += OnSearchTextChanged;

        // ViewModel 상태 바인딩
        ViewModel.PropertyChanged += OnViewModelPropertyChanged;

        // Add Account 이벤트 연결
        ViewModel.AddRequested += OnAddRequested;
        ViewModel.EditRequested += OnEditRequested;
        ViewModel.DeleteRequested += OnDeleteRequested;
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
            ViewModel.PageTitle = string.IsNullOrWhiteSpace(args.Title) ? "Accounts" : args.Title;
        }
        else
        {
            // Reset filters for "All Accounts"
            ViewModel.FilterFolderId = null;
            ViewModel.ShowFavoritesOnly = false;
            ViewModel.ShowUncategorizedOnly = false;
            ViewModel.PageTitle = "All Accounts";
        }

        PageTitle.Text = ViewModel.PageTitle;
        await ViewModel.LoadAccountsAsync();
        UpdateCollectionState();
    }

    protected override void OnNavigatedFrom(NavigationEventArgs e)
    {
        base.OnNavigatedFrom(e);
        ViewModel.PropertyChanged -= OnViewModelPropertyChanged;
        ViewModel.AddRequested -= OnAddRequested;
        ViewModel.EditRequested -= OnEditRequested;
        ViewModel.DeleteRequested -= OnDeleteRequested;
        ViewModel.Cleanup();
    }

    private void OnViewModelPropertyChanged(object? sender, System.ComponentModel.PropertyChangedEventArgs e)
    {
        switch (e.PropertyName)
        {
            case nameof(ViewModel.IsEmpty):
                UpdateCollectionState();
                break;

            case nameof(ViewModel.IsLoading):
                LoadingRing.IsActive = ViewModel.IsLoading;
                break;
        }
    }

    private void UpdateCollectionState()
    {
        EmptyState.Visibility = ViewModel.IsEmpty ? Visibility.Visible : Visibility.Collapsed;
        AccountListView.Visibility = ViewModel.IsEmpty ? Visibility.Collapsed : Visibility.Visible;
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

    private void OnEditRequested(object? sender, OtpAccount account)
    {
        if (App.MainWindow is MainWindow window)
            window.ShowAccountEditor(account);
    }

    private async void OnDeleteRequested(object? sender, OtpAccount account)
    {
        var displayName = string.IsNullOrWhiteSpace(account.issuer)
            ? account.accountName
            : $"{account.issuer} ({account.accountName})";

        var dialog = new ContentDialog
        {
            Title = "Delete account?",
            Content = $"{displayName} will be removed from this vault on every synced device.",
            PrimaryButtonText = "Delete",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Close,
            XamlRoot = XamlRoot
        };

        if (await dialog.ShowAsync() != ContentDialogResult.Primary)
            return;

        try
        {
            _client.DeleteAccount(account.id);
        }
        catch (Exception ex)
        {
            var error = new ContentDialog
            {
                Title = "Could not delete account",
                Content = ex.Message,
                CloseButtonText = "OK",
                XamlRoot = XamlRoot
            };
            await error.ShowAsync();
        }
    }

    public async Task ShowQrScannerDialogAsync()
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

    public async Task ShowManualAddDialogAsync()
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
