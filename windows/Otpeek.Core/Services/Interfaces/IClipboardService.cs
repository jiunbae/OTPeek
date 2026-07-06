namespace Otpeek.Core.Services.Interfaces;

/// <summary>
/// 클립보드 서비스 인터페이스
/// </summary>
public interface IClipboardService
{
    /// <summary>
    /// 텍스트를 클립보드에 복사
    /// </summary>
    /// <param name="text">복사할 텍스트</param>
    /// <param name="autoClearSeconds">자동 삭제 시간 (초), 0이면 자동 삭제 안함</param>
    Task CopyAsync(string text, int autoClearSeconds = 0);

    /// <summary>
    /// 클립보드 내용 삭제
    /// </summary>
    Task ClearAsync();

    /// <summary>
    /// 클립보드에서 텍스트 가져오기
    /// </summary>
    Task<string?> GetTextAsync();

    /// <summary>
    /// 자동 삭제 타이머 취소
    /// </summary>
    void CancelAutoClear();
}
