using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Otpeek.Core.Windows;
using Otpeek.Core.Windows.Services;
using Uniffi.Otpeek;

namespace Otpeek.App.ViewModels;

/// <summary>
/// 계정 편집/추가 ViewModel
/// </summary>
public partial class AccountEditViewModel : BaseViewModel
{
    private readonly IOtpClientService _client;

    private OtpAccount? _originalAccount;

    [ObservableProperty]
    private bool _isEditMode;

    [ObservableProperty]
    private string _issuer = string.Empty;

    [ObservableProperty]
    private string _accountName = string.Empty;

    [ObservableProperty]
    private string _secretKey = string.Empty;

    [ObservableProperty]
    private OtpType _selectedType = OtpType.Totp;

    [ObservableProperty]
    private HashAlgorithm _selectedAlgorithm = HashAlgorithm.Sha1;

    [ObservableProperty]
    private int _digits = 6;

    [ObservableProperty]
    private int _period = 30;

    /// <summary>
    /// 메모 (참고: v2 볼트 모델에는 메모 필드가 없어 저장되지 않습니다. UI 호환을 위해 유지)
    /// </summary>
    [ObservableProperty]
    private string? _notes;

    [ObservableProperty]
    private string? _validationError;

    [ObservableProperty]
    private bool _isValid;

    public event EventHandler<OtpAccount>? Saved;
    public event EventHandler? Cancelled;

    public IReadOnlyList<OtpType> OtpTypes { get; } = Enum.GetValues<OtpType>();
    public IReadOnlyList<HashAlgorithm> Algorithms { get; } = Enum.GetValues<HashAlgorithm>();
    public IReadOnlyList<int> DigitOptions { get; } = new[] { 6, 8 };
    public IReadOnlyList<int> PeriodOptions { get; } = new[] { 15, 30, 60 };

    public AccountEditViewModel(IOtpClientService client)
    {
        _client = client;
    }

    public void InitializeForAdd()
    {
        IsEditMode = false;
        _originalAccount = null;

        Issuer = string.Empty;
        AccountName = string.Empty;
        SecretKey = string.Empty;
        SelectedType = OtpType.Totp;
        SelectedAlgorithm = HashAlgorithm.Sha1;
        Digits = 6;
        Period = 30;
        Notes = null;

        Validate();
    }

    public void InitializeForEdit(OtpAccount account)
    {
        IsEditMode = true;
        _originalAccount = account;

        Issuer = account.issuer ?? string.Empty;
        AccountName = account.accountName;
        SecretKey = account.secret;
        SelectedType = account.otpType;
        SelectedAlgorithm = account.algorithm;
        Digits = (int)account.digits;
        Period = (int)account.period;
        Notes = null;

        Validate();
    }

    /// <summary>
    /// otpauth:// URI로 초기화 (미리보기 용도로 코어 파서를 사용)
    /// </summary>
    public bool InitializeFromUri(string uri)
    {
        OtpAccount account;
        try
        {
            account = OtpMethods.ParseOtpauthUri(uri, DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());
        }
        catch (OtpException ex)
        {
            ValidationError = $"Invalid OTP URI: {ex.Message}";
            return false;
        }

        IsEditMode = false;
        _originalAccount = null;

        Issuer = account.issuer ?? string.Empty;
        AccountName = account.accountName;
        SecretKey = account.secret;
        SelectedType = account.otpType;
        SelectedAlgorithm = account.algorithm;
        Digits = (int)account.digits;
        Period = (int)account.period;

        Validate();
        return true;
    }

    private void Validate()
    {
        ValidationError = null;

        if (string.IsNullOrWhiteSpace(AccountName))
        {
            ValidationError = "Account name is required";
            IsValid = false;
            return;
        }

        if (string.IsNullOrWhiteSpace(SecretKey))
        {
            ValidationError = "Secret key is required";
            IsValid = false;
            return;
        }

        if (!OtpMethods.ValidateSecret(SecretKey))
        {
            ValidationError = "Invalid secret key format (must be Base32)";
            IsValid = false;
            return;
        }

        IsValid = true;
    }

    partial void OnAccountNameChanged(string value) => Validate();
    partial void OnSecretKeyChanged(string value) => Validate();

    [RelayCommand(CanExecute = nameof(IsValid))]
    private async Task SaveAsync()
    {
        if (!IsValid) return;

        await ExecuteAsync(() =>
        {
            OtpAccount saved;

            if (IsEditMode && _originalAccount != null)
            {
                var updated = _originalAccount with
                {
                    issuer = string.IsNullOrWhiteSpace(Issuer) ? null : Issuer,
                    accountName = AccountName,
                    secret = SecretKey,
                    otpType = SelectedType,
                    algorithm = SelectedAlgorithm,
                    digits = (uint)Digits,
                    period = (uint)Period
                };
                saved = _client.UpdateAccount(updated);
            }
            else
            {
                var account = OtpAccountExtensions.NewAccount(
                    secret: SecretKey,
                    type: SelectedType,
                    issuer: Issuer,
                    accountName: AccountName,
                    algorithm: SelectedAlgorithm,
                    digits: (uint)Digits,
                    period: (uint)Period);
                saved = _client.AddAccount(account);
            }

            Saved?.Invoke(this, saved);
            return Task.CompletedTask;
        });
    }

    [RelayCommand]
    private void Cancel()
    {
        Cancelled?.Invoke(this, EventArgs.Empty);
    }

    [RelayCommand]
    private void GenerateRandomKey()
    {
        SecretKey = SecretGenerator.RandomBase32();
    }
}
