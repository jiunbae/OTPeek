using System.Security.Cryptography;
using Uniffi.Otpeek;

namespace Otpeek.Core.Windows.Services;

public sealed partial class OtpClientService
{
    private static byte[] FetchWebDavVault(string url, string username, string password)
    {
        var backend = new WebDavSyncBackend(url, username, password);
        var remote = backend.Fetch()
            ?? throw new OtpException.Backend("No vault was found at this WebDAV location.");
        return remote.data;
    }

    public string? JoinExistingWebDavVault(string url, string username, string password, string masterPassword)
    {
        if (!IsUnlocked)
            throw new InvalidOperationException("Unlock your local vault before joining WebDAV.");

        return AdoptRemoteVault(FetchWebDavVault(url, username, password), masterPassword);
    }

    // Null means the current vault already uses the remote key and can sync normally.
    internal string? AdoptRemoteVault(byte[] remoteBlob, string masterPassword)
    {
        var directory = Directory.CreateDirectory(
            Path.Combine(_secureStorage.DataDirectory, $".webdav-join-{Guid.NewGuid():N}"));
        try
        {
            string remotePath = Path.Combine(directory.FullName, "remote.otpvault");
            WriteSnapshot(remotePath, remoteBlob);
            using var staged = OtpClient.OpenWithPassword(remotePath, masterPassword);
            byte[] remoteKey = staged.VaultKey();
            try
            {
                return MergeAndInstallRemoteVault(directory.FullName, remotePath, staged, remoteKey);
            }
            finally
            {
                CryptographicOperations.ZeroMemory(remoteKey);
            }
        }
        finally
        {
            try
            {
                directory.Delete(recursive: true);
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
                // Staging contains encrypted snapshots only. Cleanup must not mask the outcome.
            }
        }
    }

    private string? MergeAndInstallRemoteVault(string directory, string remotePath, OtpClient staged, byte[] remoteKey)
    {
        byte[] localKey;
        OtpClient original;
        byte[] localBlob;
        string vaultPath = _secureStorage.VaultPath;
        lock (_gate)
        {
            original = Client;
            localBlob = File.ReadAllBytes(vaultPath);
            localKey = original.VaultKey();
        }

        try
        {
            // Use the same bytes for the merge source and the encrypted recovery copy.
            if (CryptographicOperations.FixedTimeEquals(remoteKey, localKey))
                return null;

            string localPath = Path.Combine(directory, "local.otpvault");
            WriteSnapshot(localPath, localBlob);
            using (var local = OtpClient.OpenWithKey(localPath, localKey))
                CopyLiveEntities(local, staged);

            string recoveryPath = Path.Combine(_secureStorage.DataDirectory,
                $"vault-before-webdav-{DateTime.UtcNow:yyyyMMdd-HHmmss}-{Guid.NewGuid():N}.otpvault");
            lock (_gate)
            {
                using var fileLock = LockVaultFile(vaultPath);
                if (!ReferenceEquals(_client, original) || _activeSyncs != 0
                    || !File.ReadAllBytes(vaultPath).AsSpan().SequenceEqual(localBlob))
                {
                    throw new InvalidOperationException("The local vault changed or is syncing. Try joining again.");
                }

                File.Move(localPath, recoveryPath);
                InstallJoinedVault(remotePath, vaultPath, recoveryPath, remoteKey);
            }

            RaiseChanged();
            return recoveryPath;
        }
        finally
        {
            CryptographicOperations.ZeroMemory(localKey);
        }
    }

    private static void CopyLiveEntities(OtpClient local, OtpClient staged)
    {
        // Fresh IDs keep independent entries separate and avoid reviving remote tombstones.
        var folderIds = new Dictionary<string, string>();
        foreach (var folder in local.ListFolders())
        {
            var added = staged.AddFolder(folder with { id = string.Empty });
            folderIds[folder.id] = added.id;
        }

        foreach (var account in local.ListAccounts())
        {
            string? folderId = account.folderId is null ? null : folderIds.GetValueOrDefault(account.folderId);
            staged.AddAccount(account with { id = string.Empty, folderId = folderId });
        }
    }

    private void InstallJoinedVault(string stagedPath, string vaultPath, string recoveryPath, byte[] remoteKey)
    {
        // Keep the old protected key until the replacement opens successfully.
        // The encrypted recovery copy also covers an interruption between the two writes.
        File.Move(stagedPath, vaultPath, overwrite: true);
        OtpClient? joined = null;
        try
        {
            joined = OtpClient.OpenWithKey(vaultPath, remoteKey);
            _secureStorage.SaveVaultKey(remoteKey);
        }
        catch
        {
            joined?.Dispose();
            try
            {
                File.Move(recoveryPath, vaultPath, overwrite: true);
            }
            catch (Exception ex)
            {
                throw new IOException(
                    $"The vault switch could not be rolled back. Your original vault is at {recoveryPath} and uses your previous master password.",
                    ex);
            }
            throw;
        }
        ReplaceClient(joined);
    }

    private static void WriteSnapshot(string path, byte[] data)
    {
        using var file = new FileStream(path, FileMode.CreateNew, FileAccess.Write);
        file.Write(data);
        file.Flush(flushToDisk: true);
    }

    private static FileStream? LockVaultFile(string vaultPath)
    {
        if (!OperatingSystem.IsWindows())
            return null;

        // The Rust core's Windows vault writer locks this same byte of the sidecar.
        string path = Path.Combine(Path.GetDirectoryName(vaultPath)!, $".{Path.GetFileName(vaultPath)}.lock");
        var stream = new FileStream(path, FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.ReadWrite);
        try
        {
            stream.Lock(0, 1);
            return stream;
        }
        catch
        {
            stream.Dispose();
            throw;
        }
    }
}
