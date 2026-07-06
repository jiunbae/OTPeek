using CommunityToolkit.Mvvm.ComponentModel;

namespace Otpeek.App.ViewModels;

/// <summary>
/// ViewModel 기본 클래스
/// </summary>
public abstract partial class BaseViewModel : ObservableObject
{
    [ObservableProperty]
    private bool _isLoading;

    [ObservableProperty]
    private string? _errorMessage;

    /// <summary>
    /// 비동기 작업 실행 (로딩 상태 관리)
    /// </summary>
    protected async Task ExecuteAsync(Func<Task> operation, Action<Exception>? onError = null)
    {
        try
        {
            IsLoading = true;
            ErrorMessage = null;
            await operation();
        }
        catch (Exception ex)
        {
            ErrorMessage = ex.Message;
            onError?.Invoke(ex);
        }
        finally
        {
            IsLoading = false;
        }
    }

    /// <summary>
    /// 비동기 작업 실행 (결과 반환)
    /// </summary>
    protected async Task<T?> ExecuteAsync<T>(Func<Task<T>> operation, Action<Exception>? onError = null)
    {
        try
        {
            IsLoading = true;
            ErrorMessage = null;
            return await operation();
        }
        catch (Exception ex)
        {
            ErrorMessage = ex.Message;
            onError?.Invoke(ex);
            return default;
        }
        finally
        {
            IsLoading = false;
        }
    }
}
