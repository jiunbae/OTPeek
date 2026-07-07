using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Otpeek.Core.Services.Interfaces;
using Otpeek.Core.Windows.Services;
using Uniffi.Otpeek;

namespace Otpeek.App.ViewModels;

/// <summary>
/// 설정 ViewModel
/// </summary>
public partial class SettingsViewModel : BaseViewModel
{
    private readonly ISettingsService _settingsService;
    private readonly ISecureStorageService _secureStorage;
    private readonly IOtpClientService _client;

    [ObservableProperty]
    private bool _startWithWindows;

    [ObservableProperty]
    private bool _startMinimized;

    [ObservableProperty]
    private bool _minimizeToTray;

    [ObservableProperty]
    private bool _autoCopyToClipboard;

    [ObservableProperty]
    private int _clipboardClearSeconds;

    [ObservableProperty]
    private bool _enableWidgetProvider;

    [ObservableProperty]
    private string _selectedTheme = "System";

    [ObservableProperty]
    private bool _requireAuthentication;

    [ObservableProperty]
    private bool _showFavicons;

    // --- WebDAV 동기화 ---

    [ObservableProperty]
    private bool _webDavEnabled;

    [ObservableProperty]
    private string _webDavUrl = string.Empty;

    [ObservableProperty]
    private string _webDavUsername = string.Empty;

    [ObservableProperty]
    private string _webDavPassword = string.Empty;

    [ObservableProperty]
    private bool _webDavAutoSync;

    [ObservableProperty]
    private int _webDavSyncIntervalMinutes;

    [ObservableProperty]
    private string? _syncStatus;

    public IReadOnlyList<string> ThemeOptions { get; } = new[] { "System", "Light", "Dark" };
    public IReadOnlyList<int> ClipboardClearOptions { get; } = new[] { 0, 15, 30, 60, 120 };
    public IReadOnlyList<int> SyncIntervalOptions { get; } = new[] { 5, 15, 30, 60 };

    public SettingsViewModel(
        ISettingsService settingsService,
        ISecureStorageService secureStorage,
        IOtpClientService client)
    {
        _settingsService = settingsService;
        _secureStorage = secureStorage;
        _client = client;
    }

    [RelayCommand]
    public async Task LoadSettingsAsync()
    {
        await _settingsService.LoadAsync();
        var settings = _settingsService.Settings;

        StartWithWindows = settings.StartWithWindows;
        StartMinimized = settings.StartMinimized;
        MinimizeToTray = settings.MinimizeToTray;
        AutoCopyToClipboard = settings.AutoCopyToClipboard;
        ClipboardClearSeconds = settings.ClipboardClearSeconds;
        EnableWidgetProvider = settings.EnableWidgetProvider;
        SelectedTheme = settings.Theme;
        RequireAuthentication = settings.RequireAuthentication;
        ShowFavicons = settings.ShowFavicons;

        WebDavEnabled = settings.WebDav.Enabled;
        WebDavUrl = settings.WebDav.Url;
        WebDavUsername = settings.WebDav.Username;
        WebDavPassword = _secureStorage.UnprotectString(settings.WebDav.ProtectedPassword) ?? string.Empty;
        WebDavAutoSync = settings.WebDav.AutoSync;
        WebDavSyncIntervalMinutes = settings.WebDav.SyncIntervalMinutes;
    }

    [RelayCommand]
    public async Task SaveSettingsAsync()
    {
        await ExecuteAsync(async () =>
        {
            var settings = _settingsService.Settings;

            settings.StartWithWindows = StartWithWindows;
            settings.StartMinimized = StartMinimized;
            settings.MinimizeToTray = MinimizeToTray;
            settings.AutoCopyToClipboard = AutoCopyToClipboard;
            settings.ClipboardClearSeconds = ClipboardClearSeconds;
            settings.EnableWidgetProvider = EnableWidgetProvider;
            settings.Theme = SelectedTheme;
            settings.RequireAuthentication = RequireAuthentication;
            settings.ShowFavicons = ShowFavicons;

            settings.WebDav.Enabled = WebDavEnabled;
            settings.WebDav.Url = WebDavUrl;
            settings.WebDav.Username = WebDavUsername;
            settings.WebDav.ProtectedPassword = string.IsNullOrEmpty(WebDavPassword)
                ? string.Empty
                : _secureStorage.ProtectString(WebDavPassword);
            settings.WebDav.AutoSync = WebDavAutoSync;
            settings.WebDav.SyncIntervalMinutes = WebDavSyncIntervalMinutes;

            await _settingsService.SaveAsync();

            ApplyWebDavToClient();
            await UpdateStartupAsync();
        });
    }

    /// <summary>
    /// 현재 WebDAV 설정을 코어 동기화 백엔드에 반영
    /// </summary>
    private void ApplyWebDavToClient()
    {
        if (!_client.IsUnlocked)
            return;

        try
        {
            if (WebDavEnabled && !string.IsNullOrWhiteSpace(WebDavUrl))
                _client.ConfigureWebDavSync(WebDavUrl, WebDavUsername, WebDavPassword);
            else
                _client.ClearSync();
        }
        catch
        {
            // 구성 실패는 무시 (SyncNow 시 오류 표시)
        }
    }

    /// <summary>
    /// 지금 동기화
    /// </summary>
    [RelayCommand]
    public async Task SyncNowAsync()
    {
        await ExecuteAsync(() =>
        {
            if (!_client.IsUnlocked)
            {
                SyncStatus = "Vault is locked.";
                return Task.CompletedTask;
            }

            try
            {
                ApplyWebDavToClient();
                SyncOutcome outcome = _client.Sync();
                _settingsService.Settings.WebDav.LastSyncTime = DateTime.UtcNow;
                SyncStatus = $"Synced. pushed={outcome.pushed}, pulled={outcome.pulled}, changes={outcome.mergedChanges}";
            }
            catch (OtpException ex)
            {
                SyncStatus = $"Sync failed: {ex.Message}";
            }
            return Task.CompletedTask;
        });
    }

    [RelayCommand]
    public async Task ResetSettingsAsync()
    {
        await ExecuteAsync(async () =>
        {
            _settingsService.Settings.WebDav.ProtectedPassword = string.Empty;
            await _settingsService.ResetAsync();
            await LoadSettingsAsync();
        });
    }

    private async Task UpdateStartupAsync()
    {
        try
        {
            var startupTask = await global::Windows.ApplicationModel.StartupTask.GetAsync("OtpAuthStartup");

            if (StartWithWindows)
                await startupTask.RequestEnableAsync();
            else
                startupTask.Disable();
        }
        catch
        {
            // 시작 프로그램 설정 실패 (무시)
        }
    }

    partial void OnStartWithWindowsChanged(bool value) => _ = SaveSettingsAsync();
    partial void OnStartMinimizedChanged(bool value) => _ = SaveSettingsAsync();
    partial void OnMinimizeToTrayChanged(bool value) => _ = SaveSettingsAsync();
    partial void OnAutoCopyToClipboardChanged(bool value) => _ = SaveSettingsAsync();
    partial void OnClipboardClearSecondsChanged(int value) => _ = SaveSettingsAsync();
    partial void OnSelectedThemeChanged(string value)
    {
        ApplyTheme(value);
        _ = SaveSettingsAsync();
    }

    public static void ApplyTheme(string theme)
    {
        if (App.MainWindow?.Content is Microsoft.UI.Xaml.FrameworkElement rootElement)
        {
            rootElement.RequestedTheme = theme switch
            {
                "Light" => Microsoft.UI.Xaml.ElementTheme.Light,
                "Dark" => Microsoft.UI.Xaml.ElementTheme.Dark,
                _ => Microsoft.UI.Xaml.ElementTheme.Default
            };
        }
    }
}
