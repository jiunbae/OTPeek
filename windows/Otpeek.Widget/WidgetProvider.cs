using System.Runtime.InteropServices;
using System.Text.Json;
using Microsoft.Windows.Widgets.Providers;

namespace Otpeek.Widget;

/// <summary>Out-of-process Windows 11 widget provider.</summary>
[ComVisible(true)]
[ComDefaultInterface(typeof(IWidgetProvider))]
[ClassInterface(ClassInterfaceType.None)]
[Guid(Program.ProviderClassId)]
public sealed partial class WidgetProvider : IWidgetProvider
{
    public const string WidgetDefinitionId = "OtpWidget";

    private static readonly object Gate = new();
    private static readonly Dictionary<string, WidgetInstanceState> WidgetInstances = new();
    private static readonly OtpWidgetDataProvider DataProvider = new();
    private static readonly Lazy<string> WidgetTemplate = new(LoadTemplate);
    private static System.Threading.Timer? _refreshTimer;
    private static int _recoveryState;

    public WidgetProvider()
    {
        WidgetDiagnostics.Log("Provider", "Instance created");
        RecoverRunningWidgets();
    }

    public void CreateWidget(WidgetContext widgetContext)
    {
        string widgetId = widgetContext.Id;
        string definitionId = widgetContext.DefinitionId;
        WidgetDiagnostics.Log("Provider", $"CreateWidget; id={widgetId}, definition={definitionId}");

        if (!string.Equals(definitionId, WidgetDefinitionId, StringComparison.Ordinal))
        {
            WidgetDiagnostics.Log("Provider", $"Ignoring unknown definition: {definitionId}");
            return;
        }

        lock (Gate)
        {
            WidgetInstances[widgetId] = new WidgetInstanceState
            {
                WidgetId = widgetId,
                DefinitionId = definitionId,
                IsActive = true
            };
        }

        UpdateWidget(widgetId);
        ScheduleNextRefresh();
    }

    public void DeleteWidget(string widgetId, string customState)
    {
        WidgetDiagnostics.Log("Provider", $"DeleteWidget; id={widgetId}");
        bool isEmpty;
        lock (Gate)
        {
            WidgetInstances.Remove(widgetId);
            isEmpty = WidgetInstances.Count == 0;
        }

        ScheduleNextRefresh();
        if (isEmpty)
            Program.RequestShutdown();
    }

    public void OnActionInvoked(WidgetActionInvokedArgs actionInvokedArgs)
    {
        string widgetId = actionInvokedArgs.WidgetContext.Id;
        string verb = actionInvokedArgs.Verb ?? string.Empty;
        WidgetDiagnostics.Log("Provider", $"Action; id={widgetId}, verb={verb}");

        try
        {
            EnsureWidget(widgetId, actionInvokedArgs.WidgetContext.DefinitionId);
            switch (verb)
            {
                case "copy":
                    CopyCurrentCode(widgetId, actionInvokedArgs.Data);
                    break;

                case "refresh":
                    DataProvider.Invalidate();
                    UpdateWidget(widgetId);
                    break;

                case "next":
                    MoveSelection(widgetId, 1);
                    break;

                case "prev":
                    MoveSelection(widgetId, -1);
                    break;

                default:
                    WidgetDiagnostics.Log("Provider", $"Ignoring unknown action verb: {verb}");
                    break;
            }
        }
        catch (Exception ex)
        {
            WidgetDiagnostics.LogException("Provider", $"Action {verb}", ex);
        }
        finally
        {
            ScheduleNextRefresh();
        }
    }

    public void OnWidgetContextChanged(WidgetContextChangedArgs contextChangedArgs)
    {
        string widgetId = contextChangedArgs.WidgetContext.Id;
        WidgetDiagnostics.Log("Provider", $"Context changed; id={widgetId}");
        EnsureWidget(widgetId, contextChangedArgs.WidgetContext.DefinitionId);

        // The single Adaptive Card uses $host.widgetSize, so the host selects the
        // correct small/medium/large layout without retaining callback objects.
        UpdateWidget(widgetId);
        ScheduleNextRefresh();
    }

    public void Activate(WidgetContext widgetContext)
    {
        string widgetId = widgetContext.Id;
        WidgetDiagnostics.Log("Provider", $"Activate; id={widgetId}");
        EnsureWidget(widgetId, widgetContext.DefinitionId);
        lock (Gate)
        {
            if (WidgetInstances.TryGetValue(widgetId, out var state))
                state.IsActive = true;
        }

        DataProvider.Invalidate();
        UpdateWidget(widgetId);
        ScheduleNextRefresh();
    }

    public void Deactivate(string widgetId)
    {
        WidgetDiagnostics.Log("Provider", $"Deactivate; id={widgetId}");
        lock (Gate)
        {
            if (WidgetInstances.TryGetValue(widgetId, out var state))
                state.IsActive = false;
        }
        ScheduleNextRefresh();
    }

    private static void EnsureWidget(string widgetId, string definitionId)
    {
        lock (Gate)
        {
            if (!WidgetInstances.ContainsKey(widgetId))
            {
                WidgetInstances[widgetId] = new WidgetInstanceState
                {
                    WidgetId = widgetId,
                    DefinitionId = definitionId
                };
            }
        }
    }

    private static void MoveSelection(string widgetId, int offset)
    {
        WidgetInstanceState? snapshot = Snapshot(widgetId);
        if (snapshot == null)
            return;

        int index = DataProvider.ClampIndex(snapshot.CurrentIndex + offset);
        string? accountId = DataProvider.GetAccountId(index);
        lock (Gate)
        {
            if (WidgetInstances.TryGetValue(widgetId, out var state))
            {
                state.CurrentIndex = index;
                state.AccountId = accountId;
                state.CopiedUntil = DateTimeOffset.MinValue;
                state.CopiedAccountId = null;
            }
        }

        UpdateWidget(widgetId);
    }

    private static void CopyCurrentCode(string widgetId, string? actionData)
    {
        WidgetInstanceState? snapshot = Snapshot(widgetId);
        if (snapshot == null)
            return;

        ParseCopyActionData(actionData, out string? requestedAccountId, out string? legacyCode);
        string? accountId = requestedAccountId ?? snapshot.AccountId;

        bool hasCode = DataProvider.TryGetFreshCode(snapshot.CurrentIndex, accountId, out string code);
        if (!hasCode && legacyCode is { Length: > 0 } && legacyCode.All(char.IsDigit))
        {
            // Compatibility for a click dispatched from the previous installed card
            // while this updated provider is starting. New templates only send accountId.
            code = legacyCode;
            hasCode = true;
        }

        if (!hasCode)
        {
            WidgetDiagnostics.Log("Provider", $"Copy skipped; no current code for id={widgetId}");
            UpdateWidget(widgetId);
            return;
        }

        if (!TryCopyToClipboard(code))
        {
            WidgetDiagnostics.Log("Provider", $"Copy failed; clipboard unavailable for id={widgetId}");
            return;
        }

        lock (Gate)
        {
            if (WidgetInstances.TryGetValue(widgetId, out var state))
            {
                state.CopiedUntil = DateTimeOffset.UtcNow.AddSeconds(2);
                state.CopiedAccountId = accountId;
            }
        }
        UpdateWidget(widgetId);
    }

    private static WidgetInstanceState? Snapshot(string widgetId)
    {
        lock (Gate)
        {
            if (!WidgetInstances.TryGetValue(widgetId, out var state))
                return null;
            return state.Clone();
        }
    }

    private static void UpdateWidget(string widgetId)
    {
        WidgetInstanceState? snapshot = Snapshot(widgetId);
        if (snapshot == null)
            return;

        try
        {
            int index = DataProvider.ResolveIndex(snapshot.CurrentIndex, snapshot.AccountId);
            string? accountId = DataProvider.GetAccountId(index);
            bool copied = snapshot.CopiedUntil > DateTimeOffset.UtcNow;
            string data = DataProvider.GetWidgetData(
                index,
                copied,
                copied ? snapshot.CopiedAccountId : null);
            string customState = SerializeState(index, accountId);

            lock (Gate)
            {
                if (WidgetInstances.TryGetValue(widgetId, out var state))
                {
                    state.CurrentIndex = index;
                    state.AccountId = accountId;
                    if (!copied)
                    {
                        state.CopiedUntil = DateTimeOffset.MinValue;
                        state.CopiedAccountId = null;
                    }
                }
            }

            var options = new WidgetUpdateRequestOptions(widgetId)
            {
                Template = WidgetTemplate.Value,
                Data = data,
                CustomState = customState
            };
            WidgetManager.GetDefault().UpdateWidget(options);
            WidgetDiagnostics.Log("Provider", $"Updated; id={widgetId}, index={index}, copied={copied}");
        }
        catch (Exception ex)
        {
            WidgetDiagnostics.LogException("Provider", $"Update id={widgetId}", ex);
        }
    }

    private static void RecoverRunningWidgets()
    {
        if (Interlocked.CompareExchange(ref _recoveryState, 1, 0) != 0)
            return;

        try
        {
            var widgetInfos = WidgetManager.GetDefault().GetWidgetInfos();
            foreach (var widgetInfo in widgetInfos)
            {
                string widgetId = widgetInfo.WidgetContext.Id;
                string definitionId = widgetInfo.WidgetContext.DefinitionId;
                if (!string.Equals(definitionId, WidgetDefinitionId, StringComparison.Ordinal))
                    continue;

                ParseState(widgetInfo.CustomState, out int index, out string? accountId);
                index = DataProvider.ResolveIndex(index, accountId);
                accountId = DataProvider.GetAccountId(index);

                lock (Gate)
                {
                    WidgetInstances.TryAdd(widgetId, new WidgetInstanceState
                    {
                        WidgetId = widgetId,
                        DefinitionId = definitionId,
                        CurrentIndex = index,
                        AccountId = accountId,
                        IsActive = false
                    });
                }
            }

            WidgetDiagnostics.Log("Provider", $"Recovery complete; widgetCount={WidgetInstances.Count}");
            Volatile.Write(ref _recoveryState, 2);
        }
        catch (Exception ex)
        {
            // Package identity/registration failures are useful diagnostics. Allow a
            // later activation attempt to retry instead of permanently caching failure.
            Volatile.Write(ref _recoveryState, 0);
            WidgetDiagnostics.LogException("Provider", "Recover running widgets", ex);
        }
    }

    private static void ScheduleNextRefresh()
    {
        try
        {
            List<WidgetInstanceState> activeStates;
            lock (Gate)
            {
                activeStates = WidgetInstances.Values
                    .Where(state => state.IsActive)
                    .Select(state => state.Clone())
                    .ToList();

                if (activeStates.Count == 0)
                {
                    _refreshTimer?.Dispose();
                    _refreshTimer = null;
                    return;
                }
            }

            DateTimeOffset now = DateTimeOffset.UtcNow;
            TimeSpan due = activeStates
                .Select(state => DataProvider.GetNextRefreshDelay(state.CurrentIndex))
                .Min();

            foreach (var state in activeStates.Where(state => state.CopiedUntil > now))
            {
                TimeSpan feedbackDelay = state.CopiedUntil - now;
                if (feedbackDelay < due)
                    due = feedbackDelay;
            }

            due = TimeSpan.FromMilliseconds(Math.Clamp(due.TotalMilliseconds, 250, 300_000));
            lock (Gate)
            {
                _refreshTimer ??= new System.Threading.Timer(
                    static _ => OnRefreshTimer(),
                    null,
                    Timeout.InfiniteTimeSpan,
                    Timeout.InfiniteTimeSpan);
                _refreshTimer.Change(due, Timeout.InfiniteTimeSpan);
            }
        }
        catch (Exception ex)
        {
            WidgetDiagnostics.LogException("Provider", "Schedule refresh", ex);
        }
    }

    private static void OnRefreshTimer()
    {
        try
        {
            List<string> activeWidgetIds;
            lock (Gate)
            {
                activeWidgetIds = WidgetInstances.Values
                    .Where(state => state.IsActive)
                    .Select(state => state.WidgetId)
                    .ToList();
            }

            DataProvider.Invalidate();
            foreach (string widgetId in activeWidgetIds)
                UpdateWidget(widgetId);
        }
        catch (Exception ex)
        {
            WidgetDiagnostics.LogException("Provider", "Refresh timer", ex);
        }
        finally
        {
            ScheduleNextRefresh();
        }
    }

    private static string LoadTemplate()
    {
        string path = GetTemplatePath();
        try
        {
            string template = File.ReadAllText(path);
            using var _ = JsonDocument.Parse(template);
            return template;
        }
        catch (Exception ex)
        {
            WidgetDiagnostics.LogException("Template", $"Load {path}", ex);
            return FallbackTemplate;
        }
    }

    private static string GetTemplatePath() => Path.Combine(
        AppContext.BaseDirectory,
        "Templates",
        "OtpWidgetTemplate.json");

    internal static void ValidateDeployment()
    {
        string path = GetTemplatePath();
        if (!File.Exists(path))
            throw new FileNotFoundException("The widget Adaptive Card template was not deployed.", path);
        using var _ = JsonDocument.Parse(File.ReadAllText(path));
    }

    private static string SerializeState(int index, string? accountId) => JsonSerializer.Serialize(new
    {
        version = 1,
        index,
        accountId = accountId ?? string.Empty
    });

    private static void ParseState(string? customState, out int index, out string? accountId)
    {
        index = 0;
        accountId = null;
        if (string.IsNullOrWhiteSpace(customState))
            return;

        if (int.TryParse(customState, out int legacyIndex))
        {
            index = Math.Max(0, legacyIndex);
            return;
        }

        try
        {
            using var document = JsonDocument.Parse(customState);
            JsonElement root = document.RootElement;
            if (root.TryGetProperty("index", out JsonElement indexElement) &&
                indexElement.TryGetInt32(out int parsedIndex))
                index = Math.Max(0, parsedIndex);
            if (root.TryGetProperty("accountId", out JsonElement accountElement) &&
                accountElement.ValueKind == JsonValueKind.String)
                accountId = accountElement.GetString();
        }
        catch (JsonException ex)
        {
            WidgetDiagnostics.LogException("Provider", "Parse custom state", ex);
        }
    }

    private static void ParseCopyActionData(
        string? data,
        out string? accountId,
        out string? legacyCode)
    {
        accountId = null;
        legacyCode = null;
        if (string.IsNullOrWhiteSpace(data))
            return;

        try
        {
            using var document = JsonDocument.Parse(data);
            JsonElement root = document.RootElement;
            if (root.ValueKind == JsonValueKind.Object)
            {
                if (root.TryGetProperty("accountId", out JsonElement accountElement) &&
                    accountElement.ValueKind == JsonValueKind.String)
                    accountId = accountElement.GetString();
                if (root.TryGetProperty("code", out JsonElement codeElement) &&
                    codeElement.ValueKind == JsonValueKind.String)
                    legacyCode = codeElement.GetString();
            }
            else if (root.ValueKind == JsonValueKind.String)
            {
                legacyCode = root.GetString();
            }
        }
        catch (JsonException)
        {
            legacyCode = data;
        }
    }

    private static bool TryCopyToClipboard(string text)
    {
        IntPtr clipboardMemory = IntPtr.Zero;
        bool opened = false;
        try
        {
            for (int attempt = 0; attempt < 5 && !opened; attempt++)
            {
                opened = OpenClipboard(IntPtr.Zero);
                if (!opened)
                    Thread.Sleep(15);
            }
            if (!opened || !EmptyClipboard())
                return false;

            byte[] bytes = System.Text.Encoding.Unicode.GetBytes(text + '\0');
            clipboardMemory = GlobalAlloc(GMEM_MOVEABLE, (UIntPtr)bytes.Length);
            if (clipboardMemory == IntPtr.Zero)
                return false;

            IntPtr destination = GlobalLock(clipboardMemory);
            if (destination == IntPtr.Zero)
                return false;
            try
            {
                Marshal.Copy(bytes, 0, destination, bytes.Length);
            }
            finally
            {
                GlobalUnlock(clipboardMemory);
            }

            if (SetClipboardData(CF_UNICODETEXT, clipboardMemory) == IntPtr.Zero)
                return false;

            clipboardMemory = IntPtr.Zero; // Windows owns it after SetClipboardData.
            return true;
        }
        catch (Exception ex)
        {
            WidgetDiagnostics.LogException("Clipboard", "Copy", ex);
            return false;
        }
        finally
        {
            if (opened)
                CloseClipboard();
            if (clipboardMemory != IntPtr.Zero)
                GlobalFree(clipboardMemory);
        }
    }

    private const string FallbackTemplate = """
    {
      "type": "AdaptiveCard",
      "$schema": "http://adaptivecards.io/schemas/adaptive-card.json",
      "version": "1.5",
      "body": [
        { "type": "TextBlock", "text": "OTPeek", "weight": "bolder" },
        { "type": "TextBlock", "text": "${otpCode}", "fontType": "monospace", "size": "extraLarge" }
      ],
      "actions": [
        { "type": "Action.Execute", "title": "Refresh", "verb": "refresh" }
      ]
    }
    """;

    private const uint CF_UNICODETEXT = 13;
    private const uint GMEM_MOVEABLE = 0x0002;

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool OpenClipboard(IntPtr hWndNewOwner);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool CloseClipboard();

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool EmptyClipboard();

    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr SetClipboardData(uint uFormat, IntPtr hMem);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr GlobalAlloc(uint uFlags, UIntPtr dwBytes);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr GlobalLock(IntPtr hMem);

    [DllImport("kernel32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GlobalUnlock(IntPtr hMem);

    [DllImport("kernel32.dll")]
    private static extern IntPtr GlobalFree(IntPtr hMem);
}

internal sealed class WidgetInstanceState
{
    public string WidgetId { get; init; } = string.Empty;
    public string DefinitionId { get; init; } = string.Empty;
    public bool IsActive { get; set; }
    public int CurrentIndex { get; set; }
    public string? AccountId { get; set; }
    public DateTimeOffset CopiedUntil { get; set; }
    public string? CopiedAccountId { get; set; }

    public WidgetInstanceState Clone() => new()
    {
        WidgetId = WidgetId,
        DefinitionId = DefinitionId,
        IsActive = IsActive,
        CurrentIndex = CurrentIndex,
        AccountId = AccountId,
        CopiedUntil = CopiedUntil,
        CopiedAccountId = CopiedAccountId
    };
}
