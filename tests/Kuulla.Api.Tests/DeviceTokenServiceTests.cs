using Kuulla.Core.Models;
using Kuulla.Core.Services;
using Microsoft.Azure.Cosmos;
using Moq;

namespace Kuulla.Api.Tests;

public class DeviceTokenServiceTests
{
    private const string UserId = "user-1";
    private const string DeviceId = "device-1";
    private const string ApnsToken = "apns-token";

    private readonly Mock<Container> _deviceTokensContainer = new();
    private readonly DeviceTokenService _sut;

    public DeviceTokenServiceTests()
    {
        _sut = new DeviceTokenService(_deviceTokensContainer.Object);
    }

    [Fact]
    public async Task RegisterAsync_UpsertsTokenWithCompositeId()
    {
        _deviceTokensContainer
            .Setup(c => c.UpsertItemAsync(It.IsAny<DeviceToken>(), It.IsAny<PartitionKey?>(), null, default))
            .ReturnsAsync((DeviceToken t, PartitionKey? _, ItemRequestOptions? _, CancellationToken _) => CosmosTestHelpers.ItemResponse(t));

        var result = await _sut.RegisterAsync(UserId, DeviceId, ApnsToken, DevicePlatform.Ios, useSandbox: true, CancellationToken.None);

        Assert.Equal(DeviceToken.BuildId(UserId, DeviceId), result.Id);
        Assert.Equal(UserId, result.UserId);
        Assert.Equal(DeviceId, result.DeviceId);
        Assert.Equal(ApnsToken, result.ApnsToken);
        Assert.Equal(DevicePlatform.Ios, result.Platform);
        Assert.True(result.UseSandbox);
        _deviceTokensContainer.Verify(
            c => c.UpsertItemAsync(
                It.Is<DeviceToken>(t => t.Id == DeviceToken.BuildId(UserId, DeviceId)),
                It.Is<PartitionKey?>(p => p == new PartitionKey(UserId)),
                null, default),
            Times.Once);
    }

    [Fact]
    public async Task RegisterAsync_ReRegisteringOverwritesPreviousToken()
    {
        // Unlike SubscriptionService's create-then-handle-Conflict (which preserves the original
        // SubscribedAt), a device re-registering must overwrite the stored ApnsToken — Apple can
        // reissue a device's token, so the newest value has to win, not the first one seen.
        _deviceTokensContainer
            .Setup(c => c.UpsertItemAsync(It.IsAny<DeviceToken>(), It.IsAny<PartitionKey?>(), null, default))
            .ReturnsAsync((DeviceToken t, PartitionKey? _, ItemRequestOptions? _, CancellationToken _) => CosmosTestHelpers.ItemResponse(t));

        var result = await _sut.RegisterAsync(UserId, DeviceId, "new-token", DevicePlatform.Ios, useSandbox: false, CancellationToken.None);

        Assert.Equal("new-token", result.ApnsToken);
        _deviceTokensContainer.Verify(c => c.CreateItemAsync(It.IsAny<DeviceToken>(), It.IsAny<PartitionKey?>(), null, default), Times.Never);
    }

    [Fact]
    public async Task UnregisterAsync_DeletesTokenByCompositeId()
    {
        _deviceTokensContainer
            .Setup(c => c.DeleteItemAsync<DeviceToken>(DeviceToken.BuildId(UserId, DeviceId), It.IsAny<PartitionKey>(), null, default))
            .ReturnsAsync(CosmosTestHelpers.ItemResponse<DeviceToken>(null!));

        await _sut.UnregisterAsync(UserId, DeviceId, CancellationToken.None);

        _deviceTokensContainer.Verify(
            c => c.DeleteItemAsync<DeviceToken>(DeviceToken.BuildId(UserId, DeviceId), new PartitionKey(UserId), null, default),
            Times.Once);
    }

    [Fact]
    public async Task UnregisterAsync_IsIdempotentWhenTokenDoesNotExist()
    {
        _deviceTokensContainer
            .Setup(c => c.DeleteItemAsync<DeviceToken>(It.IsAny<string>(), It.IsAny<PartitionKey>(), null, default))
            .ThrowsAsync(CosmosTestHelpers.NotFound());

        await _sut.UnregisterAsync(UserId, DeviceId, CancellationToken.None);
    }

    [Fact]
    public async Task GetTokensForUserAsync_ReturnsAllPagesFromIterator()
    {
        var page1 = new[] { new DeviceToken(DeviceToken.BuildId(UserId, "device-1"), UserId, "device-1", "token-1", DevicePlatform.Ios) };
        var page2 = new[] { new DeviceToken(DeviceToken.BuildId(UserId, "device-2"), UserId, "device-2", "token-2", DevicePlatform.Ios) };
        _deviceTokensContainer
            .Setup(c => c.GetItemQueryIterator<DeviceToken>(It.IsAny<QueryDefinition>(), null, It.IsAny<QueryRequestOptions>()))
            .Returns(CosmosTestHelpers.FeedIterator<DeviceToken>(page1, page2));

        var results = await _sut.GetTokensForUserAsync(UserId, CancellationToken.None);

        Assert.Equal(page1.Concat(page2), results);
    }
}
