using Microsoft.Extensions.DependencyInjection;
using Otpeek.Core.Services;
using Otpeek.Core.Services.Interfaces;

namespace Otpeek.Core.Extensions;

/// <summary>
/// DI 확장 메서드 (플랫폼 독립적)
/// </summary>
public static class ServiceCollectionExtensions
{
    /// <summary>
    /// Core 서비스 등록 (플랫폼 독립적인 서비스만).
    /// 계정/시크릿 관련 서비스는 Rust 코어를 감싸는 OtpClientService로 대체되었으며,
    /// 이는 각 플랫폼 확장(예: AddWindowsPlatformServices)에서 등록합니다.
    /// </summary>
    public static IServiceCollection AddCoreServices(this IServiceCollection services)
    {
        services.AddSingleton<ISettingsService, SettingsService>();

        return services;
    }
}
