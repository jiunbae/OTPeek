using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Otpeek.Core.Services.Interfaces;
using Otpeek.Core.Windows.Services;
using Uniffi.Otpeek;

namespace Otpeek.App;

public partial class App
{
    internal async Task<bool> JoinWebDavFromSettingsAsync(XamlRoot xamlRoot, string url, string username, string password)
    {
        var client = Services.GetRequiredService<IOtpClientService>();
        if (!client.IsUnlocked)
        {
            await ShowMessageAsync(xamlRoot, "Vault locked", "Unlock your local vault before joining WebDAV.");
            return false;
        }

        return await TryJoinWebDavAsync(client, xamlRoot, (url, username, password));
    }

    private async Task<bool> TryJoinWebDavAsync(
        IOtpClientService client, XamlRoot xamlRoot,
        (string Url, string Username, string Password)? existingConnection = null)
    {
        bool joiningExisting = existingConnection.HasValue;
        var settingsService = Services.GetRequiredService<ISettingsService>();
        var secure = Services.GetRequiredService<ISecureStorageService>();
        var settings = settingsService.Settings.WebDav;
        var url = new TextBox
        {
            Header = "HTTPS WebDAV URL",
            PlaceholderText = "https://dav.example.com/otp/",
            Text = existingConnection?.Url ?? settings.Url
        };
        var username = new TextBox
        {
            Header = "WebDAV username",
            Text = existingConnection?.Username ?? settings.Username
        };
        var password = new PasswordBox
        {
            Header = "WebDAV password",
            Password = existingConnection?.Password ?? secure.UnprotectString(settings.ProtectedPassword) ?? string.Empty
        };
        var masterPassword = new PasswordBox { Header = "Remote vault master password" };
        var error = new TextBlock { TextWrapping = TextWrapping.Wrap, Visibility = Visibility.Collapsed };
        var content = new StackPanel { Spacing = 8 };
        if (joiningExisting)
        {
            content.Children.Add(new TextBlock
            {
                Text = "If the vaults use different keys, joining copies your local accounts and folders into the WebDAV vault and switches this device to it. OTPeek keeps an encrypted recovery copy that uses your previous master password.",
                TextWrapping = TextWrapping.Wrap
            });
        }
        content.Children.Add(url);
        content.Children.Add(username);
        content.Children.Add(password);
        content.Children.Add(masterPassword);
        content.Children.Add(error);

        var dialog = new ContentDialog
        {
            Title = "Join a WebDAV vault",
            Content = content,
            PrimaryButtonText = "Join",
            CloseButtonText = "Cancel",
            DefaultButton = joiningExisting ? ContentDialogButton.Close : ContentDialogButton.Primary,
            XamlRoot = xamlRoot
        };

        bool joined = false;
        bool joining = false;
        string? recoveryPath = null;
        string? settingsError = null;

        async Task SaveConnectionAsync()
        {
            try
            {
                await settingsService.SaveAsync();
                settingsError = null;
            }
            catch (Exception ex)
            {
                settingsError = ex.Message;
            }
        }

        dialog.Closing += (_, args) => args.Cancel = joining;
        dialog.PrimaryButtonClick += async (_, args) =>
        {
            string address = url.Text.Trim();
            string user = username.Text;
            string webDavPassword = password.Password;
            string vaultPassword = masterPassword.Password;
            if (address.Length == 0 || vaultPassword.Length == 0)
            {
                error.Text = "Enter the WebDAV URL and the vault's master password.";
                error.Visibility = Visibility.Visible;
                args.Cancel = true;
                return;
            }

            var deferral = args.GetDeferral();
            joining = true;
            dialog.IsPrimaryButtonEnabled = false;
            error.Text = "Downloading and unlocking the vault…";
            error.Visibility = Visibility.Visible;
            try
            {
                string protectedPassword = webDavPassword.Length == 0
                    ? string.Empty
                    : secure.ProtectString(webDavPassword);
                if (joiningExisting)
                {
                    recoveryPath = await Task.Run(() =>
                        client.JoinExistingWebDavVault(address, user, webDavPassword, vaultPassword));
                }
                else
                {
                    await Task.Run(() => client.JoinWebDavVault(address, user, webDavPassword, vaultPassword));
                }
                joined = true;

                settings.Enabled = true;
                settings.Url = address;
                settings.Username = user;
                settings.ProtectedPassword = protectedPassword;
                settings.LastSyncTime = null;
                await SaveConnectionAsync();
            }
            catch (Exception ex)
            {
                error.Text = ex is OtpException.WrongPassword
                    ? "The vault master password is incorrect."
                    : ex.Message;
                args.Cancel = true;
            }
            finally
            {
                joining = false;
                dialog.IsPrimaryButtonEnabled = joiningExisting ? client.IsUnlocked : !client.VaultExists;
                deferral.Complete();
            }
        };

        await dialog.ShowAsync();
        if (joiningExisting && joined)
        {
            RefreshAutoSyncSchedule();
            try
            {
                await Task.Run(client.Sync);
                settings.LastSyncTime = DateTime.UtcNow;
                await SaveConnectionAsync();
            }
            catch (Exception ex)
            {
                await ShowMessageAsync(xamlRoot, "WebDAV sync failed", ex.Message);
            }
            if (recoveryPath != null)
            {
                await ShowMessageAsync(xamlRoot, "WebDAV vault joined",
                    $"Your accounts and folders were copied into the joined vault. Your encrypted recovery copy is at {recoveryPath}. It uses your previous master password.");
            }
        }
        if (settingsError != null)
        {
            await ShowMessageAsync(xamlRoot, "WebDAV settings could not be saved",
                $"Your vault is available on this device. Save the connection again in Settings. {settingsError}");
        }
        return joined;
    }
}
