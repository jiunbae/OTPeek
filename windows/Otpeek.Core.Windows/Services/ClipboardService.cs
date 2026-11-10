using Otpeek.Core.Services.Interfaces;
using Windows.ApplicationModel.DataTransfer;

namespace Otpeek.Core.Windows.Services;

/// <summary>
/// Windows 클립보드 서비스
/// </summary>
public class ClipboardService : IClipboardService
{
    private CancellationTokenSource? _autoClearCts;
    private const string OwnerProperty = "OTPeek.ClipboardOwner";
    private string? _owner;
    private readonly Func<DataPackage, ClipboardContentOptions, bool> _setContent;
    private readonly Func<DataPackageView> _getContent;
    private readonly Action _clear;
    private readonly Action _flush;

    public ClipboardService() : this(Clipboard.SetContentWithOptions, Clipboard.GetContent,
                                     Clipboard.Clear, Clipboard.Flush) { }

    // Fixture seam: exercise clipboard ownership/timers without touching the user's clipboard.
    internal ClipboardService(Func<DataPackage, ClipboardContentOptions, bool> setContent,
                              Func<DataPackageView> getContent, Action clear, Action flush)
    {
        _setContent = setContent;
        _getContent = getContent;
        _clear = clear;
        _flush = flush;
    }

    public async Task CopyAsync(string text, int autoClearSeconds = 0)
    {
        CancelAutoClear();

        var dataPackage = new DataPackage();
        dataPackage.SetText(text);
        var owner = Guid.NewGuid().ToString("N");
        dataPackage.Properties[OwnerProperty] = owner;

        // Windows 10 1809+, below this app's minimum supported Windows version.
        var options = new ClipboardContentOptions
        {
            IsAllowedInHistory = false,
            IsRoamable = false
        };
        if (!_setContent(dataPackage, options))
        {
            throw new InvalidOperationException("The clipboard is unavailable.");
        }
        _owner = owner;
        _flush(); // 앱이 종료되어도 클립보드 유지

        if (autoClearSeconds > 0)
        {
            _autoClearCts = new CancellationTokenSource();
            var token = _autoClearCts.Token;

            try
            {
                await Task.Delay(TimeSpan.FromSeconds(autoClearSeconds), token);
                if (!token.IsCancellationRequested)
                {
                    ClearOwned(owner);
                }
            }
            catch (TaskCanceledException)
            {
            }
        }
    }

    public Task ClearAsync()
    {
        ClearOwned(_owner);
        return Task.CompletedTask;
    }

    private void ClearOwned(string? owner)
    {
        if (owner is null || owner != _owner) return;
        try
        {
            var content = _getContent();
            if (content.Properties.TryGetValue(OwnerProperty, out var marker) &&
                marker is string currentOwner && currentOwner == owner)
            {
                _clear();
            }
            _owner = null;
        }
        catch
        {
        }
    }

    public async Task<string?> GetTextAsync()
    {
        try
        {
            var content = _getContent();
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
