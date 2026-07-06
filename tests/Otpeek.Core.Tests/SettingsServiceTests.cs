using FluentAssertions;
using Moq;
using Otpeek.Core.Models;
using Otpeek.Core.Services;
using Otpeek.Core.Services.Interfaces;
using Xunit;

namespace Otpeek.Core.Tests;

/// <summary>
/// SettingsService 테스트. 실제 DPAPI를 사용하지 않도록 ISecureStorageService를 모킹합니다.
/// </summary>
public class SettingsServiceTests
{
    [Fact]
    public async Task LoadAsync_WhenNoStoredData_UsesDefaults()
    {
        var storage = new Mock<ISecureStorageService>();
        storage.Setup(s => s.LoadEncryptedDataAsync<AppSettings>(It.IsAny<string>()))
               .ReturnsAsync((AppSettings?)null);

        var service = new SettingsService(storage.Object);
        await service.LoadAsync();

        service.Settings.Should().NotBeNull();
        service.Settings.Theme.Should().Be("System");
    }

    [Fact]
    public async Task LoadAsync_WhenStoredData_UsesStored()
    {
        var stored = new AppSettings { Theme = "Dark", ClipboardClearSeconds = 60 };
        var storage = new Mock<ISecureStorageService>();
        storage.Setup(s => s.LoadEncryptedDataAsync<AppSettings>(It.IsAny<string>()))
               .ReturnsAsync(stored);

        var service = new SettingsService(storage.Object);
        await service.LoadAsync();

        service.Settings.Theme.Should().Be("Dark");
        service.Settings.ClipboardClearSeconds.Should().Be(60);
    }

    [Fact]
    public async Task SaveAsync_PersistsAndRaisesEvent()
    {
        var storage = new Mock<ISecureStorageService>();
        storage.Setup(s => s.SaveEncryptedDataAsync(It.IsAny<string>(), It.IsAny<AppSettings>()))
               .Returns(Task.CompletedTask);

        var service = new SettingsService(storage.Object);
        var raised = false;
        service.SettingsChanged += (_, _) => raised = true;

        service.Settings.Theme = "Light";
        await service.SaveAsync();

        storage.Verify(s => s.SaveEncryptedDataAsync(It.IsAny<string>(), It.IsAny<AppSettings>()), Times.Once);
        raised.Should().BeTrue();
    }

    [Fact]
    public async Task ResetAsync_RestoresDefaults()
    {
        var storage = new Mock<ISecureStorageService>();
        storage.Setup(s => s.SaveEncryptedDataAsync(It.IsAny<string>(), It.IsAny<AppSettings>()))
               .Returns(Task.CompletedTask);

        var service = new SettingsService(storage.Object);
        service.Settings.Theme = "Dark";

        await service.ResetAsync();

        service.Settings.Theme.Should().Be("System");
    }
}
