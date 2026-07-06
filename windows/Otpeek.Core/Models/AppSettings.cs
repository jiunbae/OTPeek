namespace Otpeek.Core.Models;

/// <summary>
/// 애플리케이션 설정 (계정/시크릿은 Rust 코어 볼트에 저장되며 여기에는 앱 환경설정만 보관)
/// </summary>
public class AppSettings
{
    /// <summary>
    /// Windows 시작 시 자동 실행
    /// </summary>
    public bool StartWithWindows { get; set; } = false;

    /// <summary>
    /// 시작 시 최소화 상태로 실행
    /// </summary>
    public bool StartMinimized { get; set; } = false;

    /// <summary>
    /// 닫기 버튼 클릭 시 트레이로 최소화
    /// </summary>
    public bool MinimizeToTray { get; set; } = true;

    /// <summary>
    /// OTP 클릭 시 자동으로 클립보드에 복사
    /// </summary>
    public bool AutoCopyToClipboard { get; set; } = true;

    /// <summary>
    /// 클립보드 자동 삭제 시간 (초)
    /// </summary>
    public int ClipboardClearSeconds { get; set; } = 30;

    /// <summary>
    /// 작업 표시줄에 표시
    /// </summary>
    public bool ShowInTaskbar { get; set; } = false;

    /// <summary>
    /// Windows 11 위젯 활성화
    /// </summary>
    public bool EnableWidgetProvider { get; set; } = true;

    /// <summary>
    /// 테마 (Light, Dark, System)
    /// </summary>
    public string Theme { get; set; } = "System";

    /// <summary>
    /// 언어 (ko-KR, en-US, System)
    /// </summary>
    public string Language { get; set; } = "System";

    /// <summary>
    /// 앱 실행 시 인증 필요 여부 (Windows Hello)
    /// </summary>
    public bool RequireAuthentication { get; set; } = false;

    /// <summary>
    /// 복사 후 알림 표시
    /// </summary>
    public bool ShowCopyNotification { get; set; } = true;

    /// <summary>
    /// WebDAV 동기화 설정 (Rust 코어의 SyncBackend로 연결)
    /// </summary>
    public WebDavSettings WebDav { get; set; } = new();

    /// <summary>
    /// 핫키 설정
    /// </summary>
    public HotkeySettings Hotkeys { get; set; } = new();
}

/// <summary>
/// WebDAV 동기화 설정. 비밀번호는 DPAPI로 보호되어 <see cref="ProtectedPassword"/>에 저장됩니다.
/// </summary>
public class WebDavSettings
{
    /// <summary>
    /// 동기화 활성화 여부
    /// </summary>
    public bool Enabled { get; set; } = false;

    /// <summary>
    /// WebDAV 컬렉션(디렉터리) URL. 볼트 파일은 이 URL 하위의 otpeek-vault.otpvault로 저장됩니다.
    /// </summary>
    public string Url { get; set; } = string.Empty;

    /// <summary>
    /// Basic 인증 사용자명
    /// </summary>
    public string Username { get; set; } = string.Empty;

    /// <summary>
    /// DPAPI(CurrentUser)로 보호된 비밀번호의 Base64 문자열. 평문 비밀번호는 저장하지 않습니다.
    /// </summary>
    public string ProtectedPassword { get; set; } = string.Empty;

    /// <summary>
    /// 자동 동기화 활성화
    /// </summary>
    public bool AutoSync { get; set; } = true;

    /// <summary>
    /// 동기화 주기 (분)
    /// </summary>
    public int SyncIntervalMinutes { get; set; } = 15;

    /// <summary>
    /// 마지막 동기화 시간
    /// </summary>
    public DateTime? LastSyncTime { get; set; }
}

/// <summary>
/// 핫키 설정
/// </summary>
public class HotkeySettings
{
    /// <summary>
    /// 팝업 표시 핫키
    /// </summary>
    public string ShowPopup { get; set; } = "Ctrl+Shift+O";

    /// <summary>
    /// 빠른 복사 핫키
    /// </summary>
    public string QuickCopy { get; set; } = "Ctrl+Shift+C";
}
