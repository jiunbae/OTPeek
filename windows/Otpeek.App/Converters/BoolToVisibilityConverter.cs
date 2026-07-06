using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Data;

namespace Otpeek.App.Converters;

/// <summary>
/// Bool을 Visibility로 변환
/// </summary>
public class BoolToVisibilityConverter : IValueConverter
{
    public bool Inverse { get; set; } = false;

    public object Convert(object value, Type targetType, object parameter, string language)
    {
        bool boolValue = value is bool b && b;

        if (Inverse)
            boolValue = !boolValue;

        return boolValue ? Visibility.Visible : Visibility.Collapsed;
    }

    public object ConvertBack(object value, Type targetType, object parameter, string language)
    {
        bool visible = value is Visibility v && v == Visibility.Visible;

        if (Inverse)
            visible = !visible;

        return visible;
    }
}

/// <summary>
/// 복사 아이콘 변환 (IsCopied에 따라 체크 또는 복사 아이콘)
/// </summary>
public class CopyIconConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language)
    {
        bool isCopied = value is bool b && b;
        return isCopied ? "\uE73E" : "\uE8C8"; // Checkmark : Copy
    }

    public object ConvertBack(object value, Type targetType, object parameter, string language)
    {
        throw new NotImplementedException();
    }
}

/// <summary>
/// 진행률을 색상으로 변환
/// </summary>
public class ProgressToColorConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language)
    {
        double progress = value is double d ? d : 1.0;

        if (progress < 0.2)
            return new Microsoft.UI.Xaml.Media.SolidColorBrush(Microsoft.UI.Colors.Red);
        if (progress < 0.4)
            return new Microsoft.UI.Xaml.Media.SolidColorBrush(Microsoft.UI.Colors.Orange);

        return new Microsoft.UI.Xaml.Media.SolidColorBrush(Microsoft.UI.Colors.Green);
    }

    public object ConvertBack(object value, Type targetType, object parameter, string language)
    {
        throw new NotImplementedException();
    }
}

/// <summary>
/// 복사 상태에 따른 배경색 변환 (복사됨: 연한 녹색, 기본: 반투명)
/// </summary>
public class CopiedBackgroundConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language)
    {
        bool isCopied = value is bool b && b;

        if (isCopied)
        {
            // Light green with opacity
            return new Microsoft.UI.Xaml.Media.SolidColorBrush(
                Windows.UI.Color.FromArgb(40, 0, 200, 0)); // #2800C800
        }
        else
        {
            // Subtle background
            return new Microsoft.UI.Xaml.Media.SolidColorBrush(
                Windows.UI.Color.FromArgb(20, 128, 128, 128)); // #14808080
        }
    }

    public object ConvertBack(object value, Type targetType, object parameter, string language)
    {
        throw new NotImplementedException();
    }
}
