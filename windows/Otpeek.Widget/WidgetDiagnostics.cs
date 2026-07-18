namespace Otpeek.Widget;

/// <summary>
/// Small, best-effort diagnostics sink for the out-of-process widget server.
/// Widget callbacks must never fail because a log file is unavailable.
/// </summary>
internal static class WidgetDiagnostics
{
    private const long MaxLogBytes = 1_048_576;
    private static readonly object Gate = new();
    private static readonly string LogDirectory = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "Otpeek");

    internal static string LogPath { get; } = Path.Combine(LogDirectory, "widget.log");

    internal static void Log(string component, string message)
    {
        try
        {
            lock (Gate)
            {
                Directory.CreateDirectory(LogDirectory);
                RotateIfNeeded();
                File.AppendAllText(
                    LogPath,
                    $"[{DateTimeOffset.Now:yyyy-MM-dd HH:mm:ss.fff zzz}] " +
                    $"[{Environment.ProcessId}:{Environment.CurrentManagedThreadId}] " +
                    $"[{component}] {message}{Environment.NewLine}");
            }
        }
        catch
        {
            // Logging is deliberately non-fatal. The widget host owns this process.
        }
    }

    internal static void LogException(string component, string operation, Exception exception)
    {
        Log(component, $"{operation} failed: {exception.GetType().Name} " +
            $"(0x{exception.HResult:X8}): {exception.Message}");
    }

    private static void RotateIfNeeded()
    {
        if (!File.Exists(LogPath) || new FileInfo(LogPath).Length < MaxLogBytes)
            return;

        string previousPath = LogPath + ".previous";
        File.Delete(previousPath);
        File.Move(LogPath, previousPath);
    }
}
