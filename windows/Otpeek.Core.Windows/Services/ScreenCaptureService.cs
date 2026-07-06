using System.Runtime.InteropServices;
using Otpeek.Core.Services.Interfaces;

namespace Otpeek.Core.Windows.Services;

/// <summary>
/// Windows 화면 캡처 서비스 (System.Drawing 기반)
/// </summary>
public class ScreenCaptureService : IScreenCaptureService
{
    public Task<CaptureResult?> CaptureWithPickerAsync()
    {
        // 전체 화면 캡처로 대체 (Win2D 없이는 Picker 사용 불가)
        return CaptureAllScreensAsync().ContinueWith(t =>
            t.Result.FirstOrDefault());
    }

    public async Task<IReadOnlyList<CaptureResult>> CaptureAllScreensAsync()
    {
        var results = new List<CaptureResult>();
        var monitors = GetAllMonitors();

        foreach (var monitor in monitors)
        {
            var result = await CaptureRegionAsync(
                monitor.Left,
                monitor.Top,
                monitor.Width,
                monitor.Height);

            if (result != null && result.IsSuccess)
            {
                results.Add(result);
            }
        }

        return results;
    }

    public Task<CaptureResult?> CaptureRegionAsync(int x, int y, int width, int height)
    {
        return Task.Run(() =>
        {
            try
            {
                using var bitmap = new System.Drawing.Bitmap(width, height, System.Drawing.Imaging.PixelFormat.Format32bppArgb);
                using var graphics = System.Drawing.Graphics.FromImage(bitmap);

                graphics.CopyFromScreen(x, y, 0, 0, new System.Drawing.Size(width, height));

                var bmpData = bitmap.LockBits(
                    new System.Drawing.Rectangle(0, 0, width, height),
                    System.Drawing.Imaging.ImageLockMode.ReadOnly,
                    System.Drawing.Imaging.PixelFormat.Format32bppArgb);

                var pixelData = new byte[width * height * 4];
                Marshal.Copy(bmpData.Scan0, pixelData, 0, pixelData.Length);
                bitmap.UnlockBits(bmpData);

                return new CaptureResult
                {
                    PixelData = pixelData,
                    Width = width,
                    Height = height
                };
            }
            catch
            {
                return null;
            }
        });
    }

    private List<MonitorInfo> GetAllMonitors()
    {
        var monitors = new List<MonitorInfo>();

        EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, (hMonitor, hdcMonitor, lprcMonitor, dwData) =>
        {
            var info = new MONITORINFO { cbSize = Marshal.SizeOf<MONITORINFO>() };
            if (GetMonitorInfo(hMonitor, ref info))
            {
                monitors.Add(new MonitorInfo
                {
                    Left = info.rcMonitor.Left,
                    Top = info.rcMonitor.Top,
                    Width = info.rcMonitor.Right - info.rcMonitor.Left,
                    Height = info.rcMonitor.Bottom - info.rcMonitor.Top
                });
            }
            return true;
        }, IntPtr.Zero);

        return monitors;
    }

    #region P/Invoke

    [DllImport("user32.dll")]
    private static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    private static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr lprcClip, MonitorEnumProc lpfnEnum, IntPtr dwData);

    [DllImport("user32.dll")]
    private static extern bool GetMonitorInfo(IntPtr hMonitor, ref MONITORINFO lpmi);

    private delegate bool MonitorEnumProc(IntPtr hMonitor, IntPtr hdcMonitor, IntPtr lprcMonitor, IntPtr dwData);

    [StructLayout(LayoutKind.Sequential)]
    private struct MONITORINFO
    {
        public int cbSize;
        public RECT rcMonitor;
        public RECT rcWork;
        public uint dwFlags;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct RECT
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    private class MonitorInfo
    {
        public int Left { get; set; }
        public int Top { get; set; }
        public int Width { get; set; }
        public int Height { get; set; }
    }

    #endregion
}
