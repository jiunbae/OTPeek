namespace OtpAuthenticator.Core.Services.Interfaces;

/// <summary>
/// QR 코드 서비스 인터페이스.
/// v2에서는 OTP 파싱을 Rust 코어가 담당하므로, 이 서비스는 QR 이미지에서
/// 원본 텍스트(otpauth:// 또는 otpauth-migration:// URI)만 추출/생성합니다.
/// </summary>
public interface IQrCodeService
{
    /// <summary>
    /// 이미지 바이트(BGRA)에서 QR 코드 텍스트 디코딩
    /// </summary>
    /// <returns>디코딩된 텍스트(otpauth:// 등) 또는 null</returns>
    string? DecodeFromImage(byte[] imageData, int width, int height);

    /// <summary>
    /// 이미지 파일에서 QR 코드 텍스트 디코딩
    /// </summary>
    /// <returns>디코딩된 텍스트 또는 null</returns>
    string? DecodeFromFile(string filePath);

    /// <summary>
    /// 텍스트를 QR 코드 PNG 이미지로 생성
    /// </summary>
    byte[] GenerateQrCode(string text, int size = 256);
}
