using System.Runtime.InteropServices;
using System.Text.Json;
using Microsoft.Windows.Widgets.Providers;

namespace Otpeek.Widget;

/// <summary>
/// Windows 11 위젯 프로바이더
/// </summary>
[ComVisible(true)]
[ClassInterface(ClassInterfaceType.None)]
[Guid("8A2C4E6F-1B3D-5A7C-9E0F-2D4B6C8A0E1F")]
public partial class WidgetProvider : IWidgetProvider
{
    private readonly Dictionary<string, WidgetInfo> _activeWidgets = new();
    private readonly OtpWidgetDataProvider _dataProvider;

    public static readonly string WidgetDefinitionId = "OtpWidget";

    private static void Log(string message)
    {
        try
        {
            var logPath = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "Otpeek", "widget.log");
            File.AppendAllText(logPath, $"[{DateTime.Now:yyyy-MM-dd HH:mm:ss}] [Provider] {message}\n");
        }
        catch { }
    }

    public WidgetProvider()
    {
        Log("WidgetProvider constructor called");
        _dataProvider = new OtpWidgetDataProvider();
        Log("WidgetProvider initialized");
    }

    /// <summary>
    /// 위젯 생성
    /// </summary>
    public void CreateWidget(WidgetContext widgetContext)
    {
        Log($"CreateWidget called: Id={widgetContext.Id}, DefinitionId={widgetContext.DefinitionId}");
        var widgetId = widgetContext.Id;
        var definitionId = widgetContext.DefinitionId;

        _activeWidgets[widgetId] = new WidgetInfo
        {
            WidgetId = widgetId,
            DefinitionId = definitionId,
            IsActive = true
        };

        // 초기 데이터로 위젯 업데이트
        UpdateWidget(widgetContext);
        Log($"CreateWidget completed for {widgetId}");
    }

    /// <summary>
    /// 위젯 삭제
    /// </summary>
    public void DeleteWidget(string widgetId, string customState)
    {
        Log($"DeleteWidget called: {widgetId}");
        _activeWidgets.Remove(widgetId);
    }

    /// <summary>
    /// 액션 처리 (복사, 새로고침 등)
    /// </summary>
    public void OnActionInvoked(WidgetActionInvokedArgs actionInvokedArgs)
    {
        var widgetId = actionInvokedArgs.WidgetContext.Id;
        var verb = actionInvokedArgs.Verb;
        var data = actionInvokedArgs.Data;

        switch (verb)
        {
            case "copy":
                // 클립보드에 OTP 코드 복사
                if (!string.IsNullOrEmpty(data))
                {
                    CopyToClipboard(data);
                }
                break;

            case "refresh":
                // 위젯 새로고침
                UpdateWidget(actionInvokedArgs.WidgetContext);
                break;

            case "next":
                // 다음 계정 표시
                if (_activeWidgets.TryGetValue(widgetId, out var info))
                {
                    info.CurrentIndex++;
                    UpdateWidget(actionInvokedArgs.WidgetContext);
                }
                break;

            case "prev":
                // 이전 계정 표시
                if (_activeWidgets.TryGetValue(widgetId, out var prevInfo))
                {
                    prevInfo.CurrentIndex = Math.Max(0, prevInfo.CurrentIndex - 1);
                    UpdateWidget(actionInvokedArgs.WidgetContext);
                }
                break;
        }
    }

    /// <summary>
    /// 위젯 컨텍스트 변경
    /// </summary>
    public void OnWidgetContextChanged(WidgetContextChangedArgs contextChangedArgs)
    {
        var widgetId = contextChangedArgs.WidgetContext.Id;

        if (_activeWidgets.TryGetValue(widgetId, out var info))
        {
            // 기본 크기 사용 (SDK에서 WidgetSize 열거형 미지원)
            UpdateWidget(contextChangedArgs.WidgetContext);
        }
    }

    /// <summary>
    /// 위젯 활성화
    /// </summary>
    public void Activate(WidgetContext widgetContext)
    {
        var widgetId = widgetContext.Id;

        if (_activeWidgets.TryGetValue(widgetId, out var info))
        {
            info.IsActive = true;
        }

        UpdateWidget(widgetContext);
    }

    /// <summary>
    /// 위젯 비활성화
    /// </summary>
    public void Deactivate(string widgetId)
    {
        if (_activeWidgets.TryGetValue(widgetId, out var info))
        {
            info.IsActive = false;
        }
    }

    /// <summary>
    /// 위젯 업데이트
    /// </summary>
    private void UpdateWidget(WidgetContext widgetContext)
    {
        var widgetId = widgetContext.Id;

        if (!_activeWidgets.TryGetValue(widgetId, out var info))
            return;

        try
        {
            var template = GetWidgetTemplate(info.Size);
            var data = _dataProvider.GetWidgetData(info.CurrentIndex);

            var updateOptions = new WidgetUpdateRequestOptions(widgetId)
            {
                Template = template,
                Data = data
            };

            WidgetManager.GetDefault().UpdateWidget(updateOptions);
            Log($"UpdateWidget completed: Id={widgetId}, DataLength={data.Length}");
        }
        catch (Exception ex)
        {
            Log($"UpdateWidget failed: Id={widgetId}, {ex.GetType().Name}: {ex.Message}");
        }
    }

    /// <summary>
    /// Adaptive Card 템플릿 반환
    /// </summary>
    private string GetWidgetTemplate(WidgetSizeType size)
    {
        // 크기에 따라 다른 템플릿 사용
        return size switch
        {
            WidgetSizeType.Small => GetSmallTemplate(),
            WidgetSizeType.Medium => GetMediumTemplate(),
            WidgetSizeType.Large => GetLargeTemplate(),
            _ => GetMediumTemplate()
        };
    }

    /// <summary>
    /// 작은 크기 템플릿
    /// </summary>
    private static string GetSmallTemplate()
    {
        return """
        {
            "type": "AdaptiveCard",
            "version": "1.5",
            "$schema": "http://adaptivecards.io/schemas/adaptive-card.json",
            "body": [
                {
                    "type": "TextBlock",
                    "text": "${issuer}",
                    "weight": "bolder",
                    "size": "medium",
                    "wrap": true
                },
                {
                    "type": "TextBlock",
                    "text": "${otpCode}",
                    "size": "extraLarge",
                    "weight": "bolder",
                    "fontType": "monospace",
                    "spacing": "small"
                }
            ],
            "actions": [
                {
                    "type": "Action.Execute",
                    "title": "Copy",
                    "verb": "copy",
                    "data": "${rawCode}"
                }
            ],
            "refresh": {
                "action": {
                    "type": "Action.Execute",
                    "verb": "refresh"
                },
                "expires": "2099-12-31T23:59:59Z"
            }
        }
        """;
    }

    /// <summary>
    /// 중간 크기 템플릿
    /// </summary>
    private static string GetMediumTemplate()
    {
        return """
        {
            "type": "AdaptiveCard",
            "version": "1.5",
            "$schema": "http://adaptivecards.io/schemas/adaptive-card.json",
            "body": [
                {
                    "type": "Container",
                    "items": [
                        {
                            "type": "ColumnSet",
                            "columns": [
                                {
                                    "type": "Column",
                                    "width": "auto",
                                    "items": [
                                        {
                                            "type": "Container",
                                            "style": "accent",
                                            "items": [
                                                {
                                                    "type": "TextBlock",
                                                    "text": "${initial}",
                                                    "size": "large",
                                                    "weight": "bolder",
                                                    "horizontalAlignment": "center"
                                                }
                                            ],
                                            "bleed": true,
                                            "minHeight": "40px"
                                        }
                                    ]
                                },
                                {
                                    "type": "Column",
                                    "width": "stretch",
                                    "items": [
                                        {
                                            "type": "TextBlock",
                                            "text": "${issuer}",
                                            "weight": "bolder",
                                            "size": "medium"
                                        },
                                        {
                                            "type": "TextBlock",
                                            "text": "${accountName}",
                                            "size": "small",
                                            "isSubtle": true,
                                            "wrap": true
                                        }
                                    ]
                                }
                            ]
                        },
                        {
                            "type": "TextBlock",
                            "text": "${otpCode}",
                            "size": "extraLarge",
                            "weight": "bolder",
                            "fontType": "monospace",
                            "horizontalAlignment": "center",
                            "spacing": "medium"
                        },
                        {
                            "type": "ProgressBar",
                            "value": "${timeProgress}",
                            "color": "${progressColor}"
                        }
                    ]
                }
            ],
            "actions": [
                {
                    "type": "Action.Execute",
                    "title": "Copy",
                    "verb": "copy",
                    "data": "${rawCode}"
                },
                {
                    "type": "Action.Execute",
                    "title": "Next",
                    "verb": "next"
                }
            ],
            "refresh": {
                "action": {
                    "type": "Action.Execute",
                    "verb": "refresh"
                },
                "expires": "2099-12-31T23:59:59Z"
            }
        }
        """;
    }

    /// <summary>
    /// 큰 크기 템플릿
    /// </summary>
    private static string GetLargeTemplate()
    {
        return GetMediumTemplate(); // 현재는 동일
    }

    /// <summary>
    /// 클립보드에 복사 (Win32 API 사용)
    /// </summary>
    private static void CopyToClipboard(string text)
    {
        try
        {
            if (!OpenClipboard(IntPtr.Zero)) return;
            try
            {
                EmptyClipboard();
                var hGlobal = Marshal.StringToHGlobalUni(text);
                SetClipboardData(CF_UNICODETEXT, hGlobal);
            }
            finally
            {
                CloseClipboard();
            }
        }
        catch
        {
            // 클립보드 접근 실패 무시
        }
    }

    private const uint CF_UNICODETEXT = 13;

    [DllImport("user32.dll")]
    private static extern bool OpenClipboard(IntPtr hWndNewOwner);

    [DllImport("user32.dll")]
    private static extern bool CloseClipboard();

    [DllImport("user32.dll")]
    private static extern bool EmptyClipboard();

    [DllImport("user32.dll")]
    private static extern IntPtr SetClipboardData(uint uFormat, IntPtr hMem);
}

/// <summary>
/// 위젯 정보
/// </summary>
internal class WidgetInfo
{
    public string WidgetId { get; set; } = string.Empty;
    public string DefinitionId { get; set; } = string.Empty;
    public bool IsActive { get; set; }
    public WidgetSizeType Size { get; set; } = WidgetSizeType.Medium;
    public int CurrentIndex { get; set; }
}

/// <summary>
/// 위젯 크기 열거형 (Windows Widget SDK 호환)
/// </summary>
internal enum WidgetSizeType
{
    Small,
    Medium,
    Large
}
