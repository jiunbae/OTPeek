using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;
using OtpAuthenticator.App.ViewModels;

namespace OtpAuthenticator.App.Views;

/// <summary>
/// 설정 페이지
/// </summary>
public sealed partial class SettingsPage : Page
{
    public SettingsViewModel ViewModel { get; }

    public SettingsPage()
    {
        this.InitializeComponent();
        ViewModel = App.Services.GetRequiredService<SettingsViewModel>();

        // 이벤트 연결
        ResetButton.Click += async (s, e) => await ViewModel.ResetSettingsCommand.ExecuteAsync(null);
        ThemeCombo.SelectionChanged += OnThemeChanged;
        StartWithWindowsToggle.Toggled += (s, e) => ViewModel.StartWithWindows = StartWithWindowsToggle.IsOn;
        StartMinimizedToggle.Toggled += (s, e) => ViewModel.StartMinimized = StartMinimizedToggle.IsOn;
        MinimizeToTrayToggle.Toggled += (s, e) => ViewModel.MinimizeToTray = MinimizeToTrayToggle.IsOn;
        EnableWidgetToggle.Toggled += (s, e) => ViewModel.EnableWidgetProvider = EnableWidgetToggle.IsOn;
        RequireAuthToggle.Toggled += (s, e) => ViewModel.RequireAuthentication = RequireAuthToggle.IsOn;
        ClipboardClearCombo.SelectionChanged += OnClipboardClearChanged;

        // WebDAV 동기화
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
        ViewModel.WebDavEnabled = WebDavEnabledToggle.IsOn;
        ViewModel.WebDavUrl = WebDavUrlTextBox.Text;
        ViewModel.WebDavUsername = WebDavUserTextBox.Text;
        ViewModel.WebDavPassword = WebDavPasswordBox.Password;
        await ViewModel.SaveSettingsCommand.ExecuteAsync(null);
    }

    private async void OnSyncNowClick(object sender, Microsoft.UI.Xaml.RoutedEventArgs e)
    {
        // 최신 입력값을 먼저 저장한 뒤 동기화
        ViewModel.WebDavEnabled = WebDavEnabledToggle.IsOn;
        ViewModel.WebDavUrl = WebDavUrlTextBox.Text;
        ViewModel.WebDavUsername = WebDavUserTextBox.Text;
        ViewModel.WebDavPassword = WebDavPasswordBox.Password;
        await ViewModel.SaveSettingsCommand.ExecuteAsync(null);
        await ViewModel.SyncNowCommand.ExecuteAsync(null);
    }

    protected override async void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        await ViewModel.LoadSettingsAsync();
        UpdateUI();
    }

    private void UpdateUI()
    {
        StartWithWindowsToggle.IsOn = ViewModel.StartWithWindows;
        StartMinimizedToggle.IsOn = ViewModel.StartMinimized;
        MinimizeToTrayToggle.IsOn = ViewModel.MinimizeToTray;
        EnableWidgetToggle.IsOn = ViewModel.EnableWidgetProvider;
        RequireAuthToggle.IsOn = ViewModel.RequireAuthentication;

        // ComboBox 선택
        SelectComboBoxItem(ClipboardClearCombo, ViewModel.ClipboardClearSeconds.ToString());
        SelectComboBoxItem(ThemeCombo, ViewModel.SelectedTheme);

        // WebDAV
        WebDavEnabledToggle.IsOn = ViewModel.WebDavEnabled;
        WebDavUrlTextBox.Text = ViewModel.WebDavUrl;
        WebDavUserTextBox.Text = ViewModel.WebDavUsername;
        WebDavPasswordBox.Password = ViewModel.WebDavPassword;
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
        if (ThemeCombo.SelectedItem is ComboBoxItem item && item.Tag is string theme)
        {
            ViewModel.SelectedTheme = theme;
        }
    }

    private void OnClipboardClearChanged(object sender, SelectionChangedEventArgs e)
    {
        if (ClipboardClearCombo.SelectedItem is ComboBoxItem item && item.Tag is string tag)
        {
            if (int.TryParse(tag, out int seconds))
            {
                ViewModel.ClipboardClearSeconds = seconds;
            }
        }
    }
}
