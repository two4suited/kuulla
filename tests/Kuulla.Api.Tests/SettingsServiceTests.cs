using Kuulla.Core.Models;
using Kuulla.Core.Services;
using Microsoft.Azure.Cosmos;
using Moq;
using Newtonsoft.Json;

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

        // Compared field-by-field rather than via record equality against a second
        // UserSettings.CreateDefault(UserId) call — CreateDefault stamps UpdatedAt with
        // DateTimeOffset.UtcNow, so two independent calls are never equal.
        var expected = UserSettings.CreateDefault(UserId);
        Assert.Equal(expected with { UpdatedAt = result.UpdatedAt }, result);
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
    public async Task UpdateUnlistenedEpisodeCountAsync_CreatesWithIncrementedVersionWhenNoDocumentExists()
    {
        _settingsContainer
            .Setup(c => c.ReadItemAsync<UserSettings>(UserId, It.IsAny<PartitionKey>(), null, default))
            .ThrowsAsync(CosmosTestHelpers.NotFound());
        _settingsContainer
            .Setup(c => c.CreateItemAsync(It.IsAny<UserSettings>(), It.IsAny<PartitionKey?>(), null, default))
            .ReturnsAsync((UserSettings s, PartitionKey? _, ItemRequestOptions? _, CancellationToken _) => CosmosTestHelpers.ItemResponse(s));

        var result = await _sut.UpdateUnlistenedEpisodeCountAsync(UserId, UnlistenedEpisodeCount.Unlimited, CancellationToken.None);

        Assert.Equal(UserId, result.UserId);
        Assert.Equal(UnlistenedEpisodeCount.Unlimited, result.UnlistenedEpisodeCount);
        Assert.Equal(2, result.Version);
        _settingsContainer.Verify(
            c => c.UpsertItemAsync(It.IsAny<UserSettings>(), It.IsAny<PartitionKey?>(), It.IsAny<ItemRequestOptions>(), default), Times.Never);
    }

    [Fact]
    public async Task UpdateUnlistenedEpisodeCountAsync_RetriesWhenConcurrentCreateWinsTheRace()
    {
        // Two devices both create a brand-new user's settings document for the first time; ours
        // loses the race to CreateItemAsync (Conflict), so it must re-read the now-existing
        // document and retry as a conditional update rather than silently giving up or
        // overwriting via an unconditional upsert.
        var wonByOtherDevice = new UserSettings(
            UserId, UnlistenedEpisodeCount.Five, Version: 1, AutoArchiveRule.Never, AutoDownloadNewEpisodes: true);

        _settingsContainer
            .SetupSequence(c => c.ReadItemAsync<UserSettings>(UserId, It.IsAny<PartitionKey>(), null, default))
            .ThrowsAsync(CosmosTestHelpers.NotFound())
            .ReturnsAsync(CosmosTestHelpers.ItemResponse(wonByOtherDevice, etag: "etag-1"));
        _settingsContainer
            .Setup(c => c.CreateItemAsync(It.IsAny<UserSettings>(), It.IsAny<PartitionKey?>(), null, default))
            .ThrowsAsync(CosmosTestHelpers.Conflict());
        _settingsContainer
            .Setup(c => c.UpsertItemAsync(
                It.IsAny<UserSettings>(), It.IsAny<PartitionKey?>(),
                It.Is<ItemRequestOptions>(o => o!.IfMatchEtag == "etag-1"), default))
            .ReturnsAsync((UserSettings s, PartitionKey? _, ItemRequestOptions? _, CancellationToken _) => CosmosTestHelpers.ItemResponse(s));

        var result = await _sut.UpdateUnlistenedEpisodeCountAsync(UserId, UnlistenedEpisodeCount.Unlimited, CancellationToken.None);

        Assert.Equal(UnlistenedEpisodeCount.Unlimited, result.UnlistenedEpisodeCount);
        Assert.True(result.AutoDownloadNewEpisodes);
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
            .Setup(c => c.UpsertItemAsync(It.IsAny<UserSettings>(), It.IsAny<PartitionKey?>(), It.IsAny<ItemRequestOptions>(), default))
            .ReturnsAsync((UserSettings s, PartitionKey? _, ItemRequestOptions? _, CancellationToken _) => CosmosTestHelpers.ItemResponse(s));

        var result = await _sut.UpdateUnlistenedEpisodeCountAsync(UserId, UnlistenedEpisodeCount.One, CancellationToken.None);

        Assert.Equal(UnlistenedEpisodeCount.One, result.UnlistenedEpisodeCount);
        Assert.Equal(4, result.Version);
    }

    [Fact]
    public async Task UpdateSubscriptionSortOrderAsync_IncrementsVersionOfExistingDocument()
    {
        var existing = new UserSettings(UserId, UnlistenedEpisodeCount.Five, Version: 3);
        _settingsContainer
            .Setup(c => c.ReadItemAsync<UserSettings>(UserId, It.IsAny<PartitionKey>(), null, default))
            .ReturnsAsync(CosmosTestHelpers.ItemResponse(existing));
        _settingsContainer
            .Setup(c => c.UpsertItemAsync(It.IsAny<UserSettings>(), It.IsAny<PartitionKey?>(), It.IsAny<ItemRequestOptions>(), default))
            .ReturnsAsync((UserSettings s, PartitionKey? _, ItemRequestOptions? _, CancellationToken _) => CosmosTestHelpers.ItemResponse(s));

        var result = await _sut.UpdateSubscriptionSortOrderAsync(UserId, SubscriptionSortOrder.LatestEpisode, CancellationToken.None);

        Assert.Equal(SubscriptionSortOrder.LatestEpisode, result.SubscriptionSortOrder);
        Assert.Equal(4, result.Version);
    }

    [Fact]
    public async Task SyncAsync_PreservesStoredSubscriptionSortOrderWhenChangeOmitsIt()
    {
        var lastSyncedAt = DateTimeOffset.UtcNow.AddHours(-2);
        var stored = new UserSettings(
            UserId, UnlistenedEpisodeCount.Five, Version: 3, UpdatedAt: DateTimeOffset.UtcNow.AddHours(-1),
            SubscriptionSortOrder: SubscriptionSortOrder.RecentlyAdded);
        _settingsContainer
            .Setup(c => c.ReadItemAsync<UserSettings>(UserId, It.IsAny<PartitionKey>(), null, default))
            .ReturnsAsync(CosmosTestHelpers.ItemResponse(stored));
        _settingsContainer
            .Setup(c => c.UpsertItemAsync(It.IsAny<UserSettings>(), It.IsAny<PartitionKey?>(), It.IsAny<ItemRequestOptions>(), default))
            .ReturnsAsync((UserSettings s, PartitionKey? _, ItemRequestOptions? _, CancellationToken _) => CosmosTestHelpers.ItemResponse(s));

        // Older client that doesn't send the field yet.
        var change = MakeChange(DateTimeOffset.UtcNow, subscriptionSortOrder: null);
        await _sut.SyncAsync(UserId, "device-a", lastSyncedAt, "stale-hash", [change], CancellationToken.None);

        _settingsContainer.Verify(
            c => c.UpsertItemAsync(
                It.Is<UserSettings>(s => s.SubscriptionSortOrder == SubscriptionSortOrder.RecentlyAdded),
                It.IsAny<PartitionKey?>(), null, default),
            Times.Once);
    }

    [Fact]
    public async Task UpdateSubscriptionManualOrderAsync_PersistsListAndBumpsVersion()
    {
        var existing = new UserSettings(UserId, UnlistenedEpisodeCount.Five, Version: 3);
        _settingsContainer
            .Setup(c => c.ReadItemAsync<UserSettings>(UserId, It.IsAny<PartitionKey>(), null, default))
            .ReturnsAsync(CosmosTestHelpers.ItemResponse(existing));
        _settingsContainer
            .Setup(c => c.UpsertItemAsync(It.IsAny<UserSettings>(), It.IsAny<PartitionKey?>(), It.IsAny<ItemRequestOptions>(), default))
            .ReturnsAsync((UserSettings s, PartitionKey? _, ItemRequestOptions? _, CancellationToken _) => CosmosTestHelpers.ItemResponse(s));

        var result = await _sut.UpdateSubscriptionManualOrderAsync(UserId, ["show-b", "show-a", "show-c"], CancellationToken.None);

        Assert.Equal(["show-b", "show-a", "show-c"], result.SubscriptionManualOrder);
        Assert.Equal(4, result.Version);
    }

    [Fact]
    public async Task SyncAsync_PreservesStoredManualOrderWhenChangeOmitsIt()
    {
        var lastSyncedAt = DateTimeOffset.UtcNow.AddHours(-2);
        var stored = new UserSettings(
            UserId, UnlistenedEpisodeCount.Five, Version: 3, UpdatedAt: DateTimeOffset.UtcNow.AddHours(-1),
            SubscriptionManualOrder: ["show-x", "show-y"]);
        _settingsContainer
            .Setup(c => c.ReadItemAsync<UserSettings>(UserId, It.IsAny<PartitionKey>(), null, default))
            .ReturnsAsync(CosmosTestHelpers.ItemResponse(stored));
        _settingsContainer
            .Setup(c => c.UpsertItemAsync(It.IsAny<UserSettings>(), It.IsAny<PartitionKey?>(), It.IsAny<ItemRequestOptions>(), default))
            .ReturnsAsync((UserSettings s, PartitionKey? _, ItemRequestOptions? _, CancellationToken _) => CosmosTestHelpers.ItemResponse(s));

        var change = MakeChange(DateTimeOffset.UtcNow, subscriptionManualOrder: null);
        await _sut.SyncAsync(UserId, "device-a", lastSyncedAt, "stale-hash", [change], CancellationToken.None);

        _settingsContainer.Verify(
            c => c.UpsertItemAsync(
                It.Is<UserSettings>(s => s.SubscriptionManualOrder != null && s.SubscriptionManualOrder.SequenceEqual(new[] { "show-x", "show-y" })),
                It.IsAny<PartitionKey?>(), null, default),
            Times.Once);
    }

    [Fact]
    public async Task SyncAsync_AppliesNonEmptyManualOrderFromChange()
    {
        var lastSyncedAt = DateTimeOffset.UtcNow.AddHours(-2);
        var stored = new UserSettings(
            UserId, UnlistenedEpisodeCount.Five, Version: 3, UpdatedAt: DateTimeOffset.UtcNow.AddHours(-1),
            SubscriptionManualOrder: ["show-x"]);
        _settingsContainer
            .Setup(c => c.ReadItemAsync<UserSettings>(UserId, It.IsAny<PartitionKey>(), null, default))
            .ReturnsAsync(CosmosTestHelpers.ItemResponse(stored));
        _settingsContainer
            .Setup(c => c.UpsertItemAsync(It.IsAny<UserSettings>(), It.IsAny<PartitionKey?>(), It.IsAny<ItemRequestOptions>(), default))
            .ReturnsAsync((UserSettings s, PartitionKey? _, ItemRequestOptions? _, CancellationToken _) => CosmosTestHelpers.ItemResponse(s));

        var change = MakeChange(DateTimeOffset.UtcNow, subscriptionManualOrder: ["show-y", "show-z"]);
        await _sut.SyncAsync(UserId, "device-a", lastSyncedAt, "stale-hash", [change], CancellationToken.None);

        _settingsContainer.Verify(
            c => c.UpsertItemAsync(
                It.Is<UserSettings>(s => s.SubscriptionManualOrder != null && s.SubscriptionManualOrder.SequenceEqual(new[] { "show-y", "show-z" })),
                It.IsAny<PartitionKey?>(), null, default),
            Times.Once);
    }

    [Fact]
    public async Task SyncAsync_KeepsStoredManualOrderWhenChangeSendsAnEmptyList()
    {
        var lastSyncedAt = DateTimeOffset.UtcNow.AddHours(-2);
        var stored = new UserSettings(
            UserId, UnlistenedEpisodeCount.Five, Version: 3, UpdatedAt: DateTimeOffset.UtcNow.AddHours(-1),
            SubscriptionManualOrder: ["show-x", "show-w"]);
        _settingsContainer
            .Setup(c => c.ReadItemAsync<UserSettings>(UserId, It.IsAny<PartitionKey>(), null, default))
            .ReturnsAsync(CosmosTestHelpers.ItemResponse(stored));
        _settingsContainer
            .Setup(c => c.UpsertItemAsync(It.IsAny<UserSettings>(), It.IsAny<PartitionKey?>(), It.IsAny<ItemRequestOptions>(), default))
            .ReturnsAsync((UserSettings s, PartitionKey? _, ItemRequestOptions? _, CancellationToken _) => CosmosTestHelpers.ItemResponse(s));

        // A device with no local arrangement (iOS DTO can only send [] here, never null) must
        // not wipe the order saved from another device.
        var change = MakeChange(DateTimeOffset.UtcNow, subscriptionManualOrder: []);
        await _sut.SyncAsync(UserId, "device-a", lastSyncedAt, "stale-hash", [change], CancellationToken.None);

        _settingsContainer.Verify(
            c => c.UpsertItemAsync(
                It.Is<UserSettings>(s => s.SubscriptionManualOrder != null && s.SubscriptionManualOrder.SequenceEqual(new[] { "show-x", "show-w" })),
                It.IsAny<PartitionKey?>(), null, default),
            Times.Once);
    }

    [Fact]
    public async Task SyncAsync_AppliesSubscriptionSortOrderFromChange()
    {
        var lastSyncedAt = DateTimeOffset.UtcNow.AddHours(-2);
        var stored = new UserSettings(
            UserId, UnlistenedEpisodeCount.Five, Version: 3, UpdatedAt: DateTimeOffset.UtcNow.AddHours(-1));
        _settingsContainer
            .Setup(c => c.ReadItemAsync<UserSettings>(UserId, It.IsAny<PartitionKey>(), null, default))
            .ReturnsAsync(CosmosTestHelpers.ItemResponse(stored));
        _settingsContainer
            .Setup(c => c.UpsertItemAsync(It.IsAny<UserSettings>(), It.IsAny<PartitionKey?>(), It.IsAny<ItemRequestOptions>(), default))
            .ReturnsAsync((UserSettings s, PartitionKey? _, ItemRequestOptions? _, CancellationToken _) => CosmosTestHelpers.ItemResponse(s));

        var change = MakeChange(DateTimeOffset.UtcNow, subscriptionSortOrder: SubscriptionSortOrder.Manual);
        await _sut.SyncAsync(UserId, "device-a", lastSyncedAt, "stale-hash", [change], CancellationToken.None);

        _settingsContainer.Verify(
            c => c.UpsertItemAsync(
                It.Is<UserSettings>(s => s.SubscriptionSortOrder == SubscriptionSortOrder.Manual),
                It.IsAny<PartitionKey?>(), null, default),
            Times.Once);
    }

    [Fact]
    public async Task UpdateHideCaughtUpShowsAsync_PersistsValueAndBumpsVersion()
    {
        var existing = new UserSettings(UserId, UnlistenedEpisodeCount.Five, Version: 3);
        _settingsContainer
            .Setup(c => c.ReadItemAsync<UserSettings>(UserId, It.IsAny<PartitionKey>(), null, default))
            .ReturnsAsync(CosmosTestHelpers.ItemResponse(existing));
        _settingsContainer
            .Setup(c => c.UpsertItemAsync(It.IsAny<UserSettings>(), It.IsAny<PartitionKey?>(), It.IsAny<ItemRequestOptions>(), default))
            .ReturnsAsync((UserSettings s, PartitionKey? _, ItemRequestOptions? _, CancellationToken _) => CosmosTestHelpers.ItemResponse(s));

        var result = await _sut.UpdateHideCaughtUpShowsAsync(UserId, true, CancellationToken.None);

        Assert.True(result.HideCaughtUpShows);
        Assert.Equal(4, result.Version);
    }

    [Fact]
    public async Task UpdateLeadingSwipeActionsAsync_PersistsValueAndBumpsVersion()
    {
        var existing = new UserSettings(UserId, UnlistenedEpisodeCount.Five, Version: 3);
        _settingsContainer
            .Setup(c => c.ReadItemAsync<UserSettings>(UserId, It.IsAny<PartitionKey>(), null, default))
            .ReturnsAsync(CosmosTestHelpers.ItemResponse(existing));
        _settingsContainer
            .Setup(c => c.UpsertItemAsync(It.IsAny<UserSettings>(), It.IsAny<PartitionKey?>(), It.IsAny<ItemRequestOptions>(), default))
            .ReturnsAsync((UserSettings s, PartitionKey? _, ItemRequestOptions? _, CancellationToken _) => CosmosTestHelpers.ItemResponse(s));

        var result = await _sut.UpdateLeadingSwipeActionsAsync(
            UserId, [EpisodeSwipeAction.Download], CancellationToken.None);

        Assert.Equal([EpisodeSwipeAction.Download], result.LeadingSwipeActions);
        Assert.Equal(4, result.Version);
    }

    [Fact]
    public async Task UpdateTrailingSwipeActionsAsync_PersistsValueAndBumpsVersion()
    {
        var existing = new UserSettings(UserId, UnlistenedEpisodeCount.Five, Version: 3);
        _settingsContainer
            .Setup(c => c.ReadItemAsync<UserSettings>(UserId, It.IsAny<PartitionKey>(), null, default))
            .ReturnsAsync(CosmosTestHelpers.ItemResponse(existing));
        _settingsContainer
            .Setup(c => c.UpsertItemAsync(It.IsAny<UserSettings>(), It.IsAny<PartitionKey?>(), It.IsAny<ItemRequestOptions>(), default))
            .ReturnsAsync((UserSettings s, PartitionKey? _, ItemRequestOptions? _, CancellationToken _) => CosmosTestHelpers.ItemResponse(s));

        var result = await _sut.UpdateTrailingSwipeActionsAsync(
            UserId, [EpisodeSwipeAction.MarkPlayed, EpisodeSwipeAction.AddToUpNext], CancellationToken.None);

        Assert.Equal([EpisodeSwipeAction.MarkPlayed, EpisodeSwipeAction.AddToUpNext], result.TrailingSwipeActions);
        Assert.Equal(4, result.Version);
    }

    [Fact]
    public async Task SyncAsync_PreservesStoredSwipeActionsWhenChangeOmitsThem()
    {
        var lastSyncedAt = DateTimeOffset.UtcNow.AddHours(-2);
        var stored = new UserSettings(
            UserId, UnlistenedEpisodeCount.Five, Version: 3, UpdatedAt: DateTimeOffset.UtcNow.AddHours(-1),
            LeadingSwipeActions: [EpisodeSwipeAction.Download], TrailingSwipeActions: [EpisodeSwipeAction.MarkPlayed]);
        _settingsContainer
            .Setup(c => c.ReadItemAsync<UserSettings>(UserId, It.IsAny<PartitionKey>(), null, default))
            .ReturnsAsync(CosmosTestHelpers.ItemResponse(stored));
        _settingsContainer
            .Setup(c => c.UpsertItemAsync(It.IsAny<UserSettings>(), It.IsAny<PartitionKey?>(), It.IsAny<ItemRequestOptions>(), default))
            .ReturnsAsync((UserSettings s, PartitionKey? _, ItemRequestOptions? _, CancellationToken _) => CosmosTestHelpers.ItemResponse(s));

        var change = MakeChange(DateTimeOffset.UtcNow);
        await _sut.SyncAsync(UserId, "device-a", lastSyncedAt, "stale-hash", [change], CancellationToken.None);

        _settingsContainer.Verify(
            c => c.UpsertItemAsync(
                It.Is<UserSettings>(s =>
                    s.LeadingSwipeActions!.SequenceEqual(new[] { EpisodeSwipeAction.Download }) &&
                    s.TrailingSwipeActions!.SequenceEqual(new[] { EpisodeSwipeAction.MarkPlayed })),
                It.IsAny<PartitionKey?>(), null, default),
            Times.Once);
    }

    [Fact]
    public async Task SyncAsync_AppliesExplicitEmptyLeadingSwipeActionsFromChange()
    {
        // Unlike SubscriptionManualOrder (SyncAsync_KeepsStoredManualOrderWhenChangeSendsAnEmptyList
        // above), a change that explicitly sends [] for swipe actions is a deliberate "no actions
        // on this side" and must be allowed to clear a non-empty stored value (#571) — only a
        // genuinely omitted (null) field falls back to what's stored, per
        // SyncAsync_PreservesStoredSwipeActionsWhenChangeOmitsThem above.
        var lastSyncedAt = DateTimeOffset.UtcNow.AddHours(-2);
        var stored = new UserSettings(
            UserId, UnlistenedEpisodeCount.Five, Version: 3, UpdatedAt: DateTimeOffset.UtcNow.AddHours(-1),
            LeadingSwipeActions: [EpisodeSwipeAction.Download], TrailingSwipeActions: [EpisodeSwipeAction.MarkPlayed]);
        _settingsContainer
            .Setup(c => c.ReadItemAsync<UserSettings>(UserId, It.IsAny<PartitionKey>(), null, default))
            .ReturnsAsync(CosmosTestHelpers.ItemResponse(stored));
        _settingsContainer
            .Setup(c => c.UpsertItemAsync(It.IsAny<UserSettings>(), It.IsAny<PartitionKey?>(), It.IsAny<ItemRequestOptions>(), default))
            .ReturnsAsync((UserSettings s, PartitionKey? _, ItemRequestOptions? _, CancellationToken _) => CosmosTestHelpers.ItemResponse(s));

        var change = MakeChange(DateTimeOffset.UtcNow, leadingSwipeActions: [], trailingSwipeActions: [EpisodeSwipeAction.AddToUpNext]);
        await _sut.SyncAsync(UserId, "device-a", lastSyncedAt, "stale-hash", [change], CancellationToken.None);

        _settingsContainer.Verify(
            c => c.UpsertItemAsync(
                It.Is<UserSettings>(s =>
                    s.LeadingSwipeActions!.Count == 0 &&
                    s.TrailingSwipeActions!.SequenceEqual(new[] { EpisodeSwipeAction.AddToUpNext })),
                It.IsAny<PartitionKey?>(), null, default),
            Times.Once);
    }

    [Fact]
    public async Task SyncAsync_PreservesStoredHideCaughtUpShowsWhenChangeOmitsIt()
    {
        var lastSyncedAt = DateTimeOffset.UtcNow.AddHours(-2);
        var stored = new UserSettings(
            UserId, UnlistenedEpisodeCount.Five, Version: 3, UpdatedAt: DateTimeOffset.UtcNow.AddHours(-1),
            HideCaughtUpShows: true);
        _settingsContainer
            .Setup(c => c.ReadItemAsync<UserSettings>(UserId, It.IsAny<PartitionKey>(), null, default))
            .ReturnsAsync(CosmosTestHelpers.ItemResponse(stored));
        _settingsContainer
            .Setup(c => c.UpsertItemAsync(It.IsAny<UserSettings>(), It.IsAny<PartitionKey?>(), It.IsAny<ItemRequestOptions>(), default))
            .ReturnsAsync((UserSettings s, PartitionKey? _, ItemRequestOptions? _, CancellationToken _) => CosmosTestHelpers.ItemResponse(s));

        // Older client that doesn't send the field yet — null must not turn the setting off.
        var change = MakeChange(DateTimeOffset.UtcNow, hideCaughtUpShows: null);
        await _sut.SyncAsync(UserId, "device-a", lastSyncedAt, "stale-hash", [change], CancellationToken.None);

        _settingsContainer.Verify(
            c => c.UpsertItemAsync(
                It.Is<UserSettings>(s => s.HideCaughtUpShows),
                It.IsAny<PartitionKey?>(), null, default),
            Times.Once);
    }

    [Fact]
    public async Task SyncAsync_AppliesHideCaughtUpShowsFromChange()
    {
        var lastSyncedAt = DateTimeOffset.UtcNow.AddHours(-2);
        var stored = new UserSettings(
            UserId, UnlistenedEpisodeCount.Five, Version: 3, UpdatedAt: DateTimeOffset.UtcNow.AddHours(-1));
        _settingsContainer
            .Setup(c => c.ReadItemAsync<UserSettings>(UserId, It.IsAny<PartitionKey>(), null, default))
            .ReturnsAsync(CosmosTestHelpers.ItemResponse(stored));
        _settingsContainer
            .Setup(c => c.UpsertItemAsync(It.IsAny<UserSettings>(), It.IsAny<PartitionKey?>(), It.IsAny<ItemRequestOptions>(), default))
            .ReturnsAsync((UserSettings s, PartitionKey? _, ItemRequestOptions? _, CancellationToken _) => CosmosTestHelpers.ItemResponse(s));

        var change = MakeChange(DateTimeOffset.UtcNow, hideCaughtUpShows: true);
        await _sut.SyncAsync(UserId, "device-a", lastSyncedAt, "stale-hash", [change], CancellationToken.None);

        _settingsContainer.Verify(
            c => c.UpsertItemAsync(
                It.Is<UserSettings>(s => s.HideCaughtUpShows),
                It.IsAny<PartitionKey?>(), null, default),
            Times.Once);
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

        // Same rationale as GetSettingsAsync_ReturnsDefaultWhenNoDocumentExists above.
        var expected = ShowSettings.CreateDefault(UserId, showId);
        Assert.Equal(expected with { UpdatedAt = result.UpdatedAt }, result);
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
            .Setup(c => c.UpsertItemAsync(It.IsAny<UserSettings>(), It.IsAny<PartitionKey?>(), It.IsAny<ItemRequestOptions>(), default))
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

    [Fact]
    public async Task UpdateShowAutoDeleteRuleAsync_SetsOverrideAndIncrementsVersion()
    {
        const string showId = "show-1";
        var id = ShowSettings.BuildId(UserId, showId);
        var existing = new ShowSettings(id, UserId, showId, null, Version: 2);
        _settingsContainer
            .Setup(c => c.ReadItemAsync<ShowSettings>(id, It.IsAny<PartitionKey>(), null, default))
            .ReturnsAsync(CosmosTestHelpers.ItemResponse(existing));
        _settingsContainer
            .Setup(c => c.UpsertItemAsync(It.IsAny<ShowSettings>(), It.IsAny<PartitionKey?>(), null, default))
            .ReturnsAsync((ShowSettings s, PartitionKey? _, ItemRequestOptions? _, CancellationToken _) => CosmosTestHelpers.ItemResponse(s));

        var result = await _sut.UpdateShowAutoDeleteRuleAsync(UserId, showId, AutoDeleteRule.AfterDays, 14, CancellationToken.None);

        Assert.Equal(AutoDeleteRule.AfterDays, result.AutoDeleteRule);
        Assert.Equal(14, result.AutoDeleteAfterDays);
        Assert.Equal(3, result.Version);
    }

    [Fact]
    public async Task UpdateShowAutoDeleteRuleAsync_ClearsOverrideWhenValuesAreNull()
    {
        const string showId = "show-1";
        var id = ShowSettings.BuildId(UserId, showId);
        var existing = new ShowSettings(
            id, UserId, showId, null, Version: 4, AutoDeleteRule: AutoDeleteRule.AfterDays, AutoDeleteAfterDays: 30);
        _settingsContainer
            .Setup(c => c.ReadItemAsync<ShowSettings>(id, It.IsAny<PartitionKey>(), null, default))
            .ReturnsAsync(CosmosTestHelpers.ItemResponse(existing));
        _settingsContainer
            .Setup(c => c.UpsertItemAsync(It.IsAny<ShowSettings>(), It.IsAny<PartitionKey?>(), null, default))
            .ReturnsAsync((ShowSettings s, PartitionKey? _, ItemRequestOptions? _, CancellationToken _) => CosmosTestHelpers.ItemResponse(s));

        var result = await _sut.UpdateShowAutoDeleteRuleAsync(UserId, showId, null, null, CancellationToken.None);

        Assert.Null(result.AutoDeleteRule);
        Assert.Null(result.AutoDeleteAfterDays);
        Assert.Equal(5, result.Version);
    }

    [Fact]
    public async Task GetEffectiveAutoDeleteRuleAsync_ReturnsShowOverrideWhenBothFieldsSet()
    {
        const string showId = "show-1";
        var showSettingsId = ShowSettings.BuildId(UserId, showId);
        var showSettings = new ShowSettings(
            showSettingsId, UserId, showId, null, Version: 2, AutoDeleteRule: AutoDeleteRule.AfterDays, AutoDeleteAfterDays: 3);
        _settingsContainer
            .Setup(c => c.ReadItemAsync<ShowSettings>(showSettingsId, It.IsAny<PartitionKey>(), null, default))
            .ReturnsAsync(CosmosTestHelpers.ItemResponse(showSettings));

        var result = await _sut.GetEffectiveAutoDeleteRuleAsync(UserId, showId, CancellationToken.None);

        Assert.Equal((AutoDeleteRule.AfterDays, 3), result);
        _settingsContainer.Verify(
            c => c.ReadItemAsync<UserSettings>(It.IsAny<string>(), It.IsAny<PartitionKey>(), null, default), Times.Never);
    }

    [Fact]
    public async Task GetEffectiveAutoDeleteRuleAsync_FallsBackToUserSettingsPerField()
    {
        const string showId = "show-1";
        var showSettingsId = ShowSettings.BuildId(UserId, showId);
        // Rule overridden to AfterDays, but the day count inherits the global value.
        var showSettings = new ShowSettings(
            showSettingsId, UserId, showId, null, Version: 2, AutoDeleteRule: AutoDeleteRule.AfterDays);
        _settingsContainer
            .Setup(c => c.ReadItemAsync<ShowSettings>(showSettingsId, It.IsAny<PartitionKey>(), null, default))
            .ReturnsAsync(CosmosTestHelpers.ItemResponse(showSettings));
        var userSettings = new UserSettings(
            UserId, UnlistenedEpisodeCount.Five, Version: 1, AutoDeleteRule: AutoDeleteRule.Never, AutoDeleteAfterDays: 21);
        _settingsContainer
            .Setup(c => c.ReadItemAsync<UserSettings>(UserId, It.IsAny<PartitionKey>(), null, default))
            .ReturnsAsync(CosmosTestHelpers.ItemResponse(userSettings));

        var result = await _sut.GetEffectiveAutoDeleteRuleAsync(UserId, showId, CancellationToken.None);

        Assert.Equal((AutoDeleteRule.AfterDays, 21), result);
    }

    [Fact]
    public async Task UpdateAutoSkipAsync_IncrementsVersionOfExistingDocument()
    {
        var existing = new UserSettings(UserId, UnlistenedEpisodeCount.Five, Version: 3);
        _settingsContainer
            .Setup(c => c.ReadItemAsync<UserSettings>(UserId, It.IsAny<PartitionKey>(), null, default))
            .ReturnsAsync(CosmosTestHelpers.ItemResponse(existing));
        _settingsContainer
            .Setup(c => c.UpsertItemAsync(It.IsAny<UserSettings>(), It.IsAny<PartitionKey?>(), It.IsAny<ItemRequestOptions>(), default))
            .ReturnsAsync((UserSettings s, PartitionKey? _, ItemRequestOptions? _, CancellationToken _) => CosmosTestHelpers.ItemResponse(s));

        var result = await _sut.UpdateAutoSkipAsync(UserId, 15, 30, CancellationToken.None);

        Assert.Equal(15, result.AutoSkipIntroSeconds);
        Assert.Equal(30, result.AutoSkipOutroSeconds);
        Assert.Equal(4, result.Version);
    }

    [Fact]
    public async Task UpdateShowAutoSkipAsync_ClearsOverrideWhenValuesAreNull()
    {
        const string showId = "show-1";
        var id = ShowSettings.BuildId(UserId, showId);
        var existing = new ShowSettings(
            id, UserId, showId, UnlistenedEpisodeCount.Ten, Version: 2,
            AutoArchiveRule: null, AutoSkipIntroSeconds: 10, AutoSkipOutroSeconds: 20);
        _settingsContainer
            .Setup(c => c.ReadItemAsync<ShowSettings>(id, It.IsAny<PartitionKey>(), null, default))
            .ReturnsAsync(CosmosTestHelpers.ItemResponse(existing));
        _settingsContainer
            .Setup(c => c.UpsertItemAsync(It.IsAny<ShowSettings>(), It.IsAny<PartitionKey?>(), null, default))
            .ReturnsAsync((ShowSettings s, PartitionKey? _, ItemRequestOptions? _, CancellationToken _) => CosmosTestHelpers.ItemResponse(s));

        var result = await _sut.UpdateShowAutoSkipAsync(UserId, showId, null, null, CancellationToken.None);

        Assert.Null(result.AutoSkipIntroSeconds);
        Assert.Null(result.AutoSkipOutroSeconds);
        Assert.Equal(3, result.Version);
    }

    [Fact]
    public async Task GetEffectiveAutoSkipAsync_ReturnsShowOverrideWhenBothFieldsSetWithoutReadingUserSettings()
    {
        const string showId = "show-1";
        var showSettingsId = ShowSettings.BuildId(UserId, showId);
        var showSettings = new ShowSettings(
            showSettingsId, UserId, showId, null, Version: 2,
            AutoArchiveRule: null, AutoSkipIntroSeconds: 12, AutoSkipOutroSeconds: 25);
        _settingsContainer
            .Setup(c => c.ReadItemAsync<ShowSettings>(showSettingsId, It.IsAny<PartitionKey>(), null, default))
            .ReturnsAsync(CosmosTestHelpers.ItemResponse(showSettings));

        var result = await _sut.GetEffectiveAutoSkipAsync(UserId, showId, CancellationToken.None);

        Assert.Equal(12, result.IntroSeconds);
        Assert.Equal(25, result.OutroSeconds);
        _settingsContainer.Verify(
            c => c.ReadItemAsync<UserSettings>(It.IsAny<string>(), It.IsAny<PartitionKey>(), null, default), Times.Never);
    }

    [Fact]
    public async Task GetEffectiveAutoSkipAsync_FallsBackToUserSettingsPerFieldWhenNoOverride()
    {
        const string showId = "show-1";
        var showSettingsId = ShowSettings.BuildId(UserId, showId);
        // Only intro is overridden; outro should still fall back to the global default.
        var showSettings = new ShowSettings(
            showSettingsId, UserId, showId, null, Version: 2,
            AutoArchiveRule: null, AutoSkipIntroSeconds: 12, AutoSkipOutroSeconds: null);
        _settingsContainer
            .Setup(c => c.ReadItemAsync<ShowSettings>(showSettingsId, It.IsAny<PartitionKey>(), null, default))
            .ReturnsAsync(CosmosTestHelpers.ItemResponse(showSettings));
        var userSettings = new UserSettings(
            UserId, UnlistenedEpisodeCount.Five, Version: 1,
            AutoArchiveRule.Never, AutoSkipIntroSeconds: 5, AutoSkipOutroSeconds: 40);
        _settingsContainer
            .Setup(c => c.ReadItemAsync<UserSettings>(UserId, It.IsAny<PartitionKey>(), null, default))
            .ReturnsAsync(CosmosTestHelpers.ItemResponse(userSettings));

        var result = await _sut.GetEffectiveAutoSkipAsync(UserId, showId, CancellationToken.None);

        Assert.Equal(12, result.IntroSeconds);
        Assert.Equal(40, result.OutroSeconds);
    }

    [Fact]
    public async Task UpdatePlaybackSpeedAsync_IncrementsVersionOfExistingDocument()
    {
        var existing = new UserSettings(UserId, UnlistenedEpisodeCount.Five, Version: 3);
        _settingsContainer
            .Setup(c => c.ReadItemAsync<UserSettings>(UserId, It.IsAny<PartitionKey>(), null, default))
            .ReturnsAsync(CosmosTestHelpers.ItemResponse(existing));
        _settingsContainer
            .Setup(c => c.UpsertItemAsync(It.IsAny<UserSettings>(), It.IsAny<PartitionKey?>(), It.IsAny<ItemRequestOptions>(), default))
            .ReturnsAsync((UserSettings s, PartitionKey? _, ItemRequestOptions? _, CancellationToken _) => CosmosTestHelpers.ItemResponse(s));

        var result = await _sut.UpdatePlaybackSpeedAsync(UserId, 1.5f, CancellationToken.None);

        Assert.Equal(1.5f, result.PlaybackSpeed);
        Assert.Equal(4, result.Version);
    }

    [Fact]
    public async Task UpdateShowPlaybackSpeedAsync_ClearsOverrideWhenValueIsNull()
    {
        const string showId = "show-1";
        var id = ShowSettings.BuildId(UserId, showId);
        var existing = new ShowSettings(
            id, UserId, showId, UnlistenedEpisodeCount.Ten, Version: 2,
            AutoArchiveRule: null, AutoSkipIntroSeconds: null, AutoSkipOutroSeconds: null, PlaybackSpeed: 2.0f);
        _settingsContainer
            .Setup(c => c.ReadItemAsync<ShowSettings>(id, It.IsAny<PartitionKey>(), null, default))
            .ReturnsAsync(CosmosTestHelpers.ItemResponse(existing));
        _settingsContainer
            .Setup(c => c.UpsertItemAsync(It.IsAny<ShowSettings>(), It.IsAny<PartitionKey?>(), null, default))
            .ReturnsAsync((ShowSettings s, PartitionKey? _, ItemRequestOptions? _, CancellationToken _) => CosmosTestHelpers.ItemResponse(s));

        var result = await _sut.UpdateShowPlaybackSpeedAsync(UserId, showId, null, CancellationToken.None);

        Assert.Null(result.PlaybackSpeed);
        Assert.Equal(3, result.Version);
    }

    [Fact]
    public async Task GetEffectivePlaybackSpeedAsync_ReturnsShowOverrideWhenSet()
    {
        const string showId = "show-1";
        var showSettingsId = ShowSettings.BuildId(UserId, showId);
        var showSettings = new ShowSettings(
            showSettingsId, UserId, showId, null, Version: 2,
            AutoArchiveRule: null, AutoSkipIntroSeconds: null, AutoSkipOutroSeconds: null, PlaybackSpeed: 1.75f);
        _settingsContainer
            .Setup(c => c.ReadItemAsync<ShowSettings>(showSettingsId, It.IsAny<PartitionKey>(), null, default))
            .ReturnsAsync(CosmosTestHelpers.ItemResponse(showSettings));

        var result = await _sut.GetEffectivePlaybackSpeedAsync(UserId, showId, CancellationToken.None);

        Assert.Equal(1.75f, result);
        _settingsContainer.Verify(
            c => c.ReadItemAsync<UserSettings>(It.IsAny<string>(), It.IsAny<PartitionKey>(), null, default), Times.Never);
    }

    [Fact]
    public async Task GetEffectivePlaybackSpeedAsync_FallsBackToUserSettingsWhenNoOverride()
    {
        const string showId = "show-1";
        var showSettingsId = ShowSettings.BuildId(UserId, showId);
        _settingsContainer
            .Setup(c => c.ReadItemAsync<ShowSettings>(showSettingsId, It.IsAny<PartitionKey>(), null, default))
            .ThrowsAsync(CosmosTestHelpers.NotFound());
        var userSettings = new UserSettings(
            UserId, UnlistenedEpisodeCount.Five, Version: 1,
            AutoArchiveRule.Never, AutoSkipIntroSeconds: 0, AutoSkipOutroSeconds: 0, PlaybackSpeed: 1.25f);
        _settingsContainer
            .Setup(c => c.ReadItemAsync<UserSettings>(UserId, It.IsAny<PartitionKey>(), null, default))
            .ReturnsAsync(CosmosTestHelpers.ItemResponse(userSettings));

        var result = await _sut.GetEffectivePlaybackSpeedAsync(UserId, showId, CancellationToken.None);

        Assert.Equal(1.25f, result);
    }

    [Fact]
    public async Task UpdateAutoDeleteRuleAsync_IncrementsVersionOfExistingDocument()
    {
        var existing = new UserSettings(
            UserId, UnlistenedEpisodeCount.Five, Version: 3,
            AutoArchiveRule.Never, AutoDeleteRule: AutoDeleteRule.Never);
        _settingsContainer
            .Setup(c => c.ReadItemAsync<UserSettings>(UserId, It.IsAny<PartitionKey>(), null, default))
            .ReturnsAsync(CosmosTestHelpers.ItemResponse(existing));
        _settingsContainer
            .Setup(c => c.UpsertItemAsync(It.IsAny<UserSettings>(), It.IsAny<PartitionKey?>(), It.IsAny<ItemRequestOptions>(), default))
            .ReturnsAsync((UserSettings s, PartitionKey? _, ItemRequestOptions? _, CancellationToken _) => CosmosTestHelpers.ItemResponse(s));

        var result = await _sut.UpdateAutoDeleteRuleAsync(UserId, AutoDeleteRule.AfterPlayed, 14, CancellationToken.None);

        Assert.Equal(AutoDeleteRule.AfterPlayed, result.AutoDeleteRule);
        Assert.Equal(14, result.AutoDeleteAfterDays);
        Assert.Equal(4, result.Version);
    }

    [Fact]
    public async Task UpdateAutoDownloadNewEpisodesAsync_IncrementsVersionOfExistingDocument()
    {
        var existing = new UserSettings(
            UserId, UnlistenedEpisodeCount.Five, Version: 3,
            AutoArchiveRule.Never, AutoDownloadNewEpisodes: false);
        _settingsContainer
            .Setup(c => c.ReadItemAsync<UserSettings>(UserId, It.IsAny<PartitionKey>(), null, default))
            .ReturnsAsync(CosmosTestHelpers.ItemResponse(existing));
        _settingsContainer
            .Setup(c => c.UpsertItemAsync(It.IsAny<UserSettings>(), It.IsAny<PartitionKey?>(), It.IsAny<ItemRequestOptions>(), default))
            .ReturnsAsync((UserSettings s, PartitionKey? _, ItemRequestOptions? _, CancellationToken _) => CosmosTestHelpers.ItemResponse(s));

        var result = await _sut.UpdateAutoDownloadNewEpisodesAsync(UserId, true, CancellationToken.None);

        Assert.True(result.AutoDownloadNewEpisodes);
        Assert.Equal(4, result.Version);
    }

    [Fact]
    public async Task UpdateShowAutoDownloadNewEpisodesAsync_ClearsOverrideWhenValueIsNull()
    {
        const string showId = "show-1";
        var id = ShowSettings.BuildId(UserId, showId);
        var existing = new ShowSettings(id, UserId, showId, UnlistenedEpisodeCount.Ten, Version: 2, AutoDownloadNewEpisodes: true);
        _settingsContainer
            .Setup(c => c.ReadItemAsync<ShowSettings>(id, It.IsAny<PartitionKey>(), null, default))
            .ReturnsAsync(CosmosTestHelpers.ItemResponse(existing));
        _settingsContainer
            .Setup(c => c.UpsertItemAsync(It.IsAny<ShowSettings>(), It.IsAny<PartitionKey?>(), null, default))
            .ReturnsAsync((ShowSettings s, PartitionKey? _, ItemRequestOptions? _, CancellationToken _) => CosmosTestHelpers.ItemResponse(s));

        var result = await _sut.UpdateShowAutoDownloadNewEpisodesAsync(UserId, showId, null, CancellationToken.None);

        Assert.Null(result.AutoDownloadNewEpisodes);
    }

    [Fact]
    public async Task GetEffectiveAutoDownloadNewEpisodesAsync_ReturnsShowOverrideWhenSet()
    {
        const string showId = "show-1";
        var showSettingsId = ShowSettings.BuildId(UserId, showId);
        var showSettings = new ShowSettings(showSettingsId, UserId, showId, null, Version: 2, AutoDownloadNewEpisodes: true);
        _settingsContainer
            .Setup(c => c.ReadItemAsync<ShowSettings>(showSettingsId, It.IsAny<PartitionKey>(), null, default))
            .ReturnsAsync(CosmosTestHelpers.ItemResponse(showSettings));

        var result = await _sut.GetEffectiveAutoDownloadNewEpisodesAsync(UserId, showId, CancellationToken.None);

        Assert.True(result);
        _settingsContainer.Verify(
            c => c.ReadItemAsync<UserSettings>(It.IsAny<string>(), It.IsAny<PartitionKey>(), null, default), Times.Never);
    }

    [Fact]
    public async Task GetEffectiveAutoDownloadNewEpisodesAsync_FallsBackToUserSettingsWhenNoOverride()
    {
        const string showId = "show-1";
        var showSettingsId = ShowSettings.BuildId(UserId, showId);
        _settingsContainer
            .Setup(c => c.ReadItemAsync<ShowSettings>(showSettingsId, It.IsAny<PartitionKey>(), null, default))
            .ThrowsAsync(CosmosTestHelpers.NotFound());
        var userSettings = new UserSettings(
            UserId, UnlistenedEpisodeCount.Five, Version: 1, AutoArchiveRule.Never, AutoDownloadNewEpisodes: true);
        _settingsContainer
            .Setup(c => c.ReadItemAsync<UserSettings>(UserId, It.IsAny<PartitionKey>(), null, default))
            .ReturnsAsync(CosmosTestHelpers.ItemResponse(userSettings));

        var result = await _sut.GetEffectiveAutoDownloadNewEpisodesAsync(UserId, showId, CancellationToken.None);

        Assert.True(result);
    }

    [Fact]
    public async Task UpdateAutoAddNewEpisodesToUpNextAsync_IncrementsVersionOfExistingDocument()
    {
        var existing = new UserSettings(
            UserId, UnlistenedEpisodeCount.Five, Version: 3,
            AutoArchiveRule.Never, AutoAddNewEpisodesToUpNext: false);
        _settingsContainer
            .Setup(c => c.ReadItemAsync<UserSettings>(UserId, It.IsAny<PartitionKey>(), null, default))
            .ReturnsAsync(CosmosTestHelpers.ItemResponse(existing));
        _settingsContainer
            .Setup(c => c.UpsertItemAsync(It.IsAny<UserSettings>(), It.IsAny<PartitionKey?>(), It.IsAny<ItemRequestOptions>(), default))
            .ReturnsAsync((UserSettings s, PartitionKey? _, ItemRequestOptions? _, CancellationToken _) => CosmosTestHelpers.ItemResponse(s));

        var result = await _sut.UpdateAutoAddNewEpisodesToUpNextAsync(UserId, true, CancellationToken.None);

        Assert.True(result.AutoAddNewEpisodesToUpNext);
        Assert.Equal(4, result.Version);
    }

    [Fact]
    public async Task UpdateUpNextInsertPositionAsync_UpdatesValueAndIncrementsVersion()
    {
        var existing = new UserSettings(
            UserId, UnlistenedEpisodeCount.Five, Version: 3, AutoArchiveRule.Never);
        _settingsContainer
            .Setup(c => c.ReadItemAsync<UserSettings>(UserId, It.IsAny<PartitionKey>(), null, default))
            .ReturnsAsync(CosmosTestHelpers.ItemResponse(existing));
        _settingsContainer
            .Setup(c => c.UpsertItemAsync(It.IsAny<UserSettings>(), It.IsAny<PartitionKey?>(), It.IsAny<ItemRequestOptions>(), default))
            .ReturnsAsync((UserSettings s, PartitionKey? _, ItemRequestOptions? _, CancellationToken _) => CosmosTestHelpers.ItemResponse(s));

        var result = await _sut.UpdateUpNextInsertPositionAsync(UserId, UpNextInsertPosition.Top, CancellationToken.None);

        Assert.Equal(UpNextInsertPosition.Top, result.UpNextInsertPosition);
        Assert.Equal(4, result.Version);
    }

    [Fact]
    public async Task UpdateShowAutoAddNewEpisodesToUpNextAsync_ClearsOverrideWhenValueIsNull()
    {
        const string showId = "show-1";
        var id = ShowSettings.BuildId(UserId, showId);
        var existing = new ShowSettings(id, UserId, showId, UnlistenedEpisodeCount.Ten, Version: 2, AutoAddNewEpisodesToUpNext: true);
        _settingsContainer
            .Setup(c => c.ReadItemAsync<ShowSettings>(id, It.IsAny<PartitionKey>(), null, default))
            .ReturnsAsync(CosmosTestHelpers.ItemResponse(existing));
        _settingsContainer
            .Setup(c => c.UpsertItemAsync(It.IsAny<ShowSettings>(), It.IsAny<PartitionKey?>(), null, default))
            .ReturnsAsync((ShowSettings s, PartitionKey? _, ItemRequestOptions? _, CancellationToken _) => CosmosTestHelpers.ItemResponse(s));

        var result = await _sut.UpdateShowAutoAddNewEpisodesToUpNextAsync(UserId, showId, null, CancellationToken.None);

        Assert.Null(result.AutoAddNewEpisodesToUpNext);
    }

    [Fact]
    public async Task GetEffectiveAutoAddNewEpisodesToUpNextAsync_ReturnsShowOverrideWhenSet()
    {
        const string showId = "show-1";
        var showSettingsId = ShowSettings.BuildId(UserId, showId);
        var showSettings = new ShowSettings(showSettingsId, UserId, showId, null, Version: 2, AutoAddNewEpisodesToUpNext: true);
        _settingsContainer
            .Setup(c => c.ReadItemAsync<ShowSettings>(showSettingsId, It.IsAny<PartitionKey>(), null, default))
            .ReturnsAsync(CosmosTestHelpers.ItemResponse(showSettings));

        var result = await _sut.GetEffectiveAutoAddNewEpisodesToUpNextAsync(UserId, showId, CancellationToken.None);

        Assert.True(result);
        _settingsContainer.Verify(
            c => c.ReadItemAsync<UserSettings>(It.IsAny<string>(), It.IsAny<PartitionKey>(), null, default), Times.Never);
    }

    [Fact]
    public async Task GetEffectiveAutoAddNewEpisodesToUpNextAsync_FallsBackToUserSettingsWhenNoOverride()
    {
        const string showId = "show-1";
        var showSettingsId = ShowSettings.BuildId(UserId, showId);
        _settingsContainer
            .Setup(c => c.ReadItemAsync<ShowSettings>(showSettingsId, It.IsAny<PartitionKey>(), null, default))
            .ThrowsAsync(CosmosTestHelpers.NotFound());
        var userSettings = new UserSettings(
            UserId, UnlistenedEpisodeCount.Five, Version: 1, AutoArchiveRule.Never, AutoAddNewEpisodesToUpNext: true);
        _settingsContainer
            .Setup(c => c.ReadItemAsync<UserSettings>(UserId, It.IsAny<PartitionKey>(), null, default))
            .ReturnsAsync(CosmosTestHelpers.ItemResponse(userSettings));

        var result = await _sut.GetEffectiveAutoAddNewEpisodesToUpNextAsync(UserId, showId, CancellationToken.None);

        Assert.True(result);
    }

    [Fact]
    public async Task UpdateShowUpNextInsertPositionAsync_SetsOverrideAndIncrementsVersion()
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

        var result = await _sut.UpdateShowUpNextInsertPositionAsync(
            UserId, showId, UpNextInsertPosition.Top, CancellationToken.None);

        Assert.Equal(UpNextInsertPosition.Top, result.UpNextInsertPosition);
        Assert.Equal(3, result.Version);
    }

    [Fact]
    public async Task UpdateShowUpNextInsertPositionAsync_ClearsOverrideWhenValueIsNull()
    {
        const string showId = "show-1";
        var id = ShowSettings.BuildId(UserId, showId);
        var existing = new ShowSettings(
            id, UserId, showId, UnlistenedEpisodeCount.Ten, Version: 2, UpNextInsertPosition: UpNextInsertPosition.Top);
        _settingsContainer
            .Setup(c => c.ReadItemAsync<ShowSettings>(id, It.IsAny<PartitionKey>(), null, default))
            .ReturnsAsync(CosmosTestHelpers.ItemResponse(existing));
        _settingsContainer
            .Setup(c => c.UpsertItemAsync(It.IsAny<ShowSettings>(), It.IsAny<PartitionKey?>(), null, default))
            .ReturnsAsync((ShowSettings s, PartitionKey? _, ItemRequestOptions? _, CancellationToken _) => CosmosTestHelpers.ItemResponse(s));

        var result = await _sut.UpdateShowUpNextInsertPositionAsync(UserId, showId, null, CancellationToken.None);

        Assert.Null(result.UpNextInsertPosition);
    }

    [Fact]
    public async Task GetEffectiveUpNextInsertPositionAsync_ReturnsShowOverrideWhenSet()
    {
        const string showId = "show-1";
        var showSettingsId = ShowSettings.BuildId(UserId, showId);
        var showSettings = new ShowSettings(
            showSettingsId, UserId, showId, null, Version: 2, UpNextInsertPosition: UpNextInsertPosition.Top);
        _settingsContainer
            .Setup(c => c.ReadItemAsync<ShowSettings>(showSettingsId, It.IsAny<PartitionKey>(), null, default))
            .ReturnsAsync(CosmosTestHelpers.ItemResponse(showSettings));

        var result = await _sut.GetEffectiveUpNextInsertPositionAsync(UserId, showId, CancellationToken.None);

        Assert.Equal(UpNextInsertPosition.Top, result);
        _settingsContainer.Verify(
            c => c.ReadItemAsync<UserSettings>(It.IsAny<string>(), It.IsAny<PartitionKey>(), null, default), Times.Never);
    }

    [Fact]
    public async Task GetEffectiveUpNextInsertPositionAsync_FallsBackToUserSettingsWhenNoOverride()
    {
        const string showId = "show-1";
        var showSettingsId = ShowSettings.BuildId(UserId, showId);
        _settingsContainer
            .Setup(c => c.ReadItemAsync<ShowSettings>(showSettingsId, It.IsAny<PartitionKey>(), null, default))
            .ThrowsAsync(CosmosTestHelpers.NotFound());
        var userSettings = new UserSettings(
            UserId, UnlistenedEpisodeCount.Five, Version: 1, AutoArchiveRule.Never,
            UpNextInsertPosition: UpNextInsertPosition.Top);
        _settingsContainer
            .Setup(c => c.ReadItemAsync<UserSettings>(UserId, It.IsAny<PartitionKey>(), null, default))
            .ReturnsAsync(CosmosTestHelpers.ItemResponse(userSettings));

        var result = await _sut.GetEffectiveUpNextInsertPositionAsync(UserId, showId, CancellationToken.None);

        Assert.Equal(UpNextInsertPosition.Top, result);
    }

    [Fact]
    public async Task UpdateSmartSpeedAsync_IncrementsVersionOfExistingDocument()
    {
        var existing = new UserSettings(
            UserId, UnlistenedEpisodeCount.Five, Version: 3,
            AutoArchiveRule.Never, SmartSpeed: false);
        _settingsContainer
            .Setup(c => c.ReadItemAsync<UserSettings>(UserId, It.IsAny<PartitionKey>(), null, default))
            .ReturnsAsync(CosmosTestHelpers.ItemResponse(existing));
        _settingsContainer
            .Setup(c => c.UpsertItemAsync(It.IsAny<UserSettings>(), It.IsAny<PartitionKey?>(), It.IsAny<ItemRequestOptions>(), default))
            .ReturnsAsync((UserSettings s, PartitionKey? _, ItemRequestOptions? _, CancellationToken _) => CosmosTestHelpers.ItemResponse(s));

        var result = await _sut.UpdateSmartSpeedAsync(UserId, true, CancellationToken.None);

        Assert.True(result.SmartSpeed);
        Assert.Equal(4, result.Version);
    }

    [Fact]
    public async Task UpdateSmartSpeedAsync_RetriesOnStaleETagAndPreservesConcurrentFieldChange()
    {
        // Simulates two devices racing: our SmartSpeed update reads first (etag-1), but before
        // it can upsert, a concurrent AutoDownloadNewEpisodes write from another device lands and
        // moves the document to etag-2. Without the IfMatchEtag/retry loop, our upsert would
        // blindly overwrite using our stale read and silently discard that other device's change
        // (the lost-update scenario UserSettings.Version's doc comment used to call out). With it,
        // the PreconditionFailed on etag-1 forces a re-read, which picks up the concurrent change
        // and reapplies our SmartSpeed change on top of it instead of clobbering it.
        var staleRead = new UserSettings(
            UserId, UnlistenedEpisodeCount.Five, Version: 3, AutoArchiveRule.Never,
            SmartSpeed: false, AutoDownloadNewEpisodes: false);
        var concurrentlyWritten = staleRead with { AutoDownloadNewEpisodes = true, Version = 4 };

        _settingsContainer
            .SetupSequence(c => c.ReadItemAsync<UserSettings>(UserId, It.IsAny<PartitionKey>(), null, default))
            .ReturnsAsync(CosmosTestHelpers.ItemResponse(staleRead, etag: "etag-1"))
            .ReturnsAsync(CosmosTestHelpers.ItemResponse(concurrentlyWritten, etag: "etag-2"));

        _settingsContainer
            .Setup(c => c.UpsertItemAsync(
                It.IsAny<UserSettings>(), It.IsAny<PartitionKey?>(),
                It.Is<ItemRequestOptions>(o => o!.IfMatchEtag == "etag-1"), default))
            .ThrowsAsync(CosmosTestHelpers.PreconditionFailed());
        _settingsContainer
            .Setup(c => c.UpsertItemAsync(
                It.IsAny<UserSettings>(), It.IsAny<PartitionKey?>(),
                It.Is<ItemRequestOptions>(o => o!.IfMatchEtag == "etag-2"), default))
            .ReturnsAsync((UserSettings s, PartitionKey? _, ItemRequestOptions? _, CancellationToken _) => CosmosTestHelpers.ItemResponse(s));

        var result = await _sut.UpdateSmartSpeedAsync(UserId, true, CancellationToken.None);

        Assert.True(result.SmartSpeed);
        Assert.True(result.AutoDownloadNewEpisodes);
        Assert.Equal(5, result.Version);
        _settingsContainer.Verify(
            c => c.UpsertItemAsync(It.IsAny<UserSettings>(), It.IsAny<PartitionKey?>(), It.IsAny<ItemRequestOptions>(), default),
            Times.Exactly(2));
    }

    [Fact]
    public async Task UpdateSmartSpeedAsync_ThrowsAfterExhaustingRetriesOnPersistentETagConflict()
    {
        var current = new UserSettings(UserId, UnlistenedEpisodeCount.Five, Version: 3, AutoArchiveRule.Never, SmartSpeed: false);

        _settingsContainer
            .Setup(c => c.ReadItemAsync<UserSettings>(UserId, It.IsAny<PartitionKey>(), null, default))
            .ReturnsAsync(CosmosTestHelpers.ItemResponse(current, etag: "etag-always-stale"));
        _settingsContainer
            .Setup(c => c.UpsertItemAsync(It.IsAny<UserSettings>(), It.IsAny<PartitionKey?>(), It.IsAny<ItemRequestOptions>(), default))
            .ThrowsAsync(CosmosTestHelpers.PreconditionFailed());

        await Assert.ThrowsAsync<InvalidOperationException>(
            () => _sut.UpdateSmartSpeedAsync(UserId, true, CancellationToken.None));

        _settingsContainer.Verify(
            c => c.UpsertItemAsync(It.IsAny<UserSettings>(), It.IsAny<PartitionKey?>(), It.IsAny<ItemRequestOptions>(), default),
            Times.Exactly(5));
    }

    [Fact]
    public async Task UpdateShowSmartSpeedAsync_ClearsOverrideWhenValueIsNull()
    {
        const string showId = "show-1";
        var id = ShowSettings.BuildId(UserId, showId);
        var existing = new ShowSettings(id, UserId, showId, UnlistenedEpisodeCount.Ten, Version: 2, SmartSpeed: true);
        _settingsContainer
            .Setup(c => c.ReadItemAsync<ShowSettings>(id, It.IsAny<PartitionKey>(), null, default))
            .ReturnsAsync(CosmosTestHelpers.ItemResponse(existing));
        _settingsContainer
            .Setup(c => c.UpsertItemAsync(It.IsAny<ShowSettings>(), It.IsAny<PartitionKey?>(), null, default))
            .ReturnsAsync((ShowSettings s, PartitionKey? _, ItemRequestOptions? _, CancellationToken _) => CosmosTestHelpers.ItemResponse(s));

        var result = await _sut.UpdateShowSmartSpeedAsync(UserId, showId, null, CancellationToken.None);

        Assert.Null(result.SmartSpeed);
    }

    [Fact]
    public async Task GetEffectiveSmartSpeedAsync_ReturnsShowOverrideWhenSet()
    {
        const string showId = "show-1";
        var showSettingsId = ShowSettings.BuildId(UserId, showId);
        var showSettings = new ShowSettings(showSettingsId, UserId, showId, null, Version: 2, SmartSpeed: true);
        _settingsContainer
            .Setup(c => c.ReadItemAsync<ShowSettings>(showSettingsId, It.IsAny<PartitionKey>(), null, default))
            .ReturnsAsync(CosmosTestHelpers.ItemResponse(showSettings));

        var result = await _sut.GetEffectiveSmartSpeedAsync(UserId, showId, CancellationToken.None);

        Assert.True(result);
        _settingsContainer.Verify(
            c => c.ReadItemAsync<UserSettings>(It.IsAny<string>(), It.IsAny<PartitionKey>(), null, default), Times.Never);
    }

    [Fact]
    public async Task GetEffectiveSmartSpeedAsync_FallsBackToUserSettingsWhenNoOverride()
    {
        const string showId = "show-1";
        var showSettingsId = ShowSettings.BuildId(UserId, showId);
        _settingsContainer
            .Setup(c => c.ReadItemAsync<ShowSettings>(showSettingsId, It.IsAny<PartitionKey>(), null, default))
            .ThrowsAsync(CosmosTestHelpers.NotFound());
        var userSettings = new UserSettings(
            UserId, UnlistenedEpisodeCount.Five, Version: 1, AutoArchiveRule.Never, SmartSpeed: true);
        _settingsContainer
            .Setup(c => c.ReadItemAsync<UserSettings>(UserId, It.IsAny<PartitionKey>(), null, default))
            .ReturnsAsync(CosmosTestHelpers.ItemResponse(userSettings));

        var result = await _sut.GetEffectiveSmartSpeedAsync(UserId, showId, CancellationToken.None);

        Assert.True(result);
    }

    [Fact]
    public async Task UpdateNotificationsEnabledAsync_IncrementsVersionOfExistingDocument()
    {
        var existing = new UserSettings(
            UserId, UnlistenedEpisodeCount.Five, Version: 3,
            AutoArchiveRule.Never, NotificationsEnabled: true);
        _settingsContainer
            .Setup(c => c.ReadItemAsync<UserSettings>(UserId, It.IsAny<PartitionKey>(), null, default))
            .ReturnsAsync(CosmosTestHelpers.ItemResponse(existing));
        _settingsContainer
            .Setup(c => c.UpsertItemAsync(It.IsAny<UserSettings>(), It.IsAny<PartitionKey?>(), null, default))
            .ReturnsAsync((UserSettings s, PartitionKey? _, ItemRequestOptions? _, CancellationToken _) => CosmosTestHelpers.ItemResponse(s));

        var result = await _sut.UpdateNotificationsEnabledAsync(UserId, false, CancellationToken.None);

        Assert.False(result.NotificationsEnabled);
        Assert.Equal(4, result.Version);
    }

    [Fact]
    public async Task UpdateShowNotificationsEnabledAsync_ClearsOverrideWhenValueIsNull()
    {
        const string showId = "show-1";
        var id = ShowSettings.BuildId(UserId, showId);
        var existing = new ShowSettings(id, UserId, showId, UnlistenedEpisodeCount.Ten, Version: 2, NotificationsEnabled: false);
        _settingsContainer
            .Setup(c => c.ReadItemAsync<ShowSettings>(id, It.IsAny<PartitionKey>(), null, default))
            .ReturnsAsync(CosmosTestHelpers.ItemResponse(existing));
        _settingsContainer
            .Setup(c => c.UpsertItemAsync(It.IsAny<ShowSettings>(), It.IsAny<PartitionKey?>(), null, default))
            .ReturnsAsync((ShowSettings s, PartitionKey? _, ItemRequestOptions? _, CancellationToken _) => CosmosTestHelpers.ItemResponse(s));

        var result = await _sut.UpdateShowNotificationsEnabledAsync(UserId, showId, null, CancellationToken.None);

        Assert.Null(result.NotificationsEnabled);
    }

    [Fact]
    public async Task GetEffectiveNotificationsEnabledAsync_ReturnsShowOverrideWhenSet()
    {
        const string showId = "show-1";
        var showSettingsId = ShowSettings.BuildId(UserId, showId);
        var showSettings = new ShowSettings(showSettingsId, UserId, showId, null, Version: 2, NotificationsEnabled: false);
        _settingsContainer
            .Setup(c => c.ReadItemAsync<ShowSettings>(showSettingsId, It.IsAny<PartitionKey>(), null, default))
            .ReturnsAsync(CosmosTestHelpers.ItemResponse(showSettings));

        var result = await _sut.GetEffectiveNotificationsEnabledAsync(UserId, showId, CancellationToken.None);

        Assert.False(result);
        _settingsContainer.Verify(
            c => c.ReadItemAsync<UserSettings>(It.IsAny<string>(), It.IsAny<PartitionKey>(), null, default), Times.Never);
    }

    [Fact]
    public async Task GetEffectiveNotificationsEnabledAsync_FallsBackToUserSettingsWhenNoOverride()
    {
        const string showId = "show-1";
        var showSettingsId = ShowSettings.BuildId(UserId, showId);
        _settingsContainer
            .Setup(c => c.ReadItemAsync<ShowSettings>(showSettingsId, It.IsAny<PartitionKey>(), null, default))
            .ThrowsAsync(CosmosTestHelpers.NotFound());
        var userSettings = new UserSettings(
            UserId, UnlistenedEpisodeCount.Five, Version: 1, AutoArchiveRule.Never, NotificationsEnabled: false);
        _settingsContainer
            .Setup(c => c.ReadItemAsync<UserSettings>(UserId, It.IsAny<PartitionKey>(), null, default))
            .ReturnsAsync(CosmosTestHelpers.ItemResponse(userSettings));

        var result = await _sut.GetEffectiveNotificationsEnabledAsync(UserId, showId, CancellationToken.None);

        Assert.False(result);
    }

    private static UserSettingsChange MakeChange(
        DateTimeOffset updatedAt,
        float playbackSpeed = 1.0f,
        bool? notificationsEnabled = true,
        int? sleepTimerDefaultDurationMinutes = null,
        SubscriptionSortOrder? subscriptionSortOrder = SubscriptionSortOrder.Title,
        IReadOnlyList<string>? subscriptionManualOrder = null,
        bool? hideCaughtUpShows = false,
        bool? autoAddNewEpisodesToUpNext = false,
        UpNextInsertPosition? upNextInsertPosition = UpNextInsertPosition.Bottom,
        IReadOnlyList<EpisodeSwipeAction>? leadingSwipeActions = null,
        IReadOnlyList<EpisodeSwipeAction>? trailingSwipeActions = null) =>
        new(
            UnlistenedEpisodeCount.Five, AutoArchiveRule.Never, 0, 0, playbackSpeed, AutoDeleteRule.Never, 7, false, false,
            notificationsEnabled, sleepTimerDefaultDurationMinutes, subscriptionSortOrder, subscriptionManualOrder,
            hideCaughtUpShows, autoAddNewEpisodesToUpNext, upNextInsertPosition, leadingSwipeActions, trailingSwipeActions,
            updatedAt);

    [Fact]
    public async Task SyncAsync_FastPathReturnsEmptyWhenHashMatchesAndNoChanges()
    {
        var stored = new UserSettings(UserId, UnlistenedEpisodeCount.Five, Version: 3, UpdatedAt: DateTimeOffset.UtcNow.AddDays(-2));
        _settingsContainer
            .Setup(c => c.ReadItemAsync<UserSettings>(UserId, It.IsAny<PartitionKey>(), null, default))
            .ReturnsAsync(CosmosTestHelpers.ItemResponse(stored));
        var currentHash = SyncSummary.FromRecords<UserSettings>([stored]).Hash;

        var result = await _sut.SyncAsync(
            UserId, "device-a", DateTimeOffset.UtcNow.AddDays(-1), currentHash, [], CancellationToken.None);

        Assert.Empty(result.ServerChanges);
        Assert.Equal(currentHash, result.Hash);
        _settingsContainer.Verify(
            c => c.UpsertItemAsync(It.IsAny<UserSettings>(), It.IsAny<PartitionKey?>(), It.IsAny<ItemRequestOptions>(), default),
            Times.Never);
    }

    [Fact]
    public async Task SyncAsync_AcceptsChangeNewerThanStoredAndExcludesItFromDelta()
    {
        var lastSyncedAt = DateTimeOffset.UtcNow.AddHours(-2);
        var stored = new UserSettings(UserId, UnlistenedEpisodeCount.Five, Version: 3, UpdatedAt: DateTimeOffset.UtcNow.AddHours(-1));
        _settingsContainer
            .Setup(c => c.ReadItemAsync<UserSettings>(UserId, It.IsAny<PartitionKey>(), null, default))
            .ReturnsAsync(CosmosTestHelpers.ItemResponse(stored));
        _settingsContainer
            .Setup(c => c.UpsertItemAsync(It.IsAny<UserSettings>(), It.IsAny<PartitionKey?>(), It.IsAny<ItemRequestOptions>(), default))
            .ReturnsAsync((UserSettings s, PartitionKey? _, ItemRequestOptions? _, CancellationToken _) => CosmosTestHelpers.ItemResponse(s));

        var change = MakeChange(DateTimeOffset.UtcNow, playbackSpeed: 1.5f);
        var result = await _sut.SyncAsync(UserId, "device-a", lastSyncedAt, "stale-hash", [change], CancellationToken.None);

        Assert.Empty(result.ServerChanges);
        _settingsContainer.Verify(
            c => c.UpsertItemAsync(
                It.Is<UserSettings>(s => s.PlaybackSpeed == 1.5f && s.Version == 4 && s.DeviceId == "device-a"),
                It.IsAny<PartitionKey?>(), null, default),
            Times.Once);
    }

    [Fact]
    public async Task SyncAsync_DiscardsChangeOlderThanStoredAndReturnsStoredAsDelta()
    {
        var lastSyncedAt = DateTimeOffset.UtcNow.AddHours(-2);
        var stored = new UserSettings(UserId, UnlistenedEpisodeCount.Five, Version: 3, UpdatedAt: DateTimeOffset.UtcNow, PlaybackSpeed: 2.0f);
        _settingsContainer
            .Setup(c => c.ReadItemAsync<UserSettings>(UserId, It.IsAny<PartitionKey>(), null, default))
            .ReturnsAsync(CosmosTestHelpers.ItemResponse(stored));

        var staleChange = MakeChange(DateTimeOffset.UtcNow.AddHours(-1), playbackSpeed: 1.2f);
        var result = await _sut.SyncAsync(UserId, "device-a", lastSyncedAt, "stale-hash", [staleChange], CancellationToken.None);

        Assert.Single(result.ServerChanges);
        Assert.Equal(2.0f, result.ServerChanges[0].PlaybackSpeed);
        _settingsContainer.Verify(
            c => c.UpsertItemAsync(It.IsAny<UserSettings>(), It.IsAny<PartitionKey?>(), null, default), Times.Never);
    }

    [Fact]
    public void Deserialize_SyncPayloadMissingNotificationsEnabled_BindsToNullNotFalse()
    {
        // POST /api/sync/settings bodies are bound via minimal-API's default System.Text.Json,
        // not the Newtonsoft.Json used for Cosmos documents. An existing client (before #219 adds
        // this field to the iOS DTO) omits "notificationsEnabled" entirely; NotificationsEnabled
        // must come back null here, not false — a non-nullable bool would silently bind to false
        // and SyncAsync would clobber every user's actual preference on their next settings sync.
        var legacyJson = """{"unlistenedEpisodeCount":5,"autoArchiveRule":0,"autoSkipIntroSeconds":0,"autoSkipOutroSeconds":0,"playbackSpeed":1.0,"autoDeleteRule":0,"autoDeleteAfterDays":7,"autoDownloadNewEpisodes":false,"smartSpeed":false,"updatedAt":"2026-01-01T00:00:00Z"}""";

        var deserialized = System.Text.Json.JsonSerializer.Deserialize<UserSettingsChange>(
            legacyJson, new System.Text.Json.JsonSerializerOptions { PropertyNameCaseInsensitive = true });

        Assert.NotNull(deserialized);
        Assert.Null(deserialized.NotificationsEnabled);
    }

    [Fact]
    public async Task SyncAsync_PreservesStoredNotificationsEnabledWhenChangeOmitsIt()
    {
        var lastSyncedAt = DateTimeOffset.UtcNow.AddHours(-2);
        var stored = new UserSettings(
            UserId, UnlistenedEpisodeCount.Five, Version: 3, UpdatedAt: DateTimeOffset.UtcNow.AddHours(-1), NotificationsEnabled: false);
        _settingsContainer
            .Setup(c => c.ReadItemAsync<UserSettings>(UserId, It.IsAny<PartitionKey>(), null, default))
            .ReturnsAsync(CosmosTestHelpers.ItemResponse(stored));
        _settingsContainer
            .Setup(c => c.UpsertItemAsync(It.IsAny<UserSettings>(), It.IsAny<PartitionKey?>(), null, default))
            .ReturnsAsync((UserSettings s, PartitionKey? _, ItemRequestOptions? _, CancellationToken _) => CosmosTestHelpers.ItemResponse(s));

        // notificationsEnabled: null simulates a client that doesn't send this field yet.
        var change = MakeChange(DateTimeOffset.UtcNow, notificationsEnabled: null);
        await _sut.SyncAsync(UserId, "device-a", lastSyncedAt, "stale-hash", [change], CancellationToken.None);

        _settingsContainer.Verify(
            c => c.UpsertItemAsync(
                It.Is<UserSettings>(s => s.NotificationsEnabled == false),
                It.IsAny<PartitionKey?>(), null, default),
            Times.Once);
    }

    [Fact]
    public void Deserialize_LegacyDocumentMissingNotificationsEnabled_DefaultsToTrue()
    {
        // A UserSettings document written before NotificationsEnabled existed has no
        // "notificationsEnabled" property at all. Without DefaultValueHandling.Populate on that
        // property, Newtonsoft would fall back to bool's CLR default (false) instead of the
        // constructor's `= true` default, silently opting pre-existing users out.
        var legacyJson = $$"""
            {"id":"{{UserId}}","unlistenedEpisodeCount":5,"version":1,"updatedAt":"2026-01-01T00:00:00Z"}
            """;

        var deserialized = JsonConvert.DeserializeObject<UserSettings>(legacyJson);

        Assert.NotNull(deserialized);
        Assert.True(deserialized.NotificationsEnabled);
    }

    [Fact]
    public void Deserialize_LegacyDocumentMissingSleepTimerDefaultDurationMinutes_DefaultsToNull()
    {
        // A UserSettings document written before this field existed has no
        // "sleepTimerDefaultDurationMinutes" property. Unlike NotificationsEnabled, null is
        // already the field's declared default, so no DefaultValueHandling.Populate is needed —
        // this test just guards against a future regression that adds one incorrectly.
        var legacyJson = $$"""
            {"id":"{{UserId}}","unlistenedEpisodeCount":5,"version":1,"updatedAt":"2026-01-01T00:00:00Z"}
            """;

        var deserialized = JsonConvert.DeserializeObject<UserSettings>(legacyJson);

        Assert.NotNull(deserialized);
        Assert.Null(deserialized.SleepTimerDefaultDurationMinutes);
    }

    [Fact]
    public void CreateDefault_SleepTimerDefaultDurationMinutesIsNull()
    {
        var defaults = UserSettings.CreateDefault(UserId);

        Assert.Null(defaults.SleepTimerDefaultDurationMinutes);
    }

    [Fact]
    public async Task UpdateSleepTimerDefaultDurationAsync_IncrementsVersionOfExistingDocument()
    {
        var existing = new UserSettings(
            UserId, UnlistenedEpisodeCount.Five, Version: 3,
            AutoArchiveRule.Never, SleepTimerDefaultDurationMinutes: null);
        _settingsContainer
            .Setup(c => c.ReadItemAsync<UserSettings>(UserId, It.IsAny<PartitionKey>(), null, default))
            .ReturnsAsync(CosmosTestHelpers.ItemResponse(existing));
        _settingsContainer
            .Setup(c => c.UpsertItemAsync(It.IsAny<UserSettings>(), It.IsAny<PartitionKey?>(), It.IsAny<ItemRequestOptions>(), default))
            .ReturnsAsync((UserSettings s, PartitionKey? _, ItemRequestOptions? _, CancellationToken _) => CosmosTestHelpers.ItemResponse(s));

        var result = await _sut.UpdateSleepTimerDefaultDurationAsync(UserId, 30, CancellationToken.None);

        Assert.Equal(30, result.SleepTimerDefaultDurationMinutes);
        Assert.Equal(4, result.Version);
    }

    [Fact]
    public async Task SyncAsync_AcceptsSleepTimerDefaultDurationMinutesWhenChangeSendsIt()
    {
        var lastSyncedAt = DateTimeOffset.UtcNow.AddHours(-2);
        var stored = new UserSettings(
            UserId, UnlistenedEpisodeCount.Five, Version: 3, UpdatedAt: DateTimeOffset.UtcNow.AddHours(-1),
            SleepTimerDefaultDurationMinutes: null);
        _settingsContainer
            .Setup(c => c.ReadItemAsync<UserSettings>(UserId, It.IsAny<PartitionKey>(), null, default))
            .ReturnsAsync(CosmosTestHelpers.ItemResponse(stored));
        _settingsContainer
            .Setup(c => c.UpsertItemAsync(It.IsAny<UserSettings>(), It.IsAny<PartitionKey?>(), null, default))
            .ReturnsAsync((UserSettings s, PartitionKey? _, ItemRequestOptions? _, CancellationToken _) => CosmosTestHelpers.ItemResponse(s));

        var change = MakeChange(DateTimeOffset.UtcNow, sleepTimerDefaultDurationMinutes: 15);
        await _sut.SyncAsync(UserId, "device-a", lastSyncedAt, "stale-hash", [change], CancellationToken.None);

        _settingsContainer.Verify(
            c => c.UpsertItemAsync(
                It.Is<UserSettings>(s => s.SleepTimerDefaultDurationMinutes == 15),
                It.IsAny<PartitionKey?>(), null, default),
            Times.Once);
    }

    [Fact]
    public async Task SyncAsync_PreservesStoredSleepTimerDefaultDurationMinutesWhenChangeOmitsIt()
    {
        var lastSyncedAt = DateTimeOffset.UtcNow.AddHours(-2);
        var stored = new UserSettings(
            UserId, UnlistenedEpisodeCount.Five, Version: 3, UpdatedAt: DateTimeOffset.UtcNow.AddHours(-1),
            SleepTimerDefaultDurationMinutes: 45);
        _settingsContainer
            .Setup(c => c.ReadItemAsync<UserSettings>(UserId, It.IsAny<PartitionKey>(), null, default))
            .ReturnsAsync(CosmosTestHelpers.ItemResponse(stored));
        _settingsContainer
            .Setup(c => c.UpsertItemAsync(It.IsAny<UserSettings>(), It.IsAny<PartitionKey?>(), null, default))
            .ReturnsAsync((UserSettings s, PartitionKey? _, ItemRequestOptions? _, CancellationToken _) => CosmosTestHelpers.ItemResponse(s));

        // sleepTimerDefaultDurationMinutes: null simulates a client that doesn't send this field yet.
        var change = MakeChange(DateTimeOffset.UtcNow, sleepTimerDefaultDurationMinutes: null);
        await _sut.SyncAsync(UserId, "device-a", lastSyncedAt, "stale-hash", [change], CancellationToken.None);

        _settingsContainer.Verify(
            c => c.UpsertItemAsync(
                It.Is<UserSettings>(s => s.SleepTimerDefaultDurationMinutes == 45),
                It.IsAny<PartitionKey?>(), null, default),
            Times.Once);
    }
}
