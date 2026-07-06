using Otpeek.Core.Models;
using Otpeek.Core.Services.Interfaces;

namespace Otpeek.Core.Services;

/// <summary>
/// 설정 서비스
/// </summary>
public class SettingsService : ISettingsService
{
    private const string SettingsFileName = "settings.dat";
    private readonly ISecureStorageService _secureStorage;
    private AppSettings _settings = new();

    public AppSettings Settings => _settings;

    public event EventHandler<AppSettings>? SettingsChanged;

    public SettingsService(ISecureStorageService secureStorage)
    {
        _secureStorage = secureStorage;
    }

    /// <summary>
    /// 설정 로드
    /// </summary>
    public async Task LoadAsync()
    {
        var loaded = await _secureStorage.LoadEncryptedDataAsync<AppSettings>(SettingsFileName);
        _settings = loaded ?? new AppSettings();
    }

    /// <summary>
    /// 설정 저장
    /// </summary>
    public async Task SaveAsync()
    {
        await _secureStorage.SaveEncryptedDataAsync(SettingsFileName, _settings);
        SettingsChanged?.Invoke(this, _settings);
    }

    /// <summary>
    /// 설정 초기화
    /// </summary>
    public async Task ResetAsync()
    {
        _settings = new AppSettings();
        await SaveAsync();
    }
}
