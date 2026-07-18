using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Otpeek.App.ViewModels;
using Windows.Graphics;

namespace Otpeek.App.Views;

/// <summary>
/// Compact system-tray surface. A single instance is retained by <see cref="App"/>
/// while it is open so repeated tray clicks focus the existing popup.
/// </summary>
public sealed partial class TrayPopupWindow : Window
{
    public TrayPopupViewModel ViewModel { get; }

    /// <summary>Raised exactly once while the native window is closing.</summary>
    public event EventHandler? PopupClosed;

    private AppWindow? _appWindow;
    private bool _isClosing;

    public TrayPopupWindow()
    {
        InitializeComponent();

        ViewModel = App.Services.GetRequiredService<TrayPopupViewModel>();
        AccountListView.ItemsSource = ViewModel.Accounts;

        ViewModel.CloseRequested += OnCloseRequested;
        ViewModel.OpenMainWindowRequested += OnOpenMainWindowRequested;
        ViewModel.OpenSettingsRequested += OnOpenSettingsRequested;
        ViewModel.PropertyChanged += OnViewModelPropertyChanged;

        RefreshButton.Click += OnRefreshClick;
        SettingsButton.Click += OnSettingsClick;
        OpenAppButton.Click += OnOpenAppClick;

        SetupWindow();
        _ = RefreshAccountsAsync();
    }

    private void SetupWindow()
    {
        var hwnd = WinRT.Interop.WindowNative.GetWindowHandle(this);
        var windowId = Microsoft.UI.Win32Interop.GetWindowIdFromWindow(hwnd);
        _appWindow = AppWindow.GetFromWindowId(windowId);

        if (_appWindow != null)
        {
            _appWindow.Resize(new SizeInt32(360, 420));
            _appWindow.Closing += OnAppWindowClosing;

            if (_appWindow.Presenter is OverlappedPresenter presenter)
            {
                presenter.IsAlwaysOnTop = true;
                presenter.SetBorderAndTitleBar(false, false);
                presenter.IsResizable = false;
                presenter.IsMinimizable = false;
                presenter.IsMaximizable = false;
            }

            PositionNearTaskbar();
        }

        Activated += OnWindowActivated;
    }

    private void PositionNearTaskbar()
    {
        if (_appWindow == null) return;

        try
        {
            var displayArea = DisplayArea.GetFromWindowId(_appWindow.Id, DisplayAreaFallback.Primary);
            var workArea = displayArea.WorkArea;
            var windowSize = _appWindow.Size;

            int x = workArea.X + workArea.Width - windowSize.Width - 12;
            int y = workArea.Y + workArea.Height - windowSize.Height - 12;
            _appWindow.Move(new PointInt32(x, y));
        }
        catch
        {
            // Keep the system-selected position if display information is unavailable.
        }
    }

    private async Task RefreshAccountsAsync()
    {
        RefreshButton.IsEnabled = false;
        try
        {
            await ViewModel.LoadAccountsAsync();
            UpdateEmptyState();
        }
        finally
        {
            RefreshButton.IsEnabled = true;
        }
    }

    private void UpdateEmptyState()
    {
        EmptyState.Visibility = ViewModel.IsEmpty ? Visibility.Visible : Visibility.Collapsed;
        AccountListView.Visibility = ViewModel.IsEmpty ? Visibility.Collapsed : Visibility.Visible;
    }

    private void UpdateCopyFeedback()
    {
        CopyFeedbackText.Text = ViewModel.CopyFeedback;
        CopyFeedbackPanel.Visibility = ViewModel.IsCopyFeedbackVisible
            ? Visibility.Visible
            : Visibility.Collapsed;
        CopyHintText.Visibility = ViewModel.IsCopyFeedbackVisible
            ? Visibility.Collapsed
            : Visibility.Visible;
    }

    private void OnWindowActivated(object sender, WindowActivatedEventArgs args)
    {
        if (args.WindowActivationState == WindowActivationState.Deactivated)
            ClosePopup();
    }

    private void OnAppWindowClosing(AppWindow sender, AppWindowClosingEventArgs args)
    {
        if (_isClosing) return;
        _isClosing = true;

        ViewModel.Cleanup();
        ViewModel.CloseRequested -= OnCloseRequested;
        ViewModel.OpenMainWindowRequested -= OnOpenMainWindowRequested;
        ViewModel.OpenSettingsRequested -= OnOpenSettingsRequested;
        ViewModel.PropertyChanged -= OnViewModelPropertyChanged;

        Activated -= OnWindowActivated;
        sender.Closing -= OnAppWindowClosing;

        PopupClosed?.Invoke(this, EventArgs.Empty);
    }

    private void OnViewModelPropertyChanged(object? sender, System.ComponentModel.PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(ViewModel.IsEmpty))
            UpdateEmptyState();
        else if (e.PropertyName is nameof(ViewModel.CopyFeedback) or nameof(ViewModel.IsCopyFeedbackVisible))
            UpdateCopyFeedback();
    }

    private async void OnAccountItemClick(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is AccountItemViewModel account)
            await ViewModel.CopyAccountAsync(account);
    }

    private async void OnRefreshClick(object sender, RoutedEventArgs e) => await RefreshAccountsAsync();

    private void OnSettingsClick(object sender, RoutedEventArgs e) =>
        ViewModel.OpenSettingsCommand.Execute(null);

    private void OnOpenAppClick(object sender, RoutedEventArgs e) =>
        ViewModel.OpenMainWindowCommand.Execute(null);

    private void OnCloseRequested(object? sender, EventArgs e) => ClosePopup();

    private void OnOpenMainWindowRequested(object? sender, EventArgs e)
    {
        if (App.MainWindow is MainWindow mainWindow)
        {
            mainWindow.Show();
            mainWindow.Activate();
        }
    }

    private void OnOpenSettingsRequested(object? sender, EventArgs e)
    {
        if (App.MainWindow is MainWindow mainWindow)
        {
            mainWindow.Show();
            mainWindow.NavigateToSettings();
            mainWindow.Activate();
        }
    }

    private void ClosePopup()
    {
        if (!_isClosing)
            Close();
    }
}
