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
        PopulateFolders();

        // Event handlers
        IssuerTextBox.TextChanged += OnTextChanged;
        AccountNameTextBox.TextChanged += OnTextChanged;
        SecretKeyTextBox.TextChanged += OnTextChanged;
        OtpTypeCombo.SelectionChanged += OnOtpTypeChanged;
        AlgorithmCombo.SelectionChanged += (_, _) => UpdatePreview();
        DigitsCombo.SelectionChanged += (_, _) => UpdatePreview();
        PeriodNumberBox.ValueChanged += (_, _) => UpdatePreview();

        this.PrimaryButtonClick += OnPrimaryButtonClick;
    }

    private void OnTextChanged(object sender, TextChangedEventArgs e)
    {
        ValidateForm();
    }

    private void ValidateForm()
    {
        bool hasAccount = !string.IsNullOrWhiteSpace(AccountNameTextBox.Text);
        string secret = NormalizeSecret(SecretKeyTextBox.Text);
        IsPrimaryButtonEnabled = hasAccount && OtpeekMethods.ValidateSecret(secret);
        UpdatePreview();
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
            UpdatePreview();
        }
    }

    private void OnPrimaryButtonClick(ContentDialog sender, ContentDialogButtonClickEventArgs args)
    {
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

            if (string.IsNullOrWhiteSpace(AccountNameTextBox.Text))
            {
                StatusInfoBar.Severity = InfoBarSeverity.Error;
                StatusInfoBar.Message = "Account Name is required.";
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
            string secretKey = NormalizeSecret(SecretKeyTextBox.Text);

            if (!OtpeekMethods.ValidateSecret(secretKey))
            {
                StatusInfoBar.Severity = InfoBarSeverity.Error;
                StatusInfoBar.Message = "Secret Key must be valid Base32.";
                args.Cancel = true;
                return;
            }

            string issuer = IssuerTextBox.Text.Trim();
            string accountName = AccountNameTextBox.Text.Trim();
            double numericValue = PeriodNumberBox.Value;
            if (double.IsNaN(numericValue) || double.IsInfinity(numericValue))
            {
                numericValue = otpType == OtpType.Totp ? 30 : 0;
            }

            var account = OtpAccountExtensions.NewAccount(
                secret: secretKey,
                type: otpType,
                issuer: issuer,
                accountName: accountName,
                algorithm: algorithm,
                digits: digits,
                period: otpType == OtpType.Totp ? (uint)Math.Max(10, numericValue) : 30,
                counter: otpType == OtpType.Hotp ? (ulong)Math.Max(0, numericValue) : 0,
                folderId: (FolderCombo.SelectedItem as ComboBoxItem)?.Tag?.ToString()) with
            {
                isFavorite = FavoriteToggle.IsOn,
                color = (ColorCombo.SelectedItem as ComboBoxItem)?.Tag?.ToString() ?? "#0078D4"
            };

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
    }

    private void UpdatePreview()
    {
        if (PreviewCodeText == null) return;

        string secret = NormalizeSecret(SecretKeyTextBox.Text);
        if (!OtpeekMethods.ValidateSecret(secret))
        {
            PreviewCodeText.Text = "------";
            PreviewCaptionText.Text = "Enter a valid secret to preview";
            return;
        }

        if (SelectedOtpType() == OtpType.Hotp)
        {
            PreviewCodeText.Text = "HOTP";
            PreviewCaptionText.Text = "The counter code is generated after adding";
            return;
        }

        try
        {
            double periodValue = PeriodNumberBox.Value;
            if (double.IsNaN(periodValue) || double.IsInfinity(periodValue)) periodValue = 30;

            string code = OtpeekMethods.GenerateTotpNow(
                secret,
                SelectedAlgorithm(),
                SelectedDigits(),
                (uint)Math.Max(10, periodValue),
                DateTimeOffset.UtcNow.ToUnixTimeSeconds());
            PreviewCodeText.Text = code.Length switch
            {
                6 => $"{code[..3]} {code[3..]}",
                7 => $"{code[..3]} {code[3..]}",
                8 => $"{code[..4]} {code[4..]}",
                _ => code
            };
            PreviewCaptionText.Text = "Live preview";
        }
        catch
        {
            PreviewCodeText.Text = "------";
            PreviewCaptionText.Text = "The secret could not be previewed";
        }
    }

    private OtpType SelectedOtpType()
        => (OtpTypeCombo.SelectedItem as ComboBoxItem)?.Tag?.ToString() == "hotp"
            ? OtpType.Hotp
            : OtpType.Totp;

    private HashAlgorithm SelectedAlgorithm()
        => (AlgorithmCombo.SelectedItem as ComboBoxItem)?.Tag?.ToString() switch
        {
            "SHA256" => HashAlgorithm.Sha256,
            "SHA512" => HashAlgorithm.Sha512,
            _ => HashAlgorithm.Sha1
        };

    private uint SelectedDigits()
        => uint.TryParse((DigitsCombo.SelectedItem as ComboBoxItem)?.Tag?.ToString(), out uint digits)
            ? digits
            : 6;

    private static string NormalizeSecret(string value)
        => value.Replace(" ", string.Empty).Replace("-", string.Empty).ToUpperInvariant();

    private void PopulateFolders()
    {
        FolderCombo.Items.Clear();
        FolderCombo.Items.Add(new ComboBoxItem { Content = "Uncategorized", Tag = null });
        if (_client.IsUnlocked)
        {
            foreach (var folder in _client.ListFolders())
                FolderCombo.Items.Add(new ComboBoxItem { Content = folder.name, Tag = folder.id });
        }
        FolderCombo.SelectedIndex = 0;
    }
}
