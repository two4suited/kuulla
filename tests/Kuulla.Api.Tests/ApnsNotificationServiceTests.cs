using dotAPNS;
using Kuulla.Core.Models;
using Kuulla.Core.Services;
using Microsoft.Extensions.Logging.Abstractions;
using Moq;

namespace Kuulla.Api.Tests;

public class ApnsNotificationServiceTests
{
    private const string UserId = "user-1";
    private const string ShowId = "show-1";

    private readonly Mock<IApnsClient> _apnsClient = new();
    private readonly Mock<IDeviceTokenService> _deviceTokenService = new();
    private readonly ApnsNotificationService _sut;

    public ApnsNotificationServiceTests()
    {
        _sut = new ApnsNotificationService(
            _apnsClient.Object, _deviceTokenService.Object, new ApnsNotificationServiceOptions(UseSandbox: false),
            NullLogger<ApnsNotificationService>.Instance);
    }

    private static DeviceToken MakeToken(string deviceId = "device-1") =>
        new(DeviceToken.BuildId(UserId, deviceId), UserId, deviceId, $"apns-token-{deviceId}", DevicePlatform.Ios);

    private static Episode MakeEpisode(string id) =>
        new(id, ShowId, $"Episode {id}", DateTimeOffset.UtcNow, TimeSpan.FromMinutes(30), $"https://audio.example/{id}.mp3", null, null, null);

    [Fact]
    public async Task NotifyNewEpisodesAsync_SendsOnePushPerDeviceToken()
    {
        var tokens = new[] { MakeToken("device-1"), MakeToken("device-2") };
        _apnsClient.Setup(c => c.SendAsync(It.IsAny<ApplePush>(), It.IsAny<CancellationToken>())).ReturnsAsync(ApnsResponse.Successful());

        await _sut.NotifyNewEpisodesAsync(tokens, ShowId, "Show Title", [MakeEpisode("ep-1")], CancellationToken.None);

        _apnsClient.Verify(c => c.SendAsync(It.Is<ApplePush>(p => p.Token == "apns-token-device-1"), It.IsAny<CancellationToken>()), Times.Once);
        _apnsClient.Verify(c => c.SendAsync(It.Is<ApplePush>(p => p.Token == "apns-token-device-2"), It.IsAny<CancellationToken>()), Times.Once);
    }

    [Fact]
    public async Task NotifyNewEpisodesAsync_UnregistersDeviceOnBadDeviceTokenResponse()
    {
        var token = MakeToken();
        _apnsClient
            .Setup(c => c.SendAsync(It.IsAny<ApplePush>(), It.IsAny<CancellationToken>()))
            .ReturnsAsync(ApnsResponse.Error(ApnsResponseReason.BadDeviceToken, "BadDeviceToken"));

        await _sut.NotifyNewEpisodesAsync([token], ShowId, "Show Title", [MakeEpisode("ep-1")], CancellationToken.None);

        _deviceTokenService.Verify(s => s.UnregisterAsync(UserId, token.DeviceId, It.IsAny<CancellationToken>()), Times.Once);
    }

    [Fact]
    public async Task NotifyNewEpisodesAsync_DoesNotUnregisterDeviceOnTransientFailure()
    {
        var token = MakeToken();
        _apnsClient
            .Setup(c => c.SendAsync(It.IsAny<ApplePush>(), It.IsAny<CancellationToken>()))
            .ReturnsAsync(ApnsResponse.Error(ApnsResponseReason.InternalServerError, "InternalServerError"));

        await _sut.NotifyNewEpisodesAsync([token], ShowId, "Show Title", [MakeEpisode("ep-1")], CancellationToken.None);

        _deviceTokenService.Verify(s => s.UnregisterAsync(It.IsAny<string>(), It.IsAny<string>(), It.IsAny<CancellationToken>()), Times.Never);
    }

    [Fact]
    public async Task NotifyNewEpisodesAsync_IsolatesOneDeviceSendFailureFromOthers()
    {
        var tokens = new[] { MakeToken("device-1"), MakeToken("device-2") };
        _apnsClient
            .Setup(c => c.SendAsync(It.Is<ApplePush>(p => p.Token == "apns-token-device-1"), It.IsAny<CancellationToken>()))
            .ThrowsAsync(new HttpRequestException("network error"));
        _apnsClient
            .Setup(c => c.SendAsync(It.Is<ApplePush>(p => p.Token == "apns-token-device-2"), It.IsAny<CancellationToken>()))
            .ReturnsAsync(ApnsResponse.Successful());

        // Must not throw — one device's send failing shouldn't fail the whole fan-out.
        await _sut.NotifyNewEpisodesAsync(tokens, ShowId, "Show Title", [MakeEpisode("ep-1")], CancellationToken.None);

        _apnsClient.Verify(c => c.SendAsync(It.Is<ApplePush>(p => p.Token == "apns-token-device-2"), It.IsAny<CancellationToken>()), Times.Once);
    }

    [Fact]
    public async Task NotifyNewEpisodesAsync_IncludesEpisodeIdWhenExactlyOneNewEpisode()
    {
        var token = MakeToken();
        ApplePush? sentPush = null;
        _apnsClient
            .Setup(c => c.SendAsync(It.IsAny<ApplePush>(), It.IsAny<CancellationToken>()))
            .Callback<ApplePush, CancellationToken>((p, _) => sentPush = p)
            .ReturnsAsync(ApnsResponse.Successful());

        await _sut.NotifyNewEpisodesAsync([token], ShowId, "Show Title", [MakeEpisode("ep-1")], CancellationToken.None);

        Assert.NotNull(sentPush);
        Assert.Equal(ShowId, sentPush!.CustomProperties["showId"]);
        Assert.Equal("ep-1", sentPush.CustomProperties["episodeId"]);
    }

    [Fact]
    public async Task NotifyNewEpisodesAsync_OmitsEpisodeIdWhenMultipleNewEpisodes()
    {
        var token = MakeToken();
        ApplePush? sentPush = null;
        _apnsClient
            .Setup(c => c.SendAsync(It.IsAny<ApplePush>(), It.IsAny<CancellationToken>()))
            .Callback<ApplePush, CancellationToken>((p, _) => sentPush = p)
            .ReturnsAsync(ApnsResponse.Successful());

        await _sut.NotifyNewEpisodesAsync([token], ShowId, "Show Title", [MakeEpisode("ep-1"), MakeEpisode("ep-2")], CancellationToken.None);

        Assert.NotNull(sentPush);
        Assert.False(sentPush!.CustomProperties.ContainsKey("episodeId"));
        Assert.Equal("2 new episodes", sentPush.Alert.Body);
    }
}
