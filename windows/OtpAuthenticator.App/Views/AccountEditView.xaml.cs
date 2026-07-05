using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using OtpAuthenticator.App.ViewModels;
using Uniffi.Otp;

namespace OtpAuthenticator.App.Views;

/// <summary>
/// 계정 편집/추가 뷰
/// </summary>
public sealed partial class AccountEditView : UserControl
{
    public AccountEditViewModel ViewModel { get; }

    public event EventHandler? CloseRequested;

    public AccountEditView()
    {
        this.InitializeComponent();
        ViewModel = App.Services.GetRequiredService<AccountEditViewModel>();

        // ViewModel 이벤트 연결
        ViewModel.Saved += OnSaved;
        ViewModel.Cancelled += OnCancelled;
        ViewModel.PropertyChanged += OnViewModelPropertyChanged;

        // 바인딩 설정
        SetupBindings();
    }

    private void SetupBindings()
    {
        IssuerTextBox.TextChanged += (s, e) => ViewModel.Issuer = IssuerTextBox.Text;
        AccountNameTextBox.TextChanged += (s, e) => ViewModel.AccountName = AccountNameTextBox.Text;
        SecretKeyTextBox.TextChanged += (s, e) => ViewModel.SecretKey = SecretKeyTextBox.Text;
    }

    private void OnViewModelPropertyChanged(object? sender, System.ComponentModel.PropertyChangedEventArgs e)
    {
        switch (e.PropertyName)
        {
            case nameof(ViewModel.IsEditMode):
                TitleText.Text = ViewModel.IsEditMode ? "Edit Account" : "Add Account";
                break;

            case nameof(ViewModel.ValidationError):
                ValidationErrorBar.IsOpen = !string.IsNullOrEmpty(ViewModel.ValidationError);
                ValidationErrorBar.Message = ViewModel.ValidationError ?? string.Empty;
                break;

            case nameof(ViewModel.IsValid):
                SaveButton.IsEnabled = ViewModel.IsValid;
                break;
        }
    }

    /// <summary>
    /// 새 계정 추가 모드로 초기화
    /// </summary>
    public void InitializeForAdd()
    {
        ViewModel.InitializeForAdd();
        UpdateUI();
    }

    /// <summary>
    /// 편집 모드로 초기화
    /// </summary>
    public void InitializeForEdit(OtpAccount account)
    {
        ViewModel.InitializeForEdit(account);
        UpdateUI();
    }

    /// <summary>
    /// URI로 초기화
    /// </summary>
    public bool InitializeFromUri(string uri)
    {
        var result = ViewModel.InitializeFromUri(uri);
        if (result)
        {
            UpdateUI();
        }
        return result;
    }

    private void UpdateUI()
    {
        IssuerTextBox.Text = ViewModel.Issuer;
        AccountNameTextBox.Text = ViewModel.AccountName;
        SecretKeyTextBox.Text = ViewModel.SecretKey;

        // ComboBox 선택
        TypeComboBox.SelectedIndex = (int)ViewModel.SelectedType;
        AlgorithmComboBox.SelectedIndex = (int)ViewModel.SelectedAlgorithm;
        DigitsComboBox.SelectedIndex = ViewModel.Digits == 6 ? 0 : 1;
        PeriodComboBox.SelectedIndex = ViewModel.Period switch
        {
            15 => 0,
            30 => 1,
            60 => 2,
            _ => 1
        };
        NotesTextBox.Text = ViewModel.Notes ?? string.Empty;
    }

    private void OnCloseClick(object sender, RoutedEventArgs e)
    {
        CloseRequested?.Invoke(this, EventArgs.Empty);
    }

    private void OnCancelClick(object sender, RoutedEventArgs e)
    {
        ViewModel.CancelCommand.Execute(null);
    }

    private async void OnSaveClick(object sender, RoutedEventArgs e)
    {
        // ComboBox 값 업데이트
        ViewModel.SelectedType = TypeComboBox.SelectedIndex == 0 ? OtpType.Totp : OtpType.Hotp;
        ViewModel.SelectedAlgorithm = (HashAlgorithm)AlgorithmComboBox.SelectedIndex;
        ViewModel.Digits = DigitsComboBox.SelectedIndex == 0 ? 6 : 8;
        ViewModel.Period = PeriodComboBox.SelectedIndex switch
        {
            0 => 15,
            1 => 30,
            2 => 60,
            _ => 30
        };
        ViewModel.Notes = string.IsNullOrWhiteSpace(NotesTextBox.Text) ? null : NotesTextBox.Text;

        await ViewModel.SaveCommand.ExecuteAsync(null);
    }

    private void OnGenerateKeyClick(object sender, RoutedEventArgs e)
    {
        ViewModel.GenerateRandomKeyCommand.Execute(null);
        SecretKeyTextBox.Text = ViewModel.SecretKey;
    }

    private void OnSaved(object? sender, OtpAccount account)
    {
        CloseRequested?.Invoke(this, EventArgs.Empty);
    }

    private void OnCancelled(object? sender, EventArgs e)
    {
        CloseRequested?.Invoke(this, EventArgs.Empty);
    }
}
