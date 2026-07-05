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
using Microsoft.Windows.AppLifecycle;
using Uniffi.Otp;
using System.Linq;

namespace OtpAuthenticator.App;

/// <summary>
/// 애플리케이션 엔트리포인트
/// </summary>
public partial class App : Application
{
    private TaskbarIcon? _trayIcon;

    /// <summary>
    /// 파일 연결(.otpvault)로 앱이 활성화될 때 열린 파일 경로.
    /// 잠금 해제 흐름이 끝난 뒤 가져오기/복원 다이얼로그에서 소비됩니다.
    /// </summary>
    private string? _pendingImportPath;

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
        // 파일 연결(.otpvault) 등 확장 활성화 인자 확보
        var activationArgs = AppInstance.GetCurrent().GetActivatedEventArgs();

        // 단일 인스턴스: 이미 실행 중인 인스턴스가 있으면 이 활성화를 그쪽으로 넘기고 종료.
        // (실행 중 파일을 더블클릭해도 두 번째 인스턴스가 뜨지 않고 기존 창이 처리)
        var mainInstance = AppInstance.FindOrRegisterForKey("OtpAuthenticatorMainInstance");
        if (!mainInstance.IsCurrent)
        {
            await mainInstance.RedirectActivationToAsync(activationArgs);
            Environment.Exit(0);
            return;
        }

        // 실행 중 추가 활성화(파일 재연결)를 처리하기 위한 이벤트 구독
        mainInstance.Activated += OnAppInstanceActivated;

        // 이번 실행에서 열린 파일 경로 보관
        CapturePendingFile(activationArgs);

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
        // (최초 실행 + 파일 활성화 시 "이 백업으로 복원" 옵션을 제공)
        await UnlockVaultAsync();

        // WebDAV 동기화 백엔드 구성 (설정에 활성화되어 있으면)
        ConfigureSyncFromSettings(settingsService);

        // 파일 연결로 실행되었고 볼트가 열려 있으면 가져오기 다이얼로그 표시
        await HandlePendingFileAsync();

        // 설정에 따라 시작 모드 결정
        if (settingsService.Settings.StartMinimized)
        {
            MainWindow.Hide();
        }
    }

    /// <summary>
    /// 앱이 이미 실행 중일 때 파일을 더블클릭하면 발생하는 재활성화 처리.
    /// 이벤트는 백그라운드 스레드에서 오므로 UI 스레드로 마샬링합니다.
    /// </summary>
    private void OnAppInstanceActivated(object? sender, AppActivationArguments activationArgs)
    {
        MainWindow?.DispatcherQueue.TryEnqueue(async () =>
        {
            CapturePendingFile(activationArgs);
            ShowMainWindow();
            await HandlePendingFileAsync();
        });
    }

    /// <summary>
    /// 활성화 인자가 파일 연결(.otpvault)이면 첫 번째 파일 경로를 보관합니다.
    /// </summary>
    private void CapturePendingFile(AppActivationArguments activationArgs)
    {
        if (activationArgs.Kind != ExtendedActivationKind.File)
            return;

        if (activationArgs.Data is Windows.ApplicationModel.Activation.IFileActivatedEventArgs fileArgs)
        {
            var file = fileArgs.Files.FirstOrDefault();
            if (file != null && !string.IsNullOrEmpty(file.Path))
                _pendingImportPath = file.Path;
        }
    }

    /// <summary>
    /// 보관된 파일이 있고 볼트가 열려 있으면 가져오기 다이얼로그를 표시합니다.
    /// (최초 실행 복원 경로는 <see cref="UnlockVaultAsync"/>에서 이미 소비했을 수 있음)
    /// </summary>
    private async Task HandlePendingFileAsync()
    {
        if (_pendingImportPath == null)
            return;

        var client = Services.GetRequiredService<IOtpClientService>();
        var xamlRoot = MainWindow?.Content?.XamlRoot;
        if (!client.IsUnlocked || xamlRoot == null)
            return; // 볼트를 열지 못했으면 가져오기하지 않음

        string path = _pendingImportPath;
        _pendingImportPath = null; // 소비
        await ShowImportDialogAsync(client, xamlRoot, path);
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

            // 볼트 없음 + 파일 활성화: 열린 백업을 새 볼트로 복원하는 옵션을 먼저 제공
            if (_pendingImportPath != null)
            {
                bool restored = await TryRestoreFromPendingFileAsync(client, xamlRoot);
                if (restored)
                {
                    _pendingImportPath = null; // 복원으로 소비됨 → 이후 가져오기 다이얼로그 생략
                    return;
                }
                // 사용자가 복원을 취소 → 일반 볼트 생성 흐름으로 진행
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

    // --- 파일 연결(.otpvault) 가져오기 / 복원 다이얼로그 ---

    private const string MergeTooltip =
        "Merge adds accounts you don't have yet and restores ones you deleted by mistake. " +
        "Turn it off to replace your entire vault with the contents of this backup.";

    /// <summary>
    /// 열린 .otpvault 백업을 기존 볼트로 가져오는 다이얼로그.
    /// 백업 비밀번호 + 병합 체크박스(기본 켜짐) → <see cref="IOtpClientService.ImportBackup"/>.
    /// v2 컨테이너가 아니면 레거시 v1으로 자동 재시도하며, 잘못된 비밀번호는 다이얼로그를 열어둔 채 재시도합니다.
    /// </summary>
    private static async Task ShowImportDialogAsync(IOtpClientService client, XamlRoot xamlRoot, string filePath)
    {
        byte[] data;
        try
        {
            data = await File.ReadAllBytesAsync(filePath);
        }
        catch (Exception ex)
        {
            await ShowMessageAsync(xamlRoot, "Import failed", $"Could not read the backup file: {ex.Message}");
            return;
        }

        var passwordBox = new PasswordBox { PlaceholderText = "Backup password" };
        var mergeCheck = new CheckBox { Content = "Merge with existing accounts", IsChecked = true };
        ToolTipService.SetToolTip(mergeCheck, MergeTooltip);
        var mergeHint = new TextBlock
        {
            Text = MergeTooltip,
            TextWrapping = TextWrapping.Wrap,
            Opacity = 0.7,
            FontSize = 12
        };
        var errorText = new TextBlock
        {
            Foreground = new Microsoft.UI.Xaml.Media.SolidColorBrush(Microsoft.UI.Colors.OrangeRed),
            Visibility = Visibility.Collapsed,
            TextWrapping = TextWrapping.Wrap
        };

        var dialog = new ContentDialog
        {
            Title = "Import backup",
            Content = new StackPanel
            {
                Spacing = 8,
                Children =
                {
                    new TextBlock
                    {
                        Text = $"Import accounts from \"{Path.GetFileName(filePath)}\". Enter the password used to encrypt this backup.",
                        TextWrapping = TextWrapping.Wrap
                    },
                    passwordBox,
                    mergeCheck,
                    mergeHint,
                    errorText
                }
            },
            PrimaryButtonText = "Import",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary,
            XamlRoot = xamlRoot
        };

        uint importedCount = 0;
        bool imported = false;

        dialog.PrimaryButtonClick += (s, e) =>
        {
            if (string.IsNullOrEmpty(passwordBox.Password))
            {
                errorText.Text = "Password cannot be empty.";
                errorText.Visibility = Visibility.Visible;
                e.Cancel = true;
                return;
            }

            bool merge = mergeCheck.IsChecked == true;
            try
            {
                try
                {
                    // v2 컨테이너 우선
                    importedCount = client.ImportBackup(data, passwordBox.Password, merge);
                }
                catch (OtpException.Corrupt)
                {
                    // v2가 아니면 레거시 v1 .otpbackup으로 재시도
                    importedCount = client.ImportBackupV1(data, passwordBox.Password, merge);
                }
                imported = true;
            }
            catch (OtpException.WrongPassword)
            {
                errorText.Text = "The password is incorrect. Please try again.";
                errorText.Visibility = Visibility.Visible;
                e.Cancel = true;
            }
            catch (OtpException ex)
            {
                errorText.Text = $"Import failed: {ex.Message}";
                errorText.Visibility = Visibility.Visible;
                e.Cancel = true;
            }
        };

        await dialog.ShowAsync();

        if (imported)
            await ShowMessageAsync(xamlRoot, "Import complete",
                $"{importedCount} entity/entities were imported from the backup.");
    }

    /// <summary>
    /// 최초 실행(볼트 없음) 시 열린 .otpvault 백업으로 볼트를 새로 만드는 복원 다이얼로그.
    /// 마스터 비밀번호를 받아 <see cref="IOtpClientService.RestoreFromBlob"/>를 호출합니다.
    /// 복원 성공 시 <c>true</c>, 사용자가 취소하면 <c>false</c>(일반 볼트 생성 흐름으로 진행).
    /// </summary>
    private async Task<bool> TryRestoreFromPendingFileAsync(IOtpClientService client, XamlRoot? xamlRoot)
    {
        if (xamlRoot == null || _pendingImportPath == null)
            return false;

        byte[] data;
        try
        {
            data = await File.ReadAllBytesAsync(_pendingImportPath);
        }
        catch
        {
            return false; // 파일을 읽지 못하면 일반 생성 흐름으로
        }

        var passwordBox = new PasswordBox { PlaceholderText = "Master password" };
        var errorText = new TextBlock
        {
            Foreground = new Microsoft.UI.Xaml.Media.SolidColorBrush(Microsoft.UI.Colors.OrangeRed),
            Visibility = Visibility.Collapsed,
            TextWrapping = TextWrapping.Wrap
        };

        var dialog = new ContentDialog
        {
            Title = "Restore from this backup",
            Content = new StackPanel
            {
                Spacing = 8,
                Children =
                {
                    new TextBlock
                    {
                        Text = $"There is no vault on this device yet. Restore \"{Path.GetFileName(_pendingImportPath)}\" as a new vault? " +
                               "Enter the backup's master password.",
                        TextWrapping = TextWrapping.Wrap
                    },
                    passwordBox,
                    errorText
                }
            },
            PrimaryButtonText = "Restore",
            CloseButtonText = "Set up manually",
            DefaultButton = ContentDialogButton.Primary,
            XamlRoot = xamlRoot
        };

        bool restored = false;

        dialog.PrimaryButtonClick += (s, e) =>
        {
            if (string.IsNullOrEmpty(passwordBox.Password))
            {
                errorText.Text = "Password cannot be empty.";
                errorText.Visibility = Visibility.Visible;
                e.Cancel = true;
                return;
            }

            try
            {
                client.RestoreFromBlob(data, passwordBox.Password);
                restored = true;
            }
            catch (OtpException.WrongPassword)
            {
                errorText.Text = "The master password is incorrect. Please try again.";
                errorText.Visibility = Visibility.Visible;
                e.Cancel = true;
            }
            catch (OtpException ex)
            {
                errorText.Text = $"Restore failed: {ex.Message}";
                errorText.Visibility = Visibility.Visible;
                e.Cancel = true;
            }
        };

        await dialog.ShowAsync();
        return restored;
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
