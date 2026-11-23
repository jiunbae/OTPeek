using System.Security.Cryptography;
using Otpeek.Core.Services.Interfaces;
using Uniffi.Otpeek;

namespace Otpeek.Core.Windows.Services;

/// <summary>
/// <see cref="IOtpClientService"/> 구현. Rust 코어 <see cref="OtpClient"/>를 래핑합니다.
/// </summary>
public sealed partial class OtpClientService : IOtpClientService, IDisposable
{
    private readonly ISecureStorageService _secureStorage;
    private readonly object _gate = new();
    private OtpClient? _client;
    private string? _webDavConfigurationError;
    private int _activeSyncs;

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

    private T WithClient<T>(Func<OtpClient, T> operation)
    {
        lock (_gate)
            return operation(Client);
    }

    private void WithClient(Action<OtpClient> operation)
    {
        lock (_gate)
            operation(Client);
    }

    private void ReplaceClient(OtpClient? client)
    {
        var previous = _client;
        _client = client;
        _webDavConfigurationError = null;
        previous?.Dispose();
    }

    // --- 생명주기 ---

    public void CreateVault(string masterPassword)
    {
        lock (_gate)
        {
            var client = OtpClient.Create(_secureStorage.VaultPath, masterPassword);
            _secureStorage.SaveVaultKey(client.VaultKey());
            ReplaceClient(client);
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
            ReplaceClient(client);
        }
        RaiseChanged();
    }

    public void OpenWithPassword(string masterPassword)
    {
        lock (_gate)
        {
            var client = OtpClient.OpenWithPassword(_secureStorage.VaultPath, masterPassword);
            _secureStorage.SaveVaultKey(client.VaultKey());
            ReplaceClient(client);
        }
        RaiseChanged();
    }

    public void RestoreFromBlob(byte[] blob, string masterPassword)
    {
        lock (_gate)
        {
            EnsureNewVaultDestination();

            string vaultPath = _secureStorage.VaultPath;
            string stagingPath = $"{vaultPath}.{Guid.NewGuid():N}.tmp";
            try
            {
                File.WriteAllBytes(stagingPath, blob);
                byte[] key;
                using (var stagedClient = OtpClient.OpenWithPassword(stagingPath, masterPassword))
                    key = stagedClient.VaultKey();

                try
                {
                    // Publish the authenticated snapshot atomically without clobbering a vault
                    // created after the initial check.
                    File.Move(stagingPath, vaultPath, overwrite: false);
                    var client = OtpClient.OpenWithKey(vaultPath, key);
                    try
                    {
                        _secureStorage.SaveVaultKey(key);
                    }
                    catch
                    {
                        // The installed snapshot can still be unlocked with its password.
                        client.Dispose();
                        throw;
                    }
                    ReplaceClient(client);
                }
                finally
                {
                    CryptographicOperations.ZeroMemory(key);
                }
            }
            finally
            {
                File.Delete(stagingPath);
            }
        }
        RaiseChanged();
    }

    public void JoinWebDavVault(string url, string username, string password, string masterPassword)
    {
        lock (_gate)
            EnsureNewVaultDestination();

        RestoreFromBlob(FetchWebDavVault(url, username, password), masterPassword);
    }

    private void EnsureNewVaultDestination()
    {
        if (_client is not null || VaultExists)
            throw new InvalidOperationException("This device already has a local vault.");
    }

    public void ChangePassword(string oldPassword, string newPassword)
    {
        WithClient(client => client.ChangePassword(oldPassword, newPassword));
        // VMK는 변경되지 않으므로 vmk.bin은 그대로 유효합니다.
    }

    public void Lock()
    {
        lock (_gate)
        {
            ReplaceClient(null);
        }
        RaiseChanged();
    }

    // --- 계정 ---

    public IReadOnlyList<OtpAccount> ListAccounts() => WithClient(client => client.ListAccounts());

    public OtpAccount? GetAccount(string id) => WithClient(client => client.GetAccount(id));

    public OtpAccount AddAccount(OtpAccount account)
    {
        var result = WithClient(client => client.AddAccount(account));
        RaiseChanged();
        return result;
    }

    public IReadOnlyList<OtpAccount> AddFromUri(string uri)
    {
        var result = WithClient(client => client.AddFromUri(uri));
        RaiseChanged();
        return result;
    }

    public OtpAccount UpdateAccount(OtpAccount account)
    {
        var result = WithClient(client => client.UpdateAccount(account));
        RaiseChanged();
        return result;
    }

    public void DeleteAccount(string id)
    {
        WithClient(client => client.DeleteAccount(id));
        RaiseChanged();
    }

    // --- 폴더 ---

    public IReadOnlyList<OtpFolder> ListFolders() => WithClient(client => client.ListFolders());

    public OtpFolder AddFolder(OtpFolder folder)
    {
        var result = WithClient(client => client.AddFolder(folder));
        RaiseChanged();
        return result;
    }

    public OtpFolder UpdateFolder(OtpFolder folder)
    {
        var result = WithClient(client => client.UpdateFolder(folder));
        RaiseChanged();
        return result;
    }

    public void DeleteFolder(string id)
    {
        WithClient(client => client.DeleteFolder(id));
        RaiseChanged();
    }

    // --- 코드 ---

    public OtpCode Code(string id) => CodeAt(id, NowMs());

    public OtpCode CodeAt(string id, long unixTimeMs) => WithClient(client => client.Code(id, unixTimeMs));

    public OtpCode NextHotp(string id)
    {
        var result = WithClient(client => client.NextHotp(id));
        RaiseChanged();
        return result;
    }

    public IReadOnlyList<AccountCode> CodesAt(long unixTimeMs) => WithClient(client => client.CodesAt(unixTimeMs));

    // --- 백업 / 동기화 ---

    public byte[] ExportBackup(string password) => WithClient(client => client.ExportBackup(password));

    public uint ImportBackup(byte[] data, string password, bool merge)
    {
        var count = WithClient(client => client.ImportBackup(data, password, merge));
        RaiseChanged();
        return count;
    }

    public uint ImportBackupV1(byte[] data, string password, bool merge)
    {
        var count = WithClient(client => client.ImportBackupV1(data, password, merge));
        RaiseChanged();
        return count;
    }

    public void ConfigureWebDavSync(string url, string username, string password)
    {
        lock (_gate)
        {
            var client = Client;
            try
            {
                client.SetSyncBackend(new WebDavSyncBackend(url, username, password));
                _webDavConfigurationError = null;
            }
            catch (Exception ex)
            {
                _webDavConfigurationError = ex is OtpException ? ex.Message : "Could not configure WebDAV sync.";
                client.ClearSyncBackend();
                throw;
            }
        }
    }

    public void ClearSync()
    {
        lock (_gate)
        {
            Client.ClearSyncBackend();
            _webDavConfigurationError = null;
        }
    }

    public SyncOutcome Sync()
    {
        OtpClient client;
        lock (_gate)
        {
            client = Client;
            if (_webDavConfigurationError is not null)
                throw new OtpException.Backend(_webDavConfigurationError);
            _activeSyncs++;
        }

        SyncOutcome outcome;
        try
        {
            outcome = client.Sync(NowMs());
        }
        finally
        {
            lock (_gate)
                _activeSyncs--;
        }
        if (outcome.pulled)
            RaiseChanged();
        return outcome;
    }

    public void Dispose()
    {
        lock (_gate)
        {
            ReplaceClient(null);
        }
    }
}
