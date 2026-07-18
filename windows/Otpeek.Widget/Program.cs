using System.Runtime.InteropServices;
using Microsoft.Windows.Widgets.Providers;
using WinRT;

namespace Otpeek.Widget;

/// <summary>
/// Widget Provider COM 서버 엔트리포인트
/// </summary>
public static class Program
{
    internal const string ProviderClassId = "8A2C4E6F-1B3D-5A7C-9E0F-2D4B6C8A0E1F";
    private static readonly ManualResetEventSlim ShutdownEvent = new(false);

    [MTAThread]
    public static int Main(string[] args)
    {
        WidgetDiagnostics.Log("Server", $"Started; argumentCount={args.Length}");

        if (args.Any(arg => string.Equals(arg, "--diagnostics", StringComparison.OrdinalIgnoreCase)))
            return RunDiagnostics();

        if (!args.Any(arg => string.Equals(
                arg,
                "-RegisterProcessAsComServer",
                StringComparison.OrdinalIgnoreCase)))
        {
            WidgetDiagnostics.Log("Server", "No COM activation argument; exiting");
            return 0;
        }

        uint cookie = 0;
        try
        {
            ComWrappersSupport.InitializeComWrappers();
            var factoryGuid = Guid.Parse(ProviderClassId);
            var factory = new WidgetProviderFactory<WidgetProvider>();
            int hr = CoRegisterClassObject(
                factoryGuid,
                factory,
                CLSCTX_LOCAL_SERVER,
                REGCLS_MULTIPLEUSE,
                out cookie);
            Marshal.ThrowExceptionForHR(hr);

            WidgetDiagnostics.Log("Server", $"COM class registered; cookie={cookie}");

            // This is an MTA local server. COM supplies its own RPC threads, so a Win32
            // window message pump is neither required nor desirable here. We stay alive
            // until the host deletes the final widget instance.
            ShutdownEvent.Wait();
            WidgetDiagnostics.Log("Server", "Shutdown requested after final widget deletion");
            return 0;
        }
        catch (Exception ex)
        {
            WidgetDiagnostics.LogException("Server", "COM server startup", ex);
            return ex.HResult != 0 ? ex.HResult : 1;
        }
        finally
        {
            if (cookie != 0)
            {
                int revokeResult = CoRevokeClassObject(cookie);
                WidgetDiagnostics.Log("Server", $"COM class revoked; result=0x{revokeResult:X8}");
            }
        }
    }

    internal static void RequestShutdown() => ShutdownEvent.Set();

    private static int RunDiagnostics()
    {
        try
        {
            WidgetProvider.ValidateDeployment();
            var dataProvider = new OtpWidgetDataProvider();
            dataProvider.ValidateStorageAccess();
            using var data = System.Text.Json.JsonDocument.Parse(dataProvider.GetWidgetData());
            if (!data.RootElement.TryGetProperty("entries", out var entries) ||
                entries.ValueKind != System.Text.Json.JsonValueKind.Array ||
                entries.GetArrayLength() > OtpWidgetDataProvider.MaxVisibleAccounts)
            {
                throw new InvalidDataException("The widget data must contain at most eight visible entries.");
            }

            int iconEntryCount = 0;
            foreach (var entry in entries.EnumerateArray())
            {
                if (!entry.TryGetProperty("icon", out _) ||
                    !entry.TryGetProperty("hasIcon", out var hasIcon) ||
                    !entry.TryGetProperty("showInMedium", out _))
                {
                    throw new InvalidDataException("Every visible entry must contain its icon and layout state.");
                }

                if (hasIcon.ValueKind == System.Text.Json.JsonValueKind.True)
                    iconEntryCount++;
            }
            WidgetDiagnostics.Log(
                "Diagnostics",
                $"Template, data JSON, native vault reader, and DPAPI probe passed; " +
                $"visibleEntryCount={entries.GetArrayLength()}, iconEntryCount={iconEntryCount}");
            return 0;
        }
        catch (Exception ex)
        {
            WidgetDiagnostics.LogException("Diagnostics", "Self-test", ex);
            return 1;
        }
    }

    private const uint CLSCTX_LOCAL_SERVER = 0x4;
    private const uint REGCLS_MULTIPLEUSE = 1;

    [DllImport("ole32.dll")]
    private static extern int CoRegisterClassObject(
        [MarshalAs(UnmanagedType.LPStruct)] Guid rclsid,
        [MarshalAs(UnmanagedType.IUnknown)] object pUnk,
        uint dwClsContext,
        uint flags,
        out uint lpdwRegister);

    [DllImport("ole32.dll")]
    private static extern int CoRevokeClassObject(uint dwRegister);

}

/// <summary>
/// Widget Provider Factory
/// </summary>
[ComVisible(true)]
internal sealed class WidgetProviderFactory<T> : IClassFactory where T : IWidgetProvider, new()
{
    public int CreateInstance(IntPtr pUnkOuter, ref Guid riid, out IntPtr ppvObject)
    {
        WidgetDiagnostics.Log("Factory", $"CreateInstance; riid={riid}");
        ppvObject = IntPtr.Zero;

        if (pUnkOuter != IntPtr.Zero)
            return CLASS_E_NOAGGREGATION;

        if (riid != typeof(T).GUID && riid != typeof(IWidgetProvider).GUID && riid != IUnknownGuid)
            return E_NOINTERFACE;

        try
        {
            var provider = new T();
            // IWidgetProvider is a WinRT interface. Marshal.GetIUnknownForObject creates
            // a classic COM callable wrapper that the Widget Host cannot inspect. CsWinRT's
            // MarshalInspectable produces the required IInspectable/IWidgetProvider CCW.
            ppvObject = MarshalInspectable<IWidgetProvider>.FromManaged(provider);
            return 0;
        }
        catch (Exception ex)
        {
            WidgetDiagnostics.LogException("Factory", "Provider activation", ex);
            ppvObject = IntPtr.Zero;
            return Marshal.GetHRForException(ex);
        }
    }

    public int LockServer(bool fLock)
    {
        return 0;
    }

    private static readonly Guid IUnknownGuid = new("00000000-0000-0000-C000-000000000046");
    private const int CLASS_E_NOAGGREGATION = unchecked((int)0x80040110);
    private const int E_NOINTERFACE = unchecked((int)0x80004002);
}

[ComImport, ComVisible(false)]
[Guid("00000001-0000-0000-C000-000000000046")]
[InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IClassFactory
{
    [PreserveSig]
    int CreateInstance(IntPtr pUnkOuter, ref Guid riid, out IntPtr ppvObject);

    [PreserveSig]
    int LockServer(bool fLock);
}
