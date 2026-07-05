using Uniffi.Otp;

namespace OtpAuthenticator.Core.Windows;

/// <summary>
/// 생성된 <see cref="OtpAccount"/> / <see cref="OtpFolder"/> 레코드(불변)를 UI에서
/// 편하게 다루기 위한 헬퍼 확장 및 팩토리.
/// </summary>
public static class OtpAccountExtensions
{
    /// <summary>
    /// 표시용 이름 (Issuer: AccountName 형식)
    /// </summary>
    public static string DisplayName(this OtpAccount a)
        => string.IsNullOrEmpty(a.issuer) ? a.accountName : $"{a.issuer}: {a.accountName}";

    /// <summary>
    /// 표시용 이니셜 (Issuer의 첫 글자, 없으면 AccountName의 첫 글자)
    /// </summary>
    public static string Initial(this OtpAccount a)
    {
        if (!string.IsNullOrEmpty(a.issuer))
            return a.issuer[..1].ToUpperInvariant();
        if (!string.IsNullOrEmpty(a.accountName))
            return a.accountName[..1].ToUpperInvariant();
        return "?";
    }

    /// <summary>
    /// 새 계정 레코드를 기본값으로 생성합니다. id는 ""로 두어 코어가 할당하도록 합니다.
    /// created_at/updated_at도 코어가 설정하므로 0으로 둡니다.
    /// </summary>
    public static OtpAccount NewAccount(
        string secret,
        OtpType type = OtpType.Totp,
        string? issuer = null,
        string accountName = "",
        HashAlgorithm algorithm = HashAlgorithm.Sha1,
        uint digits = 6,
        uint period = 30,
        ulong counter = 0,
        string? folderId = null)
        => new OtpAccount(
            @id: string.Empty,
            @otpType: type,
            @secret: secret,
            @issuer: string.IsNullOrWhiteSpace(issuer) ? null : issuer,
            @accountName: accountName,
            @algorithm: algorithm,
            @digits: digits,
            @period: period,
            @counter: counter,
            @folderId: folderId,
            @isFavorite: false,
            @sortOrder: 0,
            @icon: null,
            @color: null,
            @createdAt: 0,
            @updatedAt: 0,
            @deletedAt: null);

    /// <summary>
    /// 새 폴더 레코드를 기본값으로 생성합니다.
    /// </summary>
    public static OtpFolder NewFolder(string name, string? icon = null, string? color = null)
        => new OtpFolder(
            @id: string.Empty,
            @name: name,
            @icon: icon,
            @color: color,
            @sortOrder: 0,
            @createdAt: 0,
            @updatedAt: 0,
            @deletedAt: null);
}
