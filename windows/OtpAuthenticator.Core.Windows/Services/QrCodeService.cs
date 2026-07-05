using OtpAuthenticator.Core.Services.Interfaces;
using ZXing;
using ZXing.Common;
using ZXing.Windows.Compatibility;

namespace OtpAuthenticator.Core.Windows.Services;

/// <summary>
/// Windows QR 코드 서비스 (ZXing.NET Windows).
/// QR에서 원본 텍스트(otpauth:// / otpauth-migration://)만 추출하며,
/// OTP 파싱/추가는 호출부에서 OtpClient.AddFromUri로 처리합니다.
/// </summary>
public class QrCodeService : IQrCodeService
{
    private readonly BarcodeReaderGeneric _barcodeReader;
    private readonly BarcodeWriter<System.Drawing.Bitmap> _barcodeWriter;

    public QrCodeService()
    {
        _barcodeReader = new BarcodeReaderGeneric
        {
            AutoRotate = true,
            Options = new DecodingOptions
            {
                TryHarder = true,
                TryInverted = true,
                PossibleFormats = new List<BarcodeFormat> { BarcodeFormat.QR_CODE }
            }
        };

        _barcodeWriter = new BarcodeWriter<System.Drawing.Bitmap>
        {
            Format = BarcodeFormat.QR_CODE,
            Options = new EncodingOptions
            {
                Width = 256,
                Height = 256,
                Margin = 1,
                PureBarcode = false
            },
            Renderer = new BitmapRenderer()
        };
    }

    public string? DecodeFromImage(byte[] imageData, int width, int height)
    {
        try
        {
            using var bitmap = CreateBitmapFromBgra(imageData, width, height);
            if (bitmap == null) return null;

            var luminanceSource = new BitmapLuminanceSource(bitmap);
            var result = _barcodeReader.Decode(luminanceSource);
            return result?.Text;
        }
        catch
        {
            return null;
        }
    }

    public string? DecodeFromFile(string filePath)
    {
        try
        {
            using var bitmap = new System.Drawing.Bitmap(filePath);
            var luminanceSource = new BitmapLuminanceSource(bitmap);
            var result = _barcodeReader.Decode(luminanceSource);
            return result?.Text;
        }
        catch
        {
            return null;
        }
    }

    public byte[] GenerateQrCode(string text, int size = 256)
    {
        try
        {
            _barcodeWriter.Options.Width = size;
            _barcodeWriter.Options.Height = size;

            using var bitmap = _barcodeWriter.Write(text);
            using var ms = new MemoryStream();

            bitmap.Save(ms, System.Drawing.Imaging.ImageFormat.Png);
            return ms.ToArray();
        }
        catch
        {
            return Array.Empty<byte>();
        }
    }

    private static System.Drawing.Bitmap? CreateBitmapFromBgra(byte[] bgraData, int width, int height)
    {
        if (bgraData.Length != width * height * 4)
            return null;

        try
        {
            var bitmap = new System.Drawing.Bitmap(width, height, System.Drawing.Imaging.PixelFormat.Format32bppArgb);

            var bmpData = bitmap.LockBits(
                new System.Drawing.Rectangle(0, 0, width, height),
                System.Drawing.Imaging.ImageLockMode.WriteOnly,
                System.Drawing.Imaging.PixelFormat.Format32bppArgb);

            System.Runtime.InteropServices.Marshal.Copy(bgraData, 0, bmpData.Scan0, bgraData.Length);
            bitmap.UnlockBits(bmpData);

            return bitmap;
        }
        catch
        {
            return null;
        }
    }
}
