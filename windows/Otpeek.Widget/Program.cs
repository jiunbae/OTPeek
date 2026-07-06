using System.Runtime.InteropServices;
using Microsoft.Windows.Widgets.Providers;
using WinRT;

namespace Otpeek.Widget;

/// <summary>
/// Widget Provider COM 서버 엔트리포인트
/// </summary>
public class Program
{
    private static readonly string LogPath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "Otpeek", "widget.log");

    private static void Log(string message)
    {
        try
        {
            var dir = Path.GetDirectoryName(LogPath);
            if (!string.IsNullOrEmpty(dir) && !Directory.Exists(dir))
                Directory.CreateDirectory(dir);
            File.AppendAllText(LogPath, $"[{DateTime.Now:yyyy-MM-dd HH:mm:ss}] {message}\n");
        }
        catch { }
    }

    [STAThread]
    public static void Main(string[] args)
    {
        Log($"Widget started with args: {string.Join(", ", args)}");

        // COM 서버 초기화
        if (args.Length > 0 && args.Contains("-RegisterProcessAsComServer"))
        {
            try
            {
                Log("Initializing COM wrappers...");
                // Widget Provider 등록
                ComWrappersSupport.InitializeComWrappers();
                Log("COM wrappers initialized");

                var factoryGuid = Guid.Parse("8A2C4E6F-1B3D-5A7C-9E0F-2D4B6C8A0E1F");

                uint cookie = 0;
                try
                {
                    Log("Creating WidgetProviderFactory...");
                    // Widget Provider Factory 등록
                    var factory = new WidgetProviderFactory<WidgetProvider>();
                    Log("Registering COM class object...");
                    var hr = CoRegisterClassObject(
                        ref factoryGuid,
                        factory,
                        CLSCTX_LOCAL_SERVER,
                        REGCLS_MULTIPLEUSE | REGCLS_SUSPENDED,
                        out cookie);

                    if (hr != 0)
                    {
                        Log($"CoRegisterClassObject failed with HRESULT: 0x{hr:X8}");
                        Marshal.ThrowExceptionForHR(hr);
                    }
                    Log($"COM class object registered, cookie: {cookie}");

                    // 모든 클래스 오브젝트 활성화
                    Log("Resuming class objects...");
                    hr = CoResumeClassObjects();
                    if (hr != 0)
                    {
                        Log($"CoResumeClassObjects failed with HRESULT: 0x{hr:X8}");
                        Marshal.ThrowExceptionForHR(hr);
                    }
                    Log("COM server ready, entering message loop...");

                    // 메시지 루프 실행
                    var msg = new MSG();
                    while (GetMessage(ref msg, IntPtr.Zero, 0, 0) != 0)
                    {
                        TranslateMessage(ref msg);
                        DispatchMessage(ref msg);
                    }
                    Log("Message loop exited");
                }
                finally
                {
                    if (cookie != 0)
                    {
                        CoRevokeClassObject(cookie);
                        Log("COM class object revoked");
                    }
                }
            }
            catch (Exception ex)
            {
                Log($"FATAL ERROR: {ex.GetType().Name}: {ex.Message}\n{ex.StackTrace}");
                throw;
            }
        }
        else
        {
            Log("No COM server argument, exiting");
        }
    }

    private const uint CLSCTX_LOCAL_SERVER = 0x4;
    private const uint REGCLS_MULTIPLEUSE = 1;
    private const uint REGCLS_SUSPENDED = 4;

    [DllImport("ole32.dll")]
    private static extern int CoRegisterClassObject(
        ref Guid rclsid,
        [MarshalAs(UnmanagedType.Interface)] object pUnk,
        uint dwClsContext,
        uint flags,
        out uint lpdwRegister);

    [DllImport("ole32.dll")]
    private static extern int CoRevokeClassObject(uint dwRegister);

    [DllImport("ole32.dll")]
    private static extern int CoResumeClassObjects();

    [StructLayout(LayoutKind.Sequential)]
    private struct MSG
    {
        public IntPtr hwnd;
        public uint message;
        public IntPtr wParam;
        public IntPtr lParam;
        public uint time;
        public POINT pt;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct POINT
    {
        public int x;
        public int y;
    }

    [DllImport("user32.dll")]
    private static extern int GetMessage(ref MSG lpMsg, IntPtr hWnd, uint wMsgFilterMin, uint wMsgFilterMax);

    [DllImport("user32.dll")]
    private static extern bool TranslateMessage(ref MSG lpMsg);

    [DllImport("user32.dll")]
    private static extern IntPtr DispatchMessage(ref MSG lpMsg);
}

/// <summary>
/// Widget Provider Factory
/// </summary>
internal class WidgetProviderFactory<T> : IClassFactory where T : IWidgetProvider, new()
{
    private static void Log(string message)
    {
        try
        {
            var logPath = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "Otpeek", "widget.log");
            File.AppendAllText(logPath, $"[{DateTime.Now:yyyy-MM-dd HH:mm:ss}] [Factory] {message}\n");
        }
        catch { }
    }

    public int CreateInstance(IntPtr pUnkOuter, ref Guid riid, out IntPtr ppvObject)
    {
        Log($"CreateInstance called. riid={riid}");
        ppvObject = IntPtr.Zero;

        if (pUnkOuter != IntPtr.Zero)
        {
            Marshal.ThrowExceptionForHR(CLASS_E_NOAGGREGATION);
        }

        if (riid == typeof(IWidgetProvider).GUID || riid == IUnknownGuid)
        {
            var provider = new T();
            ppvObject = Marshal.GetIUnknownForObject(provider);
            return 0;
        }

        Marshal.ThrowExceptionForHR(E_NOINTERFACE);
        return E_NOINTERFACE;
    }

    public int LockServer(bool fLock)
    {
        return 0;
    }

    private static readonly Guid IUnknownGuid = new("00000000-0000-0000-C000-000000000046");
    private const int CLASS_E_NOAGGREGATION = unchecked((int)0x80040110);
    private const int E_NOINTERFACE = unchecked((int)0x80004002);
}

[ComImport]
[Guid("00000001-0000-0000-C000-000000000046")]
[InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IClassFactory
{
    [PreserveSig]
    int CreateInstance(IntPtr pUnkOuter, ref Guid riid, out IntPtr ppvObject);

    [PreserveSig]
    int LockServer(bool fLock);
}
