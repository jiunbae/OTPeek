using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using OtpAuthenticator.App.ViewModels;
using OtpAuthenticator.Core.Windows;
using Windows.Storage.Pickers;
using Uniffi.Otp;

namespace OtpAuthenticator.App.Views;

/// <summary>
/// QR code scanner dialog (scan only)
/// </summary>
public sealed partial class QrScannerDialog : ContentDialog
{
    public QrScannerViewModel ViewModel { get; }

    /// <summary>
    /// Added account (available after dialog closes)
    /// </summary>
    public OtpAccount? AddedAccount { get; private set; }

    public QrScannerDialog()
    {
        this.InitializeComponent();

        ViewModel = App.Services.GetRequiredService<QrScannerViewModel>();
        ViewModel.Reset();

        // Event handlers
        ScanScreenButton.Click += OnScanScreenClick;
        ScanAreaButton.Click += OnScanAreaClick;
        ImportImageButton.Click += OnImportImageClick;
        ParseUriButton.Click += OnParseUriClick;

        ViewModel.PropertyChanged += OnViewModelPropertyChanged;
        ViewModel.AccountAdded += OnAccountAdded;

        this.PrimaryButtonClick += OnPrimaryButtonClick;
    }

    private void OnViewModelPropertyChanged(object? sender, System.ComponentModel.PropertyChangedEventArgs e)
    {
        switch (e.PropertyName)
        {
            case nameof(ViewModel.StatusMessage):
                StatusInfoBar.Message = ViewModel.StatusMessage;
                break;

            case nameof(ViewModel.IsScanning):
                LoadingProgress.Visibility = ViewModel.IsScanning ? Visibility.Visible : Visibility.Collapsed;
                ScanScreenButton.IsEnabled = !ViewModel.IsScanning;
                ScanAreaButton.IsEnabled = !ViewModel.IsScanning;
                ImportImageButton.IsEnabled = !ViewModel.IsScanning;
                break;

            case nameof(ViewModel.HasScannedAccount):
                UpdateAccountPreview();
                IsPrimaryButtonEnabled = ViewModel.HasScannedAccount;
                break;

            case nameof(ViewModel.ScannedAccount):
                UpdateAccountPreview();
                break;
        }
    }

    private void UpdateAccountPreview()
    {
        if (!ViewModel.HasScannedAccount)
        {
            AccountPreview.Visibility = Visibility.Collapsed;
            StatusInfoBar.Severity = InfoBarSeverity.Informational;
            StatusInfoBar.Message = "Choose a scan method below";
            return;
        }

        AccountPreview.Visibility = Visibility.Visible;
        StatusInfoBar.Severity = InfoBarSeverity.Success;

        var account = ViewModel.ScannedAccount;
        if (account is OtpAccount a)
        {
            AccountInitial.Text = a.Initial();
            AccountIssuer.Text = string.IsNullOrEmpty(a.issuer) ? "Unknown" : a.issuer!;
            AccountName.Text = a.accountName;
            AccountType.Text = a.otpType.ToString().ToUpperInvariant();
            AccountAlgorithm.Text = $"{a.algorithm} • {a.digits} digits";
        }
        else
        {
            // Google Authenticator 마이그레이션 QR (여러 계정, 미리보기 불가)
            AccountInitial.Text = "G";
            AccountIssuer.Text = "Google Authenticator export";
            AccountName.Text = "Multiple accounts";
            AccountType.Text = "MIGRATION";
            AccountAlgorithm.Text = string.Empty;
        }
    }

    private async void OnScanScreenClick(object sender, RoutedEventArgs e)
    {
        this.Hide();
        await Task.Delay(500);

        await ViewModel.ScanScreenCommand.ExecuteAsync(null);

        await this.ShowAsync();
    }

    private async void OnScanAreaClick(object sender, RoutedEventArgs e)
    {
        this.Hide();
        await Task.Delay(300);

        await ViewModel.ScanWithPickerCommand.ExecuteAsync(null);

        await this.ShowAsync();
    }

    private async void OnImportImageClick(object sender, RoutedEventArgs e)
    {
        var picker = new FileOpenPicker();
        picker.FileTypeFilter.Add(".png");
        picker.FileTypeFilter.Add(".jpg");
        picker.FileTypeFilter.Add(".jpeg");
        picker.FileTypeFilter.Add(".bmp");
        picker.FileTypeFilter.Add(".gif");
        picker.SuggestedStartLocation = PickerLocationId.PicturesLibrary;

        var hwnd = WinRT.Interop.WindowNative.GetWindowHandle(App.MainWindow);
        WinRT.Interop.InitializeWithWindow.Initialize(picker, hwnd);

        var file = await picker.PickSingleFileAsync();
        if (file != null)
        {
            ViewModel.ScanFromFileCommand.Execute(file.Path);
        }
    }

    private void OnParseUriClick(object sender, RoutedEventArgs e)
    {
        ViewModel.ManualUri = ManualUriTextBox.Text;
        ViewModel.ParseManualUriCommand.Execute(null);
    }

    private async void OnPrimaryButtonClick(ContentDialog sender, ContentDialogButtonClickEventArgs args)
    {
        var deferral = args.GetDeferral();

        try
        {
            await ViewModel.SaveAccountCommand.ExecuteAsync(null);
        }
        finally
        {
            deferral.Complete();
        }
    }

    private void OnAccountAdded(object? sender, OtpAccount account)
    {
        AddedAccount = account;
    }
}
