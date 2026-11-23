using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text;
using Uniffi.Otpeek;

namespace Otpeek.Core.Windows.Services;

/// <summary>
/// WebDAV 기반 <see cref="SyncBackend"/> 구현 (docs/ARCHITECTURE.md §6.1).
/// HTTPS 파일 URL 또는 컬렉션 아래의 <c>otpeek-vault.otpvault</c>에 암호화된 볼트를 저장합니다.
/// ETag / If-Match / If-None-Match:* 로 낙관적 동시성을 처리합니다.
/// 코어의 SyncBackend 트레이트는 블로킹 API이므로 <see cref="HttpClient.Send(HttpRequestMessage)"/>
/// (동기 전송)를 사용합니다.
/// </summary>
public sealed class WebDavSyncBackend : SyncBackend
{
    private const string VaultFileName = "otpeek-vault.otpvault";
    private const int MaxVaultBytes = 16 * 1024 * 1024;

    private static readonly HttpClient Http = new(new SocketsHttpHandler
    {
        AllowAutoRedirect = false,
        UseCookies = false,
        ConnectTimeout = TimeSpan.FromSeconds(10),
        PooledConnectionLifetime = TimeSpan.FromMinutes(5)
    })
    {
        Timeout = TimeSpan.FromSeconds(30),
        MaxResponseContentBufferSize = MaxVaultBytes
    };
    private readonly Uri _fileUri;
    private readonly AuthenticationHeaderValue _authorization;

    public WebDavSyncBackend(string collectionUrl, string username, string password)
    {
        if (string.IsNullOrWhiteSpace(collectionUrl))
            throw new OtpException.NotConfigured();

        _fileUri = BuildFileUri(collectionUrl);

        var raw = Encoding.UTF8.GetBytes($"{username}:{password}");
        _authorization = new AuthenticationHeaderValue("Basic", Convert.ToBase64String(raw));
    }

    private static Uri BuildFileUri(string collectionUrl)
    {
        if (!Uri.TryCreate(collectionUrl.Trim(), UriKind.Absolute, out var uri)
            || uri.Scheme != Uri.UriSchemeHttps
            || uri.UserInfo.Length != 0
            || uri.Fragment.Length != 0)
        {
            throw new OtpException.Backend("Enter an HTTPS WebDAV URL without embedded credentials or a fragment.");
        }

        if (uri.AbsolutePath.EndsWith(".otpvault", StringComparison.OrdinalIgnoreCase))
            return uri;

        return new UriBuilder(uri) { Path = $"{uri.AbsolutePath.TrimEnd('/')}/{VaultFileName}" }.Uri;
    }

    /// <inheritdoc />
    public RemoteBlob? Fetch()
    {
        try
        {
            using var request = new HttpRequestMessage(HttpMethod.Get, _fileUri);
            request.Headers.Authorization = _authorization;
            using var response = Http.Send(request);

            if (response.StatusCode is HttpStatusCode.NotFound or HttpStatusCode.Gone)
                return null;

            EnsureNotAuthError(response);

            if (response.StatusCode != HttpStatusCode.OK)
                throw new OtpException.Network($"WebDAV GET failed: {(int)response.StatusCode} {response.ReasonPhrase}");

            byte[] data = response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult();
            string? etag = response.Headers.ETag?.ToString();
            return new RemoteBlob(data, etag);
        }
        catch (OtpException)
        {
            throw;
        }
        catch (HttpRequestException ex)
        {
            throw new OtpException.Network(ex.Message);
        }
        catch (TaskCanceledException ex)
        {
            throw new OtpException.Network($"WebDAV request timed out: {ex.Message}");
        }
    }

    /// <inheritdoc />
    public string Store(byte[] @data, string? @ifMatch)
    {
        if (@data.Length > MaxVaultBytes)
            throw new OtpException.Backend("The vault exceeds the WebDAV size limit of 16 MiB.");

        try
        {
            using var request = new HttpRequestMessage(HttpMethod.Put, _fileUri)
            {
                Content = new ByteArrayContent(@data)
            };
            request.Headers.Authorization = _authorization;
            request.Content.Headers.ContentType = new MediaTypeHeaderValue("application/octet-stream");

            if (@ifMatch is not null)
            {
                if (!EntityTagHeaderValue.TryParse(@ifMatch, out var etag)
                    || etag.IsWeak || etag.Tag == "*")
                {
                    throw new OtpException.Backend("WebDAV sync requires a strong ETag from the server.");
                }
                request.Headers.IfMatch.Add(etag);
            }
            else
            {
                // 생성 전용: 이미 blob이 존재하면 412로 실패
                request.Headers.IfNoneMatch.Add(EntityTagHeaderValue.Any);
            }

            using var response = Http.Send(request);

            if (response.StatusCode == HttpStatusCode.PreconditionFailed)
                throw new OtpException.Conflict();

            EnsureNotAuthError(response);

            if (response.StatusCode is not (HttpStatusCode.OK or HttpStatusCode.Created or HttpStatusCode.NoContent))
                throw new OtpException.Network($"WebDAV PUT failed: {(int)response.StatusCode} {response.ReasonPhrase}");

            return response.Headers.ETag?.ToString() ?? string.Empty;
        }
        catch (OtpException)
        {
            throw;
        }
        catch (HttpRequestException ex)
        {
            throw new OtpException.Network(ex.Message);
        }
        catch (TaskCanceledException ex)
        {
            throw new OtpException.Network($"WebDAV request timed out: {ex.Message}");
        }
    }

    private static void EnsureNotAuthError(HttpResponseMessage response)
    {
        if (response.StatusCode is HttpStatusCode.Unauthorized or HttpStatusCode.Forbidden)
            throw new OtpException.Auth($"WebDAV auth failed: {(int)response.StatusCode} {response.ReasonPhrase}");
    }
}
