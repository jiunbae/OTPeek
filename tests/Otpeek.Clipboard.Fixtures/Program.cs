using System.Reflection;
using Otpeek.Core.Windows.Services;
using Windows.ApplicationModel.DataTransfer;

// Real WinRT DataPackage/options, in-memory transport. Never access the OS clipboard.
var passed = 0;
void Check(bool condition, string label)
{
    if (!condition) throw new InvalidOperationException(label);
    Console.WriteLine("PASS " + label);
    passed++;
}
try
{
    var transport = new FixtureClipboard();
    var service = transport.Service();
    await service.ClearAsync();
    Check(transport.Reads == 0 && transport.Clears == 0, "No copy means no clipboard access on clear");
    await service.CopyAsync("public-fixture");
    Check(transport.Options is { IsAllowedInHistory: false, IsRoamable: false },
          "Copy explicitly disables history and roaming");
    Check(transport.Flushes == 1 && await service.GetTextAsync() == "public-fixture",
          "Successful copy flushes and remains readable");
    await service.ClearAsync();
    Check(transport.Clears == 1, "Explicit clear removes owned entry");
    await service.CopyAsync("same-public-text");
    transport.Replace("same-public-text");
    await service.ClearAsync();
    Check(transport.Clears == 1 && await service.GetTextAsync() == "same-public-text",
          "Another app's identical text without ownership marker is preserved");
    var timer = service.CopyAsync("expires-public-fixture", 1);
    transport.Replace("other-app-public-fixture");
    await timer;
    Check(transport.Clears == 1 && await service.GetTextAsync() == "other-app-public-fixture",
          "Expiry preserves replacement by another app");
    timer = service.CopyAsync("old-public-fixture", 1);
    await service.CopyAsync("new-public-fixture");
    await timer;
    Check(transport.Clears == 1 && await service.GetTextAsync() == "new-public-fixture",
          "Cancelled old timer preserves newer owned copy");
    await service.CopyAsync("expires-owned-fixture", 1);
    Check(transport.Clears == 2, "Expiry clears still-owned entry");
    timer = service.CopyAsync("cancelled-fixture", 1);
    service.CancelAutoClear();
    await timer;
    Check(transport.Clears == 2 && await service.GetTextAsync() == "cancelled-fixture",
          "CancelAutoClear keeps current copied content");
    var failed = new FixtureClipboard { RejectSet = true };
    var failedService = failed.Service();
    var rejected = false;
    try { await failedService.CopyAsync("failed-public-fixture"); }
    catch (InvalidOperationException) { rejected = true; }
    Check(rejected && failed.Flushes == 0, "Rejected clipboard write is not reported as copied");
    await failedService.ClearAsync();
    Check(failed.Reads == 0 && failed.Clears == 0, "Rejected copy does not take clipboard ownership");
    Console.WriteLine($"Clipboard fixture assertions passed: {passed}; system clipboard accessed: false");
    return 0;
}
catch (Exception error)
{
    Console.Error.WriteLine("Clipboard fixture failure type: " + error.GetType().FullName);
    return 1;
}

sealed class FixtureClipboard
{
    private DataPackage current = new();
    public ClipboardContentOptions? Options;
    public int Reads, Clears, Flushes;
    public bool RejectSet;
    public ClipboardService Service()
    {
        var constructor = typeof(ClipboardService).GetConstructors(BindingFlags.NonPublic | BindingFlags.Instance).Single();
        Func<DataPackage, ClipboardContentOptions, bool> write = (data, options) =>
        {
            Options = options;
            if (RejectSet) return false;
            current = data;
            return true;
        };
        Func<DataPackageView> read = () => { Reads++; return current.GetView(); };
        Action clear = () => { Clears++; current = new DataPackage(); };
        Action flush = () => Flushes++;
        return (ClipboardService)constructor.Invoke(new object[] { write, read, clear, flush });
    }
    public void Replace(string text)
    {
        current = new DataPackage();
        current.SetText(text);
    }
}
