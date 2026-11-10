using System.Runtime.InteropServices;
using Uniffi.Otpeek;

// Public RFC test vectors only. No DPAPI, Keychain, installed app or user vault access.
if (args.Length != 1 || !Path.IsPathFullyQualified(args[0]))
    throw new ArgumentException("Pass an absolute extracted MSIX payload directory.");
var library = Path.Combine(args[0], "otpeek_ffi.dll");
if (!File.Exists(library)) throw new FileNotFoundException("Packaged native library missing.");
NativeLibrary.SetDllImportResolver(typeof(OtpClient).Assembly, (name, assembly, searchPath) =>
    name == "otpeek_ffi" ? NativeLibrary.Load(library) : IntPtr.Zero);

var directory = Path.Combine(Path.GetTempPath(), "otpeek-msstore-fixture-" + Guid.NewGuid().ToString("N"));
Directory.CreateDirectory(directory);
var vaultPath = Path.Combine(directory, "fixture.otpvault");
var passed = 0;
void Check(bool condition, string label)
{
    if (!condition) throw new InvalidOperationException("Fixture failed: " + label);
    Console.WriteLine("PASS " + label);
    passed++;
}
const string publicSeed = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ";
try
{
    Check(OtpeekMethods.GenerateTotpNow(publicSeed, HashAlgorithm.Sha1, 8, 30, 59) == "94287082",
          "RFC6238 through packaged C# and Rust ABI");
    string id;
    byte[] backup;
    byte[] sourceKey;
    using (var client = OtpClient.Create(vaultPath, "public-fixture-master"))
    {
        id = client.AddFromUri("otpauth://hotp/RFC4226?secret=" + publicSeed + "&counter=0")[0].id;
        Check(client.Code(id, 0).code == "755224" && client.GetAccount(id)?.counter == 0,
              "RFC4226 display does not consume counter");
        Check(client.NextHotp(id).code == "755224" && client.GetAccount(id)?.counter == 1,
              "HOTP consumes current counter and persists next counter");
        backup = client.ExportBackup("public-fixture-backup");
        sourceKey = client.VaultKey();
    }
    using (var client = OtpClient.OpenWithPassword(vaultPath, "public-fixture-master"))
    {
        Check(client.GetAccount(id)?.counter == 1 && client.Code(id, 0).code == "287082",
              "Password reopen preserves HOTP counter");
        using (var restored = OtpClient.Restore(Path.Combine(directory, "restored.otpvault"),
                                               backup, "public-fixture-backup"))
        {
            var restoredKey = restored.VaultKey();
            Check(!sourceKey.SequenceEqual(restoredKey) && restored.GetAccount(id)?.counter == 1,
                  "Encrypted backup restores with independent VMK");
            System.Security.Cryptography.CryptographicOperations.ZeroMemory(restoredKey);
        }
        var before = File.ReadAllBytes(vaultPath);
        var rejected = false;
        try { client.ImportBackup(backup, "wrong-public-fixture-password", false); }
        catch (OtpException.WrongPassword) { rejected = true; }
        Check(rejected && before.SequenceEqual(File.ReadAllBytes(vaultPath)),
              "Wrong backup password preserves vault bytes");
        client.NextHotp(id);
        Check(client.ImportBackup(backup, "public-fixture-backup", true) == 0 &&
              client.GetAccount(id)?.counter == 2, "Merge preserves live duplicate counter");
        client.ImportBackup(backup, "public-fixture-backup", false);
        Check(client.GetAccount(id)?.counter == 1, "Replace retains documented stale-backup counter behavior");
    }
    System.Security.Cryptography.CryptographicOperations.ZeroMemory(sourceKey);
    Console.WriteLine($"Fixture assertions passed: {passed}; user storage accessed: false");
    return 0;
}
catch (Exception error)
{
    Console.Error.WriteLine("Fixture failure type: " + error.GetType().FullName);
    return 1;
}
finally
{
    Directory.Delete(directory, recursive: true);
}
