using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Otpeek.Core.Windows.Services;
using Windows.Storage.Pickers;
using Uniffi.Otpeek;

namespace Otpeek.App.Views;

/// <summary>
/// 백업/복원 페이지. 백업 암복호화는 Rust 코어(v2 컨테이너)가 담당하며,
/// 레거시 v1 .otpbackup 가져오기도 코어의 ImportBackupV1로 처리합니다.
/// </summary>
public sealed partial class BackupPage : Page
{
    private readonly IOtpClientService _client;

    public BackupPage()
    {
        this.InitializeComponent();
        _client = App.Services.GetRequiredService<IOtpClientService>();

        ExportButton.Click += OnExportClick;
        ImportButton.Click += OnImportClick;
        ExportQrButton.Click += OnExportQrClick;
    }

    private async void OnExportClick(object sender, RoutedEventArgs e)
    {
        var password = await ShowPasswordDialogAsync("Create Backup Password",
            "Enter a password to encrypt your backup:");

        if (string.IsNullOrEmpty(password))
            return;

        var savePicker = new FileSavePicker();
        savePicker.SuggestedStartLocation = PickerLocationId.DocumentsLibrary;
        savePicker.FileTypeChoices.Add("OTP Vault Backup", new[] { ".otpvault" });
        savePicker.SuggestedFileName = $"otpeek_backup_{DateTime.Now:yyyyMMdd}";

        var hwnd = WinRT.Interop.WindowNative.GetWindowHandle(App.MainWindow);
        WinRT.Interop.InitializeWithWindow.Initialize(savePicker, hwnd);

        var file = await savePicker.PickSaveFileAsync();
        if (file == null) return;

        try
        {
            byte[] blob = _client.ExportBackup(password);
            await File.WriteAllBytesAsync(file.Path, blob);
            await ShowMessageAsync("Success", "Backup exported successfully.");
        }
        catch (Exception ex)
        {
            await ShowMessageAsync("Error", $"Failed to export backup: {ex.Message}");
        }
    }

    private async void OnImportClick(object sender, RoutedEventArgs e)
    {
        var openPicker = new FileOpenPicker();
        openPicker.SuggestedStartLocation = PickerLocationId.DocumentsLibrary;
        openPicker.FileTypeFilter.Add(".otpvault");
        openPicker.FileTypeFilter.Add(".otpbackup");

        var hwnd = WinRT.Interop.WindowNative.GetWindowHandle(App.MainWindow);
        WinRT.Interop.InitializeWithWindow.Initialize(openPicker, hwnd);

        var file = await openPicker.PickSingleFileAsync();
        if (file == null) return;

        var password = await ShowPasswordDialogAsync("Enter Backup Password",
            "Enter the password used to encrypt this backup:");

        if (string.IsNullOrEmpty(password))
            return;

        try
        {
            byte[] data = await File.ReadAllBytesAsync(file.Path);
            bool merge = RestoreSettingsToggle.IsOn;

            uint count;
            try
            {
                // v2 컨테이너 우선
                count = _client.ImportBackup(data, password, merge);
            }
            catch (OtpException.Corrupt)
            {
                // v2가 아니면 레거시 v1 .otpbackup으로 재시도
                count = _client.ImportBackupV1(data, password, merge);
            }

            ImportInfoBar.Severity = InfoBarSeverity.Success;
            ImportInfoBar.Title = "Import Successful";
            ImportInfoBar.Message = $"{count} entity/entities imported successfully.";
            ImportInfoBar.IsOpen = true;
        }
        catch (OtpException.WrongPassword)
        {
            ImportInfoBar.Severity = InfoBarSeverity.Error;
            ImportInfoBar.Title = "Invalid Password";
            ImportInfoBar.Message = "The password is incorrect or the backup file is corrupted.";
            ImportInfoBar.IsOpen = true;
        }
        catch (Exception ex)
        {
            ImportInfoBar.Severity = InfoBarSeverity.Error;
            ImportInfoBar.Title = "Import Failed";
            ImportInfoBar.Message = ex.Message;
            ImportInfoBar.IsOpen = true;
        }
    }

    private async void OnExportQrClick(object sender, RoutedEventArgs e)
    {
        await ShowMessageAsync("Coming Soon", "QR code export will be available in a future update.");
    }

    private async Task<string?> ShowPasswordDialogAsync(string title, string message)
    {
        var passwordBox = new PasswordBox { PlaceholderText = "Password" };

        var dialog = new ContentDialog
        {
            Title = title,
            Content = new StackPanel
            {
                Spacing = 12,
                Children =
                {
                    new TextBlock { Text = message, TextWrapping = TextWrapping.Wrap },
                    passwordBox
                }
            },
            PrimaryButtonText = "OK",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary,
            XamlRoot = this.XamlRoot
        };

        var result = await dialog.ShowAsync();

        if (result == ContentDialogResult.Primary)
            return passwordBox.Password;

        return null;
    }

    private async Task ShowMessageAsync(string title, string message)
    {
        var dialog = new ContentDialog
        {
            Title = title,
            Content = message,
            CloseButtonText = "OK",
            XamlRoot = this.XamlRoot
        };

        await dialog.ShowAsync();
    }
}
