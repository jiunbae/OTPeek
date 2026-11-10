using System.Net;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Runtime.Loader;
using System.Security.Cryptography;
using System.Text;
using Otpeek.Core.Windows.Services;
using Uniffi.Otpeek;

// Isolated public fixtures only. No default-path service constructors, PasswordVault,
// installed app, widget diagnostic logger, production endpoint or user vault access.
if (!OperatingSystem.IsWindows() || args.Length != 2 || args.Any(a => !Path.IsPathFullyQualified(a)))
    throw new ArgumentException("Pass absolute extracted MSIX payload and public QR fixture paths on Windows.");
var payload = args[0];
AssemblyLoadContext.Default.Resolving += (context, name) =>
{
    var path = Path.Combine(payload, name.Name + ".dll");
    return File.Exists(path) ? context.LoadFromAssemblyPath(path) : null;
};
NativeLibrary.SetDllImportResolver(typeof(OtpClient).Assembly, (name, assembly, searchPath) =>
    name == "otpeek_ffi" ? NativeLibrary.Load(Path.Combine(payload, "otpeek_ffi.dll")) : IntPtr.Zero);
var directory = Path.Combine(Path.GetTempPath(), "otpeek-windows-fixture-" + Guid.NewGuid().ToString("N"));
Directory.CreateDirectory(directory);
var vaultPath = Path.Combine(directory, "vault.otpvault");
var keyPath = Path.Combine(directory, "vmk.bin");
var entropy = Encoding.UTF8.GetBytes("Otpeek.Vmk.v2");
const string seed = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"; // RFC public vector.
var passed = 0;
void Check(bool condition, string name)
{
    if (!condition) throw new InvalidOperationException("Fixture failed: " + name);
    Console.WriteLine("PASS " + name);
    passed++;
}
void Rejected<T>(Action operation, string name) where T : Exception
{
    var rejected = false;
    try { operation(); } catch (T) { rejected = true; }
    Check(rejected, name);
}
void RunHttp(FixtureResponse[] responses, Action<WebDavSyncBackend, FixtureHttpServer> test)
{
    using var server = new FixtureHttpServer(responses);
    using var backend = new WebDavSyncBackend(server.CollectionUrl, "public-fixture", "public-fixture");
    test(backend, server);
    server.Complete();
    Check(server.Requests.All(r => r.Path == "/fixture/otpeek-vault.otpvault" &&
          r.Headers.GetValueOrDefault("Authorization") == "Basic " +
          Convert.ToBase64String(Encoding.UTF8.GetBytes("public-fixture:public-fixture"))),
          "Loopback-only fixed vault path and fixture authorization");
}
byte[]? vmk = null;
try
{
    using var client = OtpClient.Create(vaultPath, "public-fixture-master");
    var first = client.AddFromUri("otpauth://totp/fixture%20one?secret=" + seed)[0];
    var favorite = client.AddFromUri("otpauth://totp/fixture%20two?secret=" + seed)[0];
    client.UpdateAccount(favorite with { isFavorite = true });
    var hotp = client.AddFromUri("otpauth://hotp/fixture%20counter?secret=" + seed + "&counter=0")[0];
    vmk = client.VaultKey();
    var wrapped = ProtectedData.Protect(vmk, entropy, DataProtectionScope.CurrentUser);
    File.WriteAllBytes(keyPath, wrapped);

    var qr = new QrCodeService();
    var decoded = qr.DecodeFromFile(args[1]);
    Check(decoded is not null && decoded.StartsWith("otpauth://hotp/", StringComparison.Ordinal) &&
          decoded.Contains("secret=" + seed, StringComparison.Ordinal),
          "Packaged Windows QR reader decodes independent public image fixture");
    var qrAccount = OtpeekMethods.ParseOtpauthUri(decoded!, 0);
    Check(qrAccount.otpType == OtpType.Hotp && qrAccount.counter == 0,
          "Windows decoded QR reaches shared Rust parser");
    var generated = qr.GenerateQrCode("otpauth://totp/public%20fixture?secret=" + seed);
    Check(generated.Length > 0, "Packaged Windows QR writer generates PNG");
    var qrPath = Path.Combine(directory, "generated-public.png");
    File.WriteAllBytes(qrPath, generated);
    using (var bitmap = new System.Drawing.Bitmap(qrPath))
    {
        var bits = bitmap.LockBits(new System.Drawing.Rectangle(0, 0, bitmap.Width, bitmap.Height),
            System.Drawing.Imaging.ImageLockMode.ReadOnly, System.Drawing.Imaging.PixelFormat.Format32bppArgb);
        var bgra = new byte[bitmap.Width * bitmap.Height * 4];
        try { Marshal.Copy(bits.Scan0, bgra, 0, bgra.Length); }
        finally { bitmap.UnlockBits(bits); }
        Check(qr.DecodeFromImage(bgra, bitmap.Width, bitmap.Height) ==
              "otpauth://totp/public%20fixture?secret=" + seed,
              "Windows raw BGRA QR path decodes generated fixture");
    }
    Check(qr.DecodeFromImage(new byte[3], 10, 10) is null,
          "Windows malformed QR frame returns no result");
    var unwrapped = ProtectedData.Unprotect(wrapped, entropy, DataProtectionScope.CurrentUser);
    Check(vmk.SequenceEqual(unwrapped) && !wrapped.SequenceEqual(vmk), "Fixture VMK DPAPI wrap/unwrap");
    CryptographicOperations.ZeroMemory(unwrapped);
    var reader = new QuickOtpCodeProvider(directory); // Explicit isolated path; never default constructor.
    var codes = reader.GetCodes();
    Check(codes.Count == 2 && codes[0].Id == favorite.id && codes.Any(c => c.Id == first.id),
          "Packaged quick-surface v2 reader decrypts and orders favorites");
    Check(codes.All(c => c.Id != hotp.id) && client.GetAccount(hotp.id)?.counter == 0,
          "Quick surfaces exclude v2 HOTP and do not advance counter");
    File.WriteAllBytes(keyPath, new byte[] { 1, 2, 3 });
    Check(reader.GetCodes().Count == 0, "Malformed fixture key fails closed");
    var wrongKey = RandomNumberGenerator.GetBytes(32);
    File.WriteAllBytes(keyPath, ProtectedData.Protect(wrongKey, entropy, DataProtectionScope.CurrentUser));
    CryptographicOperations.ZeroMemory(wrongKey);
    Check(reader.GetCodes().Count == 0, "Wrong fixture VMK fails closed");
    File.Delete(keyPath);
    Check(reader.GetCodes().Count == 0, "Missing fixture VMK fails closed with v2 vault present");
    File.WriteAllBytes(keyPath, wrapped);

    var encrypted = File.ReadAllBytes(vaultPath);
    RunHttp(new[] { new FixtureResponse(404) }, (backend, server) =>
        Check(backend.Fetch() is null, "WebDAV missing vault returns null"));
    RunHttp(new[] { new FixtureResponse(200, encrypted, "\"fixture-v1\"") }, (backend, server) =>
    {
        var remote = backend.Fetch();
        Check(remote is not null && remote.data.SequenceEqual(encrypted) && remote.etag == "\"fixture-v1\"",
              "WebDAV fetch preserves encrypted bytes and opaque ETag");
    });
    RunHttp(new[] { new FixtureResponse(201, ETag: "\"fixture-v2\"") }, (backend, server) =>
    {
        Check(backend.Store(encrypted, null) == "\"fixture-v2\"", "WebDAV create returns ETag");
        server.Complete();
        Check(server.Requests[0].Method == "PUT" && server.Requests[0].Headers.GetValueOrDefault("If-None-Match") == "*" &&
              server.Requests[0].Body.SequenceEqual(encrypted), "WebDAV create-only precondition and ciphertext body");
    });
    RunHttp(new[] { new FixtureResponse(204, ETag: "\"fixture-v3\"") }, (backend, server) =>
    {
        backend.Store(encrypted, "fixture-v2");
        server.Complete();
        Check(server.Requests[0].Headers.GetValueOrDefault("If-Match") == "\"fixture-v2\"",
              "WebDAV update normalizes If-Match ETag");
    });
    RunHttp(new[] { new FixtureResponse(412) }, (backend, server) =>
        Rejected<OtpException.Conflict>(() => backend.Store(encrypted, "stale"), "WebDAV 412 maps to conflict"));
    foreach (var status in new[] { 401, 403 })
        RunHttp(new[] { new FixtureResponse(status) }, (backend, server) =>
            Rejected<OtpException.Auth>(() => backend.Fetch(), "WebDAV auth failure mapping " + status));
    RunHttp(new[] { new FixtureResponse(503) }, (backend, server) =>
        Rejected<OtpException.Network>(() => backend.Fetch(), "WebDAV server failure maps to network error"));
    RunHttp(new[] { new FixtureResponse(201), new FixtureResponse(200, ETag: "\"fixture-head\"") }, (backend, server) =>
    {
        Check(backend.Store(encrypted, null) == "\"fixture-head\"", "WebDAV missing PUT ETag uses HEAD");
        server.Complete();
        Check(server.Requests[1].Method == "HEAD", "WebDAV ETag fallback sends HEAD");
    });
    RunHttp(new[] { new FixtureResponse(404), new FixtureResponse(201, ETag: "\"fixture-sync\"") }, (backend, server) =>
    {
        client.SetSyncBackend(backend);
        try
        {
            var outcome = client.Sync(DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());
            Check(outcome.pushed && !outcome.pulled, "Rust sync invokes packaged C# WebDAV callbacks");
            server.Complete();
            var uploaded = Path.Combine(directory, "uploaded.otpvault");
            File.WriteAllBytes(uploaded, server.Requests[1].Body);
            using var reopened = OtpClient.OpenWithKey(uploaded, vmk);
            Check(reopened.ListAccounts().Length == 3 && reopened.GetAccount(hotp.id)?.counter == 0,
                  "Sync ciphertext reopens with same VMK and preserved HOTP counter");
        }
        finally { client.ClearSyncBackend(); }
    });
    Console.WriteLine($"New Windows fixture assertions passed: {passed}; existing vault/credential entries accessed: false; external network used: false");
    return 0;
}
catch (Exception error)
{
    Console.Error.WriteLine("Fixture failure: " + error.GetType().FullName);
    if (error is InvalidOperationException) Console.Error.WriteLine(error.Message);
    return 1;
}
finally
{
    if (vmk is not null) CryptographicOperations.ZeroMemory(vmk);
    Directory.Delete(directory, recursive: true);
}

record FixtureResponse(int Status, byte[]? Body = null, string? ETag = null);
record FixtureRequest(string Method, string Path, Dictionary<string, string> Headers, byte[] Body);

sealed class FixtureHttpServer : IDisposable
{
    private readonly TcpListener listener = new(IPAddress.Loopback, 0);
    private readonly Task task;
    public List<FixtureRequest> Requests { get; } = new();
    public string CollectionUrl { get; }
    public FixtureHttpServer(FixtureResponse[] responses)
    {
        listener.Start();
        CollectionUrl = $"http://127.0.0.1:{((IPEndPoint)listener.LocalEndpoint).Port}/fixture";
        task = Task.Run(() =>
        {
            foreach (var response in responses)
            {
                using var connection = listener.AcceptTcpClient();
                using var stream = connection.GetStream();
                stream.ReadTimeout = 10000;
                stream.WriteTimeout = 10000;
                var header = new List<byte>();
                while (true)
                {
                    var value = stream.ReadByte();
                    if (value < 0 || header.Count > 65536) throw new IOException("Invalid fixture request header");
                    header.Add((byte)value);
                    if (header.Count >= 4 && header.TakeLast(4).SequenceEqual(new byte[] { 13, 10, 13, 10 })) break;
                }
                var lines = Encoding.ASCII.GetString(header.ToArray()).Split("\r\n");
                var first = lines[0].Split(' ');
                var headers = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
                foreach (var line in lines.Skip(1).Where(l => l.Contains(':')))
                {
                    var split = line.IndexOf(':');
                    headers[line[..split]] = line[(split + 1)..].Trim();
                }
                var length = int.Parse(headers.GetValueOrDefault("Content-Length", "0"));
                if (length < 0 || length > 1024 * 1024) throw new IOException("Fixture request exceeds bound");
                var body = new byte[length];
                stream.ReadExactly(body);
                Requests.Add(new FixtureRequest(first[0], first[1], headers, body));
                var responseBody = response.Body ?? Array.Empty<byte>();
                var etag = response.ETag is null ? "" : $"ETag: {response.ETag}\r\n";
                var prefix = Encoding.ASCII.GetBytes($"HTTP/1.1 {response.Status} Fixture\r\nContent-Length: {responseBody.Length}\r\n{etag}Connection: close\r\n\r\n");
                stream.Write(prefix);
                stream.Write(responseBody);
            }
        });
    }
    public void Complete() => task.WaitAsync(TimeSpan.FromSeconds(15)).GetAwaiter().GetResult();
    public void Dispose()
    {
        listener.Stop();
        try { task.Wait(TimeSpan.FromSeconds(2)); } catch (AggregateException) { }
    }
}
