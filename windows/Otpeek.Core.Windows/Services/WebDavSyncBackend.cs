using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text;
using Uniffi.Otpeek;

namespace Otpeek.Core.Windows.Services;

/// <summary>
/// WebDAV 기반 <see cref="SyncBackend"/> 구현 (docs/ARCHITECTURE.md §6.1).
/// 구성된 컬렉션 URL 하위의 단일 파일 <c>otpeek-vault.otpvault</c>에 암호화된 볼트 blob을
/// 저장하며, ETag / If-Match / If-None-Match:* 로 낙관적 동시성을 처리합니다.
/// 코어의 SyncBackend 트레이트는 블로킹 API이므로 <see cref="HttpClient.Send(HttpRequestMessage)"/>
/// (동기 전송)를 사용합니다.
/// </summary>
public sealed class WebDavSyncBackend : SyncBackend, IDisposable
{
    private const string VaultFileName = "otpeek-vault.otpvault";

    private readonly HttpClient _http;
    private readonly Uri _fileUri;

    public WebDavSyncBackend(string collectionUrl, string username, string password)
    {
        if (string.IsNullOrWhiteSpace(collectionUrl))
            throw new OtpException.NotConfigured();

        _fileUri = BuildFileUri(collectionUrl);

        _http = new HttpClient
        {
            Timeout = TimeSpan.FromSeconds(30)
        };

        // Basic 인증 헤더
        var raw = Encoding.UTF8.GetBytes($"{username}:{password}");
        _http.DefaultRequestHeaders.Authorization =
            new AuthenticationHeaderValue("Basic", Convert.ToBase64String(raw));
    }

    private static Uri BuildFileUri(string collectionUrl)
    {
        // 컬렉션 URL 하위에 고정 파일명을 붙입니다.
        string baseUrl = collectionUrl.EndsWith("/", StringComparison.Ordinal)
            ? collectionUrl
            : collectionUrl + "/";
        return new Uri(new Uri(baseUrl), VaultFileName);
    }

    /// <inheritdoc />
    public RemoteBlob? Fetch()
    {
        try
        {
            using var request = new HttpRequestMessage(HttpMethod.Get, _fileUri);
            using var response = _http.Send(request);

            if (response.StatusCode == HttpStatusCode.NotFound)
                return null; // 원격 볼트가 아직 없음

            EnsureNotAuthError(response);

            if (!response.IsSuccessStatusCode)
                throw new OtpException.Network($"WebDAV GET failed: {(int)response.StatusCode} {response.ReasonPhrase}");

            byte[] data = ReadAllBytes(response);
            string? etag = response.Headers.ETag?.Tag;
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
        try
        {
            using var request = new HttpRequestMessage(HttpMethod.Put, _fileUri)
            {
                Content = new ByteArrayContent(@data)
            };
            request.Content.Headers.ContentType = new MediaTypeHeaderValue("application/octet-stream");

            if (@ifMatch is not null)
            {
                // 원격이 그 사이에 변경되었으면 412로 실패해야 함
                request.Headers.IfMatch.Add(ParseETag(@ifMatch));
            }
            else
            {
                // 생성 전용: 이미 blob이 존재하면 412로 실패
                request.Headers.IfNoneMatch.Add(EntityTagHeaderValue.Any);
            }

            using var response = _http.Send(request);

            if (response.StatusCode == HttpStatusCode.PreconditionFailed)
                throw new OtpException.Conflict();

            EnsureNotAuthError(response);

            if (!response.IsSuccessStatusCode)
                throw new OtpException.Network($"WebDAV PUT failed: {(int)response.StatusCode} {response.ReasonPhrase}");

            // 응답에 ETag가 있으면 사용, 없으면 HEAD로 조회
            string? etag = response.Headers.ETag?.Tag;
            if (string.IsNullOrEmpty(etag))
                etag = HeadEtag();

            // ETag를 제공하지 않는 서버도 있으므로 빈 문자열을 허용 (코어는 opaque로 취급)
            return etag ?? string.Empty;
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

    private string? HeadEtag()
    {
        try
        {
            using var request = new HttpRequestMessage(HttpMethod.Head, _fileUri);
            using var response = _http.Send(request);
            return response.IsSuccessStatusCode ? response.Headers.ETag?.Tag : null;
        }
        catch
        {
            return null;
        }
    }

    private static void EnsureNotAuthError(HttpResponseMessage response)
    {
        if (response.StatusCode is HttpStatusCode.Unauthorized or HttpStatusCode.Forbidden)
            throw new OtpException.Auth($"WebDAV auth failed: {(int)response.StatusCode} {response.ReasonPhrase}");
    }

    private static EntityTagHeaderValue ParseETag(string etag)
    {
        // etag 값이 따옴표로 감싸져 있지 않으면 감싸서 파싱
        string tag = etag.StartsWith("\"", StringComparison.Ordinal) || etag.StartsWith("W/", StringComparison.Ordinal)
            ? etag
            : $"\"{etag}\"";
        return EntityTagHeaderValue.Parse(tag);
    }

    private static byte[] ReadAllBytes(HttpResponseMessage response)
    {
        using var stream = response.Content.ReadAsStream();
        using var ms = new MemoryStream();
        stream.CopyTo(ms);
        return ms.ToArray();
    }

    public void Dispose() => _http.Dispose();
}
