using System.Net;
using Microsoft.Azure.Cosmos;
using User = Kuulla.Api.Models.User;

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
            var updated = existing.Resource with
            {
                Email = email,
                Name = name,
                PictureUrl = pictureUrl,
                LastLoginAt = DateTimeOffset.UtcNow,
            };
            await usersContainer.UpsertItemAsync(updated, partitionKey, cancellationToken: cancellationToken);
            return updated;
        }
        catch (CosmosException ex) when (ex.StatusCode == HttpStatusCode.NotFound)
        {
            var now = DateTimeOffset.UtcNow;
            var newUser = new User(googleSubject, email, name, pictureUrl, now, now);
            await usersContainer.CreateItemAsync(newUser, partitionKey, cancellationToken: cancellationToken);
            return newUser;
        }
    }
}
