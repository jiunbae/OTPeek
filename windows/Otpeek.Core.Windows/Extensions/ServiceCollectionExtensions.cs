using Microsoft.Extensions.DependencyInjection;
using Otpeek.Core.Services.Interfaces;
using Otpeek.Core.Windows.Services;

namespace Otpeek.Core.Windows.Extensions;

/// <summary>
/// Windows 플랫폼 서비스 DI 확장
/// </summary>
public static class ServiceCollectionExtensions
{
    /// <summary>
    /// Windows 플랫폼 전용 서비스 등록
    /// </summary>
    public static IServiceCollection AddWindowsPlatformServices(this IServiceCollection services)
    {
        services.AddSingleton<ISecureStorageService, SecureStorageService>();
        services.AddSingleton<IClipboardService, ClipboardService>();
        services.AddSingleton<IScreenCaptureService, ScreenCaptureService>();
        services.AddSingleton<IQrCodeService, QrCodeService>();
        services.AddSingleton<IFaviconService, FaviconService>();

        // Rust 코어 볼트 래퍼 (앱 전역에서 단일 인스턴스로 공유)
        services.AddSingleton<IOtpClientService, OtpClientService>();
        services.AddSingleton(sp => new QuickOtpCodeProvider(
            sp.GetRequiredService<ISecureStorageService>().DataDirectory));

        // v1 → v2 마이그레이션
        services.AddSingleton<ILegacyMigrationService, LegacyMigrationService>();

        return services;
    }
}
