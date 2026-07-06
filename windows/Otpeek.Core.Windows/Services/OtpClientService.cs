using Otpeek.Core.Services.Interfaces;
using Uniffi.Otpeek;

namespace Otpeek.Core.Windows.Services;

/// <summary>
/// <see cref="IOtpClientService"/> 구현. Rust 코어 <see cref="OtpClient"/>를 래핑합니다.
/// </summary>
public sealed class OtpClientService : IOtpClientService, IDisposable
{
    private readonly ISecureStorageService _secureStorage;
    private readonly object _gate = new();
    private OtpClient? _client;

    public OtpClientService(ISecureStorageService secureStorage)
    {
        _secureStorage = secureStorage;
    }

    public event EventHandler? VaultChanged;

    public bool IsUnlocked
    {
        get { lock (_gate) return _client != null; }
    }

    public bool VaultExists => File.Exists(_secureStorage.VaultPath);

    public bool HasStoredKey => _secureStorage.HasVaultKey();

    private OtpClient Client
    {
        get
        {
            lock (_gate)
            {
                return _client ?? throw new InvalidOperationException("Vault is not open. Unlock it first.");
            }
        }
    }

    private static long NowMs() => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();

    private void RaiseChanged() => VaultChanged?.Invoke(this, EventArgs.Empty);

    // --- 생명주기 ---

    public void CreateVault(string masterPassword)
    {
        lock (_gate)
        {
            var client = OtpClient.Create(_secureStorage.VaultPath, masterPassword);
            _secureStorage.SaveVaultKey(client.VaultKey());
            _client?.Dispose();
            _client = client;
        }
        RaiseChanged();
    }

    public void OpenWithStoredKey()
    {
        byte[] vmk = _secureStorage.LoadVaultKey()
            ?? throw new InvalidOperationException("No stored vault key (VMK). Open with a master password first.");

        lock (_gate)
        {
            var client = OtpClient.OpenWithKey(_secureStorage.VaultPath, vmk);
            _client?.Dispose();
            _client = client;
        }
        RaiseChanged();
    }

    public void OpenWithPassword(string masterPassword)
    {
        lock (_gate)
        {
            var client = OtpClient.OpenWithPassword(_secureStorage.VaultPath, masterPassword);
            _secureStorage.SaveVaultKey(client.VaultKey());
            _client?.Dispose();
            _client = client;
        }
        RaiseChanged();
    }

    public void RestoreFromBlob(byte[] blob, string masterPassword)
    {
        lock (_gate)
        {
            var client = OtpClient.Restore(_secureStorage.VaultPath, blob, masterPassword);
            _secureStorage.SaveVaultKey(client.VaultKey());
            _client?.Dispose();
            _client = client;
        }
        RaiseChanged();
    }

    public void ChangePassword(string oldPassword, string newPassword)
    {
        Client.ChangePassword(oldPassword, newPassword);
        // VMK는 변경되지 않으므로 vmk.bin은 그대로 유효합니다.
    }

    public void Lock()
    {
        lock (_gate)
        {
            _client?.Dispose();
            _client = null;
        }
        RaiseChanged();
    }

    // --- 계정 ---

    public IReadOnlyList<OtpAccount> ListAccounts() => Client.ListAccounts();

    public OtpAccount? GetAccount(string id) => Client.GetAccount(id);

    public OtpAccount AddAccount(OtpAccount account)
    {
        var result = Client.AddAccount(account);
        RaiseChanged();
        return result;
    }

    public IReadOnlyList<OtpAccount> AddFromUri(string uri)
    {
        var result = Client.AddFromUri(uri);
        RaiseChanged();
        return result;
    }

    public OtpAccount UpdateAccount(OtpAccount account)
    {
        var result = Client.UpdateAccount(account);
        RaiseChanged();
        return result;
    }

    public void DeleteAccount(string id)
    {
        Client.DeleteAccount(id);
        RaiseChanged();
    }

    // --- 폴더 ---

    public IReadOnlyList<OtpFolder> ListFolders() => Client.ListFolders();

    public OtpFolder AddFolder(OtpFolder folder)
    {
        var result = Client.AddFolder(folder);
        RaiseChanged();
        return result;
    }

    public OtpFolder UpdateFolder(OtpFolder folder)
    {
        var result = Client.UpdateFolder(folder);
        RaiseChanged();
        return result;
    }

    public void DeleteFolder(string id)
    {
        Client.DeleteFolder(id);
        RaiseChanged();
    }

    // --- 코드 ---

    public OtpCode Code(string id) => Client.Code(id, NowMs());

    public OtpCode CodeAt(string id, long unixTimeMs) => Client.Code(id, unixTimeMs);

    public OtpCode NextHotp(string id)
    {
        var result = Client.NextHotp(id);
        RaiseChanged();
        return result;
    }

    public IReadOnlyList<AccountCode> CodesAt(long unixTimeMs) => Client.CodesAt(unixTimeMs);

    // --- 백업 / 동기화 ---

    public byte[] ExportBackup(string password) => Client.ExportBackup(password);

    public uint ImportBackup(byte[] data, string password, bool merge)
    {
        var count = Client.ImportBackup(data, password, merge);
        RaiseChanged();
        return count;
    }

    public uint ImportBackupV1(byte[] data, string password, bool merge)
    {
        var count = Client.ImportBackupV1(data, password, merge);
        RaiseChanged();
        return count;
    }

    public void ConfigureWebDavSync(string url, string username, string password)
    {
        var backend = new WebDavSyncBackend(url, username, password);
        Client.SetSyncBackend(backend);
    }

    public void ClearSync() => Client.ClearSyncBackend();

    public SyncOutcome Sync()
    {
        var outcome = Client.Sync(NowMs());
        if (outcome.pulled)
            RaiseChanged();
        return outcome;
    }

    public void Dispose()
    {
        lock (_gate)
        {
            _client?.Dispose();
            _client = null;
        }
    }
}
