using System.Security.Cryptography;

namespace OtpAuthenticator.Core.Windows;

/// <summary>
/// 랜덤 Base32 시크릿 생성기 (RFC 4648, 패딩 없음).
/// v1의 Otp.NET KeyGeneration을 대체합니다.
/// </summary>
public static class SecretGenerator
{
    private const string Base32Alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";

    /// <summary>
    /// 지정한 바이트 수의 랜덤 키를 생성하여 Base32 문자열로 반환합니다.
    /// </summary>
    public static string RandomBase32(int bytes = 20)
    {
        byte[] buffer = new byte[bytes];
        using var rng = RandomNumberGenerator.Create();
        rng.GetBytes(buffer);
        return ToBase32(buffer);
    }

    private static string ToBase32(byte[] data)
    {
        if (data.Length == 0)
            return string.Empty;

        var sb = new System.Text.StringBuilder((data.Length * 8 + 4) / 5);
        int buffer = data[0];
        int next = 1;
        int bitsLeft = 8;

        while (bitsLeft > 0 || next < data.Length)
        {
            if (bitsLeft < 5)
            {
                if (next < data.Length)
                {
                    buffer <<= 8;
                    buffer |= data[next++] & 0xFF;
                    bitsLeft += 8;
                }
                else
                {
                    int pad = 5 - bitsLeft;
                    buffer <<= pad;
                    bitsLeft += pad;
                }
            }

            int index = 0x1F & (buffer >> (bitsLeft - 5));
            bitsLeft -= 5;
            sb.Append(Base32Alphabet[index]);
        }

        return sb.ToString();
    }
}
