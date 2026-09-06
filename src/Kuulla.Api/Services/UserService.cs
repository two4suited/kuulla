using System.Net;
using Microsoft.Azure.Cosmos;
using User = Kuulla.Core.Models.User;

namespace Kuulla.Api.Services;

public class UserService(Container usersContainer) : IUserService
{
    public async Task<User> GetOrCreateUserAsync(
        string googleSubject,
        string email,
        string? name,
        string? pictureUrl,
        CancellationToken cancellationToken)
    {
        var partitionKey = new PartitionKey(googleSubject);

        try
        {
            var existing = await usersContainer.ReadItemAsync<User>(googleSubject, partitionKey, cancellationToken: cancellationToken);
            return await TouchLoginAsync(existing.Resource, email, name, pictureUrl, partitionKey, cancellationToken);
        }
        catch (CosmosException ex) when (ex.StatusCode == HttpStatusCode.NotFound)
        {
            var now = DateTimeOffset.UtcNow;
            var newUser = new User(googleSubject, email, name, pictureUrl, now, now, now);

            try
            {
                await usersContainer.CreateItemAsync(newUser, partitionKey, cancellationToken: cancellationToken);
                return newUser;
            }
            catch (CosmosException createEx) when (createEx.StatusCode == HttpStatusCode.Conflict)
            {
                // Another concurrent first-login request won the race and created the item first.
                var existing = await usersContainer.ReadItemAsync<User>(googleSubject, partitionKey, cancellationToken: cancellationToken);
                return await TouchLoginAsync(existing.Resource, email, name, pictureUrl, partitionKey, cancellationToken);
            }
        }
    }

    private async Task<User> TouchLoginAsync(
        User existing,
        string email,
        string? name,
        string? pictureUrl,
        PartitionKey partitionKey,
        CancellationToken cancellationToken)
    {
        var now = DateTimeOffset.UtcNow;
        var updated = existing with
        {
            Email = email,
            Name = name,
            PictureUrl = pictureUrl,
            LastLoginAt = now,
            UpdatedAt = now,
        };
        await usersContainer.UpsertItemAsync(updated, partitionKey, cancellationToken: cancellationToken);
        return updated;
    }
}
