using Otpeek.Core.Models;

namespace Otpeek.Core.Services.Interfaces;

/// <summary>
/// 설정 서비스 인터페이스
/// </summary>
public interface ISettingsService
{
    /// <summary>
    /// 현재 설정
    /// </summary>
    AppSettings Settings { get; }

    /// <summary>
    /// 설정 로드
    /// </summary>
    Task LoadAsync();

    /// <summary>
    /// 설정 저장
    /// </summary>
    Task SaveAsync();

    /// <summary>
    /// 설정 초기화
    /// </summary>
    Task ResetAsync();

    /// <summary>
    /// 설정 변경 이벤트
    /// </summary>
    event EventHandler<AppSettings>? SettingsChanged;
}
