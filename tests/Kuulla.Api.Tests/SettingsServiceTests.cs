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

    [Fact]
    public async Task GetShowSettingsAsync_ReturnsDefaultWhenNoDocumentExists()
    {
        const string showId = "show-1";
        var id = ShowSettings.BuildId(UserId, showId);
        _settingsContainer
            .Setup(c => c.ReadItemAsync<ShowSettings>(id, It.IsAny<PartitionKey>(), null, default))
            .ThrowsAsync(CosmosTestHelpers.NotFound());

        var result = await _sut.GetShowSettingsAsync(UserId, showId, CancellationToken.None);

        Assert.Equal(ShowSettings.CreateDefault(UserId, showId), result);
    }

    [Fact]
    public async Task GetShowSettingsAsync_ReturnsExistingDocument()
    {
        const string showId = "show-1";
        var id = ShowSettings.BuildId(UserId, showId);
        var existing = new ShowSettings(id, UserId, showId, UnlistenedEpisodeCount.Ten, Version: 2);
        _settingsContainer
            .Setup(c => c.ReadItemAsync<ShowSettings>(id, It.IsAny<PartitionKey>(), null, default))
            .ReturnsAsync(CosmosTestHelpers.ItemResponse(existing));

        var result = await _sut.GetShowSettingsAsync(UserId, showId, CancellationToken.None);

        Assert.Equal(existing, result);
    }

    [Fact]
    public async Task UpdateShowUnlistenedEpisodeCountAsync_UpsertsWithIncrementedVersionWhenNoDocumentExists()
    {
        const string showId = "show-1";
        var id = ShowSettings.BuildId(UserId, showId);
        _settingsContainer
            .Setup(c => c.ReadItemAsync<ShowSettings>(id, It.IsAny<PartitionKey>(), null, default))
            .ThrowsAsync(CosmosTestHelpers.NotFound());
        _settingsContainer
            .Setup(c => c.UpsertItemAsync(It.IsAny<ShowSettings>(), It.IsAny<PartitionKey?>(), null, default))
            .ReturnsAsync((ShowSettings s, PartitionKey? _, ItemRequestOptions? _, CancellationToken _) => CosmosTestHelpers.ItemResponse(s));

        var result = await _sut.UpdateShowUnlistenedEpisodeCountAsync(UserId, showId, UnlistenedEpisodeCount.Two, CancellationToken.None);

        Assert.Equal(UserId, result.UserId);
        Assert.Equal(showId, result.ShowId);
        Assert.Equal(UnlistenedEpisodeCount.Two, result.UnlistenedEpisodeCount);
        Assert.Equal(2, result.Version);
    }

    [Fact]
    public async Task UpdateShowUnlistenedEpisodeCountAsync_ClearsOverrideWhenValueIsNull()
    {
        const string showId = "show-1";
        var id = ShowSettings.BuildId(UserId, showId);
        var existing = new ShowSettings(id, UserId, showId, UnlistenedEpisodeCount.Ten, Version: 2);
        _settingsContainer
            .Setup(c => c.ReadItemAsync<ShowSettings>(id, It.IsAny<PartitionKey>(), null, default))
            .ReturnsAsync(CosmosTestHelpers.ItemResponse(existing));
        _settingsContainer
            .Setup(c => c.UpsertItemAsync(It.IsAny<ShowSettings>(), It.IsAny<PartitionKey?>(), null, default))
            .ReturnsAsync((ShowSettings s, PartitionKey? _, ItemRequestOptions? _, CancellationToken _) => CosmosTestHelpers.ItemResponse(s));

        var result = await _sut.UpdateShowUnlistenedEpisodeCountAsync(UserId, showId, null, CancellationToken.None);

        Assert.Null(result.UnlistenedEpisodeCount);
        Assert.Equal(3, result.Version);
    }

    [Fact]
    public async Task GetEffectiveUnlistenedEpisodeCountAsync_ReturnsShowOverrideWhenSet()
    {
        const string showId = "show-1";
        var showSettingsId = ShowSettings.BuildId(UserId, showId);
        var showSettings = new ShowSettings(showSettingsId, UserId, showId, UnlistenedEpisodeCount.One, Version: 2);
        _settingsContainer
            .Setup(c => c.ReadItemAsync<ShowSettings>(showSettingsId, It.IsAny<PartitionKey>(), null, default))
            .ReturnsAsync(CosmosTestHelpers.ItemResponse(showSettings));

        var result = await _sut.GetEffectiveUnlistenedEpisodeCountAsync(UserId, showId, CancellationToken.None);

        Assert.Equal(UnlistenedEpisodeCount.One, result);
        _settingsContainer.Verify(
            c => c.ReadItemAsync<UserSettings>(It.IsAny<string>(), It.IsAny<PartitionKey>(), null, default), Times.Never);
    }

    [Fact]
    public async Task GetEffectiveUnlistenedEpisodeCountAsync_FallsBackToUserSettingsWhenNoOverride()
    {
        const string showId = "show-1";
        var showSettingsId = ShowSettings.BuildId(UserId, showId);
        _settingsContainer
            .Setup(c => c.ReadItemAsync<ShowSettings>(showSettingsId, It.IsAny<PartitionKey>(), null, default))
            .ThrowsAsync(CosmosTestHelpers.NotFound());
        var userSettings = new UserSettings(UserId, UnlistenedEpisodeCount.Ten, Version: 1);
        _settingsContainer
            .Setup(c => c.ReadItemAsync<UserSettings>(UserId, It.IsAny<PartitionKey>(), null, default))
            .ReturnsAsync(CosmosTestHelpers.ItemResponse(userSettings));

        var result = await _sut.GetEffectiveUnlistenedEpisodeCountAsync(UserId, showId, CancellationToken.None);

        Assert.Equal(UnlistenedEpisodeCount.Ten, result);
    }

    [Fact]
    public async Task UpdateAutoArchiveRuleAsync_IncrementsVersionOfExistingDocument()
    {
        var existing = new UserSettings(UserId, UnlistenedEpisodeCount.Five, Version: 3, AutoArchiveRule.Never);
        _settingsContainer
            .Setup(c => c.ReadItemAsync<UserSettings>(UserId, It.IsAny<PartitionKey>(), null, default))
            .ReturnsAsync(CosmosTestHelpers.ItemResponse(existing));
        _settingsContainer
            .Setup(c => c.UpsertItemAsync(It.IsAny<UserSettings>(), It.IsAny<PartitionKey?>(), null, default))
            .ReturnsAsync((UserSettings s, PartitionKey? _, ItemRequestOptions? _, CancellationToken _) => CosmosTestHelpers.ItemResponse(s));

        var result = await _sut.UpdateAutoArchiveRuleAsync(UserId, AutoArchiveRule.After7Days, CancellationToken.None);

        Assert.Equal(AutoArchiveRule.After7Days, result.AutoArchiveRule);
        Assert.Equal(4, result.Version);
    }

    [Fact]
    public async Task UpdateShowAutoArchiveRuleAsync_ClearsOverrideWhenValueIsNull()
    {
        const string showId = "show-1";
        var id = ShowSettings.BuildId(UserId, showId);
        var existing = new ShowSettings(id, UserId, showId, UnlistenedEpisodeCount.Ten, Version: 2, AutoArchiveRule.After1Day);
        _settingsContainer
            .Setup(c => c.ReadItemAsync<ShowSettings>(id, It.IsAny<PartitionKey>(), null, default))
            .ReturnsAsync(CosmosTestHelpers.ItemResponse(existing));
        _settingsContainer
            .Setup(c => c.UpsertItemAsync(It.IsAny<ShowSettings>(), It.IsAny<PartitionKey?>(), null, default))
            .ReturnsAsync((ShowSettings s, PartitionKey? _, ItemRequestOptions? _, CancellationToken _) => CosmosTestHelpers.ItemResponse(s));

        var result = await _sut.UpdateShowAutoArchiveRuleAsync(UserId, showId, null, CancellationToken.None);

        Assert.Null(result.AutoArchiveRule);
        Assert.Equal(3, result.Version);
    }

    [Fact]
    public async Task GetEffectiveAutoArchiveRuleAsync_ReturnsShowOverrideWhenSet()
    {
        const string showId = "show-1";
        var showSettingsId = ShowSettings.BuildId(UserId, showId);
        var showSettings = new ShowSettings(showSettingsId, UserId, showId, null, Version: 2, AutoArchiveRule.After30Days);
        _settingsContainer
            .Setup(c => c.ReadItemAsync<ShowSettings>(showSettingsId, It.IsAny<PartitionKey>(), null, default))
            .ReturnsAsync(CosmosTestHelpers.ItemResponse(showSettings));

        var result = await _sut.GetEffectiveAutoArchiveRuleAsync(UserId, showId, CancellationToken.None);

        Assert.Equal(AutoArchiveRule.After30Days, result);
        _settingsContainer.Verify(
            c => c.ReadItemAsync<UserSettings>(It.IsAny<string>(), It.IsAny<PartitionKey>(), null, default), Times.Never);
    }

    [Fact]
    public async Task GetEffectiveAutoArchiveRuleAsync_FallsBackToUserSettingsWhenNoOverride()
    {
        const string showId = "show-1";
        var showSettingsId = ShowSettings.BuildId(UserId, showId);
        _settingsContainer
            .Setup(c => c.ReadItemAsync<ShowSettings>(showSettingsId, It.IsAny<PartitionKey>(), null, default))
            .ThrowsAsync(CosmosTestHelpers.NotFound());
        var userSettings = new UserSettings(UserId, UnlistenedEpisodeCount.Five, Version: 1, AutoArchiveRule.AfterPlayed);
        _settingsContainer
            .Setup(c => c.ReadItemAsync<UserSettings>(UserId, It.IsAny<PartitionKey>(), null, default))
            .ReturnsAsync(CosmosTestHelpers.ItemResponse(userSettings));

        var result = await _sut.GetEffectiveAutoArchiveRuleAsync(UserId, showId, CancellationToken.None);

        Assert.Equal(AutoArchiveRule.AfterPlayed, result);
    }
}
