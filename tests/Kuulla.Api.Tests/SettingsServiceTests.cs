using Kuulla.Api.Models;
using Kuulla.Api.Services;
using Microsoft.Azure.Cosmos;
using Moq;

namespace Kuulla.Api.Tests;

public class SettingsServiceTests
{
    private const string UserId = "user-1";

    private readonly Mock<Container> _settingsContainer = new();
    private readonly SettingsService _sut;

    public SettingsServiceTests()
    {
        _sut = new SettingsService(_settingsContainer.Object);
    }

    [Fact]
    public async Task GetSettingsAsync_ReturnsDefaultWhenNoDocumentExists()
    {
        _settingsContainer
            .Setup(c => c.ReadItemAsync<UserSettings>(UserId, It.IsAny<PartitionKey>(), null, default))
            .ThrowsAsync(CosmosTestHelpers.NotFound());

        var result = await _sut.GetSettingsAsync(UserId, CancellationToken.None);

        Assert.Equal(UserSettings.CreateDefault(UserId), result);
    }

    [Fact]
    public async Task GetSettingsAsync_ReturnsExistingDocument()
    {
        var existing = new UserSettings(UserId, UnlistenedEpisodeCount.Ten, Version: 3);
        _settingsContainer
            .Setup(c => c.ReadItemAsync<UserSettings>(UserId, It.IsAny<PartitionKey>(), null, default))
            .ReturnsAsync(CosmosTestHelpers.ItemResponse(existing));

        var result = await _sut.GetSettingsAsync(UserId, CancellationToken.None);

        Assert.Equal(existing, result);
    }

    [Fact]
    public async Task UpdateUnlistenedEpisodeCountAsync_UpsertsWithIncrementedVersionWhenNoDocumentExists()
    {
        _settingsContainer
            .Setup(c => c.ReadItemAsync<UserSettings>(UserId, It.IsAny<PartitionKey>(), null, default))
            .ThrowsAsync(CosmosTestHelpers.NotFound());
        _settingsContainer
            .Setup(c => c.UpsertItemAsync(It.IsAny<UserSettings>(), It.IsAny<PartitionKey?>(), null, default))
            .ReturnsAsync((UserSettings s, PartitionKey? _, ItemRequestOptions? _, CancellationToken _) => CosmosTestHelpers.ItemResponse(s));

        var result = await _sut.UpdateUnlistenedEpisodeCountAsync(UserId, UnlistenedEpisodeCount.Unlimited, CancellationToken.None);

        Assert.Equal(UserId, result.UserId);
        Assert.Equal(UnlistenedEpisodeCount.Unlimited, result.UnlistenedEpisodeCount);
        Assert.Equal(2, result.Version);
    }

    [Fact]
    public async Task UpdateUnlistenedEpisodeCountAsync_IncrementsVersionOfExistingDocument()
    {
        var existing = new UserSettings(UserId, UnlistenedEpisodeCount.Five, Version: 3);
        _settingsContainer
            .Setup(c => c.ReadItemAsync<UserSettings>(UserId, It.IsAny<PartitionKey>(), null, default))
            .ReturnsAsync(CosmosTestHelpers.ItemResponse(existing));
        _settingsContainer
            .Setup(c => c.UpsertItemAsync(It.IsAny<UserSettings>(), It.IsAny<PartitionKey?>(), null, default))
            .ReturnsAsync((UserSettings s, PartitionKey? _, ItemRequestOptions? _, CancellationToken _) => CosmosTestHelpers.ItemResponse(s));

        var result = await _sut.UpdateUnlistenedEpisodeCountAsync(UserId, UnlistenedEpisodeCount.One, CancellationToken.None);

        Assert.Equal(UnlistenedEpisodeCount.One, result.UnlistenedEpisodeCount);
        Assert.Equal(4, result.Version);
    }
}
