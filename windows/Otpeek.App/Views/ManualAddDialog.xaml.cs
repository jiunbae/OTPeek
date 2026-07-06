using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml.Controls;
using Otpeek.Core.Windows;
using Otpeek.Core.Windows.Services;
using Uniffi.Otpeek;

namespace Otpeek.App.Views;

/// <summary>
/// Manual account entry dialog
/// </summary>
public sealed partial class ManualAddDialog : ContentDialog
{
    private readonly IOtpClientService _client;

    /// <summary>
    /// Added account (available after dialog closes)
    /// </summary>
    public OtpAccount? AddedAccount { get; private set; }

    public ManualAddDialog()
    {
        this.InitializeComponent();

        _client = App.Services.GetRequiredService<IOtpClientService>();

        // Event handlers
        IssuerTextBox.TextChanged += OnTextChanged;
        SecretKeyTextBox.TextChanged += OnTextChanged;
        OtpTypeCombo.SelectionChanged += OnOtpTypeChanged;

        this.PrimaryButtonClick += OnPrimaryButtonClick;
    }

    private void OnTextChanged(object sender, TextChangedEventArgs e)
    {
        ValidateForm();
    }

    private void ValidateForm()
    {
        bool hasIssuer = !string.IsNullOrWhiteSpace(IssuerTextBox.Text);
        bool hasSecret = !string.IsNullOrWhiteSpace(SecretKeyTextBox.Text);
        IsPrimaryButtonEnabled = hasIssuer && hasSecret;
    }

    private void OnOtpTypeChanged(object sender, SelectionChangedEventArgs e)
    {
        if (OtpTypeCombo.SelectedItem is ComboBoxItem item && item.Tag is string tag)
        {
            bool isTotp = tag == "totp";
            PeriodNumberBox.Header = isTotp ? "Period (seconds)" : "Counter";
            PeriodNumberBox.Value = isTotp ? 30 : 0;
            PeriodNumberBox.Minimum = isTotp ? 10 : 0;
            PeriodNumberBox.Maximum = isTotp ? 120 : 999999;
        }
    }

    private async void OnPrimaryButtonClick(ContentDialog sender, ContentDialogButtonClickEventArgs args)
    {
        var deferral = args.GetDeferral();

        try
        {
            // Validate
            if (string.IsNullOrWhiteSpace(SecretKeyTextBox.Text))
            {
                StatusInfoBar.Severity = InfoBarSeverity.Error;
                StatusInfoBar.Message = "Secret Key is required.";
                args.Cancel = true;
                return;
            }

            if (string.IsNullOrWhiteSpace(IssuerTextBox.Text))
            {
                StatusInfoBar.Severity = InfoBarSeverity.Error;
                StatusInfoBar.Message = "Service Name is required.";
                args.Cancel = true;
                return;
            }

            // OTP Type
            var otpType = OtpType.Totp;
            if (OtpTypeCombo.SelectedItem is ComboBoxItem typeItem && typeItem.Tag is string typeTag)
            {
                otpType = typeTag == "hotp" ? OtpType.Hotp : OtpType.Totp;
            }

            // Algorithm
            var algorithm = HashAlgorithm.Sha1;
            if (AlgorithmCombo.SelectedItem is ComboBoxItem algoItem && algoItem.Tag is string algoTag)
            {
                algorithm = algoTag switch
                {
                    "SHA256" => HashAlgorithm.Sha256,
                    "SHA512" => HashAlgorithm.Sha512,
                    _ => HashAlgorithm.Sha1
                };
            }

            // Digits
            uint digits = 6;
            if (DigitsCombo.SelectedItem is ComboBoxItem digitsItem && digitsItem.Tag is string digitsTag
                && uint.TryParse(digitsTag, out var parsedDigits))
            {
                digits = parsedDigits;
            }

            // Normalize Secret Key
            string secretKey = SecretKeyTextBox.Text
                .Replace(" ", "")
                .Replace("-", "")
                .ToUpperInvariant();

            string issuer = IssuerTextBox.Text.Trim();
            string accountName = string.IsNullOrWhiteSpace(AccountNameTextBox.Text)
                ? issuer
                : AccountNameTextBox.Text.Trim();

            var account = OtpAccountExtensions.NewAccount(
                secret: secretKey,
                type: otpType,
                issuer: issuer,
                accountName: accountName,
                algorithm: algorithm,
                digits: digits,
                period: otpType == OtpType.Totp ? (uint)PeriodNumberBox.Value : 30,
                counter: otpType == OtpType.Hotp ? (ulong)PeriodNumberBox.Value : 0);

            // Save (코어가 id/타임스탬프 할당)
            AddedAccount = _client.AddAccount(account);

            StatusInfoBar.Severity = InfoBarSeverity.Success;
            StatusInfoBar.Message = "Account added successfully!";
        }
        catch (Exception ex)
        {
            StatusInfoBar.Severity = InfoBarSeverity.Error;
            StatusInfoBar.Message = $"Failed to add account: {ex.Message}";
            args.Cancel = true;
        }
        finally
        {
            deferral.Complete();
        }
    }
}
