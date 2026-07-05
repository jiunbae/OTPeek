using FluentAssertions;
using OtpAuthenticator.Core.Models;
using Xunit;

namespace OtpAuthenticator.Core.Tests;

/// <summary>
/// 앱 환경설정 모델(WebDAV 포함)의 기본값 테스트.
/// </summary>
public class AppSettingsTests
{
    [Fact]
    public void Defaults_AreSensible()
    {
        var settings = new AppSettings();

        settings.MinimizeToTray.Should().BeTrue();
        settings.AutoCopyToClipboard.Should().BeTrue();
        settings.ClipboardClearSeconds.Should().Be(30);
        settings.EnableWidgetProvider.Should().BeTrue();
        settings.Theme.Should().Be("System");
        settings.WebDav.Should().NotBeNull();
        settings.Hotkeys.Should().NotBeNull();
    }

    [Fact]
    public void WebDav_Defaults_AreDisabledAndEmpty()
    {
        var webdav = new WebDavSettings();

        webdav.Enabled.Should().BeFalse();
        webdav.Url.Should().BeEmpty();
        webdav.Username.Should().BeEmpty();
        webdav.ProtectedPassword.Should().BeEmpty();
        webdav.AutoSync.Should().BeTrue();
        webdav.SyncIntervalMinutes.Should().Be(15);
        webdav.LastSyncTime.Should().BeNull();
    }
}
