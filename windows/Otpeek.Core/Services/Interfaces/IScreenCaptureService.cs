namespace Otpeek.Core.Services.Interfaces;

/// <summary>
/// 화면 캡처 서비스 인터페이스
/// </summary>
public interface IScreenCaptureService
{
    /// <summary>
    /// 사용자가 선택한 화면/창 캡처
    /// </summary>
    /// <returns>캡처 결과 (BGRA 픽셀 데이터)</returns>
    Task<CaptureResult?> CaptureWithPickerAsync();

    /// <summary>
    /// 전체 화면 캡처 (모든 모니터)
    /// </summary>
    /// <returns>각 모니터의 캡처 결과 목록</returns>
    Task<IReadOnlyList<CaptureResult>> CaptureAllScreensAsync();

    /// <summary>
    /// 특정 영역 캡처
    /// </summary>
    /// <param name="x">X 좌표</param>
    /// <param name="y">Y 좌표</param>
    /// <param name="width">너비</param>
    /// <param name="height">높이</param>
    /// <returns>캡처 결과</returns>
    Task<CaptureResult?> CaptureRegionAsync(int x, int y, int width, int height);
}

/// <summary>
/// 캡처 결과
/// </summary>
public class CaptureResult
{
    /// <summary>
    /// 픽셀 데이터 (BGRA 형식)
    /// </summary>
    public byte[] PixelData { get; set; } = Array.Empty<byte>();

    /// <summary>
    /// 이미지 너비
    /// </summary>
    public int Width { get; set; }

    /// <summary>
    /// 이미지 높이
    /// </summary>
    public int Height { get; set; }

    /// <summary>
    /// 캡처 성공 여부
    /// </summary>
    public bool IsSuccess => PixelData.Length > 0 && Width > 0 && Height > 0;
}
