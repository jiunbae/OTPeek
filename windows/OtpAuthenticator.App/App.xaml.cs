using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using OtpAuthenticator.App.ViewModels;
using OtpAuthenticator.App.Views;
using OtpAuthenticator.Core.Extensions;
using OtpAuthenticator.Core.Windows.Extensions;
using OtpAuthenticator.Core.Windows.Services;
using OtpAuthenticator.Core.Services.Interfaces;
using H.NotifyIcon;
using Uniffi.Otp;

namespace OtpAuthenticator.App;

/// <summary>
/// 애플리케이션 엔트리포인트
/// </summary>
public partial class App : Application
{
    private TaskbarIcon? _trayIcon;

    public static IServiceProvider Services { get; private set; } = null!;

    /// <summary>
    /// 메인 윈도우 접근용 정적 속성
    /// </summary>
    public static Window? MainWindow { get; private set; }

    public App()
    {
        this.InitializeComponent();

        // DI 컨테이너 설정
        Services = ConfigureServices();
    }

    protected override async void OnLaunched(LaunchActivatedEventArgs args)
    {
        // 설정 로드
        var settingsService = Services.GetRequiredService<ISettingsService>();
        await settingsService.LoadAsync();

        // 메인 윈도우 생성
        MainWindow = new MainWindow();

        // 저장된 테마 적용
        SettingsViewModel.ApplyTheme(settingsService.Settings.Theme);

        // 시스템 트레이 초기화
        InitializeTrayIcon();

        // 윈도우를 먼저 활성화하여 다이얼로그를 표시할 XamlRoot를 확보
        MainWindow.Activate();

        // 볼트 잠금 해제 / 최초 실행 / 마이그레이션 흐름
        await UnlockVaultAsync();

        // WebDAV 동기화 백엔드 구성 (설정에 활성화되어 있으면)
        ConfigureSyncFromSettings(settingsService);

        // 설정에 따라 시작 모드 결정
        if (settingsService.Settings.StartMinimized)
        {
            MainWindow.Hide();
        }
    }

    /// <summary>
    /// 시작 시 볼트를 잠금 해제하거나(저장된 VMK/비밀번호), 최초 실행 시 볼트를 생성하고
    /// 레거시 데이터가 있으면 마이그레이션합니다.
    /// </summary>
    private async Task UnlockVaultAsync()
    {
        var client = Services.GetRequiredService<IOtpClientService>();
        var migration = Services.GetRequiredService<ILegacyMigrationService>();
        var xamlRoot = MainWindow?.Content?.XamlRoot;

        try
        {
            if (client.VaultExists)
            {
                // 기존 볼트: 저장된 키로 열기, 실패 시 마스터 비밀번호로 부트스트랩
                if (client.HasStoredKey)
                {
                    try
                    {
                        client.OpenWithStoredKey();
                        return;
                    }
                    catch (OtpException)
                    {
                        // 키 손상/불일치 → 비밀번호로 재시도
                    }
                }

                await OpenWithPasswordLoopAsync(client, xamlRoot);
                return;
            }

            // 볼트 없음: 마스터 비밀번호 생성 후 볼트 생성
            string? newPassword = await PromptCreatePasswordAsync(xamlRoot);
            if (string.IsNullOrEmpty(newPassword))
                return; // 사용자가 취소 (다음 실행에서 다시 시도)

            client.CreateVault(newPassword);

            // 레거시 로컬 계정이 있으면 가져오기
            if (migration.HasLegacyData())
            {
                int count = migration.Migrate(client);
                if (count > 0 && xamlRoot != null)
                {
                    await ShowMessageAsync(xamlRoot, "Migration complete",
                        $"{count} account(s) were migrated from the previous version.");
                }
            }
        }
        catch (Exception ex)
        {
            if (xamlRoot != null)
                await ShowMessageAsync(xamlRoot, "Vault error", ex.Message);
        }
    }

    private static async Task OpenWithPasswordLoopAsync(IOtpClientService client, XamlRoot? xamlRoot)
    {
        for (int attempt = 0; attempt < 5; attempt++)
        {
            string? password = await PromptPasswordAsync(xamlRoot,
                "Unlock vault", "Enter your master password to unlock the vault:");
            if (string.IsNullOrEmpty(password))
                return;

            try
            {
                client.OpenWithPassword(password);
                return;
            }
            catch (OtpException.WrongPassword)
            {
                if (xamlRoot != null)
                    await ShowMessageAsync(xamlRoot, "Wrong password", "The master password is incorrect. Please try again.");
            }
        }
    }

    private void ConfigureSyncFromSettings(ISettingsService settingsService)
    {
        var client = Services.GetRequiredService<IOtpClientService>();
        var secure = Services.GetRequiredService<ISecureStorageService>();
        var webdav = settingsService.Settings.WebDav;

        if (!client.IsUnlocked || !webdav.Enabled || string.IsNullOrWhiteSpace(webdav.Url))
            return;

        string? password = secure.UnprotectString(webdav.ProtectedPassword);
        try
        {
            client.ConfigureWebDavSync(webdav.Url, webdav.Username, password ?? string.Empty);
        }
        catch
        {
            // 동기화 구성 실패는 앱 시작을 막지 않음
        }
    }

    // --- 마스터 비밀번호 다이얼로그 ---

    private static async Task<string?> PromptCreatePasswordAsync(XamlRoot? xamlRoot)
    {
        if (xamlRoot == null) return null;

        var passwordBox = new PasswordBox { PlaceholderText = "Master password", Margin = new Thickness(0, 8, 0, 0) };
        var confirmBox = new PasswordBox { PlaceholderText = "Confirm password" };
        var errorText = new TextBlock
        {
            Foreground = new Microsoft.UI.Xaml.Media.SolidColorBrush(Microsoft.UI.Colors.OrangeRed),
            Visibility = Visibility.Collapsed,
            TextWrapping = TextWrapping.Wrap
        };

        var dialog = new ContentDialog
        {
            Title = "Create master password",
            Content = new StackPanel
            {
                Spacing = 8,
                Children =
                {
                    new TextBlock
                    {
                        Text = "Your accounts are protected by an end-to-end-encrypted vault. Choose a master password. It cannot be recovered if lost.",
                        TextWrapping = TextWrapping.Wrap
                    },
                    passwordBox,
                    confirmBox,
                    errorText
                }
            },
            PrimaryButtonText = "Create",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary,
            XamlRoot = xamlRoot
        };

        dialog.PrimaryButtonClick += (s, e) =>
        {
            if (string.IsNullOrEmpty(passwordBox.Password))
            {
                errorText.Text = "Password cannot be empty.";
                errorText.Visibility = Visibility.Visible;
                e.Cancel = true;
            }
            else if (passwordBox.Password != confirmBox.Password)
            {
                errorText.Text = "Passwords do not match.";
                errorText.Visibility = Visibility.Visible;
                e.Cancel = true;
            }
        };

        var result = await dialog.ShowAsync();
        return result == ContentDialogResult.Primary ? passwordBox.Password : null;
    }

    private static async Task<string?> PromptPasswordAsync(XamlRoot? xamlRoot, string title, string message)
    {
        if (xamlRoot == null) return null;

        var passwordBox = new PasswordBox { PlaceholderText = "Master password" };
        var dialog = new ContentDialog
        {
            Title = title,
            Content = new StackPanel
            {
                Spacing = 8,
                Children =
                {
                    new TextBlock { Text = message, TextWrapping = TextWrapping.Wrap },
                    passwordBox
                }
            },
            PrimaryButtonText = "Unlock",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary,
            XamlRoot = xamlRoot
        };

        var result = await dialog.ShowAsync();
        return result == ContentDialogResult.Primary ? passwordBox.Password : null;
    }

    private static async Task ShowMessageAsync(XamlRoot xamlRoot, string title, string message)
    {
        var dialog = new ContentDialog
        {
            Title = title,
            Content = message,
            CloseButtonText = "OK",
            XamlRoot = xamlRoot
        };
        await dialog.ShowAsync();
    }

    private static IServiceProvider ConfigureServices()
    {
        var services = new ServiceCollection();

        // Core 서비스 등록
        services.AddCoreServices();
        services.AddWindowsPlatformServices();

        // ViewModels 등록
        services.AddTransient<MainViewModel>();
        services.AddTransient<AccountListViewModel>();
        services.AddTransient<AccountEditViewModel>();
        services.AddTransient<TrayPopupViewModel>();
        services.AddTransient<SettingsViewModel>();
        services.AddTransient<QrScannerViewModel>();

        return services.BuildServiceProvider();
    }

    private void InitializeTrayIcon()
    {
        try
        {
            _trayIcon = new TaskbarIcon
            {
                ToolTipText = "OTP Authenticator",
                IconSource = new H.NotifyIcon.GeneratedIconSource
                {
                    Text = "OTP",
                    Foreground = new Microsoft.UI.Xaml.Media.SolidColorBrush(Microsoft.UI.Colors.White),
                    Background = new Microsoft.UI.Xaml.Media.SolidColorBrush(Microsoft.UI.Colors.DodgerBlue)
                }
            };
        }
        catch (Exception ex)
        {
            // 트레이 아이콘 초기화 실패 시 로그
            var logPath = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "OtpAuthenticator", "app.log");
            Directory.CreateDirectory(Path.GetDirectoryName(logPath)!);
            File.AppendAllText(logPath, $"[{DateTime.Now}] TrayIcon Error: {ex}\n");
            return;
        }

        // 좌클릭: 팝업 표시
        _trayIcon.LeftClickCommand = new RelayCommand(ShowTrayPopup);

        // 더블클릭: 메인 창 표시
        _trayIcon.DoubleClickCommand = new RelayCommand(ShowMainWindow);

        // 우클릭 컨텍스트 메뉴 설정
        _trayIcon.ContextMenuMode = ContextMenuMode.SecondWindow;
        _trayIcon.ContextFlyout = CreateContextMenu();

        // 트레이 아이콘 강제 생성
        _trayIcon.ForceCreate();
    }

    private MenuFlyout CreateContextMenu()
    {
        var menu = new MenuFlyout();

        // 메인 창 열기
        var openItem = new MenuFlyoutItem
        {
            Text = "Open OTP Authenticator",
            Icon = new FontIcon { Glyph = "\uE8A7" }
        };
        openItem.Click += (s, e) => ShowMainWindow();
        menu.Items.Add(openItem);

        // 설정
        var settingsItem = new MenuFlyoutItem
        {
            Text = "Settings",
            Icon = new FontIcon { Glyph = "\uE713" }
        };
        settingsItem.Click += (s, e) => OpenSettings();
        menu.Items.Add(settingsItem);

        // 구분선
        menu.Items.Add(new MenuFlyoutSeparator());

        // 종료
        var exitItem = new MenuFlyoutItem
        {
            Text = "Exit",
            Icon = new FontIcon { Glyph = "\uE7E8" }
        };
        exitItem.Click += (s, e) => Exit();
        menu.Items.Add(exitItem);

        return menu;
    }

    private void OpenSettings()
    {
        ShowMainWindow();
        // 설정 페이지로 이동
        if (MainWindow is MainWindow mainWin)
        {
            mainWin.NavigateToSettings();
        }
    }

    private void ShowTrayPopup()
    {
        var popup = new TrayPopupWindow();
        popup.Activate();
    }

    private void ShowMainWindow()
    {
        if (MainWindow != null)
        {
            MainWindow.Show();
            MainWindow.Activate();
        }
    }

    public void HideToTray()
    {
        MainWindow?.Hide();
    }

    public new void Exit()
    {
        _trayIcon?.Dispose();
        MainWindow?.Close();
        Environment.Exit(0);
    }
}

/// <summary>
/// 간단한 RelayCommand 구현
/// </summary>
public class RelayCommand : System.Windows.Input.ICommand
{
    private readonly Action _execute;
    private readonly Func<bool>? _canExecute;

    public RelayCommand(Action execute, Func<bool>? canExecute = null)
    {
        _execute = execute;
        _canExecute = canExecute;
    }

    public event EventHandler? CanExecuteChanged;

    public bool CanExecute(object? parameter) => _canExecute?.Invoke() ?? true;

    public void Execute(object? parameter) => _execute();

    public void RaiseCanExecuteChanged() => CanExecuteChanged?.Invoke(this, EventArgs.Empty);
}
