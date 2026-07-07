using Uniffi.Otpeek;

namespace Otpeek.Core.Windows.Services;

/// <summary>
/// 계정을 웹사이트 도메인으로 해석하고, 해당 서비스의 고화질 로고/파비콘을
/// 내려받아 디스크에 캐시합니다. UI 프레임워크에 의존하지 않도록 파일 경로(byte 아님)만
/// 다루고, ImageSource 변환은 각 뷰(App 계층)에서 처리합니다.
/// iOS/macOS 의 FaviconProvider/FaviconStore 와 동작을 맞춥니다.
/// </summary>
public interface IFaviconService
{
    /// <summary>파비콘 표시 설정(off 면 로드하지 않음).</summary>
    bool Enabled { get; }

    /// <summary>계정을 가장 그럴듯한 웹사이트 도메인으로 매핑(없으면 null).</summary>
    string? DomainFor(OtpAccount account);

    /// <summary>이미 캐시된 파비콘 파일 경로(없으면 null). 동기.</summary>
    string? CachedIconPath(string domain);

    /// <summary>캐시에 없으면 내려받아 캐시한 뒤 파일 경로를 반환(실패 시 null).</summary>
    Task<string?> GetIconPathAsync(string domain, CancellationToken ct = default);
}
