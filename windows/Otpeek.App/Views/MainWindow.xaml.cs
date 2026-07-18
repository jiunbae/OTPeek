using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Otpeek.Core.Services.Interfaces;
using Otpeek.Core.Windows;
using Otpeek.Core.Windows.Services;
using Uniffi.Otpeek;

namespace Otpeek.App.Views;

/// <summary>
/// 메인 윈도우
/// </summary>
public sealed partial class MainWindow : Window
{
    private readonly IOtpClientService _client;
    private int _folderInsertIndex = -1;

    private static readonly (string Name, string Value, string Glyph)[] FolderIcons =
    {
        ("Folder", "folder.fill", "\uE8B7"),
        ("Work", "briefcase.fill", "\uE821"),
        ("Personal", "person.fill", "\uE77B"),
        ("Finance", "creditcard.fill", "\uE8C7"),
        ("Security", "lock.fill", "\uE72E"),
        ("Cloud", "cloud.fill", "\uE753"),
        ("Shopping", "cart.fill", "\uE7BF"),
        ("Games", "gamecontroller.fill", "\uE7FC")
    };

    private static readonly (string Name, string Value)[] FolderColors =
    {
        ("Blue", "#0078D4"),
        ("Green", "#34A853"),
        ("Orange", "#F7630C"),
        ("Red", "#E74856"),
        ("Purple", "#8764B8"),
        ("Pink", "#E3008C"),
        ("Teal", "#00B7C3"),
        ("Brown", "#8E562E")
    };

    public MainWindow()
    {
        try
        {
            this.InitializeComponent();
        }
        catch (Exception ex)
        {
            App.LogStartup("Main window XAML initialization failed", ex);
            throw;
        }

        _client = App.Services.GetRequiredService<IOtpClientService>();

        // 네비게이션 설정
        NavigationViewControl.SelectionChanged += OnNavigationSelectionChanged;
        AddFolderNavItem.Tapped += OnAddFolderTapped;
        ImportQrNavItem.Tapped += OnImportQrTapped;
        AddAccountNavItem.Tapped += OnAddAccountTapped;
        PasteUriNavItem.Tapped += OnPasteUriTapped;
        AccountEditView.CloseRequested += (_, _) => HideAccountEditor();
        _client.VaultChanged += OnVaultChanged;

        // 초기 페이지 로드
        ContentFrame.Navigate(
            typeof(AccountListPage),
            new AccountListNavigationArgs { Title = "All Accounts" });

        // 폴더 로드
        LoadFolders();

        // 창 설정
        SetupWindow();
    }

    private void OnVaultChanged(object? sender, EventArgs e)
    {
        DispatcherQueue.TryEnqueue(LoadFolders);
    }

    private void LoadFolders()
    {
        if (!_client.IsUnlocked)
            return;

        // Remove the previous dynamic folder rows before rebuilding counts and styles.
        for (int i = NavigationViewControl.MenuItems.Count - 1; i >= 0; i--)
        {
            if (NavigationViewControl.MenuItems[i] is NavigationViewItem item &&
                item.Tag?.ToString()?.StartsWith("folder:", StringComparison.Ordinal) == true)
            {
                NavigationViewControl.MenuItems.RemoveAt(i);
            }
        }

        _folderInsertIndex = -1;

        // Find the index after "Folders" header
        for (int i = 0; i < NavigationViewControl.MenuItems.Count; i++)
        {
            if (NavigationViewControl.MenuItems[i] is NavigationViewItemHeader header &&
                header.Content?.ToString() == "Folders")
            {
                _folderInsertIndex = i + 1;
                break;
            }
        }

        var accounts = _client.ListAccounts();
        AllAccountsNavItem.Content = $"All Accounts  {accounts.Count}";
        FavoritesNavItem.Content = $"Favorites  {accounts.Count(a => a.isFavorite)}";
        UncategorizedNavItem.Content = $"Uncategorized  {accounts.Count(a => a.folderId == null)}";

        foreach (var folder in _client.ListFolders())
        {
            AddFolderNavigationItem(folder, accounts.Count(a => a.folderId == folder.id));
        }
    }

    private void AddFolderNavigationItem(OtpFolder folder, int accountCount)
    {
        var navItem = new NavigationViewItem
        {
            Content = $"{folder.name}  {accountCount}",
            Tag = $"folder:{folder.id}",
            Icon = new FontIcon { Glyph = FolderGlyph(folder.icon) }
        };

        if (!string.IsNullOrEmpty(folder.color))
        {
            try
            {
                var color = ParseHexColor(folder.color!);
                ((FontIcon)navItem.Icon).Foreground = new Microsoft.UI.Xaml.Media.SolidColorBrush(color);
            }
            catch { }
        }

        var menu = new MenuFlyout();
        var editItem = new MenuFlyoutItem
        {
            Text = "Edit Folder",
            Icon = new FontIcon { Glyph = "\uE70F" }
        };
        editItem.Click += async (_, _) => await ShowFolderDialogAsync(folder);
        menu.Items.Add(editItem);

        var deleteItem = new MenuFlyoutItem
        {
            Text = "Delete Folder",
            Icon = new FontIcon { Glyph = "\uE74D" }
        };
        deleteItem.Click += async (_, _) => await ConfirmDeleteFolderAsync(folder, accountCount);
        menu.Items.Add(new MenuFlyoutSeparator());
        menu.Items.Add(deleteItem);
        navItem.ContextFlyout = menu;

        if (_folderInsertIndex >= 0)
        {
            NavigationViewControl.MenuItems.Insert(_folderInsertIndex, navItem);
            _folderInsertIndex++;
        }
    }

    private static Windows.UI.Color ParseHexColor(string hex)
    {
        hex = hex.TrimStart('#');
        if (hex.Length == 6)
        {
            return Windows.UI.Color.FromArgb(255,
                byte.Parse(hex.Substring(0, 2), System.Globalization.NumberStyles.HexNumber),
                byte.Parse(hex.Substring(2, 2), System.Globalization.NumberStyles.HexNumber),
                byte.Parse(hex.Substring(4, 2), System.Globalization.NumberStyles.HexNumber));
        }
        return Windows.UI.Color.FromArgb(255, 0, 120, 212); // Default blue
    }

    private async void OnAddFolderTapped(object sender, Microsoft.UI.Xaml.Input.TappedRoutedEventArgs e)
    {
        await ShowFolderDialogAsync(null);
    }

    private async Task ShowFolderDialogAsync(OtpFolder? folder)
    {
        var nameBox = new TextBox
        {
            Header = "Name",
            PlaceholderText = "Folder name",
            Text = folder?.name ?? string.Empty
        };

        var iconBox = new ComboBox { Header = "Icon", HorizontalAlignment = HorizontalAlignment.Stretch };
        foreach (var option in FolderIcons)
        {
            iconBox.Items.Add(new ComboBoxItem
            {
                Content = $"{option.Glyph}  {option.Name}",
                Tag = option.Value
            });
        }

        var colorBox = new ComboBox { Header = "Color", HorizontalAlignment = HorizontalAlignment.Stretch };
        foreach (var option in FolderColors)
            colorBox.Items.Add(new ComboBoxItem { Content = option.Name, Tag = option.Value });

        SelectTaggedItem(iconBox, folder?.icon ?? "folder.fill");
        SelectTaggedItem(colorBox, folder?.color ?? "#0078D4");

        var dialog = new ContentDialog
        {
            Title = folder == null ? "New Folder" : "Edit Folder",
            Content = new StackPanel
            {
                Spacing = 12,
                MinWidth = 320,
                Children = { nameBox, iconBox, colorBox }
            },
            PrimaryButtonText = folder == null ? "Create" : "Save",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary,
            XamlRoot = Content.XamlRoot
        };

        dialog.PrimaryButtonClick += (_, args) =>
        {
            if (string.IsNullOrWhiteSpace(nameBox.Text))
                args.Cancel = true;
        };

        if (await dialog.ShowAsync() != ContentDialogResult.Primary)
            return;

        string icon = (iconBox.SelectedItem as ComboBoxItem)?.Tag?.ToString() ?? "folder.fill";
        string color = (colorBox.SelectedItem as ComboBoxItem)?.Tag?.ToString() ?? "#0078D4";

        if (folder == null)
        {
            var created = OtpAccountExtensions.NewFolder(nameBox.Text.Trim(), icon, color) with
            {
                sortOrder = _client.ListFolders().Count
            };
            _client.AddFolder(created);
        }
        else
        {
            _client.UpdateFolder(folder with
            {
                name = nameBox.Text.Trim(),
                icon = icon,
                color = color
            });
        }
    }

    private async Task ConfirmDeleteFolderAsync(OtpFolder folder, int accountCount)
    {
        var dialog = new ContentDialog
        {
            Title = $"Delete {folder.name}?",
            Content = accountCount == 0
                ? "The folder will be removed from every synced device."
                : $"The folder will be removed. Its {accountCount} account(s) will stay in Uncategorized.",
            PrimaryButtonText = "Delete",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Close,
            XamlRoot = Content.XamlRoot
        };

        if (await dialog.ShowAsync() == ContentDialogResult.Primary)
            _client.DeleteFolder(folder.id);
    }

    private static void SelectTaggedItem(ComboBox comboBox, string tag)
    {
        foreach (var item in comboBox.Items.OfType<ComboBoxItem>())
        {
            if (string.Equals(item.Tag?.ToString(), tag, StringComparison.OrdinalIgnoreCase))
            {
                comboBox.SelectedItem = item;
                return;
            }
        }
        comboBox.SelectedIndex = 0;
    }

    private static string FolderGlyph(string? icon) => icon switch
    {
        "briefcase.fill" => "\uE821",
        "person.fill" => "\uE77B",
        "creditcard.fill" => "\uE8C7",
        "lock.fill" => "\uE72E",
        "cloud.fill" => "\uE753",
        "cart.fill" => "\uE7BF",
        "gamecontroller.fill" => "\uE7FC",
        _ => "\uE8B7"
    };

    private void SetupWindow()
    {
        var hwnd = WinRT.Interop.WindowNative.GetWindowHandle(this);
        var windowId = Microsoft.UI.Win32Interop.GetWindowIdFromWindow(hwnd);
        var appWindow = Microsoft.UI.Windowing.AppWindow.GetFromWindowId(windowId);

        appWindow.Resize(new Windows.Graphics.SizeInt32(1040, 720));
        appWindow.Title = "OTPeek";

        // WinUI does not reliably pick up the executable resource icon for an
        // unpackaged window. Set the same packaged artwork explicitly so the title
        // bar, Alt+Tab and development builds never fall back to the generic icon.
        string iconPath = Path.Combine(AppContext.BaseDirectory, "Assets", "Logo", "app.ico");
        if (File.Exists(iconPath))
            appWindow.SetIcon(iconPath);

        // Mica follows the active Windows light/dark setting and gracefully falls
        // back to the themed surfaces in XAML when the backdrop is unavailable.
        try
        {
            SystemBackdrop = new Microsoft.UI.Xaml.Media.MicaBackdrop();
        }
        catch
        {
            // Older/unsupported systems keep the tokenized fallback background.
        }

        appWindow.Closing += OnWindowClosing;
    }

    private async void OnImportQrTapped(object sender, Microsoft.UI.Xaml.Input.TappedRoutedEventArgs e)
    {
        await GetAccountListPage().ShowQrScannerDialogAsync();
    }

    private async void OnAddAccountTapped(object sender, Microsoft.UI.Xaml.Input.TappedRoutedEventArgs e)
    {
        await GetAccountListPage().ShowManualAddDialogAsync();
    }

    private async void OnPasteUriTapped(object sender, Microsoft.UI.Xaml.Input.TappedRoutedEventArgs e)
    {
        try
        {
            var content = Windows.ApplicationModel.DataTransfer.Clipboard.GetContent();
            if (!content.Contains(Windows.ApplicationModel.DataTransfer.StandardDataFormats.Text))
                throw new InvalidOperationException("The clipboard does not contain text.");

            var text = (await content.GetTextAsync()).Trim();
            if (string.IsNullOrEmpty(text) || !AccountEditView.InitializeFromUri(text))
                throw new InvalidOperationException("Copy a valid otpauth:// URI and try again.");

            EditOverlay.Visibility = Visibility.Visible;
        }
        catch (Exception ex)
        {
            var dialog = new ContentDialog
            {
                Title = "Could not read an OTP account",
                Content = ex.Message,
                CloseButtonText = "OK",
                XamlRoot = Content.XamlRoot
            };
            await dialog.ShowAsync();
        }
    }

    private AccountListPage GetAccountListPage()
    {
        if (ContentFrame.Content is not AccountListPage page)
        {
            ContentFrame.Navigate(
                typeof(AccountListPage),
                new AccountListNavigationArgs { Title = "All Accounts" });
            page = (AccountListPage)ContentFrame.Content;
        }

        return page;
    }

    private void OnNavigationSelectionChanged(NavigationView sender, NavigationViewSelectionChangedEventArgs args)
    {
        if (args.IsSettingsSelected)
        {
            ContentFrame.Navigate(typeof(SettingsPage));
            return;
        }

        var selectedItem = args.SelectedItem as NavigationViewItem;
        if (selectedItem == null) return;

        var tag = selectedItem.Tag?.ToString();

        if (string.IsNullOrEmpty(tag))
            return;

        if (tag.StartsWith("folder:"))
        {
            var folderId = tag.Substring(7);
            ContentFrame.Navigate(typeof(AccountListPage), new AccountListNavigationArgs
            {
                FolderId = folderId,
                Title = selectedItem.Content?.ToString()?.Replace($"  {_client.ListAccounts().Count(a => a.folderId == folderId)}", string.Empty)
                    ?? "Folder"
            });
        }
        else
        {
            var pageType = tag switch
            {
                "accounts" => typeof(AccountListPage),
                "favorites" => typeof(AccountListPage),
                "uncategorized" => typeof(AccountListPage),
                "backup" => typeof(BackupPage),
                _ => typeof(AccountListPage)
            };

            object? parameter = tag switch
            {
                "accounts" => new AccountListNavigationArgs { Title = "All Accounts" },
                "favorites" => new AccountListNavigationArgs { ShowFavoritesOnly = true, Title = "Favorites" },
                "uncategorized" => new AccountListNavigationArgs { ShowUncategorizedOnly = true, Title = "Uncategorized" },
                _ => null
            };

            ContentFrame.Navigate(pageType, parameter);
        }
    }

    private void OnWindowClosing(object sender, Microsoft.UI.Windowing.AppWindowClosingEventArgs args)
    {
        var settingsService = App.Services.GetRequiredService<ISettingsService>();
        if (settingsService.Settings.MinimizeToTray)
        {
            args.Cancel = true;
            this.Hide();
        }
    }

    public void Show()
    {
        this.Activate();
    }

    public void NavigateToSettings()
    {
        ContentFrame.Navigate(typeof(SettingsPage));
    }

    public void ShowAccountEditor(OtpAccount account)
    {
        AccountEditView.InitializeForEdit(account);
        EditOverlay.Visibility = Visibility.Visible;
    }

    public void HideAccountEditor()
    {
        EditOverlay.Visibility = Visibility.Collapsed;
    }

    public void Hide()
    {
        var hwnd = WinRT.Interop.WindowNative.GetWindowHandle(this);
        PInvoke.User32.ShowWindow(hwnd, PInvoke.User32.ShowWindowCommand.SW_HIDE);
    }
}

/// <summary>
/// AccountListPage 네비게이션 인자
/// </summary>
public class AccountListNavigationArgs
{
    /// <summary>코어 폴더 UUID 문자열</summary>
    public string? FolderId { get; set; }
    public bool ShowFavoritesOnly { get; set; }
    public bool ShowUncategorizedOnly { get; set; }
    public string Title { get; set; } = "All Accounts";
}

/// <summary>
/// P/Invoke 헬퍼
/// </summary>
internal static partial class PInvoke
{
    internal static class User32
    {
        public enum ShowWindowCommand
        {
            SW_HIDE = 0,
            SW_SHOW = 5,
            SW_MINIMIZE = 6,
            SW_RESTORE = 9
        }

        [System.Runtime.InteropServices.DllImport("user32.dll")]
        public static extern bool ShowWindow(IntPtr hWnd, ShowWindowCommand nCmdShow);
    }
}
