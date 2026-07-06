using Otpeek.Core.Services.Interfaces;
using Windows.ApplicationModel.DataTransfer;

namespace Otpeek.Core.Windows.Services;

/// <summary>
/// Windows 클립보드 서비스
/// </summary>
public class ClipboardService : IClipboardService
{
    private CancellationTokenSource? _autoClearCts;

    public async Task CopyAsync(string text, int autoClearSeconds = 0)
    {
        CancelAutoClear();

        var dataPackage = new DataPackage();
        dataPackage.SetText(text);

        // 클립보드 히스토리에서 제외 (Windows 10 1809+)
        try
        {
            dataPackage.Properties["IsFromRoamingClipboard"] = false;
        }
        catch
        {
            // 지원되지 않는 경우 무시
        }

        Clipboard.SetContent(dataPackage);
        Clipboard.Flush(); // 앱이 종료되어도 클립보드 유지

        if (autoClearSeconds > 0)
        {
            _autoClearCts = new CancellationTokenSource();
            var token = _autoClearCts.Token;

            try
            {
                await Task.Delay(TimeSpan.FromSeconds(autoClearSeconds), token);
                if (!token.IsCancellationRequested)
                {
                    await ClearAsync();
                }
            }
            catch (TaskCanceledException)
            {
            }
        }
    }

    public Task ClearAsync()
    {
        try
        {
            Clipboard.Clear();
        }
        catch
        {
        }

        return Task.CompletedTask;
    }

    public async Task<string?> GetTextAsync()
    {
        try
        {
            var content = Clipboard.GetContent();
            if (content.Contains(StandardDataFormats.Text))
            {
                return await content.GetTextAsync();
            }
        }
        catch
        {
        }

        return null;
    }

    public void CancelAutoClear()
    {
        _autoClearCts?.Cancel();
        _autoClearCts?.Dispose();
        _autoClearCts = null;
    }
}
