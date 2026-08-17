using Kuulla.Api.Services;
using Microsoft.Azure.Cosmos;
using Moq;
using User = Kuulla.Api.Models.User;

namespace Kuulla.Api.Tests;

public class UserServiceTests
{
    private const string Subject = "google-sub-1";

    private readonly Mock<Container> _usersContainer = new();
    private readonly UserService _sut;

    public UserServiceTests()
    {
        _sut = new UserService(_usersContainer.Object);
    }

    [Fact]
    public async Task GetOrCreateUserAsync_CreatesNewUserWhenNoneExists()
    {
        _usersContainer
            .Setup(c => c.ReadItemAsync<User>(Subject, It.IsAny<PartitionKey>(), null, default))
            .ThrowsAsync(CosmosTestHelpers.NotFound());
        _usersContainer
            .Setup(c => c.CreateItemAsync(It.IsAny<User>(), It.IsAny<PartitionKey?>(), null, default))
            .ReturnsAsync((User u, PartitionKey? _, ItemRequestOptions? _, CancellationToken _) => CosmosTestHelpers.ItemResponse(u));

        var result = await _sut.GetOrCreateUserAsync(Subject, "new@example.com", "New User", "https://pic.example/p.png", CancellationToken.None);

        Assert.Equal(Subject, result.Id);
        Assert.Equal("new@example.com", result.Email);
        Assert.Equal("New User", result.Name);
        Assert.Equal(result.CreatedAt, result.LastLoginAt);
        _usersContainer.Verify(c => c.UpsertItemAsync(It.IsAny<User>(), It.IsAny<PartitionKey?>(), null, default), Times.Never);
    }

    [Fact]
    public async Task GetOrCreateUserAsync_UpdatesProfileFieldsAndTouchesLastLoginForExistingUser()
    {
        var createdAt = DateTimeOffset.UtcNow.AddDays(-30);
        var existing = new User(Subject, "old@example.com", "Old Name", null, createdAt, createdAt.AddDays(1));
        _usersContainer
            .Setup(c => c.ReadItemAsync<User>(Subject, It.IsAny<PartitionKey>(), null, default))
            .ReturnsAsync(CosmosTestHelpers.ItemResponse(existing));
        _usersContainer
            .Setup(c => c.UpsertItemAsync(It.IsAny<User>(), It.IsAny<PartitionKey?>(), null, default))
            .ReturnsAsync((User u, PartitionKey? _, ItemRequestOptions? _, CancellationToken _) => CosmosTestHelpers.ItemResponse(u));

        var result = await _sut.GetOrCreateUserAsync(Subject, "new@example.com", "New Name", "https://pic.example/p.png", CancellationToken.None);

        Assert.Equal("new@example.com", result.Email);
        Assert.Equal("New Name", result.Name);
        Assert.Equal("https://pic.example/p.png", result.PictureUrl);
        Assert.Equal(createdAt, result.CreatedAt);
        Assert.True(result.LastLoginAt > existing.LastLoginAt);
        _usersContainer.Verify(c => c.CreateItemAsync(It.IsAny<User>(), It.IsAny<PartitionKey?>(), null, default), Times.Never);
    }

    [Fact]
    public async Task GetOrCreateUserAsync_FallsBackToTouchingLoginWhenConcurrentCreateLosesRace()
    {
        var createdAt = DateTimeOffset.UtcNow.AddMinutes(-1);
        var winner = new User(Subject, "winner@example.com", "Winner", null, createdAt, createdAt);

        _usersContainer
            .SetupSequence(c => c.ReadItemAsync<User>(Subject, It.IsAny<PartitionKey>(), null, default))
            .ThrowsAsync(CosmosTestHelpers.NotFound())
            .ReturnsAsync(CosmosTestHelpers.ItemResponse(winner));
        _usersContainer
            .Setup(c => c.CreateItemAsync(It.IsAny<User>(), It.IsAny<PartitionKey?>(), null, default))
            .ThrowsAsync(CosmosTestHelpers.Conflict());
        _usersContainer
            .Setup(c => c.UpsertItemAsync(It.IsAny<User>(), It.IsAny<PartitionKey?>(), null, default))
            .ReturnsAsync((User u, PartitionKey? _, ItemRequestOptions? _, CancellationToken _) => CosmosTestHelpers.ItemResponse(u));

        var result = await _sut.GetOrCreateUserAsync(Subject, "me@example.com", "Me", null, CancellationToken.None);

        Assert.Equal("me@example.com", result.Email);
        Assert.Equal(createdAt, result.CreatedAt);
    }
}
