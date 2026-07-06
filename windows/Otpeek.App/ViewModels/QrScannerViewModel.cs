using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Otpeek.Core.Services.Interfaces;
using Otpeek.Core.Windows.Services;
using Uniffi.Otpeek;

namespace Otpeek.App.ViewModels;

/// <summary>
/// QR 코드 스캐너 ViewModel.
/// QR에서 원본 URI를 추출한 뒤, 실제 추가는 OtpClient.AddFromUri(otpauth:// 또는
/// otpauth-migration://)로 코어에 위임합니다.
/// </summary>
public partial class QrScannerViewModel : BaseViewModel
{
    private readonly IQrCodeService _qrCodeService;
    private readonly IScreenCaptureService _screenCaptureService;
    private readonly IOtpClientService _client;

    /// <summary>스캔/입력된 원본 URI (otpauth:// 또는 otpauth-migration://)</summary>
    private string? _scannedUri;

    [ObservableProperty]
    private string _statusMessage = "Click 'Scan Screen' to capture QR code from your screen";

    [ObservableProperty]
    private bool _isScanning;

    /// <summary>미리보기용 파싱된 계정 (단일 otpauth:// 인 경우). 마이그레이션 URI면 null.</summary>
    [ObservableProperty]
    private OtpAccount? _scannedAccount;

    [ObservableProperty]
    private bool _hasScannedAccount;

    [ObservableProperty]
    private string? _manualUri;

    public event EventHandler<OtpAccount>? AccountAdded;
    public event EventHandler? CloseRequested;

    public QrScannerViewModel(
        IQrCodeService qrCodeService,
        IScreenCaptureService screenCaptureService,
        IOtpClientService client)
    {
        _qrCodeService = qrCodeService;
        _screenCaptureService = screenCaptureService;
        _client = client;
    }

    [RelayCommand]
    private async Task ScanScreenAsync()
    {
        if (IsScanning) return;

        await ExecuteAsync(async () =>
        {
            IsScanning = true;
            StatusMessage = "Scanning screen for QR codes...";
            ClearPreview();

            var captures = await _screenCaptureService.CaptureAllScreensAsync();

            foreach (var capture in captures)
            {
                if (!capture.IsSuccess) continue;

                var text = _qrCodeService.DecodeFromImage(capture.PixelData, capture.Width, capture.Height);
                if (AcceptScannedText(text))
                    return;
            }

            StatusMessage = "No QR code found on screen. Try selecting a specific area.";
        });

        IsScanning = false;
    }

    [RelayCommand]
    private async Task ScanWithPickerAsync()
    {
        if (IsScanning) return;

        await ExecuteAsync(async () =>
        {
            IsScanning = true;
            StatusMessage = "Select a window or screen area...";
            ClearPreview();

            var capture = await _screenCaptureService.CaptureWithPickerAsync();
            if (capture == null || !capture.IsSuccess)
            {
                StatusMessage = "Capture cancelled or failed";
                return;
            }

            var text = _qrCodeService.DecodeFromImage(capture.PixelData, capture.Width, capture.Height);
            if (!AcceptScannedText(text))
                StatusMessage = "No QR code found in selected area";
        });

        IsScanning = false;
    }

    [RelayCommand]
    private void ScanFromFile(string filePath)
    {
        if (string.IsNullOrWhiteSpace(filePath)) return;

        StatusMessage = "Scanning QR code from image file...";
        ClearPreview();

        var text = _qrCodeService.DecodeFromFile(filePath);
        if (!AcceptScannedText(text))
            StatusMessage = "No QR code found in the image file";
    }

    [RelayCommand]
    private void ParseManualUri()
    {
        if (string.IsNullOrWhiteSpace(ManualUri))
        {
            StatusMessage = "Please enter an otpauth:// URI";
            return;
        }

        if (!AcceptScannedText(ManualUri))
            StatusMessage = "Invalid otpauth:// URI format";
    }

    /// <summary>
    /// 스캔/입력된 텍스트가 유효한 OTP URI면 미리보기를 설정하고 true를 반환합니다.
    /// </summary>
    private bool AcceptScannedText(string? text)
    {
        if (string.IsNullOrWhiteSpace(text))
            return false;

        if (text.StartsWith("otpauth-migration://", StringComparison.OrdinalIgnoreCase))
        {
            _scannedUri = text;
            ScannedAccount = null;
            HasScannedAccount = true;
            StatusMessage = "Google Authenticator export detected. It may contain multiple accounts.";
            return true;
        }

        if (text.StartsWith("otpauth://", StringComparison.OrdinalIgnoreCase))
        {
            try
            {
                var preview = OtpeekMethods.ParseOtpauthUri(text, DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());
                _scannedUri = text;
                ScannedAccount = preview;
                HasScannedAccount = true;
                StatusMessage = "QR code scanned successfully!";
                return true;
            }
            catch (OtpException)
            {
                return false;
            }
        }

        return false;
    }

    private void ClearPreview()
    {
        ScannedAccount = null;
        HasScannedAccount = false;
        _scannedUri = null;
    }

    [RelayCommand]
    private async Task SaveAccountAsync()
    {
        if (string.IsNullOrEmpty(_scannedUri)) return;

        await ExecuteAsync(() =>
        {
            var added = _client.AddFromUri(_scannedUri!);
            if (added.Count > 0)
            {
                AccountAdded?.Invoke(this, added[0]);
                StatusMessage = added.Count == 1
                    ? "Account added successfully!"
                    : $"{added.Count} accounts added successfully!";
            }
            return Task.CompletedTask;
        });

        await Task.Delay(1000);
        CloseRequested?.Invoke(this, EventArgs.Empty);
    }

    [RelayCommand]
    private void Cancel()
    {
        CloseRequested?.Invoke(this, EventArgs.Empty);
    }

    public void Reset()
    {
        StatusMessage = "Click 'Scan Screen' to capture QR code from your screen";
        ClearPreview();
        ManualUri = null;
        IsScanning = false;
    }
}
