using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;
using Otpeek.App.ViewModels;

namespace Otpeek.App.Views;

/// <summary>
/// 설정 페이지
/// </summary>
public sealed partial class SettingsPage : Page
{
    public SettingsViewModel ViewModel { get; }
    private bool _isUpdatingUi;

    public SettingsPage()
    {
        this.InitializeComponent();
        ViewModel = App.Services.GetRequiredService<SettingsViewModel>();

        // 이벤트 연결
        ResetButton.Click += async (s, e) =>
        {
            await ViewModel.ResetSettingsCommand.ExecuteAsync(null);
            UpdateUI();
        };
        ThemeCombo.SelectionChanged += OnThemeChanged;
        StartWithWindowsToggle.Toggled += (s, e) =>
        {
            if (!_isUpdatingUi) ViewModel.StartWithWindows = StartWithWindowsToggle.IsOn;
        };
        StartMinimizedToggle.Toggled += (s, e) =>
        {
            if (!_isUpdatingUi) ViewModel.StartMinimized = StartMinimizedToggle.IsOn;
        };
        MinimizeToTrayToggle.Toggled += (s, e) =>
        {
            if (!_isUpdatingUi) ViewModel.MinimizeToTray = MinimizeToTrayToggle.IsOn;
        };
        CopyCodeOnClickToggle.Toggled += (s, e) =>
        {
            if (!_isUpdatingUi) ViewModel.AutoCopyToClipboard = CopyCodeOnClickToggle.IsOn;
        };
        ShowFaviconsToggle.Toggled += (s, e) =>
        {
            if (!_isUpdatingUi) ViewModel.ShowFavicons = ShowFaviconsToggle.IsOn;
        };
        ClipboardClearCombo.SelectionChanged += OnClipboardClearChanged;

        // WebDAV 동기화
        WebDavAutoSyncToggle.Toggled += (s, e) =>
            WebDavSyncIntervalCombo.IsEnabled = WebDavAutoSyncToggle.IsOn;
        SaveWebDavButton.Click += OnSaveWebDavClick;
        SyncNowButton.Click += OnSyncNowClick;
        ViewModel.PropertyChanged += OnViewModelPropertyChanged;
    }

    private void OnViewModelPropertyChanged(object? sender, System.ComponentModel.PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(ViewModel.SyncStatus))
        {
            SyncStatusText.Text = ViewModel.SyncStatus ?? string.Empty;
        }
    }

    private async void OnSaveWebDavClick(object sender, Microsoft.UI.Xaml.RoutedEventArgs e)
    {
        ApplyWebDavInputs();
        await ViewModel.SaveSettingsCommand.ExecuteAsync(null);
    }

    private async void OnSyncNowClick(object sender, Microsoft.UI.Xaml.RoutedEventArgs e)
    {
        // 최신 입력값을 먼저 저장한 뒤 동기화
        ApplyWebDavInputs();
        await ViewModel.SaveSettingsCommand.ExecuteAsync(null);
        await ViewModel.SyncNowCommand.ExecuteAsync(null);
    }

    private void ApplyWebDavInputs()
    {
        ViewModel.WebDavEnabled = WebDavEnabledToggle.IsOn;
        ViewModel.WebDavUrl = WebDavUrlTextBox.Text;
        ViewModel.WebDavUsername = WebDavUserTextBox.Text;
        ViewModel.WebDavPassword = WebDavPasswordBox.Password;
        ViewModel.WebDavAutoSync = WebDavAutoSyncToggle.IsOn;

        if (WebDavSyncIntervalCombo.SelectedItem is ComboBoxItem item &&
            int.TryParse(item.Tag?.ToString(), out int minutes))
        {
            ViewModel.WebDavSyncIntervalMinutes = minutes;
        }
    }

    protected override async void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        await ViewModel.LoadSettingsAsync();
        UpdateUI();
    }

    private void UpdateUI()
    {
        _isUpdatingUi = true;
        try
        {
            StartWithWindowsToggle.IsOn = ViewModel.StartWithWindows;
            StartMinimizedToggle.IsOn = ViewModel.StartMinimized;
            MinimizeToTrayToggle.IsOn = ViewModel.MinimizeToTray;
            CopyCodeOnClickToggle.IsOn = ViewModel.AutoCopyToClipboard;
            ShowFaviconsToggle.IsOn = ViewModel.ShowFavicons;

            // ComboBox 선택
            SelectComboBoxItem(ClipboardClearCombo, ViewModel.ClipboardClearSeconds.ToString());
            SelectComboBoxItem(ThemeCombo, ViewModel.SelectedTheme);

            // WebDAV
            WebDavEnabledToggle.IsOn = ViewModel.WebDavEnabled;
            WebDavUrlTextBox.Text = ViewModel.WebDavUrl;
            WebDavUserTextBox.Text = ViewModel.WebDavUsername;
            WebDavPasswordBox.Password = ViewModel.WebDavPassword;
            WebDavAutoSyncToggle.IsOn = ViewModel.WebDavAutoSync;
            WebDavSyncIntervalCombo.IsEnabled = ViewModel.WebDavAutoSync;
            SelectComboBoxItem(WebDavSyncIntervalCombo, ViewModel.WebDavSyncIntervalMinutes.ToString());
            SyncStatusText.Text = ViewModel.SyncStatus ?? string.Empty;

            VersionText.Text = $"Version {ViewModel.AppVersion}";
            AccountCountText.Text = $"Accounts: {ViewModel.AccountCount}";
            FolderCountText.Text = $"Folders: {ViewModel.FolderCount}";
        }
        finally
        {
            _isUpdatingUi = false;
        }
    }

    private void SelectComboBoxItem(ComboBox comboBox, string tag)
    {
        foreach (ComboBoxItem item in comboBox.Items)
        {
            if (item.Tag?.ToString() == tag)
            {
                comboBox.SelectedItem = item;
                return;
            }
        }
    }

    private void OnThemeChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_isUpdatingUi) return;
        if (ThemeCombo.SelectedItem is ComboBoxItem item && item.Tag is string theme)
        {
            ViewModel.SelectedTheme = theme;
        }
    }

    private void OnClipboardClearChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_isUpdatingUi) return;
        if (ClipboardClearCombo.SelectedItem is ComboBoxItem item && item.Tag is string tag)
        {
            if (int.TryParse(tag, out int seconds))
            {
                ViewModel.ClipboardClearSeconds = seconds;
            }
        }
    }
}
