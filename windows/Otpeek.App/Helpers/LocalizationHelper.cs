using Microsoft.Windows.ApplicationModel.Resources;

namespace Otpeek.App.Helpers;

/// <summary>
/// 로컬라이제이션 헬퍼
/// </summary>
public static class LocalizationHelper
{
    private static readonly ResourceLoader _resourceLoader;

    static LocalizationHelper()
    {
        _resourceLoader = new ResourceLoader();
    }

    /// <summary>
    /// 리소스 문자열 가져오기
    /// </summary>
    public static string GetString(string resourceKey)
    {
        try
        {
            return _resourceLoader.GetString(resourceKey);
        }
        catch
        {
            return resourceKey;
        }
    }

    /// <summary>
    /// 포맷된 리소스 문자열 가져오기
    /// </summary>
    public static string GetString(string resourceKey, params object[] args)
    {
        try
        {
            var format = _resourceLoader.GetString(resourceKey);
            return string.Format(format, args);
        }
        catch
        {
            return resourceKey;
        }
    }
}
